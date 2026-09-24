#!/usr/bin/env bash
# Build a distribution folder for one client: bundles/<name>/ with start-tunnel.bat, start-tunnel.ps1 and <name>-split.conf.
# Usage: scripts/make-bundle.sh mate1 [split|full]
set -euo pipefail
cd "$(dirname "$0")/.."
NAME=${1:?client name}; MODE=${2:-split}
SRC="clients/$NAME-$MODE.conf"; [ -f "$SRC" ] || { echo "missing $SRC (run scripts/fetch-configs.sh first)"; exit 1; }
OUT="bundles/$NAME"; rm -rf "$OUT"; mkdir -p "$OUT"
cp dist/start-tunnel.bat dist/start-tunnel.ps1 "$SRC" "$OUT/"
echo "bundle ready: $OUT (send the whole folder privately - the .conf holds a private key)"; ls -1 "$OUT"
