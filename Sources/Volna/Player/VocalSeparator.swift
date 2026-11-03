import Accelerate
import AVFoundation
import CoreML
import Observation
import os

/// «Голос», like Apple Music Sing: an on-device model (Open-Unmix) splits the current track into
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
    static let fftSize = 4096
    static let hop = 1024
    static let bins = fftSize / 2 + 1
    /// Model input length in STFT frames (fixed when the model was converted).
    static let frames = 256
    /// Frames dropped at each chunk edge so the recurrent model always has context.
    static let edge = 16
    private static let log2n = vDSP_Length(12)

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

        let engine = ChunkEngine(model: model, stem: stem)
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

    /// STFT → model mask → masked inverse STFT, overlap-added into the stem.
    private final class ChunkEngine {
        private let model: MLModel
        private let stem: VocalStem
        private let fft = vDSP.FFT(log2n: SeparationJob.log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                         count: SeparationJob.fftSize, isHalfWindow: false)
        /// Packed spectra per channel and frame: real and imaginary halves of `fftSize / 2`.
        private var real: [[Float]]
        private var imag: [[Float]]
        private var frame = [Float](repeating: 0, count: SeparationJob.fftSize)

        init(model: MLModel, stem: VocalStem) {
            self.model = model
            self.stem = stem
            let size = SeparationJob.frames * SeparationJob.fftSize / 2
            real = [[Float]](repeating: [Float](repeating: 0, count: size), count: stem.channels)
            imag = real
        }

        func process(input: [[Float]], count: Int, startFrame: Int, keep: Range<Int>) throws {
            let half = SeparationJob.fftSize / 2
            let bins = SeparationJob.bins
            let frames = SeparationJob.frames
            let mix = try MLMultiArray(shape: [1, 2, NSNumber(value: bins), NSNumber(value: frames)], dataType: .float32)
            let mixPointer = mix.dataPointer.assumingMemoryBound(to: Float.self)
            let s = mix.strides.map(\.intValue)
            mixPointer.initialize(repeating: 0, count: mix.count)

            // Forward STFT and magnitudes (vDSP's real FFT is scaled by 2; halve for true |X|).
            for c in 0..<stem.channels {
                for f in 0..<count {
                    let start = f * SeparationJob.hop
                    for i in 0..<SeparationJob.fftSize {
                        let index = start + i
                        frame[i] = (index < input[c].count ? input[c][index] : 0) * window[i]
                    }
                    let base = f * half
                    real[c].withUnsafeMutableBufferPointer { re in
                        imag[c].withUnsafeMutableBufferPointer { im in
                            var split = DSPSplitComplex(realp: re.baseAddress! + base, imagp: im.baseAddress! + base)
                            frame.withUnsafeBufferPointer { buf in
                                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                    vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                                }
                            }
                            fft.forward(input: split, output: &split)
                        }
                    }
                    for modelChannel in (stem.channels == 1 ? [0, 1] : [c]) {
                        let row = mixPointer + modelChannel * s[1] + f * s[3]
                        row[0] = abs(real[c][base]) / 2
                        row[(bins - 1) * s[2]] = abs(imag[c][base]) / 2
                        for b in 1..<half {
                            let re = real[c][base + b], im = imag[c][base + b]
                            row[b * s[2]] = (re * re + im * im).squareRoot() / 2
                        }
                    }
                }
            }

            let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mix": mix]))
            guard let mask = result.featureValue(for: "mask")?.multiArrayValue else { throw SeparationError.noModel }
            let read = MaskReader(mask)

            // Masked inverse STFT; WOLA with a Hann window at 75 % overlap sums to 1.5.
            let scale = 1 / (2 * Float(SeparationJob.fftSize) * 1.5)
            for c in 0..<stem.channels {
                let buffer = stem.buffers[c]
                for f in keep {
                    let base = f * half
                    var re = Array(real[c][base..<base + half])
                    var im = Array(imag[c][base..<base + half])
                    re[0] *= read(c, 0, f)
                    im[0] *= read(c, bins - 1, f)
                    for b in 1..<half {
                        let m = read(c, b, f)
                        re[b] *= m
                        im[b] *= m
                    }
                    re.withUnsafeMutableBufferPointer { rp in
                        im.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            fft.inverse(input: split, output: &split)
                            frame.withUnsafeMutableBufferPointer { buf in
                                buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                    vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                                }
                            }
                        }
                    }
                    let origin = (startFrame + f) * SeparationJob.hop
                    for i in 0..<SeparationJob.fftSize {
                        let n = origin + i
                        guard n < stem.capacity else { break }
                        buffer[n] = Float16(Float(buffer[n]) + frame[i] * window[i] * scale)
                    }
                }
            }
        }
    }

    /// Reads the model's mask (float16 or float32, any strides) clamped to 0…1.
    private struct MaskReader {
        let array: MLMultiArray
        let strides: [Int]
        let channels: Int

        init(_ array: MLMultiArray) {
            self.array = array
            strides = array.strides.map(\.intValue)
            channels = array.shape[1].intValue
        }

        func callAsFunction(_ c: Int, _ b: Int, _ f: Int) -> Float {
            let index = min(c, channels - 1) * strides[1] + b * strides[2] + f * strides[3]
            let value: Float = switch array.dataType {
            case .float16: Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[index])
            case .double: Float(array.dataPointer.assumingMemoryBound(to: Double.self)[index])
            default: array.dataPointer.assumingMemoryBound(to: Float.self)[index]
            }
            return min(max(value, 0), 1)
        }
    }
}

/// Compiles the bundled model on first use and keeps the compiled copy in Application Support.
enum VocalModel {
    private static let cached = OSAllocatedUnfairLock<MLModel?>(uncheckedState: nil)
    /// Bump when the bundled model changes so the compiled copy is rebuilt.
    private static let version = 1

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
