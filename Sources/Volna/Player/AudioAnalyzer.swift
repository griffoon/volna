import Accelerate
import AVFoundation
import MediaToolbox
import os

/// Listens to what AVPlayer plays (MTAudioProcessingTap) and turns it into numbers the visuals
/// react to. AVPlayer hands the tap audio in large chunks and *ahead* of what is heard, so every
/// chunk is cut into short windows stamped with their media time, and readers look up the window
/// that matches the player's current position. That keeps the picture locked to the sound.
final class AudioAnalyzer: @unchecked Sendable {
    struct Levels: Sendable {
        var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
        /// Fine log-spaced spectrum, 40 Hz → 16 kHz.
        var spectrum = [Float](repeating: 0, count: AudioAnalyzer.spectrumCount)
        var bass: Float = 0
        var mid: Float = 0
        var high: Float = 0
        /// Onset strength (sudden energy rise) per range, 0…1.
        var bassHit: Float = 0
        var midHit: Float = 0
        var highHit: Float = 0
        var loudness: Float = 0
        /// Counts bass onsets up to this moment; a change means a kick just hit.
        var beat: UInt64 = 0
        var updated = Date.distantPast
    }

    /// What the analyzer can say about itself, for the on-screen diagnostics.
    struct Diagnostics: Sendable {
        var tapsAttached = 0
        var sampleRate: Double = 0
        var format = "—"
        /// How far ahead of the playhead the tap is running, seconds.
        var lead: Double = 0
        var synced = false
    }

    static let shared = AudioAnalyzer()
    static let bandCount = 6
    static let spectrumCount = 32

    /// Media-time clock of what is audible now: (tap id of the playing item, seconds).
    /// Set by the player; read when visuals ask for the current frame.
    var clock: (@Sendable () -> (tap: Int, time: Double)?)?

    private struct Frame {
        let tap: Int
        let time: Double
        let levels: Levels
    }

    private let frames = OSAllocatedUnfairLock(initialState: [Frame]())
    private let info = OSAllocatedUnfairLock(initialState: Diagnostics())
    private let tapIDs = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Int]())
    private let nextTap = OSAllocatedUnfairLock(initialState: 0)
    /// ~4 s of windows at ~12 ms hops is plenty to cover AVPlayer's read-ahead.
    private static let keepFrames = 360

    /// The frame matching what is heard right now, or the newest one when there is no clock.
    func snapshot() -> Levels {
        let now = clock?()
        let picked: Levels? = frames.withLock { list in
            guard !list.isEmpty else { return nil }
            guard let now else { return list.last?.levels }
            // Latest frame of the playing tap whose time has already been reached.
            var best: Frame?
            for frame in list where frame.tap == now.tap && frame.time <= now.time + 0.005 {
                if best == nil || frame.time > best!.time { best = frame }
            }
            return best?.levels
        }
        if let now {
            info.withLock { state in
                let newest = frames.withLock { $0.last { $0.tap == now.tap }?.time } ?? now.time
                state.lead = max(0, newest - now.time)
                state.synced = picked != nil
            }
        }
        var levels = picked ?? Levels()
        if picked != nil { levels.updated = Date() }
        return levels
    }

    func diagnostics() -> Diagnostics { info.withLock { $0 } }

    /// Tap id that belongs to an item, so the player can tell the clock which stream is audible.
    func tapID(for item: AVPlayerItem) -> Int? {
        tapIDs.withLock { $0[ObjectIdentifier(item)] }
    }

    fileprivate func push(tap: Int, time: Double, levels: Levels) {
        frames.withLock { list in
            list.append(Frame(tap: tap, time: time, levels: levels))
            if list.count > Self.keepFrames { list.removeFirst(list.count - Self.keepFrames) }
        }
    }

    fileprivate func noteFormat(sampleRate: Double, format: String) {
        info.withLock {
            $0.sampleRate = sampleRate
            $0.format = format
        }
    }

    /// Installs the tap once the item's audio track is known. Safe to call for every item.
    /// `loudness` is the track's R128 data, used for volume normalisation inside the tap.
    func attach(to item: AVPlayerItem, loudness: Loudness? = nil) {
        let asset = item.asset
        let trackGain = AudioProcessing.normalizationGain(for: loudness)
        let id = nextTap.withLock { value -> Int in
            value += 1
            return value
        }
        tapIDs.withLock { map in
            if map.count > 8 { map.removeAll() }
            map[ObjectIdentifier(item)] = id
        }
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let tap = Self.makeTap(analyzer: self, tapID: id, trackGain: trackGain)
            else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            await MainActor.run { item.audioMix = mix }
            info.withLock { $0.tapsAttached += 1 }
        }
    }

    private static func makeTap(analyzer: AudioAnalyzer, tapID: Int, trackGain: Float) -> MTAudioProcessingTap? {
        let context = TapContext(analyzer: analyzer, tapID: tapID, trackGain: trackGain)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.prepare(format.pointee, maxFrames: Int(maxFrames))
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                var range = CMTimeRange.zero
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut)
                guard status == noErr else { return }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let count = Int(framesOut.pointee)
                context.process(bufferList, frames: count)
                let start = range.start.isNumeric ? range.start.seconds : nil
                context.analyze(bufferList, frames: count, startTime: start)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        return status == noErr ? tap : nil
    }
}

/// Per-tap DSP state; lives on the audio thread, so buffers are preallocated.
private final class TapContext {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    /// New analysis window every 512 samples (~12 ms at 44.1 kHz).
    private static let hop = 512
    /// Band edges in Hz: sub, bass, low-mid, mid, presence, air.
    private static let edges: [Float] = [25, 90, 250, 600, 2000, 6000, 16000]
    private static let fineEdges: [Float] = (0...AudioAnalyzer.spectrumCount).map {
        40 * pow(16000 / 40, Float($0) / Float(AudioAnalyzer.spectrumCount))
    }

    private weak var analyzer: AudioAnalyzer?
    private let tapID: Int
    private var sampleRate: Float = 44100
    private var isFloat = true
    private var isInterleaved = false
    private var channels = 2

    private let fft = vDSP.FFT(log2n: TapContext.log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                     count: TapContext.size, isHalfWindow: false)
    /// Rolling mono history so windows can span chunk boundaries.
    private var history = [Float](repeating: 0, count: TapContext.size)
    private var mono = [Float](repeating: 0, count: TapContext.size)
    private var real = [Float](repeating: 0, count: TapContext.size / 2)
    private var imag = [Float](repeating: 0, count: TapContext.size / 2)
    private var magnitudes = [Float](repeating: 0, count: TapContext.size / 2)

    // Adaptive range per band: floor and ceiling in dB that follow the track's own dynamics.
    // Running mean and spread in dB per band (see `adapt`).
    private var floorDB = [Float](repeating: -40, count: AudioAnalyzer.bandCount)
    private var ceilDB = [Float](repeating: 6, count: AudioAnalyzer.bandCount)
    private var fineFloor = [Float](repeating: -40, count: AudioAnalyzer.spectrumCount)
    private var fineCeil = [Float](repeating: 6, count: AudioAnalyzer.spectrumCount)
    /// Recent bass flux values, to require a real local peak before calling a kick.
    private var bassFluxHistory: (Float, Float) = (0, 0)
    private var bassPeak: Float = 0.001
    private var smoothed = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var fine = [Float](repeating: 0, count: AudioAnalyzer.spectrumCount)
    // Onset detection: energy per range and its running average.
    private var previousEnergy: SIMD3<Float> = .zero
    private var fluxAverage: SIMD3<Float> = SIMD3(repeating: 0.01)
    private var hits: SIMD3<Float> = .zero
    private var samplesSinceBeat = 0
    private var beat: UInt64 = 0

    // Processing: per-channel EQ filters, rebuilt when the settings version changes.
    private let trackGain: Float
    private var filters: [vDSP.Biquad<Float>] = []
    private var filterVersion = -1
    private var scratch = [Float]()

    init(analyzer: AudioAnalyzer, tapID: Int, trackGain: Float) {
        self.analyzer = analyzer
        self.tapID = tapID
        self.trackGain = trackGain
    }

    func prepare(_ format: AudioStreamBasicDescription, maxFrames: Int) {
        sampleRate = Float(format.mSampleRate)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = Int(max(1, format.mChannelsPerFrame))
        scratch = [Float](repeating: 0, count: max(maxFrames, 4096))
        filterVersion = -1
        let description = "\(isFloat ? "f32" : "int")\(isInterleaved ? " interleaved" : "") · \(channels)ch · max \(maxFrames)"
        analyzer?.noteFormat(sampleRate: format.mSampleRate, format: description)
    }

    /// Equalizer and loudness normalisation, applied in place before the audio reaches the speaker.
    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat, !isInterleaved, frames > 0, frames <= scratch.count else { return }
        let settings = AudioProcessing.shared.snapshot()
        let eqActive = settings.eqEnabled && settings.gains.contains { $0 != 0 }
        var gain: Float = settings.normalize ? trackGain : 1
        if eqActive { gain *= AudioProcessing.preamp(gains: settings.gains) }
        guard eqActive || gain != 1 else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        if eqActive, filterVersion != settings.version || filters.count != buffers.count {
            let coefficients = AudioProcessing.coefficients(gains: settings.gains, sampleRate: Double(sampleRate))
            filters = buffers.indices.compactMap { _ in
                vDSP.Biquad(coefficients: coefficients, channelCount: 1,
                            sectionCount: vDSP_Length(AudioProcessing.frequencies.count), ofType: Float.self)
            }
            filterVersion = settings.version
        }

        for (channel, buffer) in buffers.enumerated() {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let samples = UnsafeMutableBufferPointer(start: data, count: frames)
            if eqActive, filters.indices.contains(channel) {
                scratch.withUnsafeMutableBufferPointer { tmp in
                    let input = UnsafeMutableBufferPointer(rebasing: tmp[0..<frames])
                    _ = input.initialize(from: samples)
                    var output = samples
                    filters[channel].apply(input: UnsafeBufferPointer(input), output: &output)
                }
            }
            if gain != 1 {
                var g = gain
                vDSP_vsmul(data, 1, &g, data, 1, vDSP_Length(frames))
            }
            // Hard safety ceiling; the preamp and peak-aware gain keep this rarely hit.
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(data, 1, &lo, &hi, data, 1, vDSP_Length(frames))
        }
    }

    /// Walks the chunk in hops, analysing the window that ends at each hop.
    func analyze(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, startTime: Double?) {
        guard isFloat, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        let stride = isInterleaved ? channels : 1

        var position = 0
        while position < frames {
            let step = min(Self.hop, frames - position)
            // Shift history left and append this hop as mono (L+R)/2.
            history.withUnsafeMutableBufferPointer { h in
                let base = h.baseAddress!
                memmove(base, base + step, (Self.size - step) * MemoryLayout<Float>.size)
                for i in 0..<step {
                    let index = position + i
                    let l = left[index * stride]
                    let r = isInterleaved ? (channels > 1 ? left[index * stride + 1] : l) : (right?[index] ?? l)
                    base[Self.size - step + i] = (l + r) * 0.5
                }
            }
            position += step
            let time = startTime.map { $0 + Double(position) / Double(sampleRate) }
            analyzeWindow(time: time, samples: step)
        }
    }

    private func analyzeWindow(time: Double?, samples: Int) {
        var rms: Float = 0
        vDSP_rmsqv(history, 1, &rms, vDSP_Length(Self.size))
        vDSP.multiply(history, window, result: &mono)

        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                mono.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.size / 2))
                    }
                }
                fft?.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }

        let binWidth = sampleRate / Float(Self.size)
        let dt = Float(samples) / sampleRate
        var energy = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
        for band in 0..<AudioAnalyzer.bandCount {
            let db = bandDB(from: Self.edges[band], to: Self.edges[band + 1], binWidth: binWidth, tilt: 1)
            energy[band] = pow(10, db / 20)
            let level = adapt(db, floor: &floorDB[band], ceil: &ceilDB[band], dt: dt)
            let k: Float = level > smoothed[band] ? 0.7 : 0.25
            smoothed[band] += (level - smoothed[band]) * k
        }
        for band in 0..<AudioAnalyzer.spectrumCount {
            let tilt = 1 + Float(band) / Float(AudioAnalyzer.spectrumCount) * 0.6
            let db = bandDB(from: Self.fineEdges[band], to: Self.fineEdges[band + 1], binWidth: binWidth, tilt: tilt)
            let level = adapt(db, floor: &fineFloor[band], ceil: &fineCeil[band], dt: dt)
            let k: Float = level > fine[band] ? 0.6 : 0.2
            fine[band] += (level - fine[band]) * k
        }

        // Onsets: positive change in energy per range against its own recent average.
        let current = SIMD3(energy[0] + energy[1], energy[2] + energy[3], energy[4] + energy[5])
        let flux = simd_max(current - previousEnergy, .zero)
        previousEnergy = current
        fluxAverage += (flux - fluxAverage) * 0.02
        let strength = simd_clamp((flux / (fluxAverage * 3 + 1e-6)) - 0.6, .zero, SIMD3(repeating: 1))
        hits = simd_max(hits * SIMD3(repeating: 0.82), strength)

        // Kick: sub+bass flux that is a local maximum (previous window was the peak), well above
        // its own average, and on a loud enough bass. Confirming one window late (~12 ms) keeps
        // it on the attack without firing on every wobble.
        samplesSinceBeat += samples
        bassPeak = max(bassPeak * 0.9995, current.x)
        let (twoBack, oneBack) = bassFluxHistory
        bassFluxHistory = (oneBack, flux.x)
        let isPeak = oneBack > twoBack && oneBack >= flux.x
        if isPeak, oneBack > fluxAverage.x * 2.2, current.x > bassPeak * 0.35,
           samplesSinceBeat > Int(sampleRate * 0.28) {
            beat &+= 1
            samplesSinceBeat = 0
        }

        var levels = AudioAnalyzer.Levels()
        levels.bands = smoothed
        levels.spectrum = fine
        levels.bass = max(smoothed[0], smoothed[1])
        levels.mid = max(smoothed[2], smoothed[3])
        levels.high = max(smoothed[4], smoothed[5])
        levels.bassHit = hits.x
        levels.midHit = hits.y
        levels.highHit = hits.z
        levels.loudness = min(rms * 4, 1)
        levels.beat = beat
        levels.updated = Date()
        analyzer?.push(tap: tapID, time: time ?? 0, levels: levels)
    }

    private func bandDB(from lowHz: Float, to highHz: Float, binWidth: Float, tilt: Float) -> Float {
        let lo = max(1, Int(lowHz / binWidth))
        let hi = min(magnitudes.count - 1, max(lo + 1, Int(highHz / binWidth)))
        var peak: Float = 0
        magnitudes.withUnsafeBufferPointer { buf in
            vDSP_maxv(buf.baseAddress! + lo, 1, &peak, vDSP_Length(hi - lo))
        }
        return 20 * log10(max(peak * tilt / Float(Self.size), 1e-7))
    }

    /// Maps dB into 0…1 around this song's own typical level: `mean` is a ~2 s running average and
    /// `spread` its running deviation. Typical moments sit near 0.35, hits rise towards 1, quiet
    /// parts fall to 0 — instead of everything living near the top.
    private func adapt(_ db: Float, floor mean: inout Float, ceil spread: inout Float, dt: Float) -> Float {
        let k = min(1, dt / 2)
        mean += (db - mean) * k
        spread += (abs(db - mean) - spread) * k
        let deviation = max(spread, 3)
        return min(max(0.35 + (db - mean) / (deviation * 3.2), 0), 1)
    }
}
