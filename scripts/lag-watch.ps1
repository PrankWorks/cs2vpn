# lag-watch.ps1 - Run in the background while playing. Logs every short hitch ("a few times per round") with
# WHERE it happened, so a lag you felt at 21:35 can be looked up afterwards. No admin needed, switches nothing.
#
# Points pinged continuously (ICMP):
#   LAN    : home router                 every 100 ms
#   JP     : 1.1.1.1 (Cloudflare Tokyo)  every 200 ms (Cloudflare thins ICMP replies; its loss alone is ignored)
#   AWS    : exit node public IP (EIP)   every  50 ms (KDDI -> AWS, but a different flow than the tunnel)
#   TUNNEL : 10.66.0.1 through WireGuard every  50 ms (exactly the path the game packets take to the node)
#   SERVER : -Server <ip> (optional)     every  50 ms (the FACEIT server from `status`, through the tunnel)
# A sample is a spike when it is lost or slower than (minimum of the last 10 minutes) + SpikeMs.
# Spikes of one point closer than MergeMs form an event; events of different points that overlap form an incident.
# Incident -> segment:
#   LOCAL    : LAN involved                    -> PC / home LAN
#   DOMESTIC : TUNNEL + AWS + JP               -> home line / domestic segment
#   PATH     : TUNNEL + AWS                    -> KDDI <-> AWS as a whole; a port change probably will not help
#   FLOW     : TUNNEL (+ SERVER) without AWS   -> only the tunnel's flow; dist\reroll.bat (port change) is the lever
#   SERVER   : SERVER without TUNNEL           -> node -> game server segment, or the game server itself
#   UNCLEAR  : any other combination (AWS alone, TUNNEL + JP without AWS, ...)
# An incident where no point has 2+ consecutive spike samples (MinSamples) is a "blip": one delayed or lost echo,
# which busy hosts do to ICMP (the FACEIT server does it every ~20 s). Blips go to the CSV only (type=blip).
# Output: one line per incident, one summary line per minute, all appended to the CSV ($Log).
param(
  [string]$Server,
  [int]$SpikeMs = 20,
  [int]$MergeMs = 150,
  [int]$MinSamples = 2,
  [int]$BaselineSec = 600,
  [int]$Minutes = 0,
  [string]$Gateway = "10.66.0.1",
  [string]$Endpoint,
  [string]$Log = (Join-Path $PSScriptRoot "logs\lag-watch.csv")   # next to the script, not in AppData
)
$ErrorActionPreference = 'Stop'
$TickMs = 50

function New-Target([string]$name, [string]$ip, [int]$every) {
  [pscustomobject]@{
    name = $name; ip = $ip; every = $every
    pending = New-Object System.Collections.Generic.Queue[object]
    ring = New-Object 'int[]' $BaselineSec; ringSec = New-Object 'long[]' $BaselineSec
    baseline = -1; lastOk = 0L; cur = $null; samples = 0
  }
}

function Update-Baseline($tg, [long]$nowSec) {
  $m = [int]::MaxValue
  for ($i = 0; $i -lt $BaselineSec; $i++) { if ($tg.ringSec[$i] -gt $nowSec - $BaselineSec -and $tg.ringSec[$i] -gt 0 -and $tg.ring[$i] -lt $m) { $m = $tg.ring[$i] } }
  $tg.baseline = if ($m -eq [int]::MaxValue) { -1 } else { $m }
}

function Close-Event($tg) {
  if (-not $tg.cur) { return }
  $e = $tg.cur; $tg.cur = $null
  $e.end = $e.last + $tg.every * $TickMs
  if ($script:outage -and $tg.name -in $script:outageTargets) { return }
  $script:pendingEvents.Add($e)
}

function Process-Sample($tg, [long]$t, [int]$rtt) {
  # $t = send time in ms since start, $rtt = -1 when lost
  $tg.samples++
  $sec = [long][math]::Floor($t / 1000) + 1
  if ($rtt -ge 0) {
    $tg.lastOk = $t
    $slot = [int]($sec % $BaselineSec)
    if ($tg.ringSec[$slot] -ne $sec) { $tg.ringSec[$slot] = $sec; $tg.ring[$slot] = $rtt } elseif ($rtt -lt $tg.ring[$slot]) { $tg.ring[$slot] = $rtt }
    if ($tg.baseline -lt 0 -or $rtt -lt $tg.baseline) { $tg.baseline = $rtt }
  }
  if ($tg.baseline -lt 0) { return }
  if ($script:outage -and $tg.name -in $script:outageTargets) { $tg.cur = $null; return }   # one NODE/DOWN line covers it
  $spike = ($rtt -lt 0) -or ($rtt -gt $tg.baseline + $SpikeMs)
  if ($spike) {
    if ($tg.cur -and ($t - $tg.cur.last) -le $MergeMs) {
      $tg.cur.last = $t; $tg.cur.n++
      if ($rtt -lt 0) { $tg.cur.lost++ } else { $tg.cur.delayed++; if ($rtt -gt $tg.cur.peak) { $tg.cur.peak = $rtt } }
    } else {
      Close-Event $tg
      $script:eventId++
      $tg.cur = [pscustomobject]@{ id = $script:eventId; target = $tg.name; start = $t; last = $t; end = $t; n = 1
        lost = $(if ($rtt -lt 0) { 1 } else { 0 }); delayed = $(if ($rtt -ge 0) { 1 } else { 0 }); peak = $(if ($rtt -ge 0) { $rtt } else { 0 }); base = $tg.baseline }
    }
  } elseif ($tg.cur -and ($t - $tg.cur.last) -gt $MergeMs) {
    Close-Event $tg
  }
}

function Get-Segment($set) {
  if ($set -contains 'LAN') { return 'LOCAL' }
  if ($set -contains 'TUNNEL' -and $set -contains 'AWS' -and $set -contains 'JP') { return 'DOMESTIC' }
  if ($set -contains 'TUNNEL' -and $set -contains 'AWS') { return 'PATH' }
  if ($set -contains 'TUNNEL' -and $set -notcontains 'JP') { return 'FLOW' }
  if ($set -contains 'SERVER' -and $set -notcontains 'TUNNEL') { return 'SERVER' }
  return 'UNCLEAR'
}
$SegmentHint = @{ LOCAL = 'PC / 自宅 LAN'; DOMESTIC = '国内区間 (回線側)'; PATH = 'KDDI-AWS の経路全体 (ポート変更は効きにくい)'
  FLOW = 'トンネルの経路だけ (reroll が効く種類)'; SERVER = 'ノード -> ゲームサーバー区間 / サーバー自体'; UNCLEAR = '判定不能' }

function Emit-Incident($events) {
  $mi = [long][math]::Floor((($events | Measure-Object -Property start -Minimum).Minimum) / 60000)
  $tunnelOrAwsLoss = @($events | Where-Object { $_.target -in 'AWS', 'TUNNEL' -and $_.lost -gt 0 }).Count -gt 0
  # 1.1.1.1 dropping echoes on its own is Cloudflare rate limiting, not the line.
  $events = @($events | Where-Object { -not ($_.target -eq 'JP' -and $_.delayed -eq 0 -and -not $tunnelOrAwsLoss) })
  if (-not $script:minuteBuckets.ContainsKey($mi)) { $script:minuteBuckets[$mi] = @{ FLOW = 0; PATH = 0; DOMESTIC = 0; LOCAL = 0; SERVER = 0; UNCLEAR = 0; JP = 0; BLIP = 0 } }
  if ($events.Count -eq 0) { $script:minuteBuckets[$mi].JP++; return }
  $present = @($events | ForEach-Object { $_.target } | Select-Object -Unique)
  $set = @('LAN', 'JP', 'AWS', 'TUNNEL', 'SERVER' | Where-Object { $present -contains $_ })
  $seg = Get-Segment $set
  $start = ($events | Measure-Object -Property start -Minimum).Minimum
  $end = ($events | Measure-Object -Property end -Maximum).Maximum
  $parts = foreach ($n in $set) {
    $es = @($events | Where-Object { $_.target -eq $n })
    $pk = ($es | Measure-Object -Property peak -Maximum).Maximum
    $ls = ($es | Measure-Object -Property lost -Sum).Sum
    $txt = if ($pk -gt 0) { "{0} {1}ms(+{2})" -f $n, $pk, ($pk - $es[0].base) } else { "$n ロスのみ" }
    if ($ls -gt 0) { $txt += " lost$ls" }
    $txt
  }
  $detail = $parts -join ', '
  # A single delayed/lost echo (one 50 ms sample) is what a busy host does to ICMP; a felt hitch spans 2+ samples.
  $maxN = ($events | Measure-Object -Property n -Maximum).Maximum
  if ($maxN -lt $MinSamples) {
    $script:minuteBuckets[$mi].BLIP++
    Write-Out 'blip' $seg ([int]($end - $start)) ($set -join ';') $detail $start '' -NoConsole
    return
  }
  $script:minuteBuckets[$mi][$seg]++
  Write-Out 'incident' $seg ([int]($end - $start)) ($set -join ';') $detail $start ("{0,-8} {1,5:N2}s  {2}  -> {3}" -f $seg, (($end - $start) / 1000), $detail, $SegmentHint[$seg])
}

function Flush-Incidents([long]$now) {
  # Group finished events that overlap in time (transitively). Wait until every point has reported past the group.
  while ($script:pendingEvents.Count -gt 0) {
    $first = $script:pendingEvents | Sort-Object start | Select-Object -First 1
    $group = @($first); $gs = $first.start; $ge = $first.end; $grew = $true
    while ($grew) {
      $grew = $false
      foreach ($e in $script:pendingEvents) {
        if (($group | ForEach-Object { $_.id }) -contains $e.id) { continue }
        if ($e.start -le $ge + $MergeMs -and $e.end -ge $gs - $MergeMs) { $group += $e; $gs = [math]::Min($gs, $e.start); $ge = [math]::Max($ge, $e.end); $grew = $true }
      }
    }
    if ($ge -gt $now - 1500) { return }
    foreach ($tg in $script:targets) { if ($tg.cur -and $tg.cur.start -le $ge + $MergeMs) { return } }
    $ids = @($group | ForEach-Object { $_.id })
    for ($i = $script:pendingEvents.Count - 1; $i -ge 0; $i--) { if ($ids -contains $script:pendingEvents[$i].id) { $script:pendingEvents.RemoveAt($i) } }
    Emit-Incident $group
  }
}

function Check-Outage([long]$now) {
  $aws = $script:targets | Where-Object { $_.name -eq 'AWS' }; $tun = $script:targets | Where-Object { $_.name -eq 'TUNNEL' }
  if (-not $aws -or -not $tun -or $tun.samples -lt 100) { return }
  $awsDown = ($now - $aws.lastOk) -gt 5000; $tunDown = ($now - $tun.lastOk) -gt 5000
  $state = if ($awsDown -and $tunDown) { 'NODE' } elseif ($tunDown) { 'DOWN' } else { $null }
  if ($state -eq $script:outage) { return }
  if ($state) {
    $script:outageTargets = if ($state -eq 'NODE') { @('AWS', 'TUNNEL', 'SERVER') } else { @('TUNNEL', 'SERVER') }
    foreach ($tg in $script:targets) { if ($tg.name -in $script:outageTargets) { $tg.cur = $null } }
    for ($i = $script:pendingEvents.Count - 1; $i -ge 0; $i--) { if ($script:pendingEvents[$i].target -in $script:outageTargets) { $script:pendingEvents.RemoveAt($i) } }
    $msg = if ($state -eq 'NODE') { '出口ノードが応答しない (停止中? 稼働は 19:00-02:00 JST)。戻るまで記録を止めます' } else { 'トンネルの中に届かない (トンネルが無効か切れている)。戻るまで記録を止めます' }
    Write-Out 'state' $state 0 '' $msg $now ("{0,-8} {1}" -f $state, $msg)
  } else {
    Write-Out 'state' 'RECOVERED' 0 '' "$script:outage から復帰" $now ("RECOVERED {0} から復帰" -f $script:outage)
  }
  $script:outage = $state
}

$SegmentColor = @{ LOCAL = 'Red'; DOMESTIC = 'Cyan'; PATH = 'Magenta'; FLOW = 'Yellow'; SERVER = 'DarkYellow'; UNCLEAR = 'Gray'
  NODE = 'Red'; DOWN = 'Red'; RECOVERED = 'Green'; START = 'Cyan'; STOP = 'Cyan' }
function Write-Out([string]$type, [string]$seg, [int]$durMs, [string]$targetsTxt, [string]$detail, [long]$t, [string]$console, [switch]$NoConsole) {
  $when = $script:t0.AddMilliseconds($t)
  if (-not $NoConsole) {
    $color = if ($type -eq 'minute') { 'DarkGray' } elseif ($SegmentColor.ContainsKey($seg)) { $SegmentColor[$seg] } else { 'Gray' }
    Write-Host ("  {0:HH:mm:ss.fff}  " -f $when) -NoNewline -ForegroundColor DarkGray
    Write-Host $console -ForegroundColor $color
  }
  if ($script:logPath) { Add-Content -Path $script:logPath -Encoding UTF8 -Value ('{0:yyyy-MM-ddTHH:mm:ss.fff},{1},{2},{3},{4},"{5}"' -f $when, $type, $seg, $durMs, $targetsTxt, ($detail -replace '"', "'")) }
}

function Write-Minute([long]$mi) {
  # Incidents are bucketed by the minute they STARTED in; this runs a few seconds after that minute ends.
  $tun = $script:targets | Where-Object { $_.name -eq 'TUNNEL' }
  if ($script:outage -and -not $script:minuteBuckets.ContainsKey($mi)) { return }   # nothing to say while the node is down
  $c = if ($script:minuteBuckets.ContainsKey($mi)) { $script:minuteBuckets[$mi] } else { @{ FLOW = 0; PATH = 0; DOMESTIC = 0; LOCAL = 0; SERVER = 0; UNCLEAR = 0; JP = 0; BLIP = 0 } }
  $txt = "FLOW={0} PATH={1} DOMESTIC={2} LOCAL={3} SERVER={4} UNCLEAR={5} | TUNNEL 基準 {6} ms" -f $c.FLOW, $c.PATH, $c.DOMESTIC, $c.LOCAL, $c.SERVER, $c.UNCLEAR, $tun.baseline
  if ($c.BLIP) { $txt += " | 単発 (1 回分だけ) {0} 回は表示省略" -f $c.BLIP }
  if ($c.JP) { $txt += " | 1.1.1.1 単独の欠け {0} 回は無視" -f $c.JP }
  $label = "{0:HH:mm}" -f $script:t0.AddMilliseconds($mi * 60000)
  Write-Out 'minute' '' 0 '' $txt (($mi + 1) * 60000) ("-- {0} からの 1 分: {1}" -f $label, $txt)
  [void]$script:minuteBuckets.Remove($mi)
}

function Initialize-Watch {
  $script:pendingEvents = New-Object System.Collections.Generic.List[object]
  $script:eventId = 0; $script:outage = $null; $script:outageTargets = @()
  $script:minuteBuckets = @{}
  $script:t0 = Get-Date
}

# ---- main ----
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (tests): define functions only
if (-not $Endpoint) {
  $conf = Get-ChildItem -Path (Join-Path $PSScriptRoot "..\dist"), (Join-Path $PSScriptRoot "..\clients") -Filter *-split.conf -ErrorAction SilentlyContinue | Select-Object -First 1
  $ep = if ($conf) { (Get-Content $conf.FullName | Where-Object { $_ -match '^\s*Endpoint\s*=' }) -replace '^\s*Endpoint\s*=\s*', '' -replace ':\d+\s*$', '' } else { $null }
  $Endpoint = if ($ep) { $ep.Trim() } else { "52.74.31.125" }
}
$lan = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Initialize-Watch
$script:targets = @()
if ($lan) { $script:targets += New-Target 'LAN' $lan 2 }
$script:targets += New-Target 'JP' '1.1.1.1' 4
$script:targets += New-Target 'AWS' $Endpoint 1
$script:targets += New-Target 'TUNNEL' $Gateway 1
if ($Server) { $script:targets += New-Target 'SERVER' $Server 1 }
$script:logPath = $Log
$dir = Split-Path $Log; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not (Test-Path $Log)) { 'time,type,segment,duration_ms,targets,detail' | Set-Content -Path $Log -Encoding UTF8 }

Write-Host ("計測点: " + (($script:targets | ForEach-Object { "$($_.name)=$($_.ip)" }) -join '  '))
Write-Host ("跳ね = ロス、または直近 {0} 分の最小値 + {1} ms より遅い ping。記録: {2}" -f [int]($BaselineSec / 60), $SpikeMs, $Log)
Write-Host "Ctrl+C で終了。出来事 (同時に跳ねた地点の組) ごとに 1 行、1 分ごとに集計を出します。"
Write-Out 'state' 'START' 0 '' ("targets " + (($script:targets | ForEach-Object { "$($_.name)=$($_.ip)" }) -join ' ')) 0 'START'

$sw = [Diagnostics.Stopwatch]::StartNew()
$tick = 0L; $nextMinute = 0L; $stopAt = if ($Minutes -gt 0) { $Minutes * 60000L } else { [long]::MaxValue }
while ($sw.ElapsedMilliseconds -lt $stopAt) {
  $now = $sw.ElapsedMilliseconds
  foreach ($tg in $script:targets) {
    if ($tick % $tg.every -eq 0) {
      $p = New-Object System.Net.NetworkInformation.Ping
      $tg.pending.Enqueue([pscustomobject]@{ t = $now; ping = $p; task = $p.SendPingAsync($tg.ip, 1000) })
    }
    while ($tg.pending.Count -gt 0) {
      $h = $tg.pending.Peek()
      if (-not $h.task.IsCompleted -and ($now - $h.t) -lt 1200) { break }
      [void]$tg.pending.Dequeue()
      $rtt = if ($h.task.IsCompleted -and -not $h.task.IsFaulted -and $h.task.Result.Status -eq 'Success') { [int]$h.task.Result.RoundtripTime } else { -1 }
      $h.ping.Dispose()
      Process-Sample $tg $h.t $rtt
    }
  }
  if ($tick % 20 -eq 0) {
    $nowSec = [long][math]::Floor($now / 1000) + 1
    foreach ($tg in $script:targets) { Update-Baseline $tg $nowSec }
    Check-Outage $now
  }
  if ($tick % 5 -eq 0) { Flush-Incidents $now }
  if ($now -ge ($nextMinute + 1) * 60000 + 3000) { Write-Minute $nextMinute; $nextMinute++ }
  $tick++
  while ($sw.ElapsedMilliseconds -lt $tick * $TickMs) { Start-Sleep -Milliseconds 2 }
}
foreach ($tg in $script:targets) { Close-Event $tg }
Flush-Incidents ([long]::MaxValue)
foreach ($mi in @($script:minuteBuckets.Keys | Sort-Object)) { Write-Minute $mi }
Write-Out 'state' 'STOP' 0 '' '' $sw.ElapsedMilliseconds 'STOP'
