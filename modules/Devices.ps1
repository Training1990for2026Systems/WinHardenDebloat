<#
================================================================================
 WinHardenDebloat  -  modules\Devices.ps1   (v1.2, user's choices 2026-09-27)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Network adapters you do not use:
   1. Bluetooth network part only  - Bluetooth stays usable for mouse/headset.
      The "Bluetooth Network Connection" (Personal Area Network) adapter:
      DHCP OFF + autoconfiguration (169.254.x.x) OFF, then the adapter disabled.
   2. Wi-Fi Direct virtual adapters ("Local Area Connection* N") - used only for
      Mobile hotspot, casting (Miracast), Nearby sharing, Phone Link.
      Adapters disabled, Wi-Fi Direct + Mobile Hotspot services off, re-install blocked.
      Normal Wi-Fi keeps working.
   3. WAN Miniports (IKEv2, IP, IPv6, L2TP, Network Monitor, PPPOE, PPTP, SSTP) -
      only for dial-up / built-in VPN / PPPoE. Re-install blocked FIRST, then removed.
      RasMan (dial-up/VPN, Security+ N3) should be off too - it re-creates them.

 Re-install block = Windows Device Installation policy "Prevent installation of
 devices that match any of these device IDs" (HKLM\SOFTWARE\Policies\Microsoft\
 Windows\DeviceInstall\Restrictions: DenyDeviceIDs=1 + list). Microsoft lists it for
 Pro and up; on Home it is TRIED - Status (S) shows whether the devices came back.
 Everything is journaled: registry + device enable/disable = auto undo; a removed
 WAN Miniport = manual undo (remove the block, then Settings > Network reset).
 Reuses Common.ps1. Native cmdlets + pnputil.exe only.
================================================================================
#>

$script:WHDDenyKey     = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$script:WHDDenyListKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs'
$script:WHDTcpIfRoot   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
# Known hardware IDs (used even when the device is not present right now).
$script:WHDWfdIds = @('{5d624f94-8850-40c3-a3fa-a4fd2080baf3}\vwifimp_wfd')
$script:WHDWanIds = @('ms_agilevpnminiport', 'ms_ndiswanip', 'ms_ndiswanipv6', 'ms_l2tpminiport', 'ms_ndiswanbh', 'ms_pppoeminiport', 'ms_pptpminiport', 'ms_sstpminiport')
$script:WHDWfdServices = @('WFDSConMgrSvc', 'icssvc')

# ---- finders ---------------------------------------------------------------------
function Get-WHDBtPanAdapters {
    @(Get-NetAdapter -IncludeHidden -EA SilentlyContinue | Where-Object { "$($_.InterfaceDescription)" -match 'Bluetooth' -and "$($_.InterfaceDescription)" -match 'Personal Area Network|PAN' })
}
function Get-WHDWfdDevices {
    @(Get-PnpDevice -Class Net -EA SilentlyContinue | Where-Object { "$($_.FriendlyName)" -like 'Microsoft Wi-Fi Direct Virtual Adapter*' })
}
function Get-WHDWanDevices {
    @(Get-PnpDevice -Class Net -EA SilentlyContinue | Where-Object { "$($_.FriendlyName)" -like 'WAN Miniport*' })
}
function Get-WHDDeviceHwIds {
    param([Parameter(Mandatory)]$Device)
    try { @((Get-PnpDeviceProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -EA Stop).Data | Where-Object { $_ }) } catch { @() }
}
function Test-WHDDeviceDisabled { param($Device) "$($Device.ConfigManagerErrorCode)" -match 'DISABLED|^22$' }

# ---- building blocks -------------------------------------------------------------
function Get-WHDDenyIds {
    $k = Get-Item -LiteralPath $script:WHDDenyListKey -EA SilentlyContinue
    if (-not $k) { return @() }
    @($k.GetValueNames() | ForEach-Object { "$($k.GetValue($_))" } | Where-Object { $_ })
}
# Adds IDs to the device-install deny list (only those not listed yet). Journaled as reg.
function Add-WHDDenyDeviceIds {
    param([Parameter(Mandatory)][string[]]$Ids)
    $have = @(Get-WHDDenyIds | ForEach-Object { $_.ToLower() })
    $new  = @($Ids | Where-Object { $_ } | Select-Object -Unique | Where-Object { $have -notcontains $_.ToLower() })
    $st = Get-WHDRegValueState -Path $script:WHDDenyKey -Name 'DenyDeviceIDs'
    if (-not ($st.Exists -and (Test-WHDRegValueEqual $st.Value 1 'DWord'))) { Set-WHDRegistryValue -Path $script:WHDDenyKey -Name 'DenyDeviceIDs' -Value 1 -Type DWord | Out-Null }
    if (-not $new.Count) { Write-WHDLog 'Install block: all IDs already listed.' 'OK'; return }
    $k = Get-Item -LiteralPath $script:WHDDenyListKey -EA SilentlyContinue
    $used = if ($k) { @($k.GetValueNames() | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) } else { @() }
    $n = if ($used.Count) { ($used | Measure-Object -Maximum).Maximum } else { 0 }
    foreach ($id in $new) {
        $n++
        Set-WHDRegistryValue -Path $script:WHDDenyListKey -Name ("$n") -Value $id -Type String | Out-Null
    }
}
function Disable-WHDDevice {
    param([Parameter(Mandatory)]$Device)
    # Re-read first: disabling one Wi-Fi Direct adapter can make Windows drop its sibling (seen 2026-09-28:
    # adapter #2 went "not present" and Disable-PnpDevice then failed with "Generic failure").
    $now = @(Get-PnpDevice -InstanceId $Device.InstanceId -EA SilentlyContinue)[0]
    if (-not $now -or -not $now.Present) { Write-WHDLog ("already gone (not present): {0}" -f $Device.FriendlyName) 'OK'; return }
    if (Test-WHDDeviceDisabled $now) { Write-WHDLog ("already disabled: {0}" -f $Device.FriendlyName) 'OK'; return }
    $pdId = "$($Device.InstanceId)"; $pdName = "$($Device.FriendlyName)"
    $jr = @{ Kind = 'pnpdev'; InstanceId = $pdId; Name = $pdName; OldEnabled = $true; NewEnabled = $false }
    Invoke-WHDChange -Description ("disable device {0}" -f $pdName) -Force -Journal $jr -Action {
        Disable-PnpDevice -InstanceId $pdId -Confirm:$false -EA Stop
    } | Out-Null
}
function Disable-WHDServiceByReg {
    param([Parameter(Mandatory)][string]$Name)
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $p)) { Write-WHDLog ("service {0}: not present" -f $Name) 'INFO'; return }
    $st = Get-WHDRegValueState -Path $p -Name 'Start'
    if (-not ($st.Exists -and (Test-WHDRegValueEqual $st.Value 4 'DWord'))) { Set-WHDRegistryValue -Path $p -Name 'Start' -Value 4 -Type DWord | Out-Null }
    $svc = Get-Service -Name $Name -EA SilentlyContinue
    if ($svc -and "$($svc.Status)" -ne 'Stopped') {
        $dsName = $Name
        Invoke-WHDChange -Description ("stop service {0} now" -f $dsName) -Force -Action { Stop-Service -Name $dsName -Force -EA Stop } | Out-Null
    }
}

# ---- 1. Bluetooth network part ---------------------------------------------------
function Invoke-WHDBtNetworkOff {
    Write-WHDLog 'DEVICES: Bluetooth network part (PAN adapter: DHCP + autoconfiguration OFF, adapter disabled)' 'ACT'
    Write-WHDRisk 'reversible' 'Bluetooth itself stays on (mouse, keyboard, headset keep working). Only networking over Bluetooth stops. On this adapter: DHCP OFF and autoconfiguration (169.254.x.x) OFF, then the adapter is disabled. Journaled (auto undo).'
    $ads = @(Get-WHDBtPanAdapters)
    if (-not $ads.Count) { Write-WHDLog 'No Bluetooth Network Connection adapter on this PC (Bluetooth off or no PAN driver) - nothing to do.' 'OK'; return }
    foreach ($a in $ads) { Write-WHDLog ("  {0}  ({1})  {2}" -f $a.Name, $a.InterfaceDescription, $a.Status) 'INFO' }
    if (-not (Confirm-WHDProceed ("turn off the Bluetooth network part on {0} adapter(s)" -f $ads.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($a in $ads) {
        $ifKey = Join-Path $script:WHDTcpIfRoot "$($a.InterfaceGuid)"
        foreach ($v in @(@{ N = 'EnableDHCP'; V = 0 }, @{ N = 'IPAutoconfigurationEnabled'; V = 0 })) {
            $st = Get-WHDRegValueState -Path $ifKey -Name $v.N
            if ($st.Exists -and (Test-WHDRegValueEqual $st.Value $v.V 'DWord')) { continue }
            Set-WHDRegistryValue -Path $ifKey -Name $v.N -Value $v.V -Type DWord | Out-Null
        }
        # Same setting through the network stack (not journaled - the registry lines above are the undo record)
        $btIdx = [int]$a.ifIndex
        # A disabled or absent adapter has no IP interface (Set-NetIPInterface fails, seen 2026-09-29) - the registry
        # values above already cover it.
        if ("$($a.Status)" -in @('Disabled', 'Not Present')) { Write-WHDLog ("network stack step not needed: {0} is {1} (registry values set)" -f $a.Name, $a.Status) 'INFO' }
        else { Invoke-WHDChange -Description ("IPv4 DHCP off on {0} (network stack)" -f $a.Name) -Force -Action {
            Set-NetIPInterface -InterfaceIndex $btIdx -AddressFamily IPv4 -Dhcp Disabled -EA Stop
        } | Out-Null }
        $dev = @(Get-PnpDevice -InstanceId $a.PnPDeviceID -EA SilentlyContinue)[0]
        if ($dev) { Disable-WHDDevice -Device $dev }
    }
}

# ---- 2. Wi-Fi Direct virtual adapters -------------------------------------------
function Invoke-WHDWifiDirectOff {
    Write-WHDLog 'DEVICES: Wi-Fi Direct virtual adapters off + re-install blocked' 'ACT'
    Write-WHDRisk 'caution' 'Mobile hotspot, casting to a TV (Miracast), Nearby sharing and Phone Link stop working. Normal Wi-Fi and Ethernet are not affected. Services WFDSConMgrSvc (Wi-Fi Direct) + icssvc (Mobile Hotspot) off. Install block: Windows Device Installation policy (Pro and up per Microsoft; tried on Home - check Status after a restart). Journaled (auto undo).'
    $devs = @(Get-WHDWfdDevices)
    foreach ($d in $devs) { Write-WHDLog ("  {0}   {1}" -f $d.FriendlyName, $(if (Test-WHDDeviceDisabled $d) { 'disabled' } else { "$($d.Status)" })) 'INFO' }
    if (-not $devs.Count) { Write-WHDLog '  (no Wi-Fi Direct adapter present right now - the block and services are still set)' 'INFO' }
    if (-not (Confirm-WHDProceed 'turn off Wi-Fi Direct adapters + services and block re-install')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $ids = @($script:WHDWfdIds)
    foreach ($d in $devs) { $ids += @(Get-WHDDeviceHwIds -Device $d | Where-Object { $_ -match 'vwifimp_wfd' }) }
    Add-WHDDenyDeviceIds -Ids $ids
    foreach ($s in $script:WHDWfdServices) { Disable-WHDServiceByReg -Name $s }
    foreach ($d in $devs) { Disable-WHDDevice -Device $d }
    Write-WHDLog 'Restart, then Devices S: the Wi-Fi Direct adapters should stay disabled or gone.' 'INFO'
}

# ---- 3. WAN Miniports ------------------------------------------------------------
function Invoke-WHDWanMiniportsOff {
    Write-WHDLog 'DEVICES: WAN Miniports - block re-install, then remove' 'ACT'
    Write-WHDRisk 'hard' 'Dial-up, the built-in Windows VPN client and PPPoE connections made by the PC itself will not work. WAN Miniports are only needed for those; do not remove them if this PC uses any of them. The block is added FIRST, then each WAN Miniport is removed with pnputil. Undo: the block is auto-undo; the removed devices come back by removing the block and then Settings > Network & internet > Advanced network settings > Network reset.'
    $ras = Get-Service -Name RasMan -EA SilentlyContinue
    if ($ras -and "$($ras.StartType)" -ne 'Disabled') { Write-WHDLog 'Note: RasMan (dial-up/VPN) is not disabled - it re-creates WAN Miniports. Turn it off too: Security+ N3.' 'WARN' }
    $devs = @(Get-WHDWanDevices)
    foreach ($d in $devs) { Write-WHDLog ("  {0}" -f $d.FriendlyName) 'INFO' }
    if (-not $devs.Count) { Write-WHDLog '  (no WAN Miniports present right now - the block is still set)' 'INFO' }
    if (-not (Confirm-WHDProceed ("block + remove {0} WAN Miniport(s)" -f $devs.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $ids = @($script:WHDWanIds)
    foreach ($d in $devs) { $ids += @(Get-WHDDeviceHwIds -Device $d | Where-Object { $_ -match '^ms_' }) }
    Add-WHDDenyDeviceIds -Ids $ids
    $script:WHDPnpRestartNeeded = $false
    foreach ($d in $devs) {
        $wmId = "$($d.InstanceId)"; $wmName = "$($d.FriendlyName)"
        $jr = @{ Kind = 'action'; InstanceId = $wmId; Name = $wmName
                 Hint = 'remove the WAN Miniport block (Undo center, the DenyDeviceIDs lines), turn RasMan back on, then Settings > Network & internet > Advanced network settings > Network reset' }
        Invoke-WHDChange -Description ("remove device {0}" -f $wmName) -Force -Journal $jr -Action {
            $r = Invoke-WHDNative -Exe 'pnputil.exe' -ArgList @('/remove-device', $wmId)
            # pnputil: 0 = removed; 3010 / 1641 = removed, restart needed to finish
            if (@(0, 3010, 1641) -notcontains $r.Code) { throw ("pnputil exit {0}: {1}" -f $r.Code, (($r.Out | Select-Object -Last 2) -join ' ')) }
            if ($r.Code -ne 0) { $script:WHDPnpRestartNeeded = $true }
        } | Out-Null
    }
    if ($script:WHDPnpRestartNeeded) { Write-WHDLog 'A restart is needed to finish removing the devices.' 'INFO' }
    Write-WHDLog 'Restart, then Devices S: WAN Miniports should stay gone.' 'INFO'
}

# ---- status ----------------------------------------------------------------------
function Show-WHDDevicesStatus {
    Write-WHDLog '================ DEVICES STATUS (read-only) ================' 'ACT'
    if ("$((Get-UICulture).Name)" -notlike 'en*') { Write-WHDLog 'Devices are matched by their English names; on this display language they may not be found.' 'WARN' }
    $bt = @(Get-WHDBtPanAdapters)
    if (-not $bt.Count) { Write-WHDLog 'Bluetooth network adapter : none' 'OK' }
    foreach ($a in $bt) {
        $ifKey = Join-Path $script:WHDTcpIfRoot "$($a.InterfaceGuid)"
        $dh = Get-WHDRegValueState -Path $ifKey -Name 'EnableDHCP'; $ac = Get-WHDRegValueState -Path $ifKey -Name 'IPAutoconfigurationEnabled'
        $ok = ($dh.Exists -and [int]$dh.Value -eq 0) -and ($ac.Exists -and [int]$ac.Value -eq 0) -and ("$($a.Status)" -eq 'Disabled')
        Write-WHDLog ("Bluetooth network adapter : {0}  status {1}, DHCP {2}, autoconfig {3}" -f $a.Name, $a.Status, $(if ($dh.Exists -and [int]$dh.Value -eq 0) { 'off' } else { 'ON' }), $(if ($ac.Exists -and [int]$ac.Value -eq 0) { 'off' } else { 'ON' })) $(if ($ok) { 'OK' } else { 'WARN' })
    }
    $wfd = @(Get-WHDWfdDevices)
    Write-WHDLog ("Wi-Fi Direct adapters     : {0} present, {1} enabled" -f $wfd.Count, @($wfd | Where-Object { -not (Test-WHDDeviceDisabled $_) }).Count) $(if (@($wfd | Where-Object { -not (Test-WHDDeviceDisabled $_) }).Count) { 'WARN' } else { 'OK' })
    foreach ($s in $script:WHDWfdServices) {
        $svc = Get-Service -Name $s -EA SilentlyContinue
        if ($svc) { Write-WHDLog ("  service {0,-14}: {1}/{2}" -f $s, $svc.Status, $svc.StartType) $(if ("$($svc.StartType)" -eq 'Disabled') { 'OK' } else { 'INFO' }) }
    }
    $wan = @(Get-WHDWanDevices)
    Write-WHDLog ("WAN Miniports             : {0} present" -f $wan.Count) $(if ($wan.Count) { 'WARN' } else { 'OK' })
    foreach ($d in $wan) { Write-WHDLog ("  {0}" -f $d.FriendlyName) 'INFO' }
    $pol = Get-WHDRegValueState -Path $script:WHDDenyKey -Name 'DenyDeviceIDs'
    $ids = @(Get-WHDDenyIds)
    Write-WHDLog ("Install block             : {0}, {1} ID(s) listed" -f $(if ($pol.Exists -and [int]$pol.Value -eq 1) { 'ON' } else { 'off' }), $ids.Count) 'INFO'
    if (($wan.Count -or @($wfd | Where-Object { -not (Test-WHDDeviceDisabled $_) }).Count) -and $ids.Count) {
        Write-WHDLog 'Blocked devices are back or enabled - Windows Home may be ignoring the install block. Run the step again; if they keep coming back, this edition of Windows is not applying the install-block policy.' 'WARN'
    }
    Write-WHDLog '================ END ================' 'ACT'
}

# ---- menu ------------------------------------------------------------------------
function Show-WHDDevicesMenu {
    Write-Host ''
    Write-Host '  ================= DEVICES (network adapters you do not use) =================' -ForegroundColor White
    Write-Host ('   1. Bluetooth network part only (DHCP + autoconfig off, adapter off)   [{0} adapter(s)]' -f @(Get-WHDBtPanAdapters).Count)
    Write-Host ('   2. Wi-Fi Direct virtual adapters off + block re-install              [{0} present]' -f @(Get-WHDWfdDevices).Count)
    Write-Host ('   3. WAN Miniports: block re-install + remove                          [{0} present]' -f @(Get-WHDWanDevices).Count)
    Write-Host '   A. All three'
    Write-Host '   S. Status'
    Write-Host '   B. Back'
}
function Invoke-WHDDevicesSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDDevicesMenu
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^1$'    { Invoke-WHDBtNetworkOff }
            '^2$'    { Invoke-WHDWifiDirectOff }
            '^3$'    { Invoke-WHDWanMiniportsOff }
            '^[Aa]$' { Invoke-WHDBtNetworkOff; Invoke-WHDWifiDirectOff; Invoke-WHDWanMiniportsOff }
            '^[Ss]$' { Show-WHDDevicesStatus }
            '^[Bb]$' { return }
            default  { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Devices.ps1 loaded.' 'INFO'
