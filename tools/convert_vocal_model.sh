#!/usr/bin/env bash
# Run inside WSL (Ubuntu) as root: sets up a CPU-only venv and converts the vocal model.
#   bash tools/convert_vocal_model.sh
# Result: Sources/Volna/Resources/VocalModel (contents of VocalModel.mlpackage).
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$HOME/umx/venv"
OUT="$HOME/umx/out"
if [ ! -x "$VENV/bin/python" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --upgrade pip
fi
"$VENV/bin/pip" install -q torch==2.5.0 torchaudio==2.5.0 --index-url https://download.pytorch.org/whl/cpu
"$VENV/bin/pip" install -q openunmix coremltools==8.3.0 'numpy<2.1'
rm -rf "$OUT" && mkdir -p "$OUT"
cd "$OUT"
"$VENV/bin/python" "$SRC/tools/convert_vocal_model.py" "$OUT" 2>&1 | grep -v libcoremlpython
rm -rf "$SRC/Sources/Volna/Resources/VocalModel"
cp -r "$OUT/VocalModel.mlpackage" "$SRC/Sources/Volna/Resources/VocalModel"
du -sh "$SRC/Sources/Volna/Resources/VocalModel"
