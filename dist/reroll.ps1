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
  [pscustomobject]@{ n = $s.Count; min = $(if ($ok.Count) { $ok[0] } else { -1 }); med = $(if ($ok.Count) { $ok[[int][math]::Floor($ok.Count / 2)] } else { -1 }); loss = $loss }
}
function Write-MLine([string]$kind, [string]$text, [string]$color, [long]$now) {
  $when = $script:mon.t0.AddMilliseconds($now)
  Clear-Status
  Write-Host ("  {0:HH:mm:ss}  " -f $when) -NoNewline -ForegroundColor DarkGray
  Write-Host $text -ForegroundColor $color
  if ($script:monLog) { try { Add-Content -Path $script:monLog -Encoding UTF8 -Value ('{0:yyyy-MM-ddTHH:mm:ss.fff},{1},"{2}"' -f $when, $kind, ($text -replace '"', "'")) } catch { } }
}
function Get-DisplayWidth([string]$s) { $w = 0; foreach ($ch in $s.ToCharArray()) { if ([int]$ch -ge 0x1100) { $w += 2 } else { $w++ } }; $w }
function Clear-Status { if ($script:statusLen -gt 0) { Write-Host ("`r" + (' ' * $script:statusLen) + "`r") -NoNewline; $script:statusLen = 0 } }
function Invoke-Switch([string]$reason, [long]$now) {
  # Pick a port not used recently, apply it live, judge it fresh (new baseline) after a 2 s guard window.
  $m = $script:mon
  $old = $m.port
  $port = Get-Random -InputObject (40000..60000)
  for ($k = 0; $k -lt 20 -and ($m.recentPorts -contains $port -or $port -eq $old); $k++) { $port = Get-Random -InputObject (40000..60000) }
  if (-not (Set-LivePort $port)) { Write-MLine 'error' ("ポート {0} への切り替えに失敗 (理由: {1})" -f $port, $reason) 'Red' $now; return $false }
  Set-ConfPort $port
  $m.recentPorts.Add($old); while ($m.recentPorts.Count -gt 10) { $m.recentPorts.RemoveAt(0) }
  $m.port = $port; $m.switches++; $m.lastSwitchAt = $now
  $tun = $m.tunnel; Reset-Baseline $tun; $tun.cur = $null; $tun.recent.Clear()
  $m.tunEvents.Clear(); $m.flowTimes.Clear()
  $m.guardUntil = $now + 2000
  Write-MLine 'switch' ("切替  ポート {0} -> {1}  ({2})" -f $old, $port, $reason) 'Cyan' $now
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
function Show-Status([long]$now) {
  $m = $script:mon; $w = Get-Window $m.tunnel $now 5000
  $st = switch ($m.state) { 'NODE' { 'ノード停止中' } 'DOWN' { 'トンネル無応答' } default { if ($m.pauseUntil -ge 0) { '監視中 (切替休止)' } else { '監視中' } } }
  $rt = if ($w.min -ge 0) { "{0}/{1} ms" -f $w.min, $w.med } else { '---' }
  $line = "  {0:HH:mm:ss} {1} | ポート {2} | {3} ロス{4:N0}% | 跳ね {5}/{6} 全体 {7} 単発 {8} | 切替 {9}" -f $m.t0.AddMilliseconds($now), $st, $m.port, $rt, $w.loss, $m.flowTimes.Count, $RateCount, $m.pathTimes.Count, $m.blips, $m.switches
  # Keep the line inside the window: a wrapped status line cannot be rewritten in place with `r.
  $max = 100; try { $max = $Host.UI.RawUI.WindowSize.Width - 2 } catch { }
  while ((Get-DisplayWidth $line) -gt $max -and $line.Length -gt 10) { $line = $line.Substring(0, $line.Length - 1) }
  $width = Get-DisplayWidth $line
  Write-Host ("`r" + $line + (' ' * [math]::Max(0, $script:statusLen - $width))) -NoNewline -ForegroundColor $(if ($m.state -ne 'OK') { 'Red' } elseif ($m.flowTimes.Count -gt 0) { 'Yellow' } else { 'DarkGreen' })
  $script:statusLen = $width
  try { $Host.UI.RawUI.WindowTitle = "csvpn 監視中 | ポート $($m.port) | $rt" } catch { }
}

function Start-Watch {
  $script:statusLen = 0
  $script:monLog = $Log
  try { $d = Split-Path $Log; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; if (-not (Test-Path $Log)) { 'time,type,detail' | Set-Content -Path $Log -Encoding UTF8 } } catch { $script:monLog = $null }
  $ep = (Get-Content $Conf | Where-Object { $_ -match '^\s*Endpoint\s*=' }) -replace '^\s*Endpoint\s*=\s*', '' -replace ':\d+\s*$', ''
  Initialize-Monitor
  $m = $script:mon
  if ($ep) { $m.aws = New-MTarget 'AWS' $ep.Trim() }
  $m.port = Get-LivePort
  Write-Host ""
  Write-Host "  経路の監視を続けます (このウィンドウを閉じても、トンネルはそのまま使えます)" -ForegroundColor White
  Info ("トンネル内 10.66.0.1 と出口ノード {0} を 1 秒 20 回ずつ測定。記録: {1}" -f $(if ($m.aws) { $m.aws.ip } else { '(なし)' }), $Log)
  Info ("トンネルだけが 5 秒続けて悪い、または {0} 秒で {1} 回跳ねたら、試合を切らずに別の経路へ切り替えます" -f $RateWindowSec, $RateCount)
  Write-MLine 'state' ("監視開始  ポート {0}" -f $m.port) 'Cyan' 0
  $sw = [Diagnostics.Stopwatch]::StartNew(); $tick = 0L
  $stopAt = if ($WatchMinutes -gt 0) { $WatchMinutes * 60000L } else { [long]::MaxValue }
  $targets = @($m.tunnel); if ($m.aws) { $targets += $m.aws }
  while ($sw.ElapsedMilliseconds -lt $stopAt) {
    $now = $sw.ElapsedMilliseconds
    foreach ($tg in $targets) {
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
    if ($tick % 200 -eq 0) {
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

Write-Host ""
Rule
Write-Host "   csvpn  |  reroll  |  試合を切らずに経路だけ変える" -ForegroundColor Cyan
Rule
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
