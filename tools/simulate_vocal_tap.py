"""Simulates the device playback path of «голос» offline and looks for clicks and hiss.

    python tools/simulate_vocal_tap.py <model.onnx>

Separates a MUSDB preview with the app's pipeline, stores mix and vocal as float16 like
VocalStem, then replays it through a re-implementation of the tap (AudioAnalyzer.removeVocals)
with realistic callback sizes, and compares against the ideal float32 `mix − vocal`:
  * "noise"  – error energy relative to the ideal output (dB, lower is better)
  * "clicks" – largest sample-to-sample jump in the error (a discontinuity detector)
Scenarios: exact callback times, callback times rounded like a CMTime with timescale 600,
and both with the continuity fix (read position carried between callbacks).
"""
import sys

import musdb
import numpy as np
import onnxruntime

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from check_vocal_pipeline import separate  # noqa: E402

SR = 44100
LOOKAHEAD = 8192


def tap(mix16, voc16, starts_frames, gain=1.0, continuity=False):
    """Replays callbacks: starts_frames is [(start_seconds, frames)]. Returns the output."""
    out = []
    vocal_gain, last_end = 0.0, None
    processed = mix16.shape[1]
    for start, frames in starts_frames:
        first = int(round(start * SR))
        if continuity and last_end is not None and abs(first - last_end) <= 2048:
            first = last_end
        source = first
        target = gain if source + frames + max(frames, LOOKAHEAD) <= processed else 0.0
        g = vocal_gain + (target - vocal_gain) * np.arange(frames) / frames
        seg = mix16[:, source:source + frames].astype(np.float32) - g * voc16[:, source:source + frames].astype(np.float32)
        out.append(np.clip(seg, -1, 1))
        vocal_gain = target
        last_end = source + frames
    return np.concatenate(out, axis=1)


def report(name, output, ideal):
    n = min(output.shape[1], ideal.shape[1])
    err = output[:, :n] - ideal[:, :n]
    noise = 10 * np.log10(np.sum(err ** 2) / np.sum(ideal[:, :n] ** 2) + 1e-20)
    clicks = np.abs(np.diff(err, axis=1)).max()
    print(f"  {name:44} noise {noise:7.1f} dB   max error jump {clicks:.4f}")


def main(model_path):
    session = onnxruntime.InferenceSession(model_path, providers=["CPUExecutionProvider"])
    db = musdb.DB(download=True, subsets="test")
    track = [t for t in db.tracks if np.abs(t.targets["vocals"].audio).mean() > 0.01][0]
    mix = track.audio.T.astype(np.float32)
    vocal = separate(session, mix, shaped=True).astype(np.float32)
    ideal = mix - vocal
    mix16, voc16 = mix.astype(np.float16), vocal.astype(np.float16)
    print(f"{track.name}: {mix.shape[1] / SR:.1f} s")
    report("float16 storage only (no tap)", mix16.astype(np.float32) - voc16.astype(np.float32), ideal)

    rng = np.random.default_rng(1)
    sizes = rng.choice([1024, 4096, 4096, 4410, 8192], size=400)
    calls, position = [], 0
    for size in sizes:
        if position + size > mix.shape[1] - 2 * LOOKAHEAD:
            break
        calls.append((position, int(size)))
        position += int(size)
    exact = [(p / SR, f) for p, f in calls]
    rounded = [(round(p / SR * 600) / 600, f) for p, f in calls]
    end = position
    ideal = ideal[:, :end]
    report("exact callback times", tap(mix16, voc16, exact), ideal)
    report("times rounded to 1/600 s", tap(mix16, voc16, rounded), ideal)
    report("times rounded to 1/600 s + continuity", tap(mix16, voc16, rounded, continuity=True), ideal)


if __name__ == "__main__":
    main(sys.argv[1])
