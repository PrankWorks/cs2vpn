# reroll.ps1 - "Laggy right now": move the running tunnel to another network path WITHOUT restarting it.
# Run via reroll.bat (admin). Only the WireGuard source port changes (`wg set <name> listen-port`), so the
# tunnel, its routes and the game's connection stay up; the exit node follows the new port on the next packet.
# Background: the home ISP <-> AWS links are picked per flow by a hash of the UDP ports, and a flow stays on its
# link. If that link gets congested the tunnel keeps suffering until the port changes.
# 1. Measure the current path. If it is fine, change nothing (the lag is not on this path).
# 2. Otherwise try other ports one by one and stop at the first good one; keep the best, or go back to the original.
param(
  [string]$Conf,
  [int]$Candidates = 6,
  [int]$GoodMarginMs = 5,
  [int]$JitterMs = 15,
  [switch]$NoPause
)
$ErrorActionPreference = 'Continue'
$wg = "C:\Program Files\WireGuard\wg.exe"
$gw = "10.66.0.1"

function Done($code) { if (-not $NoPause) { Write-Host ""; Read-Host "Enter キーで閉じる" | Out-Null }; exit $code }

if (-not $Conf) {
  $confs = Get-ChildItem -Path $PSScriptRoot -Filter *.conf | Sort-Object { $_.Name -notlike '*-split.conf' }, Name
  if (-not $confs) { Write-Host "このフォルダに .conf がありません。start-tunnel.bat と同じフォルダで実行してください。"; Done 1 }
  $Conf = $confs[0].FullName
}
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Write-Host "トンネル '$name' が動いていません。先に start-tunnel.bat を実行してください。"; Done 1 }

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
function Show($r, $label) {
  $txt = if ($r.min -lt 0) { "応答なし" } else { "最小 {0} ms / 90% {1} ms / ロス {2}" -f $r.min, $r.p90, $r.lost }
  Write-Host ("  {0,-6} ポート {1,5}: {2}" -f $label, $r.port, $txt)
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

$curPort = [int]((& $wg show $name listen-port) | Select-Object -First 1)
if (-not $curPort) { Write-Host "wg.exe でトンネルの状態を読めませんでした (管理者権限で実行していますか?)"; Done 1 }
Write-Host "トンネル '$name' の今の経路を測定中..."
$cur = Probe $curPort
Show $cur "現在"
if ($cur.lost -eq 0 -and $cur.min -ge 0 -and ($cur.p90 - $cur.min) -le $JitterMs -and $cur.min -lt 150) {
  Write-Host ""
  Write-Host "今の経路は正常です (揺れ・ロスなし)。切り替えません。"
  Write-Host "ラグがあるなら原因はトンネルの経路以外 (ゲームサーバー側 / PC 側 / 国内区間) です。scripts\lag-check.ps1 で切り分けできます。"
  Done 0
}

Write-Host "経路が悪いので、トンネルを張ったまま別のポートを試します..."
$best = $cur
$results = @($cur)
foreach ($port in (Get-Random -Count $Candidates -InputObject (40000..60000) | Where-Object { $_ -ne $curPort })) {
  if (-not (Set-LivePort $port)) { Write-Host ("  候補   ポート {0,5}: 切り替えに失敗したので飛ばします" -f $port); continue }
  Start-Sleep -Milliseconds 300
  $r = Probe $port
  Show $r "候補"
  $results += $r
  if ($r.score -lt $best.score) { $best = $r }
  $floor = ($results | Where-Object { $_.min -ge 0 } | Measure-Object -Property min -Minimum).Minimum
  if ($best.port -ne $curPort -and $best.lost -eq 0 -and $best.p90 -le $floor + $GoodMarginMs) { break }
}

if (-not (Set-LivePort $best.port)) {
  $live = (& $wg show $name listen-port 2>$null) | Select-Object -First 1
  Write-Host ""
  Write-Host ("ポート {0} への切り替えを確認できませんでした (今のポート: {1})。start-tunnel.bat で張り直してください。" -f $best.port, $live)
  Done 1
}
Start-Sleep -Milliseconds 300
$check = Probe $best.port
Write-Host ""
if ($best.port -eq $curPort) {
  Write-Host ("どのポートも今より良くなりませんでした。元のポート {0} に戻しました (確認: 90% {1} ms / ロス {2})。" -f $curPort, $check.p90, $check.lost)
  Write-Host "経路全体が悪い可能性が高いので、しばらくしてから再実行するか、試合の合間にトンネルを切って直結と比べてください。"
  Done 1
}
Set-ConfPort $best.port
Write-Host ("ポート {0} -> {1} に切り替えました (90% {2} -> {3} ms、確認 {4} ms / ロス {5})。" -f $curPort, $best.port, $cur.p90, $best.p90, $check.p90, $check.lost)
Write-Host "トンネルは張ったままです (切り替えの瞬間に数パケット落ちることはありますが、試合の接続は続く想定です)。"
Done 0
