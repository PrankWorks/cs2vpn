# lag-check.ps1 - When the game feels laggy, find out WHERE the delay/jitter/loss is. No admin needed, switches nothing.
# Pings four points at the same time and compares them:
#   LAN    : home router                         -> PC / LAN problem
#   JP     : 1.1.1.1 (Cloudflare Tokyo)          -> home line / domestic problem
#   AWS    : the exit node's public IP (EIP)     -> KDDI -> AWS path as a whole (a different flow than the tunnel)
#   TUNNEL : 10.66.0.1 through WireGuard         -> exactly the path the game packets take
# Usage: powershell -File scripts/lag-check.ps1   (10 s snapshot with a verdict)
# This catches lag that is going on right now. Short hitches a few times per round need scripts/lag-watch.ps1,
# which keeps running during play and logs each hitch with the segment it happened in.
param(
  [int]$WindowSec = 10,
  [int]$IntervalMs = 100,
  [int]$JitterMs = 15,      # p90 - min above this counts as jittery
  [double]$LossPct = 3,     # loss above this counts as lossy
  [string]$Gateway = "10.66.0.1",
  [string]$Endpoint
)
$ErrorActionPreference = 'Stop'

if (-not $Endpoint) {
  $conf = Get-ChildItem -Path (Join-Path $PSScriptRoot "..\dist"), (Join-Path $PSScriptRoot "..\clients") -Filter *-split.conf -ErrorAction SilentlyContinue | Select-Object -First 1
  $ep = if ($conf) { (Get-Content $conf.FullName | Where-Object { $_ -match '^\s*Endpoint\s*=' }) -replace '^\s*Endpoint\s*=\s*', '' -replace ':\d+\s*$', '' } else { $null }
  $Endpoint = if ($ep) { $ep.Trim() } else { "52.74.31.125" }
}
$lan = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1).NextHop
$points = [ordered]@{ LAN = $lan; JP = "1.1.1.1"; AWS = $Endpoint; TUNNEL = $Gateway }

function Measure-Window {
  # One echo per point every $IntervalMs, replies collected asynchronously; returns per-point stats.
  $n = [int]($WindowSec * 1000 / $IntervalMs)
  $tasks = @{}; foreach ($k in $points.Keys) { $tasks[$k] = New-Object 'System.Threading.Tasks.Task[System.Net.NetworkInformation.PingReply][]' $n }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $n; $i++) {
    foreach ($k in $points.Keys) { if ($points[$k]) { $tasks[$k][$i] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($points[$k], 1000) } }
    while ($sw.ElapsedMilliseconds -lt ($i + 1) * $IntervalMs) { Start-Sleep -Milliseconds 2 }
  }
  $out = [ordered]@{}
  foreach ($k in $points.Keys) {
    if (-not $points[$k]) { continue }
    try { [void][System.Threading.Tasks.Task]::WaitAll($tasks[$k], 2000) } catch { }
    $ok = @(foreach ($t in $tasks[$k]) { if ($t -and $t.IsCompleted -and -not $t.IsFaulted -and $t.Result.Status -eq 'Success') { [int]$t.Result.RoundtripTime } } ) | Sort-Object
    $loss = [math]::Round(100 * ($n - $ok.Count) / $n, 1)
    if ($ok.Count -eq 0) { $out[$k] = [pscustomobject]@{ min = -1; p50 = -1; p90 = -1; max = -1; loss = $loss; bad = $true }; continue }
    $p = { param($q) $ok[[math]::Min($ok.Count - 1, [int][math]::Floor($q * $ok.Count))] }
    $s = [pscustomobject]@{ min = $ok[0]; p50 = (& $p 0.5); p90 = (& $p 0.9); max = $ok[-1]; loss = $loss; bad = $false }
    $s.bad = ($loss -gt $LossPct) -or (($s.p90 - $s.min) -gt $JitterMs)
    $out[$k] = $s
  }
  $out
}

function Get-Verdict($r) {
  if ($r.Contains('LAN') -and $r.LAN.bad) { return "LAN: 自宅の LAN / PC 側で遅延かロス (ルーターまでで既に悪い)" }
  # Everything beyond the router crosses the domestic segment, so a real domestic problem also shows on AWS/TUNNEL.
  # 1.1.1.1 alone dropping echoes is Cloudflare rate-limiting ICMP (seen 2026-10-06: 75% loss while AWS/TUNNEL had 0%).
  if ($r.JP.bad -and ($r.AWS.bad -or $r.TUNNEL.bad) -and -not ($r.AWS.loss -ge 100 -and $r.TUNNEL.loss -ge 100)) { return "JP: 国内区間 (回線 / プロバイダ側) が悪い" }
  if ($r.AWS.loss -ge 100 -and $r.TUNNEL.loss -ge 100) { return "NODE: 出口ノードが応答しない (停止中? 稼働は 19:00〜02:00 JST)" }
  if ($r.TUNNEL.loss -ge 100) { return "DOWN: トンネルの中に届かない (トンネルが無効か切れている。start-tunnel.bat で張り直す)" }
  if ($r.TUNNEL.bad -and $r.AWS.bad) { return "PATH: KDDI -> AWS の経路全体が悪い (ポートを変えても直らない可能性が高い)" }
  if ($r.TUNNEL.bad) { return "FLOW: トンネルが乗っている経路だけ悪い (dist\reroll.bat でポートを変えれば直る見込み)" }
  return "OK: 回線とトンネルは正常 (ラグがあるならゲームサーバー側か PC 側)"
}

function Format-Row($r) {
  ($r.Keys | ForEach-Object { $s = $r[$_]; "{0} {1}/{2}/{3}ms loss{4}%{5}" -f $_, $s.min, $s.p50, $s.p90, $s.loss, $(if ($s.bad) { '!' } else { '' }) }) -join ' | '
}

"計測点: " + (($points.Keys | ForEach-Object { "$_=$($points[$_])" }) -join '  ')
"表示は 最小/中央/90% 値。'!' はしきい値超え (揺れ > $JitterMs ms またはロス > $LossPct %)"
"$WindowSec 秒測ります..."
$r = Measure-Window
Format-Row $r
"判定: " + (Get-Verdict $r)
if ((Get-Verdict $r) -like 'OK*') { "(1 ラウンドに数回だけ跳ねるラグは 10 秒では捕まりにくいので、プレイ中は scripts\lag-watch.ps1 を流しておく)" }
