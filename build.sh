#!/usr/bin/env bash
# Build Volna.ipa with xtool. Run inside WSL (Ubuntu): bash build.sh
# Builds from a copy on the Linux filesystem (faster and steadier than /mnt/c),
# then puts the IPA back into ./xtool/.
set -euo pipefail
. "$HOME/.local/share/swiftly/env.sh"
SRC="$(cd "$(dirname "$0")" && pwd)"
WORK="$HOME/volna-build"
mkdir -p "$WORK"
rsync -a --delete --exclude .build --exclude xtool --exclude .git --exclude SideStore-Madeira-Kit "$SRC/" "$WORK/"
cd "$WORK"
xtool dev build --ipa --configuration release "$@"
mkdir -p "$SRC/xtool"
cp xtool/*.ipa "$SRC/xtool/"
echo "IPA copied to $SRC/xtool/"
