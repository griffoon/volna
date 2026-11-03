#!/usr/bin/env bash
# Build Volna.ipa with xtool. Run inside WSL (Ubuntu): ./build.sh
set -euo pipefail
. "$HOME/.local/share/swiftly/env.sh"
cd "$(dirname "$0")"
xtool dev build --ipa --configuration release "$@"
