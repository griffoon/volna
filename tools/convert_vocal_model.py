"""Converts the UVR MDX-Net "Kim Vocal 2" vocal model (ONNX) to a Core ML mlprogram for Volna.

The model takes a complex spectrogram (n_fft 7680, hop 1024, 44.1 kHz, Hann window) of a stereo
chunk laid out as 4 channels [L.re, L.im, R.re, R.im] × 3072 bins × 256 frames and returns the
vocal spectrogram in the same layout. STFT, masking and resynthesis happen in the app (vDSP).

    python tools/convert_vocal_model.py <model.onnx> <out-dir>

Writes <out-dir>/VocalModel.mlpackage.
"""
import sys

import coremltools as ct
import numpy as np
import onnx
import onnxruntime
import torch
from onnx2torch import convert

SHAPE = (1, 4, 3072, 256)


def main(onnx_path: str, out_dir: str) -> None:
    model = convert(onnx.load(onnx_path)).eval()
    example = torch.randn(*SHAPE) * 4

    session = onnxruntime.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    reference = session.run(None, {"input": example.numpy()})[0]
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
        replay = traced(example).numpy()
    diff = float(np.abs(reference - replay).max())
    print(f"onnxruntime vs traced max diff: {diff:.2e} (output scale {np.abs(reference).max():.2f})")
    assert diff < 1e-2

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input", shape=SHAPE, dtype=np.float32)],
        outputs=[ct.TensorType(name="output", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.short_description = "UVR MDX-Net Kim Vocal 2: vocal spectrogram from a mix spectrogram"
    mlmodel.save(f"{out_dir}/VocalModel.mlpackage")
    print("saved")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
