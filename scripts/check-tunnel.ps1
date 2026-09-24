# Compare the AllowedIPs in a client .conf with the routes actually installed on the WireGuard adapter.
# No admin needed. Usage: powershell -File scripts/check-tunnel.ps1 [-Conf clients\owner-split.conf]
param([string]$Conf = (Join-Path $PSScriptRoot "..\clients\owner-split.conf"))
$Conf = (Resolve-Path $Conf).Path
$name = [IO.Path]::GetFileNameWithoutExtension($Conf)
$svc = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
if (-not $svc -or $svc.Status -ne 'Running') { Write-Host "tunnel '$name' is not running"; exit 1 }
$want = ((Get-Content $Conf | Where-Object { $_ -match '^\s*AllowedIPs' }) -replace '^\s*AllowedIPs\s*=\s*','') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '0.0.0.0/0' }
$have = (Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -eq $name -and $_.RouteMetric -eq 0 }).DestinationPrefix
$missing = @($want | Where-Object { $have -notcontains $_ })
$extra   = @($have | Where-Object { $want -notcontains $_ })
Write-Host ("conf: {0} prefixes, routed: {1}" -f $want.Count, $have.Count)
$rtt = ping -n 4 -w 1500 10.66.0.1 | Select-Object -Last 1
Write-Host "tunnel RTT: $rtt"
if ($missing.Count -eq 0 -and $extra.Count -eq 0) { Write-Host "OK: routes match the conf"; exit 0 }
if ($missing) { Write-Host ("MISSING ({0}): {1}" -f $missing.Count, ($missing -join ', ')) }
if ($extra)   { Write-Host ("EXTRA ({0}): {1}"   -f $extra.Count,   ($extra -join ', ')) }
Write-Host "-> re-register with dist/start-tunnel.ps1 -Conf $Conf"
exit 2
