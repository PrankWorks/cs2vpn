#!/usr/bin/env bash
# Fill AllowedIPs of clients/*-split.conf from split-allowed-ips.txt (also adds the tunnel subnet itself).
set -euo pipefail
cd "$(dirname "$0")/.."
CIDRS=$(grep -v '^\s*#' split-allowed-ips.txt | sed 's/#.*//' | awk 'NF{print $1}' | paste -sd, -)
for f in clients/*-split.conf; do
  sed -i -E "s|^AllowedIPs = .*|AllowedIPs = 10.66.0.0/24, ${CIDRS}|" "$f"
  echo "updated $f"
done
