# start-tunnel.ps1 - Start the csvpn WireGuard tunnel and make sure it sits on a good network path.
# Run via start-tunnel.bat (double-click) or: powershell -File dist/start-tunnel.ps1 -Conf clients/owner-split.conf
# Background: home ISP <-> AWS traffic is spread over several links by a per-flow hash, so the client's
# source port decides which path (86 ms ... 250 ms, calm or jittery) the tunnel gets. After registering the
# tunnel this script compares the current port with 12 random ones by switching the listen port live with
# `wg set` and pinging through the tunnel (loss, 90th percentile, spread), keeps the best stable one (confirmed
# with a longer probe) and saves it - without re-registering, so the measured path is the one that stays.
# The tunnel is registered through the WireGuard app's own config store, so it shows up in the GUI.
# Then the window stays open and keeps watching the path (reroll.ps1 -Watch): when the tunnel's own link turns
# bad or keeps hitching, it moves to another port without dropping the game. Closing the window only stops the
# watching; the tunnel stays up. -NoWatch ends after the setup instead.
# Probe / Set-LivePort / Show-Probe are duplicated in reroll.ps1 on purpose: this file self-updates on its own.
param(
  [string]$Conf,
  [switch]$NoPause,
  [switch]$NoUpdate,
  [switch]$AssumeCurrentBad, # testing aid: treat the current path as bad so another port must win
  [switch]$NoWatch,         # end after setting up instead of staying to monitor the path
  [int]$WatchMinutes = 0,   # testing aid: stop monitoring after N minutes (0 = until the window is closed)
  [switch]$InjectFlow,      # testing aid: passed to reroll.ps1 -Watch (fake tunnel hitches to exercise a switch)
  [int]$Candidates = 12,    # ports compared besides the current one (13 in total)
  [int]$SwitchMarginMs = 2, # leave a good current port only for a candidate at least this much better
  [int]$MaxMs = 150,
  [int]$JitterMs = 15,
  [string]$ListUrl = "https://raw.githubusercontent.com/PrankWorks/cs2vpn/master/split-allowed-ips.txt"
)
$ErrorActionPreference = 'Continue'

# ---------- screen ----------
function Rule([string]$c = 'DarkCyan') { Write-Host ("  " + ('=' * 58)) -ForegroundColor $c }
function Step([int]$n, [string]$text) { Write-Host ""; Write-Host ("  [{0}/5] {1}" -f $n, $text) -ForegroundColor White }
function Info([string]$t) { Write-Host "        $t" -ForegroundColor Gray }
function Ok([string]$t) { Write-Host "    OK  $t" -ForegroundColor Green }
function Warn([string]$t) { Write-Host "    !!  $t" -ForegroundColor Yellow }
function Fail([string]$t) { Write-Host "    NG  $t" -ForegroundColor Red }
function Done($code) { if (-not $NoPause) { Write-Host ""; Read-Host "  Enter キーで閉じる" | Out-Null }; exit $code }
try { $Host.UI.RawUI.WindowTitle = "csvpn - start-tunnel" } catch { }

# ---------- self-update ----------
# Fetch the latest copy of this script (and reroll.{ps1,bat}) from the public repo; re-run if this script changed.
# Only writes files next to this script. The re-run after a self-update is guarded by CSVPN_UPDATED.
$RepoBase = ($ListUrl -replace 'split-allowed-ips\.txt$', '')
# raw.githubusercontent.com is cached by a CDN for several minutes; a changing query string bypasses it.
$cb = "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ListUrl += $cb
if (-not $NoUpdate -and $PSCommandPath) {
  # Helpers are refreshed on every run, including the re-run right after this script updated itself.
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($helper in 'reroll.ps1', 'reroll.bat') {
      try {
        $body = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri ($RepoBase + "dist/$helper" + $cb)).Content).TrimStart([char]0xFEFF)
        if ($body.Length -lt 200) { continue }
        $path = Join-Path $PSScriptRoot $helper
        $have = if (Test-Path $path) { ([IO.File]::ReadAllText($path)).TrimStart([char]0xFEFF) } else { '' }
        if (($body.Trim() -replace "`r", "") -ne ($have.Trim() -replace "`r", "")) {
          if ($helper -like '*.bat') { [IO.File]::WriteAllText($path, ($body -replace "`r?`n", "`r`n"), (New-Object Text.ASCIIEncoding)) }
          else { [IO.File]::WriteAllText($path, $body, (New-Object Text.UTF8Encoding $true)) }
        }
      } catch { }
    }
  } catch { }
}
if (-not $NoUpdate -and -not $env:CSVPN_UPDATED -and $PSCommandPath) {
  try {
    $latest = ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri ($RepoBase + "dist/start-tunnel.ps1" + $cb)).Content).TrimStart([char]0xFEFF)
    $mine = ([IO.File]::ReadAllText($PSCommandPath)).TrimStart([char]0xFEFF)
    if ($latest.Length -gt 2000 -and ($latest.Trim() -replace "`r","") -ne ($mine.Trim() -replace "`r","")) {
      [IO.File]::WriteAllText($PSCommandPath, $latest, (New-Object Text.UTF8Encoding $true))
      Write-Host "  スクリプトを最新版に更新しました。再実行します..." -ForegroundColor Cyan
      $env:CSVPN_UPDATED = '1'
      $args2 = @()
      foreach ($k in $PSBoundParameters.Keys) { $v = $PSBoundParameters[$k]; if ($v -is [switch]) { if ($v) { $args2 += "-$k" } } else { $args2 += "-$k"; $args2 += "$v" } }
      & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @args2
      exit $LASTEXITCODE
    }
  } catch { }
}

$wgui  = "C:\Program Files\WireGuard\wireguard.exe"
$wg    = "C:\Program Files\WireGuard\wg.exe"
$gw    = "10.66.0.1"
$store = "C:\Program Files\WireGuard\Data\Configurations"

Write-Host ""
Rule
Write-Host "   csvpn  |  Singapore exit node  |  WireGuard" -ForegroundColor Cyan
Rule

# ---------- 1. prepare ----------
Step 1 "準備"
if (-not (Test-Path $wgui)) {
  Info "WireGuard が見つからないのでインストールします..."
  winget install --id WireGuard.WireGuard -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
  if (-not (Test-Path $wgui)) { Fail "自動インストールに失敗。https://www.wireguard.com/install/ から入れて再実行してください。"; Done 1 }
  Ok "WireGuard をインストールしました"
}
if (-not $Conf) {
  $confs = Get-ChildItem -Path $PSScriptRoot -Filter *.conf | Sort-Object { $_.Name -notlike '*-split.conf' }, Name
  if (-not $confs) { Fail "このフォルダに .conf がありません。配布された .conf を同じフォルダに置いてください。"; Done 1 }
  $Conf = $confs[0].FullName
}
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
try { $Host.UI.RawUI.WindowTitle = "csvpn - start-tunnel ($name)" } catch { }
Info "設定: $name"

# Split configs: refresh AllowedIPs from the shared list on GitHub so everyone picks up new destinations
# just by re-running this script. The private key and everything else in the .conf stay untouched.
$curAip = ((Get-Content $Conf | Where-Object { $_ -match '^\s*AllowedIPs' }) -replace '^\s*AllowedIPs\s*=\s*','').Trim()
if (-not $NoUpdate -and $curAip -ne '0.0.0.0/0') {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $ListUrl).Content
    $cidrs = @($body -split "`n" | ForEach-Object { ($_ -replace '#.*','').Trim() } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' } | Select-Object -Unique)
    if ($cidrs.Count -ge 5) {
      $newAip = (@('10.66.0.0/24') + $cidrs) -join ', '
      if ($newAip -ne $curAip) {
        $txt = Get-Content $Conf | ForEach-Object { if ($_ -match '^\s*AllowedIPs') { "AllowedIPs = $newAip" } else { $_ } }
        Set-Content -Path $Conf -Value $txt -Encoding ASCII
        Ok ("宛先リストを更新しました ({0} 件)" -f $cidrs.Count)
      } else { Ok ("宛先リストは最新です ({0} 件)" -f $cidrs.Count) }
    } else { Warn "宛先リストの取得結果が小さすぎるので無視します" }
  } catch { Warn "宛先リストの取得に失敗 (オフライン?)。今の設定のまま続けます" }
}

# ---------- tunnel helpers ----------
function Set-ConfPort([int]$port) {
  $txt = Get-Content $Conf | Where-Object { $_ -notmatch '^\s*ListenPort' }
  $txt = $txt -replace '^\[Interface\]', "[Interface]`nListenPort = $port"
  Set-Content -Path $Conf -Value $txt -Encoding ASCII
}
function Get-ConfPort {
  foreach ($l in Get-Content $Conf) { if ($l -match '^\s*ListenPort\s*=\s*(\d+)') { return [int]$Matches[1] } }
  return 0
}
# Register the tunnel the same way the WireGuard app does: put the .conf into the app's store,
# let the manager encrypt it (so it shows up in the GUI), then start the service from that copy.
function Install-FromStore {
  & $wgui /uninstalltunnelservice $name 2>$null | Out-Null; Start-Sleep 3
  if (-not (Test-Path $store)) { New-Item -ItemType Directory -Path $store -Force | Out-Null }
  # Stop the manager first so the old encrypted copy is not held open / re-created from stale state.
  $mgr = Get-Service -Name WireGuardManager -ErrorAction SilentlyContinue
  if ($mgr) { Stop-Service WireGuardManager -Force -ErrorAction SilentlyContinue; Start-Sleep 2 }
  Get-Process -Name wireguard -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 1
  $enc = Join-Path $store "$name.conf.dpapi"
  Remove-Item -Path (Join-Path $store "$name.conf"), $enc, (Join-Path $store "*.tmp") -Force -ErrorAction SilentlyContinue
  if (Test-Path $enc) {
    takeown /f $enc 2>$null | Out-Null
    icacls $enc /grant "*S-1-5-32-544:F" 2>$null | Out-Null
    Remove-Item -Path $enc -Force -ErrorAction SilentlyContinue
  }
  if (Test-Path $enc) { Warn "古い設定 $enc を削除できませんでした" }
  Copy-Item -Path $Conf -Destination (Join-Path $store "$name.conf") -Force
  if ($mgr) { Start-Service WireGuardManager -ErrorAction SilentlyContinue } else { Start-Process $wgui | Out-Null }
  for ($t = 0; $t -lt 20 -and -not (Test-Path $enc); $t++) { Start-Sleep -Milliseconds 500 }
  $src = if (Test-Path $enc) { Remove-Item -Path (Join-Path $store "$name.conf") -Force -ErrorAction SilentlyContinue; $enc } else { Join-Path $store "$name.conf" }
  & $wgui /installtunnelservice $src | Out-Null
  Start-Sleep 4
  # Verify the routes really reflect this .conf (catches a stale store copy).
  $aip = (Get-Content $Conf | Where-Object { $_ -match '^\s*AllowedIPs\s*=' }) -replace '^\s*AllowedIPs\s*=\s*',''
  $want = ($aip -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '0.0.0.0/0' }
  $have = (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq $name }).DestinationPrefix
  $missing = $want | Where-Object { $have -notcontains $_ }
  if ($missing) { Warn ("次の宛先がトンネルのルートに載っていません: {0}" -f ($missing -join ', ')) }
}
function Wait-Tunnel([int]$sec = 12) {
  # The tunnel was just (re)started: wait for the first reply so a handshake in progress is not read as loss.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) {
    try { $p = New-Object System.Net.NetworkInformation.Ping; $ok = $p.Send($gw, 500).Status -eq 'Success'; $p.Dispose(); if ($ok) { return $true } } catch { }
    Start-Sleep -Milliseconds 200
  }
  return $false
}
function Probe([int]$port, [int]$n = 30, [int]$intervalMs = 50) {
  # $n echoes $intervalMs apart through the tunnel (same UDP flow as the game). Score = p90, plus 20 ms per lost echo.
  $tasks = New-Object 'System.Threading.Tasks.Task[System.Net.NetworkInformation.PingReply][]' $n
  $sw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $n; $i++) {
    $tasks[$i] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($gw, 1000)
    while ($sw.ElapsedMilliseconds -lt ($i + 1) * $intervalMs) { Start-Sleep -Milliseconds 2 }
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
function Get-LivePort { [int]((& $wg show $name listen-port 2>$null) | Select-Object -First 1) }
function Summary([string]$color, [string[]]$lines) {
  Write-Host ""
  Write-Host ("  " + ('-' * 58)) -ForegroundColor $color
  foreach ($l in $lines) { Write-Host "   $l" -ForegroundColor $color }
  Write-Host ("  " + ('-' * 58)) -ForegroundColor $color
}

function Start-Monitor([int]$code, [int[]]$prefer = @()) {
  # Stay in this window and keep watching the path (reroll.ps1 -Watch); switch ports live when it degrades.
  if ($NoWatch) { Done $code }
  $rr = Join-Path $PSScriptRoot 'reroll.ps1'
  if (-not (Test-Path $rr)) { Warn "reroll.ps1 が見つからないので監視は省略します (次回の実行で自動取得されます)"; Done $code }
  Step 5 "経路を監視 (プレイ中はこのウィンドウを開いたままに)"
  $a = @{ Conf = $Conf; Watch = $true; NoPause = $true }
  if ($WatchMinutes -gt 0) { $a.WatchMinutes = $WatchMinutes }
  if ($InjectFlow) { $a.InjectFlow = $true }
  if ($prefer.Count) { $a.PreferPorts = $prefer }   # ports that measured good: first choices when switching
  & $rr @a
  Done $code
}

# ---------- 2. register ----------
Step 2 "トンネルを登録"
Install-FromStore
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Fail "トンネルを開始できませんでした。.conf の内容を確認してください。"; Done 1 }
Ok "トンネル '$name' を開始しました (WireGuard アプリの一覧にも出ます)"
if (-not (Wait-Tunnel)) {
  Fail "出口ノードが応答しません。ノードの稼働時間は 19:00〜02:00 (JST) です。"
  Info "時間内なら回線かファイアウォールを確認してください。トンネルは登録済みなので、ノードが起きれば自動でつながります。"
  Done 1
}

# ---------- 3. compare ports ----------
Step 3 ("経路を比較 (今のポート + {0} ポート、約 {1} 秒)" -f $Candidates, [int](4 + $Candidates * 1.2))
$curPort = Get-LivePort
if (-not $curPort) { Fail "wg.exe でトンネルの状態を読めませんでした (管理者権限で実行していますか?)"; Done 1 }
$cur = Probe $curPort
if ($AssumeCurrentBad) { $cur.lost = $cur.lost + 30; $cur.score = 99999; Info "-AssumeCurrentBad: 今の経路を悪いとみなします (テスト用)" }
Show-Probe $cur "現在"
$results = @($cur)
foreach ($port in (Get-Random -Count $Candidates -InputObject (40000..60000) | Where-Object { $_ -ne $curPort })) {
  if (-not (Set-LivePort $port)) { Warn ("ポート {0} への切り替えに失敗したので飛ばします" -f $port); continue }
  Start-Sleep -Milliseconds 200
  $r = Probe $port 20 40      # 20 echoes in 0.8 s per candidate; the winner is re-checked with the full probe
  Show-Probe $r "候補"
  $results += $r
}
# Rank good ports by score (p90 + loss penalty), then by minimum. Bad ones only count if nothing is good.
$good = @($results | Where-Object { Test-Good $_ } | Sort-Object score, min)
$ranked = if ($good.Count) { $good } else { @($results | Sort-Object score, min) }
$pick = $ranked[0]
# Stay on a good current port unless a candidate is clearly better (1 ms is ICMP rounding).
if ((Test-Good $cur) -and $pick.port -ne $curPort -and $pick.score -gt $cur.score - $SwitchMarginMs) { $pick = $cur }

# ---------- 4. apply ----------
Step 4 "適用"
$final = $null
if ($pick.port -eq $curPort) {
  [void](Set-LivePort $curPort)
  $final = $cur
  Ok "今のポート $curPort が一番良いので、そのまま使います"
} else {
  # Confirm the winner with the full 30-echo probe; fall back to the next good ones if it does not hold.
  $order = @($pick) + @($ranked | Where-Object { $_.port -ne $pick.port -and $_.port -ne $curPort } | Select-Object -First 2)
  foreach ($c in $order) {
    if (-not (Set-LivePort $c.port)) { continue }
    Start-Sleep -Milliseconds 300
    $chk = Probe $c.port
    Show-Probe $chk "確認"
    if (Test-Good $chk) { $final = $chk; break }
  }
  if (-not $final) {
    if (Test-Good $cur) { [void](Set-LivePort $curPort); $final = $cur; Warn "候補が確認で崩れたので、今のポート $curPort に戻します" }
    else { [void](Set-LivePort $order[0].port); $final = Probe $order[0].port; Show-Probe $final "確認" }
  }
  if ($final.port -ne $curPort) { Ok ("ポート {0} -> {1} にその場で切り替えました (登録し直しなし)" -f $curPort, $final.port) }
}
if ((Get-ConfPort) -ne $final.port) { Set-ConfPort $final.port }   # next start-tunnel registers with this port
$prefer = @($ranked | Where-Object { (Test-Good $_) -and $_.port -ne $final.port } | ForEach-Object { $_.port })
if (Test-Good $final) {
  Summary 'Green' @(("準備完了  ポート {0}  /  最小 {1} ms  /  90% {2} ms  /  ロス {3}" -f $final.port, $final.min, $final.p90, $final.lost),
    ("良好だった他のポート {0} 個は、プレイ中の切り替え先の第一候補にします" -f $prefer.Count),
    "次回からは WireGuard アプリで '$name' を有効化するだけでもつながります")
  Start-Monitor 0 $prefer
}
Summary 'Yellow' @(("一番ましな経路: ポート {0}  /  最小 {1} ms  /  90% {2} ms  /  ロス {3}" -f $final.port, $final.min, $final.p90, $final.lost),
  "良好なポートが見つかりませんでした。経路全体が混んでいる可能性があります。",
  "監視を続けて、良くなる経路が見つかれば自動で切り替えます。")
Start-Monitor 1 $prefer
