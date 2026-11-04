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
        // Utility priority: the model must not starve AVPlayer's own audio threads.
        job = Task.detached(priority: .utility) { [weak self] in
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

/// One stream, decoded by us (`mix`) and its separated vocal (`vocal`). Written by the separation
/// job past `processed`, read by the audio tap below it, so the two never touch the same samples.
///
/// The tap doesn't subtract the vocal from what AVPlayer hands it: the two decoders can disagree
/// by a few milliseconds (encoder delay), and subtracting a shifted copy sounds like added reverb.
/// Instead it plays our own `mix − vocal`, which is consistent by construction, at an offset
/// measured once by cross-correlating what the tap actually plays against our decode.
final class VocalStem: @unchecked Sendable {
    let key: Int
    let sampleRate: Double
    let channels: Int
    let capacity: Int
    let mix: [UnsafeMutablePointer<Float16>]
    let vocal: [UnsafeMutablePointer<Float16>]
    private let progress = OSAllocatedUnfairLock(initialState: (decoded: 0, processed: 0))
    private let alignment = OSAllocatedUnfairLock<Alignment>(uncheckedState: Alignment())

    struct Alignment {
        var probe: (start: Int, samples: [Float])?
        /// Our decode index = tap index + offset.
        var offset: Int?
        var failures = 0
        /// Correlation of the accepted match, for the on-screen diagnostics.
        var score: Float = 0
        /// Times the tap had to jump its read position (seeks, or a timing problem if frequent).
        var resyncs = 0
    }

    init(key: Int, sampleRate: Double, channels: Int, capacity: Int) {
        self.key = key
        self.sampleRate = sampleRate
        self.channels = channels
        self.capacity = capacity
        func make() -> [UnsafeMutablePointer<Float16>] {
            (0..<channels).map { _ in
                let pointer = UnsafeMutablePointer<Float16>.allocate(capacity: capacity)
                pointer.initialize(repeating: 0, count: capacity)
                return pointer
            }
        }
        mix = make()
        vocal = make()
    }

    deinit { (mix + vocal).forEach { $0.deallocate() } }

    /// Vocal samples below this index are final.
    var processed: Int { progress.withLock { $0.processed } }
    /// Decoded mix samples below this index are written.
    var decoded: Int { progress.withLock { $0.decoded } }
    func markProcessed(_ value: Int) { progress.withLock { $0.processed = min(value, capacity) } }
    func markDecoded(_ value: Int) { progress.withLock { $0.decoded = min(value, capacity) } }

    var offset: Int? { alignment.withLock { $0.offset } }

    /// Called by the tap with what it is playing until an offset is known; keeps the first offer.
    func offerProbe(start: Int, samples: UnsafePointer<Float>, count: Int) {
        alignment.withLock { state in
            guard state.offset == nil, state.probe == nil, count >= 1024 else { return }
            state.probe = (start, Array(UnsafeBufferPointer(start: samples, count: count)))
        }
    }

    fileprivate func takeProbe() -> (start: Int, samples: [Float])? { alignment.withLock { $0.probe } }

    func noteResync() { alignment.withLock { $0.resyncs += 1 } }

    private let speedValue = OSAllocatedUnfairLock(initialState: 0.0)
    /// Seconds of audio separated per second of work so far (below 1 = slower than playback).
    var speed: Double { speedValue.withLock { $0 } }
    func noteSpeed(_ value: Double) { speedValue.withLock { $0 = value } }

    /// Offset, match score and resync count, for the status line.
    var alignmentInfo: (offset: Int?, score: Float, resyncs: Int) {
        alignment.withLock { ($0.offset, $0.score, $0.resyncs) }
    }

    fileprivate func resolve(offset: Int?, score: Float) {
        alignment.withLock { state in
            if let offset {
                state.offset = offset
                state.score = score
            } else {
                // Unclear match (silence, say): try another probe; give up on alignment eventually.
                state.probe = nil
                state.failures += 1
                if state.failures >= 12 { state.offset = 0 }
            }
        }
    }
}

/// What the audio tap reads: the current stem and how much of the vocal to remove.
enum VocalStems {
    private static let state = OSAllocatedUnfairLock<(stem: VocalStem?, gain: Float)>(uncheckedState: (nil, 0))

    static func key(for url: URL) -> Int { url.absoluteString.hashValue }

    static func set(_ stem: VocalStem?) { state.withLock { $0.stem = stem } }
    static var stem: VocalStem? { state.withLock { $0.stem } }
    static func setGain(_ gain: Float) { state.withLock { $0.gain = gain } }

    /// The stem for this stream (if any) and the removal amount 0…1.
    static func current(for key: Int) -> (stem: VocalStem, gain: Float)? {
        state.withLock { value in
            guard let stem = value.stem, stem.key == key else { return nil }
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

        // Decode the whole track first (a couple of seconds): the tap can then play our decode
        // from start to end without ever switching sources while the model catches up.
        var total = 0
        var buffers = 0
        while let buffer = output.copyNextSampleBuffer() {
            total = append(buffer, channels: Int(asbd.mChannelsPerFrame), stem: stem, at: total)
            buffers += 1
            if buffers % 64 == 0 {
                try Task.checkCancellation()
                align(stem)
            }
        }
        if reader.status == .failed { throw reader.error ?? SeparationError.unreadable }
        guard total > 0 else { throw SeparationError.noAudio }
        align(stem)

        let engine = try ChunkEngine(model: model, stem: stem)
        // Enough frames that the last one covers the end; past `total` the buffers are silence.
        let totalFrames = min((total + fftSize) / hop, (capacity - fftSize) / hop + 1)
        let chunkSamples = (frames - 1) * hop + fftSize
        var chunkStart = 0
        let started = ContinuousClock.now

        while true {
            try Task.checkCancellation()
            let count = min(frames, totalFrames - chunkStart)
            guard count > 0 else { break }
            let isLast = chunkStart + frames >= totalFrames
            let origin = chunkStart * hop
            let input = stem.mix.map { channel in
                (0..<chunkSamples).map { origin + $0 < capacity ? Float(channel[origin + $0]) : 0 }
            }

            let lo = chunkStart == 0 ? 0 : edge
            let hi = isLast ? count : frames - edge
            try engine.process(input: input, count: count, startFrame: chunkStart, keep: lo..<hi)
            stem.markProcessed(isLast ? capacity : (chunkStart + hi) * hop)
            let elapsed = (ContinuousClock.now - started) / .seconds(1)
            stem.noteSpeed(Double((chunkStart + hi) * hop) / sampleRate / max(elapsed, 0.001))
            progress(isLast ? 1 : min(0.99, Double((chunkStart + hi) * hop) / Double(total)))
            align(stem)
            if isLast { break }
            // Next chunk starts `edge` frames before the first frame it will keep.
            chunkStart += hi - edge
        }

        // Playback may start (or the probe may be unclear) after separation is done.
        for _ in 0..<600 where stem.offset == nil {
            try await Task.sleep(for: .milliseconds(200))
            align(stem)
        }
    }

    /// Writes an interleaved float sample buffer into the stem's mix; returns the new length.
    private static func append(_ buffer: CMSampleBuffer, channels sourceChannels: Int,
                               stem: VocalStem, at position: Int) -> Int {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return position }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        let stride = max(1, sourceChannels)
        let frameCount = min(samples.count / stride, max(0, stem.capacity - position))
        for c in 0..<stem.channels {
            let source = min(c, stride - 1)
            let mix = stem.mix[c] + position
            for i in 0..<frameCount { mix[i] = Float16(samples[i * stride + source]) }
        }
        stem.markDecoded(position + frameCount)
        return position + frameCount
    }

    /// Largest decoder disagreement looked for (~190 ms at 44.1 kHz).
    private static let maxLag = 8192
    /// Normalised correlation needed to trust a match.
    private static let minCorrelation: Float = 0.6

    /// Finds the tap's probe in our decode: offset = where it matches − where the tap said it was.
    private static func align(_ stem: VocalStem) {
        guard stem.offset == nil, let probe = stem.takeProbe() else { return }
        let length = probe.samples.count
        let lo = max(0, probe.start - maxLag)
        let hi = probe.start + maxLag + length
        guard hi <= stem.decoded else { return }   // not decoded that far yet
        let segment = (lo..<hi).map { Float(stem.mix[0][$0]) }
        let lags = segment.count - length + 1
        var correlation = [Float](repeating: 0, count: lags)
        segment.withUnsafeBufferPointer { s in
            probe.samples.withUnsafeBufferPointer { p in
                vDSP_conv(s.baseAddress!, 1, p.baseAddress!, 1, &correlation, 1,
                          vDSP_Length(lags), vDSP_Length(length))
            }
        }
        var peak: Float = 0
        var at: vDSP_Length = 0
        vDSP_maxvi(correlation, 1, &peak, &at, vDSP_Length(lags))
        var probeEnergy: Float = 0
        var segmentEnergy: Float = 0
        vDSP_svesq(probe.samples, 1, &probeEnergy, vDSP_Length(length))
        segment.withUnsafeBufferPointer { s in
            vDSP_svesq(s.baseAddress! + Int(at), 1, &segmentEnergy, vDSP_Length(length))
        }
        let score = peak / max((probeEnergy * segmentEnergy).squareRoot(), 1e-9)
        stem.resolve(offset: score >= minCorrelation ? lo + Int(at) - probe.start : nil, score: score)
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
                let buffer = stem.vocal[c]
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
                            let ratio = (vRe * vRe + vIm * vIm).squareRoot() / (level + 1e-9)
                            // A non-finite model value means "don't know": leave the bin alone.
                            let estimate = ratio.isFinite ? min(1, ratio) : 0
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
