import Accelerate
import AVFoundation
import CoreML
import Observation
import os

/// «Голос», like Apple Music Sing: an on-device model (UVR MDX-Net) splits the current track into
/// vocals and the rest, ahead of the playhead, and the audio tap subtracts as much of the vocal
/// as the slider asks for. The vocal is kept as a time-domain stem aligned to the stream's samples.
@MainActor
@Observable
final class VocalSeparator {
    static let shared = VocalSeparator()

    enum Phase: Equatable {
        case idle
        case preparing
        case working(Double)
        case ready
        case failed(String)
    }

    /// 1 = original vocals, 0 = karaoke (no vocals).
    var level: Double = 1 {
        didSet {
            VocalStems.setGain(Float(1 - level))
            if level < 1 { startIfNeeded() }
        }
    }
    private(set) var phase: Phase = .idle

    private var stream: StreamSource?
    private var jobStream: StreamSource?
    private var job: Task<Void, Never>?

    var isActive: Bool { level < 0.999 }

    /// Called whenever the audible stream changes.
    func streamChanged(_ source: StreamSource?) {
        guard source != stream else { return }
        stream = source
        if jobStream != source {
            job?.cancel()
            job = nil
            jobStream = nil
            VocalStems.set(nil)
            phase = .idle
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard isActive, let stream, jobStream != stream else { return }
        jobStream = stream
        phase = .preparing
        job = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await SeparationJob.run(source: stream) { progress in
                    Task { @MainActor in
                        guard let self, self.jobStream == stream else { return }
                        self.phase = progress >= 1 ? .ready : .working(progress)
                    }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    guard let self, self.jobStream == stream else { return }
                    self.phase = .failed(error.localizedDescription)
                    self.jobStream = nil
                }
            }
        }
    }
}

/// The vocal stem being built for one stream. Written by the separation job past `processed`,
/// read by the audio tap below it, so the two never touch the same samples.
final class VocalStem: @unchecked Sendable {
    let key: Int
    let sampleRate: Double
    let channels: Int
    let capacity: Int
    let buffers: [UnsafeMutablePointer<Float16>]
    private let done = OSAllocatedUnfairLock(initialState: 0)

    init(key: Int, sampleRate: Double, channels: Int, capacity: Int) {
        self.key = key
        self.sampleRate = sampleRate
        self.channels = channels
        self.capacity = capacity
        buffers = (0..<channels).map { _ in
            let pointer = UnsafeMutablePointer<Float16>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
    }

    deinit { buffers.forEach { $0.deallocate() } }

    /// Samples below this index are final.
    var processed: Int { done.withLock { $0 } }
    func markProcessed(_ value: Int) { done.withLock { $0 = min(value, capacity) } }
}

/// What the audio tap reads: the current stem and how much of it to remove.
enum VocalStems {
    private static let state = OSAllocatedUnfairLock<(stem: VocalStem?, gain: Float)>(uncheckedState: (nil, 0))

    static func key(for url: URL) -> Int { url.absoluteString.hashValue }

    static func set(_ stem: VocalStem?) { state.withLock { $0.stem = stem } }
    static func setGain(_ gain: Float) { state.withLock { $0.gain = gain } }

    /// The stem for this stream and the removal amount, or nil when there is nothing to do.
    static func current(for key: Int) -> (stem: VocalStem, gain: Float)? {
        state.withLock { value in
            guard let stem = value.stem, stem.key == key, value.gain > 0.001 else { return nil }
            return (stem, value.gain)
        }
    }
}

enum SeparationError: LocalizedError {
    case noModel, noAudio, unreadable

    var errorDescription: String? {
        switch self {
        case .noModel: "модель не загрузилась"
        case .noAudio: "в файле нет звука"
        case .unreadable: "не удалось прочитать трек"
        }
    }
}

/// Decodes the stream, runs the model chunk by chunk and writes the vocal stem.
private enum SeparationJob {
    // UVR MDX-Net "Kim Vocal 2": n_fft 7680, hop 1024, the lowest 3072 bins, 256 frames per call.
    static let fftSize = 7680
    static let hop = 1024
    static let modelBins = 3072
    /// Model input length in STFT frames (fixed when the model was converted).
    static let frames = 256
    /// Frames dropped at each chunk edge so the model always has context on both sides.
    static let edge = 16
    /// UVR's per-model gain correction for the vocal estimate.
    static let compensate: Float = 1.009

    static func run(source: StreamSource, progress: @escaping @Sendable (Double) -> Void) async throws {
        let model = try await VocalModel.load()
        let file = try await localFile(for: source)
        try Task.checkCancellation()

        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SeparationError.noAudio }
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        else { throw SeparationError.unreadable }
        let sampleRate = asbd.mSampleRate
        let channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        let duration = try await asset.load(.duration).seconds
        let capacity = Int((duration.isFinite ? duration : 600) * sampleRate) + fftSize * 2

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SeparationError.unreadable }

        // The tap identifies its stream by the URL AVPlayer was given, not the decoded copy.
        let stem = VocalStem(key: VocalStems.key(for: source.url), sampleRate: sampleRate,
                             channels: channels, capacity: capacity)
        VocalStems.set(stem)

        let engine = try ChunkEngine(model: model, stem: stem)
        var pending = [[Float]](repeating: [], count: channels)
        var pendingStart = 0
        var chunkStart = 0
        var finished = false
        let chunkSamples = (frames - 1) * hop + fftSize

        while true {
            try Task.checkCancellation()
            // Decode until a whole chunk is available (or the file ends).
            while !finished, pendingStart + pending[0].count < chunkStart * hop + chunkSamples {
                guard let buffer = output.copyNextSampleBuffer() else {
                    finished = true
                    // Silence after the end so the last frames are complete.
                    for c in 0..<channels { pending[c].append(contentsOf: repeatElement(0, count: fftSize)) }
                    break
                }
                append(buffer, channels: Int(asbd.mChannelsPerFrame), to: &pending)
            }
            if reader.status == .failed { throw reader.error ?? SeparationError.unreadable }

            let available = (pendingStart + pending[0].count - chunkStart * hop - fftSize) / hop + 1
            let count = min(frames, available)
            guard count > 0 else { break }
            let isLast = finished && available <= frames
            let offset = chunkStart * hop - pendingStart
            let input = pending.map { Array($0[offset..<min($0.count, offset + (count - 1) * hop + fftSize)]) }

            let lo = chunkStart == 0 ? 0 : edge
            let hi = isLast ? count : frames - edge
            try engine.process(input: input, count: count, startFrame: chunkStart, keep: lo..<hi)
            stem.markProcessed(isLast ? capacity : (chunkStart + hi) * hop)
            progress(isLast ? 1 : min(0.99, Double((chunkStart + hi) * hop) / Double(capacity)))
            if isLast { break }

            // Next chunk starts `edge` frames before the first frame it will keep.
            chunkStart += hi - edge
            let drop = chunkStart * hop - pendingStart
            if drop > 0 {
                for c in 0..<channels { pending[c].removeFirst(min(drop, pending[c].count)) }
                pendingStart += drop
            }
        }
    }

    /// Appends an interleaved float sample buffer to the per-channel arrays.
    private static func append(_ buffer: CMSampleBuffer, channels sourceChannels: Int, to pending: inout [[Float]]) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        let stride = max(1, sourceChannels)
        let frameCount = samples.count / stride
        for c in 0..<pending.count {
            let source = min(c, stride - 1)
            pending[c].reserveCapacity(pending[c].count + frameCount)
            for i in 0..<frameCount { pending[c].append(samples[i * stride + source]) }
        }
    }

    /// A local copy of the stream: decrypted lossless files already are; others are downloaded.
    private static func localFile(for source: StreamSource) async throws -> URL {
        if source.url.isFileURL { return source.url }
        let codec = source.codec.lowercased()
        let ext = codec.contains("mp3") ? "mp3" : (codec.contains("flac") ? "flac" : "m4a")
        let dir = FileManager.default.temporaryDirectory.appending(path: "vocals", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: "\(VocalStems.key(for: source.url) & 0x7fff_ffff).\(ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        // Only the current track is kept around.
        for old in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        let (downloaded, _) = try await URLSession.shared.download(from: source.url)
        try FileManager.default.moveItem(at: downloaded, to: target)
        return target
    }

    /// STFT → model (vocal spectrum) → strengthened vocal mask → masked inverse STFT,
    /// overlap-added into the stem.
    private final class ChunkEngine {
        private static let half = SeparationJob.fftSize / 2
        // Mask shaping. The model's estimate is conservative, so for karaoke it is pushed up a bit
        // and allowed to linger after the voice so reverb and delay tails go with it.
        /// Over-subtraction: the vocal estimate counts this much more than it says.
        private static let overSubtract: Float = 1.12
        /// < 1 lifts uncertain (mid) mask values, where reverb and breathy parts sit.
        private static let lift: Float = 0.75
        /// How long the removal lingers after the voice (seconds, 1/e decay).
        private static let tailSeconds: Float = 0.35
        /// Share of the lingering mask that is applied.
        private static let tailAmount: Float = 0.75
        /// A bin whose level jumps by this factor starts a new note: its tail is dropped so a
        /// fresh instrument hit after a vocal phrase isn't carved out.
        private static let onsetRatio: Float = 1.6

        private let model: MLModel
        private let stem: VocalStem
        private let forward: vDSP.DFT<Float>
        private let inverse: vDSP.DFT<Float>
        /// vDSP's DFTs are unnormalised and differ from the textbook one by fixed factors;
        /// measured once instead of trusting constants.
        private let forwardScale: Float
        private let roundTripScale: Float
        private let window: [Float]
        /// Synthesis window already divided by the overlap sum of window², per position.
        private let synthesis: [Float]
        private let tailDecay: Float

        /// Packed spectra per channel and frame (vDSP layout: re[0] = DC, im[0] = Nyquist).
        private var real: [[Float]]
        private var imag: [[Float]]
        /// Mask carried between frames (and chunks) per channel and bin, and last frame's level.
        private var hold: [[Float]]
        private var lastLevel: [[Float]]
        private var even = [Float](repeating: 0, count: ChunkEngine.half)
        private var odd = [Float](repeating: 0, count: ChunkEngine.half)
        private var outRe = [Float](repeating: 0, count: ChunkEngine.half)
        private var outIm = [Float](repeating: 0, count: ChunkEngine.half)

        init(model: MLModel, stem: VocalStem) throws {
            let n = SeparationJob.fftSize
            guard let forward = vDSP.DFT(count: n, direction: .forward, transformType: .complexReal, ofType: Float.self),
                  let inverse = vDSP.DFT(count: n, direction: .inverse, transformType: .complexReal, ofType: Float.self)
            else { throw SeparationError.noModel }
            self.model = model
            self.stem = stem
            self.forward = forward
            self.inverse = inverse

            // Periodic Hann, as torch.hann_window(periodic=True) used in training.
            let hann = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n)) }
            let hop = SeparationJob.hop
            var overlap = [Float](repeating: 0, count: hop)
            for i in 0..<n { overlap[i % hop] += hann[i] * hann[i] }
            window = hann
            synthesis = (0..<n).map { hann[$0] / max(overlap[$0 % hop], 1e-6) }
            tailDecay = exp(-Float(hop) / (Float(stem.sampleRate) * Self.tailSeconds))

            // Calibrate: the DC bin of a known signal gives the forward factor, a round trip the rest.
            let probe = (0..<n).map { sin(Float($0) * 0.37) + 0.5 }
            let probeEven = stride(from: 0, to: n, by: 2).map { probe[$0] }
            let probeOdd = stride(from: 1, to: n, by: 2).map { probe[$0] }
            var re = [Float](repeating: 0, count: n / 2), im = re
            forward.transform(inputReal: probeEven, inputImaginary: probeOdd, outputReal: &re, outputImaginary: &im)
            forwardScale = re[0] / probe.reduce(0, +)
            var backEven = [Float](repeating: 0, count: n / 2), backOdd = backEven
            inverse.transform(inputReal: re, inputImaginary: im, outputReal: &backEven, outputImaginary: &backOdd)
            roundTripScale = (backEven.map(abs).reduce(0, +) + backOdd.map(abs).reduce(0, +)) / probe.map(abs).reduce(0, +)

            let size = SeparationJob.frames * Self.half
            real = [[Float]](repeating: [Float](repeating: 0, count: size), count: stem.channels)
            imag = real
            hold = [[Float]](repeating: [Float](repeating: 0, count: SeparationJob.modelBins), count: stem.channels)
            lastLevel = hold
        }

        func process(input: [[Float]], count: Int, startFrame: Int, keep: Range<Int>) throws {
            let n = SeparationJob.fftSize
            let half = Self.half
            let bins = SeparationJob.modelBins
            let frames = SeparationJob.frames
            let mix = try MLMultiArray(shape: [1, 4, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
            let mixPointer = mix.dataPointer.assumingMemoryBound(to: Float.self)
            let s = mix.strides.map(\.intValue)
            for i in 0..<mix.count { mixPointer[i] = 0 }

            // Forward STFT; the model wants the textbook spectrum, so vDSP's factor is divided out.
            for c in 0..<stem.channels {
                for f in 0..<count {
                    let start = f * SeparationJob.hop
                    for i in 0..<half {
                        let a = start + 2 * i, b = a + 1
                        even[i] = (a < input[c].count ? input[c][a] : 0) * window[2 * i]
                        odd[i] = (b < input[c].count ? input[c][b] : 0) * window[2 * i + 1]
                    }
                    forward.transform(inputReal: even, inputImaginary: odd, outputReal: &outRe, outputImaginary: &outIm)
                    let base = f * half
                    for b in 0..<half {
                        real[c][base + b] = outRe[b]
                        imag[c][base + b] = outIm[b]
                    }
                    for modelChannel in (stem.channels == 1 ? [0, 1] : [c]) {
                        let re = mixPointer + (2 * modelChannel) * s[1] + f * s[3]
                        let im = mixPointer + (2 * modelChannel + 1) * s[1] + f * s[3]
                        // UVR zeroes the three lowest bins before running the model.
                        for b in 3..<bins {
                            re[b * s[2]] = outRe[b] / forwardScale
                            im[b * s[2]] = outIm[b] / forwardScale
                        }
                    }
                }
            }

            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": mix]))
            guard let output = result.featureValue(for: "output")?.multiArrayValue else { throw SeparationError.noModel }
            let vocal = OutputReader(output)

            let scale = 1 / roundTripScale
            // Model output is in textbook units; bring it to vDSP's to compare with the mix.
            let vocalScale = SeparationJob.compensate * forwardScale
            for c in 0..<stem.channels {
                let buffer = stem.buffers[c]
                for f in keep {
                    let base = f * half
                    for b in 0..<half {
                        let mixRe = real[c][base + b]
                        let mixIm = b == 0 ? 0 : imag[c][base + b]
                        let level = (mixRe * mixRe + mixIm * mixIm).squareRoot()
                        var mask: Float = 0
                        if b < bins {
                            let vRe = vocal(2 * c, b, f) * vocalScale
                            let vIm = vocal(2 * c + 1, b, f) * vocalScale
                            let estimate = min(1, (vRe * vRe + vIm * vIm).squareRoot() / (level + 1e-9))
                            mask = shape(estimate, level: level, channel: c, bin: b)
                        }
                        outRe[b] = mixRe * mask
                        outIm[b] = b == 0 ? 0 : mixIm * mask
                    }
                    inverse.transform(inputReal: outRe, inputImaginary: outIm, outputReal: &even, outputImaginary: &odd)
                    let origin = (startFrame + f) * SeparationJob.hop
                    for i in 0..<n {
                        let index = origin + i
                        guard index < stem.capacity else { break }
                        let sample = (i % 2 == 0 ? even[i / 2] : odd[i / 2]) * scale * synthesis[i]
                        buffer[index] = Float16(Float(buffer[index]) + sample)
                    }
                }
            }
        }

        /// Turns the model's vocal share of a bin into the removal mask: over-subtract, lift the
        /// uncertain middle, then let it linger after the voice unless a new note starts.
        private func shape(_ estimate: Float, level: Float, channel c: Int, bin b: Int) -> Float {
            let pushed = min(1, estimate * Self.overSubtract)
            let lifted = pow(pushed, Self.lift)
            let onset = level > lastLevel[c][b] * Self.onsetRatio + 1e-6
            lastLevel[c][b] = level
            let carried = onset ? 0 : hold[c][b] * tailDecay
            hold[c][b] = max(lifted, carried)
            return max(lifted, carried * Self.tailAmount)
        }
    }

    /// Reads the model output (float16 or float32, any strides).
    private struct OutputReader {
        let array: MLMultiArray
        let strides: [Int]

        init(_ array: MLMultiArray) {
            self.array = array
            strides = array.strides.map(\.intValue)
        }

        func callAsFunction(_ c: Int, _ b: Int, _ f: Int) -> Float {
            let index = c * strides[1] + b * strides[2] + f * strides[3]
            return switch array.dataType {
            case .float16: Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[index])
            case .double: Float(array.dataPointer.assumingMemoryBound(to: Double.self)[index])
            default: array.dataPointer.assumingMemoryBound(to: Float.self)[index]
            }
        }
    }
}

/// Compiles the bundled model on first use and keeps the compiled copy in Application Support.
enum VocalModel {
    private static let cached = OSAllocatedUnfairLock<MLModel?>(uncheckedState: nil)
    /// Bump when the bundled model changes so the compiled copy is rebuilt.
    private static let version = 2

    static func load() async throws -> MLModel {
        if let model = cached.withLock({ $0 }) { return model }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let compiled = support.appending(path: "VocalModel-v\(version).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            guard let bundled = Bundle.module.url(forResource: "VocalModel", withExtension: nil) else {
                throw SeparationError.noModel
            }
            // Core ML only compiles a folder that is named like a package.
            let package = FileManager.default.temporaryDirectory.appending(path: "VocalModel.mlpackage")
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.copyItem(at: bundled, to: package)
            let output = try await MLModel.compileModel(at: package)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: output, to: compiled)
            try? FileManager.default.removeItem(at: package)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: compiled, configuration: configuration)
        cached.withLock { $0 = model }
        return model
    }
}
