# Ping + tracert from this PC to Singapore targets. Run with and without the tunnel and compare.
# Usage: powershell -File scripts/measure-home.ps1 -Label baseline
param([string]$Label = "run")
$targets = @(
  @{n="OVH SG (FACEIT 139.99.x edge)"; ip="15.235.182.181"},
  @{n="OVH SG FACEIT candidate";       ip="139.99.112.177"},
  @{n="Leaseweb SG";                   ip="23.106.253.161"},
  @{n="GCP SG";                        ip="35.240.144.156"},
  @{n="Valve SDR sgp";                 ip="103.10.124.116"},
  @{n="Datacamp SG";                   ip="149.102.250.86"},
  @{n="AWS exit node";                 ip="52.74.31.125"}
)
$out = Join-Path $PSScriptRoot "..\measurements\home-$Label-$(Get-Date -Format yyyyMMdd-HHmm).txt"
foreach ($t in $targets) {
  "== $($t.n) $($t.ip)" | Tee-Object -FilePath $out -Append
  (ping -n 10 -w 1500 $t.ip | Select-Object -Last 1) | Tee-Object -FilePath $out -Append
  (tracert -d -w 700 -h 20 $t.ip | Where-Object { $_ -notmatch '^\s*\d+\s+\*\s+\*\s+\*' }) | Tee-Object -FilePath $out -Append
}
"saved: $out"
