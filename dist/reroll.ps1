# reroll.ps1 - "Laggy right now": move the running tunnel to another network path WITHOUT restarting it.
# Run via reroll.bat (admin). Only the WireGuard source port changes (`wg set <name> listen-port`), so the
# tunnel, its routes and the game's connection stay up; the exit node follows the new port on the next packet.
# Background: the home ISP <-> AWS links are picked per flow by a hash of the UDP ports, and a flow stays on its
# link. If that link gets congested the tunnel keeps suffering until the port changes.
# 1. Measure the current path. If it is fine, change nothing (the lag is not on this path) unless -Force.
# 2. Otherwise try other ports one by one and stop at the first good one; keep the best, or go back to the original.
# Probe / Set-LivePort / Show-Probe are duplicated in start-tunnel.ps1 on purpose (that file self-updates alone).
# start-tunnel.ps1 keeps this file up to date when it self-updates.
param(
  [string]$Conf,
  [int]$Candidates = 6,
  [int]$MaxMs = 150,
  [int]$GoodMarginMs = 5,
  [int]$JitterMs = 15,
  [switch]$Force,
  [switch]$NoPause
)
$ErrorActionPreference = 'Continue'
$wg = "C:\Program Files\WireGuard\wg.exe"
$gw = "10.66.0.1"

function Rule([string]$c = 'DarkCyan') { Write-Host ("  " + ('=' * 58)) -ForegroundColor $c }
function Info([string]$t) { Write-Host "        $t" -ForegroundColor Gray }
function Ok([string]$t) { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn([string]$t) { Write-Host "    !!  $t" -ForegroundColor Yellow }
function Fail([string]$t) { Write-Host "    NG  $t" -ForegroundColor Red }
function Done($code) { if (-not $NoPause) { Write-Host ""; Read-Host "  Enter キーで閉じる" | Out-Null }; exit $code }
function Summary([string]$color, [string[]]$lines) {
  Write-Host ""
  Write-Host ("  " + ('-' * 58)) -ForegroundColor $color
  foreach ($l in $lines) { Write-Host "   $l" -ForegroundColor $color }
  Write-Host ("  " + ('-' * 58)) -ForegroundColor $color
}
try { $Host.UI.RawUI.WindowTitle = "csvpn - reroll" } catch { }

Write-Host ""
Rule
Write-Host "   csvpn  |  reroll  |  試合を切らずに経路だけ変える" -ForegroundColor Cyan
Rule

if (-not $Conf) {
  $confs = Get-ChildItem -Path $PSScriptRoot -Filter *.conf | Sort-Object { $_.Name -notlike '*-split.conf' }, Name
  if (-not $confs) { Fail "このフォルダに .conf がありません。start-tunnel.bat と同じフォルダで実行してください。"; Done 1 }
  $Conf = $confs[0].FullName
}
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Fail "トンネル '$name' が動いていません。先に start-tunnel.bat を実行してください。"; Done 1 }

function Probe([int]$port) {
  # 30 echoes 50 ms apart through the tunnel (same UDP flow as the game). Score = p90, plus 20 ms per lost echo.
  $n = 30
  $tasks = New-Object 'System.Threading.Tasks.Task[System.Net.NetworkInformation.PingReply][]' $n
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $n; $i++) {
    $tasks[$i] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($gw, 1000)
    while ($sw.ElapsedMilliseconds -lt ($i + 1) * 50) { Start-Sleep -Milliseconds 2 }
  }
  try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 2000) } catch { }
  $ok = @(foreach ($t in $tasks) { if ($t.IsCompleted -and -not $t.IsFaulted -and $t.Result.Status -eq 'Success') { [int]$t.Result.RoundtripTime } }) | Sort-Object
  $lost = $n - $ok.Count
  if ($ok.Count -eq 0) { return [pscustomobject]@{ port = $port; min = -1; p90 = -1; lost = $lost; score = 99999 } }
  $p90 = $ok[[math]::Min($ok.Count - 1, [int][math]::Floor(0.9 * $ok.Count))]
  [pscustomobject]@{ port = $port; min = $ok[0]; p90 = $p90; lost = $lost; score = $p90 + 20 * $lost }
}
function Test-Good($r) { $r.min -ge 0 -and $r.lost -eq 0 -and $r.min -lt $MaxMs -and ($r.p90 - $r.min) -le $JitterMs }
function Show-Probe($r, [string]$label) {
  if ($r.min -lt 0) { $q = '応答なし'; $c = 'DarkRed' }
  elseif ($r.min -ge $MaxMs) { $q = '外れ経路'; $c = 'Red' }
  elseif (-not (Test-Good $r)) { $q = '揺れ/ロス'; $c = 'Yellow' }
  else { $q = '良好'; $c = 'Green' }
  $bar = if ($r.p90 -gt 0) { '#' * [math]::Min(30, [math]::Max(1, [int]($r.p90 / 10))) } else { '' }
  Write-Host ("        {0,-4} ポート {1,5}  " -f $label, $r.port) -NoNewline -ForegroundColor Gray
  Write-Host ("{0,-30}" -f $bar) -NoNewline -ForegroundColor $c
  if ($r.min -lt 0) { Write-Host "  ----" -NoNewline -ForegroundColor $c } else { Write-Host ("  {0,3}/{1,3} ms  ロス {2,-2}" -f $r.min, $r.p90, $r.lost) -NoNewline -ForegroundColor White }
  Write-Host ("  [{0}]" -f $q) -ForegroundColor $c
}
function Set-LivePort([int]$port) {
  # Apply the port and read it back; a failed `wg set` must not be mistaken for a measured path.
  & $wg set $name listen-port $port 2>$null
  $now = [int]((& $wg show $name listen-port 2>$null) | Select-Object -First 1)
  return ($now -eq $port)
}
function Set-ConfPort([int]$port) {
  $txt = Get-Content $Conf | Where-Object { $_ -notmatch '^\s*ListenPort' }
  $txt = $txt -replace '^\[Interface\]', "[Interface]`nListenPort = $port"
  Set-Content -Path $Conf -Value $txt -Encoding ASCII
}

$curPort = [int]((& $wg show $name listen-port 2>$null) | Select-Object -First 1)
if (-not $curPort) { Fail "wg.exe でトンネルの状態を読めませんでした (管理者権限で実行していますか?)"; Done 1 }
Write-Host ""
Write-Host "  今の経路を測定 (トンネル内に 30 発、1.5 秒)" -ForegroundColor White
$cur = Probe $curPort
Show-Probe $cur "現在"
if ((Test-Good $cur) -and -not $Force) {
  Summary 'Green' @("今の経路は正常です (揺れ・ロスなし)。切り替えません。",
    "ラグがあるなら原因はトンネルの経路以外 (ゲームサーバー側 / PC 側 / 国内区間)。",
    "切り分けは scripts\lag-check.ps1、プレイ中の記録は scripts\lag-watch.ps1")
  Done 0
}

Write-Host ""
if (Test-Good $cur) { Write-Host "  -Force 指定: 正常でも他のポートを試します" -ForegroundColor White }
else { Write-Host "  経路が悪いので、トンネルを張ったまま別のポートを試します" -ForegroundColor White }
$best = $cur
$results = @($cur)
foreach ($port in (Get-Random -Count $Candidates -InputObject (40000..60000) | Where-Object { $_ -ne $curPort })) {
  if (-not (Set-LivePort $port)) { Warn ("ポート {0} への切り替えに失敗したので飛ばします" -f $port); continue }
  Start-Sleep -Milliseconds 300
  $r = Probe $port
  Show-Probe $r "候補"
  $results += $r
  if ($r.score -lt $best.score) { $best = $r }
  $floor = ($results | Where-Object { $_.min -ge 0 } | Measure-Object -Property min -Minimum).Minimum
  if ($best.port -ne $curPort -and (Test-Good $best) -and $best.p90 -le $floor + $GoodMarginMs) { break }
}

if (-not (Set-LivePort $best.port)) {
  $live = (& $wg show $name listen-port 2>$null) | Select-Object -First 1
  Fail ("ポート {0} への切り替えを確認できませんでした (今のポート: {1})。start-tunnel.bat で張り直してください。" -f $best.port, $live)
  Done 1
}
Start-Sleep -Milliseconds 300
$check = Probe $best.port
Show-Probe $check "確認"
if ($best.port -eq $curPort -and (Test-Good $cur)) {
  Summary 'Green' @(("今のポート {0} が一番良かったので、そのまま戻しました。" -f $curPort))
  Done 0
}
if ($best.port -eq $curPort) {
  Summary 'Yellow' @(("どのポートも今より良くなりませんでした。元のポート {0} に戻しました。" -f $curPort),
    "経路全体が悪い可能性が高いので、しばらくしてから再実行するか、",
    "試合の合間にトンネルを切って直結と比べてください。")
  Done 1
}
Set-ConfPort $best.port
Summary 'Green' @(("ポート {0} -> {1} に切り替えました  (90% {2} -> {3} ms、ロス {4} -> {5})" -f $curPort, $best.port, $cur.p90, $check.p90, $cur.lost, $check.lost),
  "トンネルは張ったままです (切り替えの瞬間に数パケット落ちることはあります)。")
Done 0
