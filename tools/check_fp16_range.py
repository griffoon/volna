"""Checks whether the vocal model's activations fit in float16 (Core ML runs it in half precision).

    python tools/check_fp16_range.py <model.onnx> [input-scale]

Feeds real music spectra (MUSDB preview, loudest track, n_fft 7680 / hop 1024 like the app)
through the fp32 model and prints the largest absolute value per layer. Anything near 65504
overflows on the device; the output is also compared against a run in bfloat-free float16 emulation
(rounding every layer's output to float16).
"""
import sys

import musdb
import numpy as np
import onnx
import torch
from onnx2torch import convert

N, HOP, BINS, FRAMES = 7680, 1024, 3072, 256


def spectrum(audio, start_frame=0):
    window = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N)
    x = np.zeros((1, 4, BINS, FRAMES), dtype=np.float32)
    for f in range(FRAMES):
        a = (start_frame + f) * HOP
        frame = audio[:, a:a + N]
        if frame.shape[1] < N:
            break
        s = np.fft.rfft(frame * window, axis=1)
        for c in range(2):
            x[0, 2 * c, :, f] = s[c].real[:BINS]
            x[0, 2 * c + 1, :, f] = s[c].imag[:BINS]
    x[:, :, :3, :] = 0
    return torch.from_numpy(x)


def main(model_path, scale=1.0):
    model = convert(onnx.load(model_path)).eval()
    db = musdb.DB(download=True, subsets="test")
    loudest = max(db.tracks[:20], key=lambda t: np.abs(t.audio).max())
    audio = loudest.audio.T.astype(np.float32)
    audio = audio / np.abs(audio).max() * 0.99   # full scale, like a mastered track
    x = spectrum(audio) * scale

    peaks = {}
    hooks = []
    for name, module in model.named_modules():
        if len(list(module.children())) == 0:
            hooks.append(module.register_forward_hook(
                lambda m, i, o, name=name: peaks.__setitem__(name, max(peaks.get(name, 0), float(o.abs().max())))))
    with torch.no_grad():
        reference = model(x)
    for h in hooks:
        h.remove()
    top = sorted(peaks.items(), key=lambda kv: -kv[1])[:8]
    print(f"track {loudest.name}, input scale {scale}, input max {float(x.abs().max()):.1f}")
    for name, value in top:
        print(f"  {value:12.1f}  {name}")

    # float16 emulation: round every leaf module's output to half.
    hooks = [m.register_forward_hook(lambda m, i, o: o.half().float())
             for m in model.modules() if len(list(m.children())) == 0]
    with torch.no_grad():
        half = model(x.half().float())
    for h in hooks:
        h.remove()
    finite = torch.isfinite(half).all().item()
    err = float((half - reference).abs().max() / reference.abs().max())
    print(f"float16 emulation: finite={finite}, max relative error {err:.3e}")


if __name__ == "__main__":
    main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 1.0)
