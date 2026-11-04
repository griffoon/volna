#!/usr/bin/env bash
# Run inside WSL (Ubuntu) as root before building: downloads the UVR "Kim Vocal 2" model and
# converts it to Core ML for the «голос» slider.
#   bash tools/convert_vocal_model.sh
# Result: Sources/Volna/Resources/VocalModel (contents of VocalModel.mlpackage). The weights have
# no stated license, so they are not committed; every checkout converts its own copy.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$HOME/umx/venv"
WORK="$HOME/mdx"
MODEL="Kim_Vocal_2"
URL="https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/$MODEL.onnx"

if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
fi
# onnx2torch first, then pin the CPU torch it would otherwise upgrade.
"$VENV/bin/pip" install -q onnx onnxruntime onnx2torch coremltools==8.3.0 'numpy<2.1'
"$VENV/bin/pip" install -q --force-reinstall --no-deps torch==2.5.0 torchvision==0.20.0 --index-url https://download.pytorch.org/whl/cpu

mkdir -p "$WORK"
[ -f "$WORK/$MODEL.onnx" ] || curl -sSL -o "$WORK/$MODEL.onnx" "$URL"
rm -rf "$WORK/out" && mkdir -p "$WORK/out"
cd "$WORK/out"
"$VENV/bin/python" "$SRC/tools/convert_vocal_model.py" "$WORK/$MODEL.onnx" "$WORK/out" 2>&1 | grep -v libcoremlpython
rm -rf "$SRC/Sources/Volna/Resources/VocalModel"
cp -r "$WORK/out/VocalModel.mlpackage" "$SRC/Sources/Volna/Resources/VocalModel"
du -sh "$SRC/Sources/Volna/Resources/VocalModel"
