"""Offline check of the «голос» pipeline: the same framing, windows, mask shaping and overlap-add
as VocalSeparator.swift, in numpy with the ONNX model, on MUSDB18 7-second previews (real stems).

    python tools/check_vocal_pipeline.py <model.onnx> [tracks]

Prints, per track, how far `mix − vocal estimate` is from the true accompaniment (SDR, higher is
better) next to doing nothing, and a reconstruction check with an all-pass mask.
"""
import sys

import musdb
import numpy as np
import onnxruntime

N, HOP, BINS, FRAMES, EDGE = 7680, 1024, 3072, 256, 16
COMPENSATE = 1.009
OVER_SUBTRACT, LIFT, TAIL_SECONDS, TAIL_AMOUNT, ONSET_RATIO = 1.12, 0.75, 0.35, 0.75, 1.6

window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)
overlap = np.zeros(HOP)
for i in range(N):
    overlap[i % HOP] += window[i] ** 2
synthesis = window / overlap[np.arange(N) % HOP]


def separate(session, mix, shaped=True, identity=False, sr=44100):
    """mix: (channels, samples). Returns the vocal stem, same shape."""
    channels, length = mix.shape
    padded = np.concatenate([mix, np.zeros((channels, N * 2))], axis=1)
    out = np.zeros_like(padded)
    decay = np.exp(-HOP / (sr * TAIL_SECONDS))
    hold = np.zeros((channels, BINS))
    last = np.zeros((channels, BINS))
    total_frames = (length + N) // HOP
    start = 0
    while True:
        count = min(FRAMES, total_frames - start)
        if count <= 0:
            break
        is_last = total_frames - start <= FRAMES
        spec = np.zeros((channels, N // 2 + 1, FRAMES), dtype=np.complex64)
        for f in range(count):
            a = (start + f) * HOP
            spec[:, :, f] = np.fft.rfft(padded[:, a:a + N] * window, axis=1)
        x = np.zeros((1, 4, BINS, FRAMES), dtype=np.float32)
        for c in range(2):
            src = spec[min(c, channels - 1)]
            x[0, 2 * c] = src.real[:BINS]
            x[0, 2 * c + 1] = src.imag[:BINS]
        x[:, :, :3, :] = 0
        y = session.run(None, {"input": x})[0][0] * COMPENSATE
        lo = 0 if start == 0 else EDGE
        hi = count if is_last else FRAMES - EDGE
        for c in range(channels):
            for f in range(lo, hi):
                m = spec[c, :, f]
                level = np.abs(m)
                mask = np.zeros(N // 2 + 1)
                if identity:
                    mask[:] = 1
                else:
                    v = np.abs(y[2 * c, :, f] + 1j * y[2 * c + 1, :, f])
                    est = np.minimum(1, v / (level[:BINS] + 1e-9))
                    if shaped:
                        lifted = np.minimum(1, est * OVER_SUBTRACT) ** LIFT
                        onset = level[:BINS] > last[c] * ONSET_RATIO + 1e-6
                        last[c] = level[:BINS]
                        carried = np.where(onset, 0, hold[c] * decay)
                        hold[c] = np.maximum(lifted, carried)
                        mask[:BINS] = np.maximum(lifted, carried * TAIL_AMOUNT)
                    else:
                        mask[:BINS] = est
                frame = np.fft.irfft(m * mask, n=N)
                a = (start + f) * HOP
                out[c, a:a + N] += frame * synthesis
        if is_last:
            break
        start += hi - EDGE
    return out[:, :length]


def sdr(reference, estimate):
    return 10 * np.log10(np.sum(reference ** 2) / (np.sum((reference - estimate) ** 2) + 1e-12))


def split_error(karaoke, vocals, accompaniment):
    """Splits what's wrong with a karaoke output into vocal left in (dB below the original vocal)
    and accompaniment lost (dB below the accompaniment), by projecting per channel."""
    left, lost = 0.0, 0.0
    for c in range(vocals.shape[0]):
        error = karaoke[c] - accompaniment[c]
        a = np.dot(error, vocals[c]) / np.dot(vocals[c], vocals[c])
        b = np.dot(error, accompaniment[c]) / np.dot(accompaniment[c], accompaniment[c])
        left += np.sum((a * vocals[c]) ** 2)
        lost += np.sum((b * accompaniment[c]) ** 2)
    return (10 * np.log10(left / np.sum(vocals ** 2) + 1e-12),
            10 * np.log10(lost / np.sum(accompaniment ** 2) + 1e-12))


def main(model_path, tracks=4):
    global OVER_SUBTRACT, LIFT, TAIL_AMOUNT
    session = onnxruntime.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    db = musdb.DB(download=True, subsets="test")
    picked = [t for t in db.tracks if np.abs(t.targets["vocals"].audio).mean() > 0.01][:tracks]
    variants = {"raw": None, "mild": (1.05, 0.9, 0.4), "current": (1.12, 0.75, 0.75)}
    for track in picked:
        mix = track.audio.T.astype(np.float32)
        vocals = track.targets["vocals"].audio.T
        accompaniment = mix - vocals
        # Edges excluded: the very first and last samples aren't fully overlapped.
        core = slice(N, mix.shape[1] - N)
        recon = separate(session, mix, identity=True)
        line = f"{track.name[:30]:30} recon {sdr(mix[:, core], recon[:, core]):5.0f} dB | nothing {sdr(accompaniment[:, core], mix[:, core]):5.1f}"
        for name, params in variants.items():
            if params:
                OVER_SUBTRACT, LIFT, TAIL_AMOUNT = params
            est = separate(session, mix, shaped=params is not None)
            karaoke = (mix - est)[:, core]
            left, lost = split_error(karaoke, vocals[:, core], accompaniment[:, core])
            line += f" | {name} SDR {sdr(accompaniment[:, core], karaoke):5.1f} voc {left:6.1f} acc {lost:6.1f}"
        print(line)


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 4)
