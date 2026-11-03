import Accelerate
import AVFoundation
import MediaToolbox
import os

/// Listens to what AVPlayer actually plays (MTAudioProcessingTap) and turns it into a few
/// numbers the visuals react to: six spectrum bands, bass, loudness and a beat counter.
final class AudioAnalyzer: @unchecked Sendable {
    struct Levels: Sendable {
        var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
        /// Fine log-spaced spectrum for the visualizer, 40 Hz → 16 kHz.
        var spectrum = [Float](repeating: 0, count: AudioAnalyzer.spectrumCount)
        var bass: Float = 0
        var loudness: Float = 0
        var beat: UInt64 = 0
        var updated = Date.distantPast
    }

    static let shared = AudioAnalyzer()
    static let bandCount = 6
    static let spectrumCount = 32

    private let state = OSAllocatedUnfairLock(initialState: Levels())

    func snapshot() -> Levels {
        state.withLock { $0 }
    }

    fileprivate func publish(_ update: (inout Levels) -> Void) {
        state.withLock { update(&$0) }
    }

    /// Installs the tap once the item's audio track is known. Safe to call for every item.
    func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let tap = Self.makeTap(analyzer: self)
            else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            await MainActor.run { item.audioMix = mix }
        }
    }

    private static func makeTap(analyzer: AudioAnalyzer) -> MTAudioProcessingTap? {
        let context = TapContext(analyzer: analyzer)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(context).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut)
                guard status == noErr else { return }
                let context = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.analyze(bufferList, frames: Int(framesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        return status == noErr ? tap : nil
    }
}

/// Per-tap DSP state; lives on the audio thread, so everything is preallocated.
private final class TapContext {
    private static let log2n: vDSP_Length = 10
    private static let size = 1 << 10
    /// Band edges in Hz: sub, bass, low-mid, mid, presence, air.
    private static let edges: [Float] = [25, 90, 250, 600, 2000, 6000, 16000]

    private weak var analyzer: AudioAnalyzer?
    private var sampleRate: Float = 44100
    private var isFloat = true
    private var isInterleaved = false
    private var channels = 2

    private let fft = vDSP.FFT(log2n: TapContext.log2n, radix: .radix2, ofType: DSPSplitComplex.self)
    private var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: TapContext.size, isHalfWindow: false)
    private var mono = [Float](repeating: 0, count: TapContext.size)
    private var real = [Float](repeating: 0, count: TapContext.size / 2)
    private var imag = [Float](repeating: 0, count: TapContext.size / 2)
    private var magnitudes = [Float](repeating: 0, count: TapContext.size / 2)
    private var smoothed = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var fine = [Float](repeating: 0, count: AudioAnalyzer.spectrumCount)
    /// Log-spaced edges for the fine spectrum.
    private static let fineEdges: [Float] = (0...AudioAnalyzer.spectrumCount).map {
        40 * pow(16000 / 40, Float($0) / Float(AudioAnalyzer.spectrumCount))
    }
    private var bassAverage: Float = 0
    private var samplesSinceBeat = 0
    private var beat: UInt64 = 0

    init(analyzer: AudioAnalyzer) {
        self.analyzer = analyzer
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        sampleRate = Float(format.mSampleRate)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        channels = Int(max(1, format.mChannelsPerFrame))
    }

    func analyze(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat, frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return }

        // Latest `size` frames of the left channel, zero-padded when the callback is short.
        let count = min(frames, Self.size)
        let start = frames - count
        let stride = isInterleaved ? channels : 1
        for i in 0..<Self.size {
            mono[i] = i < count ? first[(start + i) * stride] : 0
        }
        var rms: Float = 0
        vDSP_rmsqv(mono, 1, &rms, vDSP_Length(count))
        vDSP.multiply(mono, window, result: &mono)

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
        for band in 0..<AudioAnalyzer.bandCount {
            let lo = max(1, Int(Self.edges[band] / binWidth))
            let hi = min(magnitudes.count - 1, max(lo + 1, Int(Self.edges[band + 1] / binWidth)))
            var peak: Float = 0
            magnitudes.withUnsafeBufferPointer { buf in
                vDSP_maxv(buf.baseAddress! + lo, 1, &peak, vDSP_Length(hi - lo))
            }
            // -70…-10 dB → 0…1, fast attack, slower release.
            let db = 20 * log10(max(peak / Float(Self.size), 1e-7))
            let level = min(max((db + 70) / 60, 0), 1)
            let k: Float = level > smoothed[band] ? 0.6 : 0.15
            smoothed[band] += (level - smoothed[band]) * k
        }

        for band in 0..<AudioAnalyzer.spectrumCount {
            let lo = max(1, Int(Self.fineEdges[band] / binWidth))
            let hi = min(magnitudes.count - 1, max(lo + 1, Int(Self.fineEdges[band + 1] / binWidth)))
            var peak: Float = 0
            magnitudes.withUnsafeBufferPointer { buf in
                vDSP_maxv(buf.baseAddress! + lo, 1, &peak, vDSP_Length(hi - lo))
            }
            // Treble is naturally quieter; tilt it up so the right side of the spectrum moves too.
            let tilt = 1 + Float(band) / Float(AudioAnalyzer.spectrumCount) * 0.6
            let db = 20 * log10(max(peak * tilt / Float(Self.size), 1e-7))
            let level = min(max((db + 72) / 58, 0), 1)
            let k: Float = level > fine[band] ? 0.55 : 0.12
            fine[band] += (level - fine[band]) * k
        }

        let bass = max(smoothed[0], smoothed[1])
        bassAverage += (bass - bassAverage) * 0.04
        samplesSinceBeat += frames
        let minGap = Int(sampleRate * 0.28)
        if bass > 0.35, bass > bassAverage * 1.25, samplesSinceBeat > minGap {
            beat &+= 1
            samplesSinceBeat = 0
        }

        let bands = smoothed
        let spectrum = fine
        let beatNow = beat
        let loudness = min(rms * 4, 1)
        analyzer?.publish {
            $0.bands = bands
            $0.spectrum = spectrum
            $0.bass = bass
            $0.loudness = loudness
            $0.beat = beatNow
            $0.updated = Date()
        }
    }
}
