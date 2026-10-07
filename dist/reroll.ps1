# reroll.ps1 - Move the running tunnel to another network path WITHOUT restarting it, once or continuously.
# Only the WireGuard source port changes (`wg set <name> listen-port`), so the tunnel, its routes and the game's
# connection stay up; the exit node follows the new port on the next packet. Measured cost of one switch: one
# round trip (~80 ms) of return packets, nothing else.
# Background: the home ISP <-> AWS links are picked per flow by a hash of the UDP ports, and a flow stays on its
# link. If that link gets congested the tunnel keeps suffering until the port changes.
#
#   reroll.bat                 one shot: measure the current path; if bad, try other ports and keep the best
#   reroll.ps1 -Watch          resident monitor (start-tunnel.ps1 starts it after setting up the tunnel):
#     pings 10.66.0.1 (inside the tunnel = the game's flow) and the exit node's EIP (a different flow) 20x/s each.
#     FLOW incident = a tunnel hitch of 2+ samples with no hitch on the EIP at the same time -> the tunnel's own
#     link, which a port change can fix. Hitches on both are PATH (whole KDDI <-> AWS path) and do not switch.
#     Switch when: the tunnel is bad for 5 s straight while the EIP is fine (sustained), or 3 FLOW incidents
#     within 180 s (the "a few times per round" pattern). After a switch the new port gets a 2 s check and is
#     replaced at once if it is a bad link. Two switches in a row that do not stop the FLOW incidents pause
#     rate switching for 15 min (probably the whole path); sustained switches are capped at 5 per 10 min.
# Probe / Set-LivePort / Show-Probe are duplicated in start-tunnel.ps1 on purpose (that file self-updates alone);
# start-tunnel.ps1 keeps this file up to date when it self-updates.
param(
  [string]$Conf,
  [int]$Candidates = 6,
  [int]$MaxMs = 150,
  [int]$GoodMarginMs = 5,
  [int]$JitterMs = 15,
  [switch]$Force,
  [switch]$NoPause,
  [switch]$Watch,
  [int]$WatchMinutes = 0,   # 0 = until the window is closed
  [switch]$InjectFlow,      # testing aid for -Watch: fake tunnel-only hitches at 20/30/40 s to exercise a switch
  [int[]]$PreferPorts = @(), # -Watch: ports that measured good at startup, tried first (in order) when switching
  [switch]$Preview,         # -Watch with fake samples: shows the monitor screen, touches nothing
  [int]$PreviewPort = 50720, # -Preview: the port start-tunnel's preview ended on
  [int]$SpikeMs = 20,
  [int]$MergeMs = 150,
  [int]$RateCount = 3,
  [int]$RateWindowSec = 180,
  [string]$Log = (Join-Path $env:LOCALAPPDATA "csvpn\monitor.csv")
)
$ErrorActionPreference = 'Continue'
$wg = "C:\Program Files\WireGuard\wg.exe"
$gw = "10.66.0.1"

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

# ---------- one-shot measurement / switching ----------
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
function Set-ConfPort([int]$port) {
  $txt = Get-Content $Conf | Where-Object { $_ -notmatch '^\s*ListenPort' }
  $txt = $txt -replace '^\[Interface\]', "[Interface]`nListenPort = $port"
  Set-Content -Path $Conf -Value $txt -Encoding ASCII
}

# ---------- resident monitor (-Watch) ----------
# All decisions live in Process-MSample / Step-Monitor / Invoke-Switch so they can be driven with synthetic samples.
function New-MTarget([string]$n, [string]$ip) {
  [pscustomobject]@{ name = $n; ip = $ip; pending = New-Object System.Collections.Generic.Queue[object]
    ring = New-Object 'int[]' 600; ringSec = New-Object 'long[]' 600; baseline = -1
    recent = New-Object System.Collections.Generic.List[object]; cur = $null; lastOk = 0L; samples = 0 }
}
function Reset-Baseline($tg) { $tg.ring = New-Object 'int[]' 600; $tg.ringSec = New-Object 'long[]' 600; $tg.baseline = -1 }
function Update-MBaseline($tg, [long]$nowSec) {
  $m = [int]::MaxValue
  for ($i = 0; $i -lt 600; $i++) { if ($tg.ringSec[$i] -gt 0 -and $tg.ringSec[$i] -gt $nowSec - 600 -and $tg.ring[$i] -lt $m) { $m = $tg.ring[$i] } }
  $tg.baseline = if ($m -eq [int]::MaxValue) { -1 } else { $m }
}
function Initialize-Monitor([long]$now = 0) {
  $script:mon = [pscustomobject]@{
    tunnel = (New-MTarget 'TUNNEL' $gw); aws = $null
    awsEvents = New-Object System.Collections.Generic.List[object]; tunEvents = New-Object System.Collections.Generic.List[object]
    flowTimes = New-Object System.Collections.Generic.List[long]; pathTimes = New-Object System.Collections.Generic.List[long]
    blips = 0; switches = 0; state = 'OK'; downSwitchAt = -1L; downWarned = $false
    lastRateSwitch = -1L; ineffective = 0; pauseUntil = -1L; sustainedTimes = New-Object System.Collections.Generic.List[long]
    guardUntil = -1L; guardTries = 0; globalMin = -1; lastSwitchAt = -1L; lastPathNote = -100000L; graceUntil = -1L; recentPorts = New-Object System.Collections.Generic.List[int]
    prefer = New-Object System.Collections.Generic.List[int]; timeline = New-Object System.Collections.Generic.List[string]
    port = 0; t0 = (Get-Date) }
}
function Process-MSample($tg, [long]$t, [int]$rtt) {
  $tg.samples++
  $tg.recent.Add([pscustomobject]@{ t = $t; rtt = $rtt })
  while ($tg.recent.Count -gt 0 -and $tg.recent[0].t -lt $t - 10000) { $tg.recent.RemoveAt(0) }
  $sec = [long][math]::Floor($t / 1000) + 1
  if ($rtt -ge 0) {
    $tg.lastOk = $t
    $slot = [int]($sec % 600)
    if ($tg.ringSec[$slot] -ne $sec) { $tg.ringSec[$slot] = $sec; $tg.ring[$slot] = $rtt } elseif ($rtt -lt $tg.ring[$slot]) { $tg.ring[$slot] = $rtt }
    if ($tg.baseline -lt 0 -or $rtt -lt $tg.baseline) { $tg.baseline = $rtt }
    if ($tg.name -eq 'TUNNEL' -and ($script:mon.globalMin -lt 0 -or $rtt -lt $script:mon.globalMin)) { $script:mon.globalMin = $rtt }
  }
  if ($tg.baseline -lt 0 -or $script:mon.state -eq 'NODE') { return }
  $spike = ($rtt -lt 0) -or ($rtt -gt $tg.baseline + $SpikeMs)
  # Assign inside the branches: `$x = if (...) { $list }` would unroll an empty List into $null.
  if ($tg.name -eq 'TUNNEL') { $list = $script:mon.tunEvents } else { $list = $script:mon.awsEvents }
  if ($spike) {
    if ($tg.cur -and ($t - $tg.cur.last) -le $MergeMs) { $tg.cur.last = $t; $tg.cur.n++; if ($rtt -lt 0) { $tg.cur.lost++ } elseif ($rtt -gt $tg.cur.peak) { $tg.cur.peak = $rtt } }
    else {
      if ($tg.cur) { $tg.cur.end = $tg.cur.last + 50; $list.Add($tg.cur) }
      $tg.cur = [pscustomobject]@{ start = $t; last = $t; end = $t + 50; n = 1; lost = [int]($rtt -lt 0); peak = [math]::Max(0, $rtt); base = $tg.baseline; done = $false }
    }
  } elseif ($tg.cur -and ($t - $tg.cur.last) -gt $MergeMs) { $tg.cur.end = $tg.cur.last + 50; $list.Add($tg.cur); $tg.cur = $null }
}
function Get-Window($tg, [long]$now, [int]$ms) {
  # Anchor at the newest processed sample, not at $now: a lost echo is only known 1.2 s after it was sent,
  # and everything sent after it waits behind it in the queue.
  $end = if ($tg.recent.Count) { [math]::Min($now, $tg.recent[$tg.recent.Count - 1].t) } else { $now }
  $s = @($tg.recent | Where-Object { $_.t -gt $end - $ms })
  $ok = @($s | Where-Object { $_.rtt -ge 0 } | ForEach-Object { $_.rtt } | Sort-Object)
  $loss = if ($s.Count) { 100.0 * ($s.Count - $ok.Count) / $s.Count } else { 0 }
  $spk = if ($tg.baseline -ge 0) { @($ok | Where-Object { $_ -gt $tg.baseline + $SpikeMs }).Count } else { 0 }
  [pscustomobject]@{ n = $s.Count; min = $(if ($ok.Count) { $ok[0] } else { -1 }); med = $(if ($ok.Count) { $ok[[int][math]::Floor($ok.Count / 2)] } else { -1 }); loss = $loss; spk = $spk }
}
function Write-MLine([string]$kind, [string]$text, [string]$color, [long]$now) {
  $when = $script:mon.t0.AddMilliseconds($now)
  $tag = switch ($kind) {
    'flow'   { @('跳ね', 'DarkYellow', 'Black') }
    'path'   { @('全体', 'DarkMagenta', 'White') }
    'switch' { @('切替', 'DarkCyan', 'White') }
    'error'  { @('失敗', 'DarkRed', 'White') }
    'note'   { if ($color -eq 'Magenta') { @('注意', 'DarkMagenta', 'White') } else { @('注意', 'DarkYellow', 'Black') } }
    default  { switch ($color) { 'Red' { @('状態', 'DarkRed', 'White') } 'Green' { @('復帰', 'DarkGreen', 'White') } 'Cyan' { @('監視', 'DarkCyan', 'White') } default { @('状態', 'DarkGray', 'White') } } }
  }
  Clear-Status
  Write-Host ("  {0:HH:mm:ss}  " -f $when) -NoNewline -ForegroundColor DarkGray
  Badge $tag[0] $tag[1] $tag[2]
  Write-Host " $text" -ForegroundColor $color
  if ($script:monLog) { try { Add-Content -Path $script:monLog -Encoding UTF8 -Value ('{0:yyyy-MM-ddTHH:mm:ss.fff},{1},"{2}"' -f $when, $kind, ($text -replace '"', "'")) } catch { } }
}
function Clear-Status { if ($script:statusLen -gt 0) { Write-Host ("`r" + (' ' * $script:statusLen) + "`r") -NoNewline; $script:statusLen = 0 } }
function Invoke-Switch([string]$reason, [long]$now) {
  # Next port that measured good at startup (if any), else a random one not used recently. Applied live and
  # judged fresh (new baseline) after a 2 s guard window.
  $m = $script:mon
  $old = $m.port
  $port = 0
  while ($m.prefer.Count -gt 0 -and -not $port) {
    $c = $m.prefer[0]; $m.prefer.RemoveAt(0)
    if ($c -ne $old -and $m.recentPorts -notcontains $c) { $port = $c }
  }
  $src = if ($port) { '良好だった候補' } else { 'ランダム' }
  if (-not $port) {
    $port = Get-Random -InputObject (40000..60000)
    for ($k = 0; $k -lt 20 -and ($m.recentPorts -contains $port -or $port -eq $old); $k++) { $port = Get-Random -InputObject (40000..60000) }
  }
  if (-not (Set-LivePort $port)) { Write-MLine 'error' ("ポート {0} への切り替えに失敗 (理由: {1})" -f $port, $reason) 'Red' $now; return $false }
  Set-ConfPort $port
  $m.recentPorts.Add($old); while ($m.recentPorts.Count -gt 10) { $m.recentPorts.RemoveAt(0) }
  $m.port = $port; $m.switches++; $m.lastSwitchAt = $now
  $tun = $m.tunnel; Reset-Baseline $tun; $tun.cur = $null; $tun.recent.Clear()
  $m.tunEvents.Clear(); $m.flowTimes.Clear()
  $m.guardUntil = $now + 2000
  Write-MLine 'switch' ("切替  ポート {0} -> {1} [{2}]  ({3})" -f $old, $port, $src, $reason) 'Cyan' $now
  return $true
}
function Step-Monitor([long]$now) {
  $m = $script:mon; $tun = $m.tunnel; $aws = $m.aws
  $nowSec = [long][math]::Floor($now / 1000) + 1
  Update-MBaseline $tun $nowSec; if ($aws) { Update-MBaseline $aws $nowSec }
  # --- node / tunnel reachability ---
  $tunSilent = $tun.samples -ge 100 -and ($now - $tun.lastOk) -gt 5000
  $awsSilent = $aws -and $aws.samples -ge 100 -and ($now - $aws.lastOk) -gt 5000
  if ($tunSilent -and $awsSilent) {
    if ($m.state -ne 'NODE') { $m.state = 'NODE'; $tun.cur = $null; if ($aws) { $aws.cur = $null }; $m.tunEvents.Clear(); $m.awsEvents.Clear()
      Write-MLine 'state' '出口ノードが応答しない (停止中? 稼働は 19:00-02:00 JST)。戻るまで切り替えません' 'Red' $now }
    return
  }
  if ($m.state -eq 'NODE') { $m.state = 'OK'; $m.graceUntil = $now + 6000; Write-MLine 'state' '出口ノードが復帰しました' 'Green' $now }
  if ($tunSilent) {
    $tun.cur = $null; $m.tunEvents.Clear(); $m.guardUntil = -1   # the DOWN line covers it; do not count these as hitches later
    if ($m.state -ne 'DOWN') { $m.state = 'DOWN'; $m.downSwitchAt = $now; $m.downWarned = $false
      Write-MLine 'state' 'トンネルの中だけ届かない。ポートを変えてみます' 'Red' $now; [void](Invoke-Switch 'トンネル無応答' $now) }
    elseif (-not $m.downWarned -and ($now - $m.downSwitchAt) -gt 10000) { $m.downWarned = $true
      Write-MLine 'state' 'まだ届きません。start-tunnel.bat で張り直してください (監視は続けます)' 'Red' $now }
    return
  }
  if ($m.state -eq 'DOWN') { $m.state = 'OK'; $m.graceUntil = $now + 6000; Write-MLine 'state' 'トンネルが復帰しました' 'Green' $now }
  # --- guard right after a switch: replace a new port that is obviously on a bad link ---
  if ($m.guardUntil -ge 0 -and $now -ge $m.guardUntil) {
    $g = Get-Window $tun $now 2000
    $bad = $g.n -ge 10 -and ($g.loss -ge 20 -or ($g.min -ge 0 -and $m.globalMin -ge 0 -and $g.med -gt $m.globalMin + 30) -or $g.min -ge $MaxMs)
    $m.guardUntil = -1
    if ($bad -and $m.guardTries -lt 4) { $m.guardTries++; [void](Invoke-Switch ("切替先が悪い経路 ({0} ms / ロス {1:N0}%)" -f $g.med, $g.loss) $now); return }
    if ($bad) { Write-MLine 'note' '切替先が 4 回続けて悪い経路でした。このポートのまま様子を見ます' 'Yellow' $now }
    $m.guardTries = 0
  }
  if ($m.guardUntil -ge 0) { return }
  # --- classify finished tunnel events (wait 1.5 s so overlapping EIP events are known) ---
  for ($i = $m.awsEvents.Count - 1; $i -ge 0; $i--) { if ($m.awsEvents[$i].end -lt $now - 15000) { $m.awsEvents.RemoveAt($i) } }
  for ($i = 0; $i -lt $m.tunEvents.Count; $i++) {
    $e = $m.tunEvents[$i]
    if ($e.done -or $e.end -gt $now - 1500) { continue }
    $e.done = $true
    if ($e.n -lt 2) { $m.blips++; continue }
    $ovl = @($m.awsEvents | Where-Object { $_.start -le $e.end + $MergeMs -and $_.end -ge $e.start - $MergeMs }).Count -gt 0
    if ($aws -and $aws.cur -and $aws.cur.start -le $e.end + $MergeMs) { $ovl = $true }
    $desc = if ($e.peak -gt 0) { "+{0} ms" -f ($e.peak - $e.base) } else { "ロス" }
    if ($ovl) { $m.pathTimes.Add($e.start); Write-MLine 'path' ("経路全体の跳ね  {0:N2}s {1} (EIP も同時。ポート変更では直らない)" -f (($e.end - $e.start) / 1000), $desc) 'Magenta' $now }
    else {
      $m.flowTimes.Add($e.start)
      $cnt = if ($m.pauseUntil -ge 0) { '切替休止中' } else { "直近 {0} 秒で {1}/{2} 回" -f $RateWindowSec, @($m.flowTimes | Where-Object { $_ -gt $now - $RateWindowSec * 1000 }).Count, $RateCount }
      Write-MLine 'flow' ("トンネルの跳ね  {0:N2}s {1}  ({2})" -f (($e.end - $e.start) / 1000), $desc, $cnt) 'Yellow' $now
    }
  }
  for ($i = $m.tunEvents.Count - 1; $i -ge 0; $i--) { if ($m.tunEvents[$i].done) { $m.tunEvents.RemoveAt($i) } }
  for ($i = $m.flowTimes.Count - 1; $i -ge 0; $i--) { if ($m.flowTimes[$i] -lt $now - $RateWindowSec * 1000) { $m.flowTimes.RemoveAt($i) } }
  for ($i = $m.pathTimes.Count - 1; $i -ge 0; $i--) { if ($m.pathTimes[$i] -lt $now - $RateWindowSec * 1000) { $m.pathTimes.RemoveAt($i) } }
  for ($i = $m.sustainedTimes.Count - 1; $i -ge 0; $i--) { if ($m.sustainedTimes[$i] -lt $now - 600000) { $m.sustainedTimes.RemoveAt($i) } }
  # --- sustained: tunnel bad for a few seconds while the EIP is fine ---
  # Near-total loss is an outage forming (NODE / DOWN above take it after 5 s), not a bad link: leave it alone.
  if ($tun.baseline -ge 0 -and ($now - $m.lastSwitchAt) -gt 7000 -and $now -ge $m.graceUntil) {
    $tw = Get-Window $tun $now 5000
    $t1 = Get-Window $tun $now 1000
    $forming = $t1.n -ge 10 -and $t1.loss -ge 90
    if (-not $forming -and $tw.n -ge 50 -and $tw.loss -lt 90 -and ($tw.loss -ge 20 -or $tw.med -gt $tun.baseline + 30)) {
      $aw = if ($aws) { Get-Window $aws $now 5000 } else { $null }
      $awsOk = $aw -and $aw.n -ge 50 -and $aw.loss -lt 20 -and $aws.baseline -ge 0 -and $aw.med -le $aws.baseline + 15
      if ($awsOk -and $m.sustainedTimes.Count -lt 5) {
        $m.sustainedTimes.Add($now)
        [void](Invoke-Switch ("悪い状態が続いた ({0} ms / ロス {1:N0}%)" -f $tw.med, $tw.loss) $now); return
      }
      if ($now - $m.lastPathNote -gt 30000) {
        $m.lastPathNote = $now
        if ($awsOk) { Write-MLine 'note' '悪い状態が続いていますが、10 分で 5 回切り替えたので休止中です' 'Yellow' $now }
        else { Write-MLine 'note' ("経路全体が悪い状態が続いています (トンネル {0} ms / EIP も悪い)。ポート変更では直りません" -f $tw.med) 'Magenta' $now }
      }
    }
  }
  # --- rate: RateCount FLOW incidents within RateWindowSec ---
  if ($m.lastRateSwitch -ge 0 -and ($now - $m.lastRateSwitch) -gt $RateWindowSec * 1000) { $m.ineffective = 0 }
  if ($m.pauseUntil -ge 0 -and $now -ge $m.pauseUntil) { $m.pauseUntil = -1; $m.ineffective = 0; Write-MLine 'note' '切り替えの休止を解除しました' 'Gray' $now }
  if ($m.flowTimes.Count -ge $RateCount) {
    if ($m.pauseUntil -ge 0) { return }
    if ($m.lastRateSwitch -ge 0 -and ($now - $m.lastRateSwitch) -le $RateWindowSec * 1000) { $m.ineffective++ }
    if ($m.ineffective -ge 2) {
      $m.pauseUntil = $now + 900000; $m.flowTimes.Clear()
      Write-MLine 'note' 'ポートを 2 回変えても跳ねが減りません。経路全体の可能性が高いので 15 分間は回数による切り替えを休みます' 'Magenta' $now
      return
    }
    $m.lastRateSwitch = $now
    [void](Invoke-Switch ("直近 {0} 秒でトンネルの跳ね {1} 回" -f $RateWindowSec, $m.flowTimes.Count) $now)
  }
}
function Update-Timeline([long]$now) {
  # One cell per second: green = calm, yellow = a hitch or a lost echo, red = bad, grey = no data / node down.
  $m = $script:mon; $tun = $m.tunnel
  $w = Get-Window $tun $now 1000
  $c = if ($m.state -ne 'OK' -or $w.n -eq 0) { 'DarkGray' }
       elseif ($w.loss -ge 20 -or ($tun.baseline -ge 0 -and $w.med -gt $tun.baseline + 30)) { 'DarkRed' }
       elseif ($w.loss -gt 0 -or $w.spk -gt 0) { 'DarkYellow' }
       else { 'DarkGreen' }
  $m.timeline.Add($c); while ($m.timeline.Count -gt 30) { $m.timeline.RemoveAt(0) }
}
function Show-Status([long]$now) {
  $m = $script:mon; $w = Get-Window $m.tunnel $now 5000
  Update-Timeline $now
  $badge = switch ($m.state) { 'NODE' { @('停止中', 'DarkRed', 'White') } 'DOWN' { @('無応答', 'DarkRed', 'White') }
    default { if ($m.pauseUntil -ge 0) { @('休止中', 'DarkYellow', 'Black') } else { @('監視中', 'DarkGreen', 'White') } } }
  $rt = if ($w.min -ge 0) { "{0}/{1} ms" -f $w.min, $w.med } else { '--- ms' }
  $text = " {0:HH:mm:ss}  ポート {1}  {2}  ロス{3,3:N0}%  跳ね {4}/{5}  切替 {6}  " -f $m.t0.AddMilliseconds($now), $m.port, $rt, $w.loss, $m.flowTimes.Count, $RateCount, $m.switches
  # Keep the whole line inside the window: a wrapped status line cannot be rewritten in place with `r.
  $max = 100; try { $max = $Host.UI.RawUI.WindowSize.Width - 2 } catch { }
  $fixed = 2 + (Get-DisplayWidth $badge[0]) + 2 + (Get-DisplayWidth $text)
  $cells = [math]::Max(0, [math]::Min($m.timeline.Count, $max - $fixed))
  Write-Host "`r  " -NoNewline
  Badge $badge[0] $badge[1] $badge[2]
  Write-Host $text -NoNewline -ForegroundColor $(if ($m.flowTimes.Count -gt 0) { 'Yellow' } else { 'Gray' })
  for ($i = $m.timeline.Count - $cells; $i -lt $m.timeline.Count; $i++) { Write-Host ' ' -NoNewline -BackgroundColor $m.timeline[$i] }
  $width = $fixed + $cells
  if ($script:statusLen -gt $width) { Write-Host (' ' * ($script:statusLen - $width)) -NoNewline }
  $script:statusLen = $width
  try { $Host.UI.RawUI.WindowTitle = "csvpn 監視中 | ポート $($m.port) | $rt" } catch { }
}
function Get-PreviewRtt([string]$n, [long]$t, [int]$port) {
  # Fake samples for -Preview: three tunnel-only hitches on the first port (-> a switch), a whole-path hitch, a blip.
  $r = $(if ($n -eq 'TUNNEL') { 79 } else { 80 }) + (Get-Random -Minimum 0 -Maximum 3)
  $s = $t / 1000.0
  if ($n -eq 'TUNNEL' -and $port -eq $script:pvFirst) { foreach ($h in 8, 15, 22) { if ($s -ge $h -and $s -lt $h + 0.35) { return $r + 95 } } }
  if ($s -ge 38 -and $s -lt 38.3) { return $r + 70 }
  if ($n -eq 'TUNNEL' -and $s -ge 31 -and $s -lt 31.05) { return $r + 60 }
  $r
}

function Start-Watch {
  $script:statusLen = 0
  $script:monLog = $Log
  try { $d = Split-Path $Log; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; if (-not (Test-Path $Log)) { 'time,type,detail' | Set-Content -Path $Log -Encoding UTF8 } } catch { $script:monLog = $null }
  $ep = if ($Preview) { '52.74.31.125' } else { (Get-Content $Conf | Where-Object { $_ -match '^\s*Endpoint\s*=' }) -replace '^\s*Endpoint\s*=\s*', '' -replace ':\d+\s*$', '' }
  Initialize-Monitor
  $m = $script:mon
  if ($ep) { $m.aws = New-MTarget 'AWS' $ep.Trim() }
  $m.port = Get-LivePort
  foreach ($p in $PreferPorts) { if ($p -and $p -ne $m.port) { $m.prefer.Add($p) } }
  $script:pvFirst = $m.port
  Write-Host ""
  Write-Host "  経路の監視を続けます (このウィンドウを閉じても、トンネルはそのまま使えます)" -ForegroundColor White
  Info ("トンネル内 10.66.0.1 と出口ノード {0} を 1 秒 20 回ずつ測定。記録: {1}" -f $(if ($m.aws) { $m.aws.ip } else { '(なし)' }), $Log)
  Info ("トンネルだけが数秒続けて悪い、または {0} 秒で {1} 回跳ねたら、試合を切らずに別の経路へ切り替えます" -f $RateWindowSec, $RateCount)
  if ($m.prefer.Count) { Info ("切り替え先は、起動時に良好だったポート {0} 個から順に使います" -f $m.prefer.Count) }
  Write-Host "         右端の帯は直近 30 秒 (1 マス 1 秒、右が最新):  " -NoNewline -ForegroundColor Gray
  foreach ($lg in @(@('DarkGreen', '安定'), @('DarkYellow', '跳ね'), @('DarkRed', '悪い'), @('DarkGray', 'なし'))) { Write-Host '  ' -NoNewline -BackgroundColor $lg[0]; Write-Host (" {0}  " -f $lg[1]) -NoNewline -ForegroundColor Gray }
  Write-Host ""
  Write-MLine 'state' ("監視開始  ポート {0}" -f $m.port) 'Cyan' 0
  $sw = [Diagnostics.Stopwatch]::StartNew(); $tick = 0L
  $stopAt = if ($WatchMinutes -gt 0) { $WatchMinutes * 60000L } else { [long]::MaxValue }
  $targets = @($m.tunnel); if ($m.aws) { $targets += $m.aws }
  while ($sw.ElapsedMilliseconds -lt $stopAt) {
    $now = $sw.ElapsedMilliseconds
    foreach ($tg in $targets) {
      if ($Preview) { Process-MSample $tg $now (Get-PreviewRtt $tg.name $now $m.port); continue }
      $p = New-Object System.Net.NetworkInformation.Ping
      $tg.pending.Enqueue([pscustomobject]@{ t = $now; ping = $p; task = $p.SendPingAsync($tg.ip, 1000) })
      while ($tg.pending.Count -gt 0) {
        $h = $tg.pending.Peek()
        if (-not $h.task.IsCompleted -and ($now - $h.t) -lt 1200) { break }
        [void]$tg.pending.Dequeue()
        $rtt = if ($h.task.IsCompleted -and -not $h.task.IsFaulted -and $h.task.Result.Status -eq 'Success') { [int]$h.task.Result.RoundtripTime } else { -1 }
        $h.ping.Dispose()
        if ($InjectFlow -and $tg.name -eq 'TUNNEL' -and $rtt -ge 0) { foreach ($s in 20, 30, 40) { if ($h.t -ge $s * 1000 -and $h.t -lt $s * 1000 + 300) { $rtt += 100 } } }
        if ($h.t -ge $m.lastSwitchAt -or $tg.name -ne 'TUNNEL') { Process-MSample $tg $h.t $rtt }   # drop echoes sent before the last switch
      }
    }
    if ($tick % 5 -eq 0) { Step-Monitor $now }
    if ($tick % 20 -eq 0) { Show-Status $now }
    if ($tick % 200 -eq 0 -and -not $Preview) {
      $svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
      if (-not $svc -or $svc.Status -ne 'Running') { Write-MLine 'state' 'トンネルが停止されたので監視を終了します' 'Gray' $now; break }
    }
    $tick++
    while ($sw.ElapsedMilliseconds -lt $tick * 50) { Start-Sleep -Milliseconds 2 }
  }
  Clear-Status
  Write-MLine 'state' ("監視終了  切替 {0} 回" -f $m.switches) 'Cyan' $sw.ElapsedMilliseconds
}

# ---------- main ----------
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (tests): define functions only
try { $Host.UI.RawUI.WindowTitle = "csvpn - reroll" } catch { }
if ($Preview) {
  # Fake tunnel helpers: the monitor screen with synthetic samples; nothing real is touched.
  $name = 'preview-split'
  function Set-LivePort([int]$port) { $true }
  function Set-ConfPort([int]$port) { }
  function Get-LivePort { $PreviewPort }
  if ($WatchMinutes -le 0) { $WatchMinutes = 1 }
  $Log = $null
  if (-not $Watch) { Header 'reroll (preview)' }
  Start-Watch; Done 0
}
if (-not $Conf) {
  $confs = Get-ChildItem -Path $PSScriptRoot -Filter *.conf | Sort-Object { $_.Name -notlike '*-split.conf' }, Name
  if (-not $confs) { Fail "このフォルダに .conf がありません。start-tunnel.bat と同じフォルダで実行してください。"; Done 1 }
  $Conf = $confs[0].FullName
}
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Fail "トンネル '$name' が動いていません。先に start-tunnel.bat を実行してください。"; Done 1 }
$curPort = Get-LivePort
if (-not $curPort) { Fail "wg.exe でトンネルの状態を読めませんでした (管理者権限で実行していますか?)"; Done 1 }

if ($Watch) { Start-Watch; Done 0 }

Header 'reroll  //  試合を切らずに経路だけ変える'
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
  $live = Get-LivePort
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
