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
  [switch]$NoSelfUpdate,    # keep this script and reroll as they are (still refresh the destination list); the beta bat passes it
  [switch]$AssumeCurrentBad, # testing aid: treat the current path as bad so another port must win
  [switch]$NoWatch,         # end after setting up instead of staying to monitor the path
  [int]$WatchMinutes = 0,   # testing aid: stop monitoring after N minutes (0 = until the window is closed)
  [switch]$InjectFlow,      # testing aid: passed to reroll.ps1 -Watch (fake tunnel hitches to exercise a switch)
  [switch]$Preview,         # show the whole screen with fake data; touches nothing (no admin, no tunnel, no files)
  [int]$Candidates = 12,    # ports compared besides the current one (13 in total)
  [int]$SwitchMarginMs = 0, # optional hysteresis: leave a good current port only for a candidate this much better
  [int]$MaxMs = 150,
  [int]$JitterMs = 15,
  [string]$ListUrl = "https://raw.githubusercontent.com/PrankWorks/cs2vpn/master/split-allowed-ips.txt"
)
$ErrorActionPreference = 'Continue'

# ---------- screen ----------
# Plain console features only (16 colours, ASCII, background-coloured spaces), so it looks the same in the classic
# console and in Windows Terminal on any PC. CJK text takes 2 columns; everything else used here takes 1.
$UiWidth = 72
function Get-DisplayWidth([string]$s) {
  $w = 0
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
        ($c -ge 0xF900 -and $c -le 0xFAFF) -or ($c -ge 0xFE30 -and $c -le 0xFE4F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
        ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w++ }
  }
  $w
}
function PadTo([string]$s, [int]$w) { $s + (' ' * [math]::Max(0, $w - (Get-DisplayWidth $s))) }
function Badge([string]$text, [string]$bg, [string]$fg = 'Black') { Write-Host " $text " -NoNewline -BackgroundColor $bg -ForegroundColor $fg }
function Band([string]$text, [string]$bg, [string]$fg = 'White') {
  # Full-width coloured bar; the line always ends in the default colours so nothing bleeds when the window scrolls.
  Write-Host "  " -NoNewline
  Write-Host (PadTo $text $UiWidth) -NoNewline -BackgroundColor $bg -ForegroundColor $fg
  Write-Host ""
}
function Header([string]$sub) {
  Write-Host ""
  Band "" 'DarkCyan'
  Band ("   CSVPN   //   Singapore exit node   //   {0}" -f $sub) 'DarkCyan' 'White'
  Band "" 'DarkCyan'
}
function Step([int]$n, [string]$text) { Write-Host ""; Write-Host "  " -NoNewline; Badge ("STEP {0}/5" -f $n) 'DarkCyan' 'White'; Write-Host "  $text" -ForegroundColor White }
function Info([string]$t) { Write-Host "         $t" -ForegroundColor Gray }
function Ok([string]$t) { Write-Host "    " -NoNewline; Badge 'OK' 'DarkGreen' 'White'; Write-Host " $t" -ForegroundColor Green }
function Warn([string]$t) { Write-Host "    " -NoNewline; Badge '!!' 'DarkYellow' 'Black'; Write-Host " $t" -ForegroundColor Yellow }
function Fail([string]$t) { Write-Host "    " -NoNewline; Badge 'NG' 'DarkRed' 'White'; Write-Host " $t" -ForegroundColor Red }
function Summary([string]$color, [string[]]$lines) {
  $bg = switch ($color) { 'Green' { 'DarkGreen' } 'Yellow' { 'DarkYellow' } default { 'DarkGray' } }
  $fg = if ($color -eq 'Yellow') { 'Black' } else { 'White' }
  Write-Host ""
  Band "" $bg $fg
  foreach ($l in $lines) { Band "   $l" $bg $fg }
  Band "" $bg $fg
}
function Done($code) { if (-not $NoPause) { Write-Host ""; Write-Host "  " -NoNewline; Badge 'Enter' 'DarkGray' 'White'; Read-Host " キーで閉じる" | Out-Null }; exit $code }
try { $Host.UI.RawUI.WindowTitle = "csvpn - start-tunnel" } catch { }

if ($Preview) { $NoUpdate = $true; $NoSelfUpdate = $true }

# ---------- self-update ----------
# Fetch the latest copy of this script (and reroll.{ps1,bat}) from the public repo; re-run if this script changed.
# Only writes files next to this script. The re-run after a self-update is guarded by CSVPN_UPDATED.
$RepoBase = ($ListUrl -replace 'split-allowed-ips\.txt$', '')
# raw.githubusercontent.com is cached by a CDN for several minutes; a changing query string bypasses it.
$cb = "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ListUrl += $cb
if (-not $NoUpdate -and -not $NoSelfUpdate -and $PSCommandPath) {
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
if (-not $NoUpdate -and -not $NoSelfUpdate -and -not $env:CSVPN_UPDATED -and $PSCommandPath) {
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

Header 'start-tunnel'

# ---------- 1. prepare ----------
Step 1 "準備"
if ($Preview) {
  $name = 'preview-split'
  Info "プレビュー: 偽のデータで画面だけ流します (トンネル・設定・WireGuard には触りません)"
  Ok "宛先リストは最新です (150 件)"
} else {
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
function Get-Quality($r) {
  if ($r.min -lt 0) { return @('応答なし', 'DarkRed', 'White') }
  if ($r.min -ge $MaxMs) { return @('外れ経路', 'DarkRed', 'White') }
  if (-not (Test-Good $r)) { return @('揺れ/ロス', 'DarkYellow', 'Black') }
  @('良好', 'DarkGreen', 'White')
}
function Write-Bar($r, [int]$cells = 25) {
  # 90th percentile on a 70..120 ms scale (2 ms per cell) in the quality colour, on a dark track.
  $q = Get-Quality $r
  $n = if ($r.p90 -gt 0) { [math]::Max(1, [math]::Min($cells, [int][math]::Round(($r.p90 - 70) / 2.0))) } else { 0 }
  if ($n -gt 0) { Write-Host (' ' * $n) -NoNewline -BackgroundColor $q[1] }
  if ($cells -gt $n) { Write-Host (' ' * ($cells - $n)) -NoNewline -BackgroundColor DarkGray }
}
function Write-Numbers($r, [string]$fc = 'White') {
  if ($r.min -lt 0) { Write-Host "    -- /  -- ms  ロス--  " -NoNewline -ForegroundColor DarkGray }
  else { Write-Host ("  {0,3} / {1,3} ms  ロス{2,2}  " -f $r.min, $r.p90, $r.lost) -NoNewline -ForegroundColor $fc }
}
function Show-Probe($r, [string]$label) {
  $q = Get-Quality $r
  Write-Host ("    {0}  {1,5}  " -f $label, $r.port) -NoNewline -ForegroundColor Gray
  Write-Bar $r
  Write-Numbers $r
  Badge $q[0] $q[1] $q[2]; Write-Host ""
}
function Set-LivePort([int]$port) {
  # Apply the port and read it back; a failed `wg set` must not be mistaken for a measured path.
  & $wg set $name listen-port $port 2>$null
  $now = [int]((& $wg show $name listen-port 2>$null) | Select-Object -First 1)
  return ($now -eq $port)
}
function Get-LivePort { [int]((& $wg show $name listen-port 2>$null) | Select-Object -First 1) }
function Select-Port($results, [int]$curPort) {
  # Rank good ports by score (p90 + loss penalty), then by minimum; on a full tie the current port goes first.
  # All results must come from the same probe size, or the p90s are not comparable.
  $good = @($results | Where-Object { Test-Good $_ })
  $pool = if ($good.Count) { $good } else { @($results) }
  @($pool | Sort-Object score, min, @{ Expression = { if ($_.port -eq $curPort) { 0 } else { 1 } } })
}
function Show-Strip($results, [int]$total) {
  # One line rewritten in place while the ports are measured: a coloured cell per port, grey ones still to come.
  Write-Host "`r    測定中  " -NoNewline -ForegroundColor White
  foreach ($r in $results) { Write-Host '  ' -NoNewline -BackgroundColor (Get-Quality $r)[1]; Write-Host ' ' -NoNewline }
  for ($i = $results.Count; $i -lt $total; $i++) { Write-Host '  ' -NoNewline -BackgroundColor DarkGray; Write-Host ' ' -NoNewline }
  Write-Host ("  {0,2} / {1} ポート" -f $results.Count, $total) -NoNewline -ForegroundColor Gray
}
function Show-Ranking($results, $ranked, [int]$curPort) {
  # Good ports in rank order first, then the rest by score.
  $rest = @($results | Where-Object { $p = $_.port; -not ($ranked | Where-Object { $_.port -eq $p }) } | Sort-Object score, min)
  $rows = @($ranked) + $rest
  Write-Host ""
  Write-Host ("    " + (PadTo '順位' 5) + (PadTo 'ポート' 8) + (PadTo '90% 値 (左ほど速くて安定)' 25) + (PadTo '  最小 / 90%' 16) + (PadTo 'ロス' 8) + '判定') -ForegroundColor DarkGray
  $i = 0
  foreach ($r in $rows) {
    $i++
    $q = Get-Quality $r
    $fc = if ($i -eq 1) { 'White' } else { 'Gray' }
    Write-Host ("    {0,3}  {1,6}  " -f $i, $r.port) -NoNewline -ForegroundColor $fc
    Write-Bar $r
    Write-Numbers $r $fc
    Badge $q[0] $q[1] $q[2]
    if ($r.port -eq $curPort) { Write-Host "  <- 今のポート" -NoNewline -ForegroundColor Cyan }
    Write-Host ""
  }
}

if ($Preview) {
  # Fake tunnel helpers: same screens, nothing real is touched.
  $script:pvRand = New-Object System.Random
  $script:pvLive = 50720
  function Install-FromStore { Start-Sleep -Milliseconds 900 }
  function Wait-Tunnel { $true }
  function Get-LivePort { $script:pvLive }
  function Set-LivePort([int]$port) { Start-Sleep -Milliseconds 60; $script:pvLive = $port; $true }
  function Set-ConfPort([int]$port) { }
  function Get-ConfPort { 50720 }
  function Probe([int]$port, [int]$n = 30, [int]$intervalMs = 50) {
    Start-Sleep -Milliseconds ([int]($n * $intervalMs * 0.7))
    $k = $script:pvRand.Next(0, 13)
    if ($k -eq 0) { $min = 246 + $script:pvRand.Next(0, 8); $p90 = $min + $script:pvRand.Next(1, 6); $lost = 0 }   # the 250 ms link
    elseif ($k -eq 1) { $min = 79 + $script:pvRand.Next(0, 2); $p90 = $min + 18 + $script:pvRand.Next(0, 10); $lost = 0 }   # jittery
    elseif ($k -eq 2) { $min = 80; $p90 = 82; $lost = 1 + $script:pvRand.Next(0, 2) }   # lossy
    else { $min = 78 + $script:pvRand.Next(0, 4); $p90 = $min + $script:pvRand.Next(0, 3); $lost = 0 }
    [pscustomobject]@{ port = $port; min = $min; p90 = $p90; lost = $lost; score = $p90 + 20 * $lost }
  }
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
  if ($Preview) { $a.Preview = $true; $a.PreviewPort = (Get-LivePort); if (-not $a.WatchMinutes) { $a.WatchMinutes = 1 } }
  & $rr @a
  Done $code
}

# ---------- 2. register ----------
Step 2 "トンネルを登録"
Install-FromStore
if (-not $Preview) {
  $svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
  if (-not $svc -or $svc.Status -ne 'Running') { Fail "トンネルを開始できませんでした。.conf の内容を確認してください。"; Done 1 }
}
Ok "トンネル '$name' を開始しました (WireGuard アプリの一覧にも出ます)"
if (-not (Wait-Tunnel)) {
  Fail "出口ノードが応答しません。ノードの稼働時間は 19:00〜02:00 (JST) です。"
  Info "時間内なら回線かファイアウォールを確認してください。トンネルは登録済みなので、ノードが起きれば自動でつながります。"
  Done 1
}

# ---------- 3. compare ports ----------
Step 3 ("経路を比較 (今のポート + {0} ポートを同じ条件で測定、約 {1} 秒)" -f $Candidates, [int](3 + $Candidates * 1.2))
$curPort = Get-LivePort
if (-not $curPort) { Fail "wg.exe でトンネルの状態を読めませんでした (管理者権限で実行していますか?)"; Done 1 }
$cur = Probe $curPort 20 40     # same probe size as the candidates, so their p90s compare fairly
if ($AssumeCurrentBad) { $cur.lost = $cur.lost + 30; $cur.score = 99999; Info "-AssumeCurrentBad: 今の経路を悪いとみなします (テスト用)" }
$results = @($cur)
Show-Strip $results ($Candidates + 1)
foreach ($port in (Get-Random -Count $Candidates -InputObject (40000..60000) | Where-Object { $_ -ne $curPort })) {
  if (-not (Set-LivePort $port)) { Write-Host ""; Warn ("ポート {0} への切り替えに失敗したので飛ばします" -f $port); continue }
  Start-Sleep -Milliseconds 200
  $r = Probe $port 20 40      # 20 echoes in 0.8 s per candidate; the winner is re-checked with the full probe
  $results += $r
  Show-Strip $results ($Candidates + 1)
}
Write-Host ""
# Bad ports only count if nothing is good.
$ranked = Select-Port $results $curPort
$pick = $ranked[0]
if ($SwitchMarginMs -gt 0 -and (Test-Good $cur) -and $pick.port -ne $curPort -and $pick.score -gt $cur.score - $SwitchMarginMs) { $pick = $cur }
$runnerUp = $ranked | Where-Object { $_.port -ne $pick.port } | Select-Object -First 1
Show-Ranking $results $ranked $curPort

# ---------- 4. apply ----------
Step 4 "適用"
$final = $null
if ($pick.port -eq $curPort) {
  [void](Set-LivePort $curPort)
  $final = $cur
  $nx = if ($runnerUp) { "  (次点: ポート {0}  {1}/{2} ms  ロス {3})" -f $runnerUp.port, $runnerUp.min, $runnerUp.p90, $runnerUp.lost } else { '' }
  Ok ("今のポート {0} ({1}/{2} ms) が 13 ポート中で一番良いので、そのまま使います{3}" -f $curPort, $cur.min, $cur.p90, $nx)
} else {
  Info ("ポート {0} ({1}/{2} ms) が今のポート ({3}/{4} ms) より良いので、確かめてから移ります" -f $pick.port, $pick.min, $pick.p90, $cur.min, $cur.p90)
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
