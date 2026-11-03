"""Converts the Open-Unmix `umxhq` vocals model (MIT) to a Core ML mlprogram for Volna.

The model takes a magnitude spectrogram (n_fft 4096, hop 1024, 44.1 kHz, stereo) and returns
the vocal magnitude estimate. STFT, masking and resynthesis happen in the app (vDSP).

    python tools/convert_vocal_model.py <out-dir>

Writes <out-dir>/VocalModel.mlpackage. The app ships its contents as a plain resource folder
(Sources/Volna/Resources/VocalModel) and compiles it on the device.
"""
import sys

import coremltools as ct
import numpy as np
import openunmix
import torch

FRAMES = 256  # ~6 s per chunk at hop 1024 / 44.1 kHz
BINS = 2049


class VocalMask(torch.nn.Module):
    """Open-Unmix core with the mask exposed instead of the masked magnitude, so the app can
    apply it to the complex STFT directly."""

    def __init__(self, umx):
        super().__init__()
        self.umx = umx

    def forward(self, mix):
        estimate = self.umx(mix)
        return estimate / (mix + 1e-8)


def main(out_dir):
    separator = openunmix.umxhq(targets=["vocals"], device="cpu", pretrained=True)
    umx = separator.target_models["vocals"].eval()
    model = VocalMask(umx).eval()

    example = torch.rand(1, 2, BINS, FRAMES) * 20
    with torch.no_grad():
        eager = model(example)
        traced = torch.jit.trace(model, example)
        replay = traced(example)
    diff = (eager - replay).abs().max().item()
    print(f"traced vs eager max diff: {diff:.2e}; mask range {eager.min().item():.3f}…{eager.max().item():.3f}")
    assert diff < 1e-4

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="mix", shape=(1, 2, BINS, FRAMES), dtype=np.float32)],
        outputs=[ct.TensorType(name="mask", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "Open-Unmix umxhq vocals mask (MIT, sigsep/open-unmix-pytorch)"
    mlmodel.save(f"{out_dir}/VocalModel.mlpackage")
    print("saved")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
