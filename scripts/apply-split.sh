#!/usr/bin/env bash
# After editing split-allowed-ips.txt: fill the CIDRs into clients/*-split.conf and rebuild bundles/<name>/ for
# every client. Then double-click bundles/<name>/start-tunnel.bat (yours) or send the folder to the others.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fill-split.sh
for f in clients/*-split.conf; do
  n=$(basename "$f" -split.conf)
  scripts/make-bundle.sh "$n" split >/dev/null && echo "bundle: bundles/$n"
done
echo "now run bundles/<your-name>/start-tunnel.bat (admin prompt) to apply on this PC"
