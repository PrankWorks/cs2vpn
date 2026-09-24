# start-tunnel.ps1 - Start the csvpn WireGuard tunnel on the BEST available path.
# Run via start-tunnel.bat (double-click) or: powershell -File dist/start-tunnel.ps1 -Conf clients/owner-split.conf
# Background: home ISP <-> AWS traffic is spread over several links by a per-flow hash, so the client's
# source port decides which path (86 ms ... 250 ms) the tunnel gets. This script keeps the tunnel up and
# switches the listen port with `wg set`, measures the RTT to the exit node for each candidate port,
# then keeps the fastest one and writes it into the .conf. The tunnel is registered through the
# WireGuard app's own config store, so it shows up in the GUI and can be toggled there afterwards.
param(
  [string]$Conf,
  [switch]$NoPause,
  [int]$Candidates = 12,
  [int]$MaxMs = 150
)
$ErrorActionPreference = 'Continue'
$wgui  = "C:\Program Files\WireGuard\wireguard.exe"
$wg    = "C:\Program Files\WireGuard\wg.exe"
$gw    = "10.66.0.1"
$store = "C:\Program Files\WireGuard\Data\Configurations"

function Done($code) { if (-not $NoPause) { Write-Host ""; Read-Host "Enter キーで閉じる" | Out-Null }; exit $code }

if (-not (Test-Path $wgui)) {
  Write-Host "WireGuard が見つからないのでインストールします..."
  winget install --id WireGuard.WireGuard -e --silent --accept-package-agreements --accept-source-agreements | Out-Null
  if (-not (Test-Path $wgui)) { Write-Host "自動インストールに失敗。https://www.wireguard.com/install/ から入れて再実行してください。"; Done 1 }
}

if (-not $Conf) {
  $confs = Get-ChildItem -Path $PSScriptRoot -Filter *.conf | Sort-Object { $_.Name -notlike '*-split.conf' }, Name
  if (-not $confs) { Write-Host "このフォルダに .conf がありません。配布された .conf を同じフォルダに置いてください。"; Done 1 }
  $Conf = $confs[0].FullName
}
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
Write-Host "設定: $name"

function Get-Rtt {
  # min of 4 pings; -1 when unreachable
  $line = ping -n 4 -w 1500 $gw | Select-Object -Last 1
  if ($line -match '= (\d+)ms.*= (\d+)ms.*= (\d+)ms') { return [int]$Matches[1] }
  return -1
}
function Set-ConfPort([int]$port) {
  $txt = Get-Content $Conf | Where-Object { $_ -notmatch '^\s*ListenPort' }
  $txt = $txt -replace '^\[Interface\]', "[Interface]`nListenPort = $port"
  Set-Content -Path $Conf -Value $txt -Encoding ASCII
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
  if (Test-Path $enc) { Write-Host "警告: 古い設定 $enc を削除できませんでした。" }
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
  if ($missing) { Write-Host ("警告: 次の宛先がトンネルのルートに載っていません: {0}" -f ($missing -join ', ')) }
}

# Bring the tunnel up through the app store so it appears in the WireGuard GUI.
Install-FromStore
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Write-Host "トンネルを開始できませんでした。.conf の内容を確認してください。"; Done 1 }

$current = $null
foreach ($l in Get-Content $Conf) { if ($l -match '^\s*ListenPort\s*=\s*(\d+)') { $current = [int]$Matches[1] } }
$ports = @(); if ($current) { $ports += $current }
$ports += Get-Random -Count $Candidates -InputObject (40000..60000) | Where-Object { $_ -ne $current }

Write-Host "経路を測定中 ($($ports.Count) ポート)..."
$results = @()
foreach ($port in $ports) {
  & $wg set $name listen-port $port 2>$null
  Start-Sleep -Milliseconds 800
  $rtt = Get-Rtt
  $label = if ($rtt -lt 0) { "応答なし" } else { "$rtt ms" }
  Write-Host ("  ポート {0,5}: {1}" -f $port, $label)
  $results += [pscustomobject]@{ port = $port; rtt = $rtt }
}
$ok = $results | Where-Object { $_.rtt -ge 0 } | Sort-Object rtt
if (-not $ok) { Write-Host "どのポートでも応答がありません。ネットワークやファイアウォールを確認してください。"; Done 1 }
$best = $ok[0]

Set-ConfPort $best.port
Install-FromStore
$final = Get-Rtt
if (-not ($final -ge 0 -and $final -lt $MaxMs)) {
  # After a restart the flow can land on a slow path again. Keep the tunnel up and switch ports live
  # until it is fast, then remember that port.
  Write-Host ("  再起動後は {0} ms。トンネルを張ったままポートを切り替えて良い経路を探します..." -f $final)
  $live = @($ok | Select-Object -Skip 1 | ForEach-Object { $_.port }) + (Get-Random -Count $Candidates -InputObject (40000..60000))
  foreach ($port in $live) {
    & $wg set $name listen-port $port 2>$null
    Start-Sleep -Milliseconds 800
    $final = Get-Rtt
    Write-Host ("  ポート {0,5}: {1}" -f $port, $(if ($final -lt 0) { "応答なし" } else { "$final ms" }))
    if ($final -ge 0 -and $final -lt $MaxMs) { $best = [pscustomobject]@{ port = $port; rtt = $final }; Set-ConfPort $port; break }
  }
}
Write-Host ""
Write-Host ("最速: ポート {0} ({1} ms)。この設定を保存し、トンネル '{2}' を再起動しました (確認 {3} ms)。" -f $best.port, $best.rtt, $name, $final)
if ($best.rtt -ge $MaxMs) { Write-Host "注意: 最速でも $MaxMs ms を超えています。時間をおいて再実行してください。"; Done 1 }
Write-Host "WireGuard アプリの一覧に '$name' が表示され、次回からはそこで有効化するだけで OK です。"
Done 0
