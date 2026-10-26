#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Devices.ps1   (network adapters you do not use)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6. Build step
 5.5 (one part, D37). Status is ST (D38; S stays safe mode, D25).
   1. Bluetooth network part only - the "Bluetooth Network Connection" (PAN)
      adapter: DHCP OFF + autoconfiguration (169.254.x.x) OFF, adapter disabled.
      Bluetooth itself (mouse, keyboard, headset) keeps working.
   2. Wi-Fi Direct virtual adapters - install block first, the Wi-Fi Direct and
      Mobile Hotspot services off, the adapters disabled. Normal Wi-Fi keeps working.
   3. WAN Miniports - install block FIRST, then each one removed (pnputil).
      Only dial-up / the built-in VPN client / PPPoE use them. RasMan (Security
      menu N3) re-creates them while it runs.
 Install block = Windows' Device Installation policy "Prevent installation of
 devices that match any of these device IDs" (HKLM\SOFTWARE\Policies\Microsoft\
 Windows\DeviceInstall\Restrictions: DenyDeviceIDs = 1 + the numbered list).
 Recorded: registry values and device on/off = automatic undo; a removed WAN
 Miniport = manual undo (remove the block, RasMan back on, Network reset).
 Windows' own cmdlets + pnputil.exe only.
================================================================================
#>

$script:WHDDenyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
$script:WHDDenyListKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions\DenyDeviceIDs'
$script:WHDTcpIfRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
# Hardware IDs that are blocked even when the device is not present right now.
$script:WHDWfdIds = @('{5d624f94-8850-40c3-a3fa-a4fd2080baf3}\vwifimp_wfd')
$script:WHDWanIds = @('ms_agilevpnminiport', 'ms_ndiswanip', 'ms_ndiswanipv6', 'ms_l2tpminiport', 'ms_ndiswanbh', 'ms_pppoeminiport', 'ms_pptpminiport', 'ms_sstpminiport')
$script:WHDWfdServices = @('WFDSConMgrSvc', 'icssvc')

# ---- finders (read-only) -----------------------------------------------------------------
function Get-WHDBtPanAdapter {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { [string]$_.InterfaceDescription -match 'Bluetooth' -and [string]$_.InterfaceDescription -match 'Personal Area Network|PAN' })
}

function Get-WHDWfdDevice {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { [string]$_.FriendlyName -like 'Microsoft Wi-Fi Direct Virtual Adapter*' })
}

function Get-WHDWanDevice {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { [string]$_.FriendlyName -like 'WAN Miniport*' })
}

function Get-WHDDeviceHwId {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Device)
    try { return @((Get-PnpDeviceProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop).Data | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
    catch { return @() }
}

function Test-WHDDeviceDisabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Device)
    return ([string]$Device.ConfigManagerErrorCode -match 'DISABLED|^22$')
}

function Get-WHDDenyId {
    # The IDs already on the install-block list.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    if (-not (Test-Path -LiteralPath $script:WHDDenyListKey)) { return @() }
    $k = Get-Item -LiteralPath $script:WHDDenyListKey -ErrorAction SilentlyContinue
    if (-not $k) { return @() }
    return @($k.GetValueNames() | ForEach-Object { [string]$k.GetValue($_) } | Where-Object { $_ })
}

function Get-WHDDenyMissing {
    # Which of -Ids are not on the block list yet (case-insensitive, unique). (pure apart from the read)
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string[]]$Ids)
    # One HashSet that ignores case: an ID Windows reports in capitals is the same ID (no double entries).
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($h in @(Get-WHDDenyId)) { [void]$seen.Add($h) }
    return @(foreach ($id in @($Ids)) { if ($id -and $seen.Add([string]$id)) { [string]$id } })
}

function Test-WHDDenyOn {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $st = Get-WHDRegValueState -Path $script:WHDDenyKey -Name 'DenyDeviceIDs'
    return ($st.Exists -and (Test-WHDRegValueEqual -A $st.Value -B 1 -Type 'DWord'))
}

function Get-WHDServiceStartValue {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$Name)
    $st = Get-WHDRegValueState -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $Name) -Name 'Start'
    if ($st.Exists) { return [int]$st.Value }
    return $null
}

# ---- building blocks (changes go through the gate) ---------------------------------------
function Add-WHDDenyDeviceId {
    # Switches the block on and adds only the IDs not listed yet, numbered after the highest one in use.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string[]]$Ids)
    if (-not $PSCmdlet.ShouldProcess('device install block', 'add IDs')) { return }
    if (-not (Test-WHDDenyOn)) { Set-WHDRegistryValue -Path $script:WHDDenyKey -Name 'DenyDeviceIDs' -Value 1 -Type 'DWord' | Out-Null }
    $new = @(Get-WHDDenyMissing -Ids $Ids)
    if (-not $new.Count) { Write-WHDLog -Message 'Install block: every ID is already listed.' -Level 'OK'; return }
    $used = @()
    if (Test-Path -LiteralPath $script:WHDDenyListKey) {
        $k = Get-Item -LiteralPath $script:WHDDenyListKey -ErrorAction SilentlyContinue
        if ($k) { $used = @($k.GetValueNames() | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
    }
    $n = if ($used.Count) { [int]($used | Measure-Object -Maximum).Maximum } else { 0 }
    foreach ($id in $new) {
        $n++
        Set-WHDRegistryValue -Path $script:WHDDenyListKey -Name ([string]$n) -Value $id -Type 'String' | Out-Null
    }
}

function Disable-WHDDeviceIfOn {
    # Reads the device again first: disabling one Wi-Fi Direct adapter can make Windows drop
    # its sibling (seen 2026-09-28) - a device that is gone or already off is left alone.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Device)
    $now = (Get-PnpDevice -InstanceId $Device.InstanceId -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $now -or -not $now.Present) { Write-WHDLog -Message ('already gone (not present): {0}' -f $Device.FriendlyName) -Level 'OK'; return }
    if (Test-WHDDeviceDisabled -Device $now) { Write-WHDLog -Message ('already disabled: {0}' -f $Device.FriendlyName) -Level 'OK'; return }
    if (-not $PSCmdlet.ShouldProcess([string]$Device.FriendlyName, 'disable device')) { return }
    Set-WHDPnpDeviceEnabled -InstanceId ([string]$Device.InstanceId) -Name ([string]$Device.FriendlyName) -Enabled $false -WasEnabled $true | Out-Null
}

function Disable-WHDServiceStart {
    # Start = 4 by the registry (recorded, exact undo), then stopped now if it runs.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    $p = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $Name
    if (-not (Test-Path -LiteralPath $p)) { Write-WHDLog -Message ('service {0}: not present' -f $Name); return }
    if (-not $PSCmdlet.ShouldProcess($Name, 'service off')) { return }
    if ((Get-WHDServiceStartValue -Name $Name) -ne 4) { Set-WHDRegistryValue -Path $p -Name 'Start' -Value 4 -Type 'DWord' | Out-Null }
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc -and [string]$svc.Status -ne 'Stopped') {
        $dvSvc = $Name
        Invoke-WHDChange -Description ('stop service {0} now' -f $dvSvc) -Action { Stop-Service -Name $dvSvc -Force -ErrorAction Stop } | Out-Null
    }
}

# ---- what each item still has to do (read-only; empty = already done) ---------------------
function Get-WHDBtTodo {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $out = foreach ($a in @(Get-WHDBtPanAdapter)) {
        $ifKey = ('{0}\{1}' -f $script:WHDTcpIfRoot, [string]$a.InterfaceGuid)
        $dh = Get-WHDRegValueState -Path $ifKey -Name 'EnableDHCP'
        $ac = Get-WHDRegValueState -Path $ifKey -Name 'IPAutoconfigurationEnabled'
        $regOk = ($dh.Exists -and [int]$dh.Value -eq 0) -and ($ac.Exists -and [int]$ac.Value -eq 0)
        $off = [string]$a.Status -in 'Disabled', 'Not Present'
        if (-not ($regOk -and $off)) { $a }
    }
    return @($out)
}

function Test-WHDWfdDone {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-WHDDenyOn) -or @(Get-WHDDenyMissing -Ids $script:WHDWfdIds).Count) { return $false }
    foreach ($s in $script:WHDWfdServices) {
        if (-not (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $s))) { continue }
        if ((Get-WHDServiceStartValue -Name $s) -ne 4) { return $false }
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc -and [string]$svc.Status -ne 'Stopped') { return $false }
    }
    return (-not @(Get-WHDWfdDevice | Where-Object { $_.Present -and -not (Test-WHDDeviceDisabled -Device $_) }).Count)
}

function Test-WHDWanDone {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ((Test-WHDDenyOn) -and -not @(Get-WHDDenyMissing -Ids $script:WHDWanIds).Count -and -not @(Get-WHDWanDevice).Count)
}

# ---- 1. Bluetooth network part --------------------------------------------------------------
function Invoke-WHDBtNetworkOff {
    [CmdletBinding()]
    param([switch]$NoAsk)
    Write-WHDLog -Message 'DEVICES 1: Bluetooth network part (PAN adapter: DHCP + autoconfiguration OFF, adapter disabled)' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'Bluetooth itself stays on (mouse, keyboard, headset keep working). Only networking over Bluetooth stops. Recorded (automatic undo).'
    $ads = @(Get-WHDBtPanAdapter)
    if (-not $ads.Count) { Write-WHDLog -Message 'No Bluetooth Network Connection adapter on this PC (Bluetooth off or no PAN driver) - nothing to do.' -Level 'OK'; return }
    foreach ($a in $ads) { Write-WHDLog -Message ('  {0}  ({1})  {2}' -f $a.Name, $a.InterfaceDescription, $a.Status) }
    $todo = @(Get-WHDBtTodo)
    if (-not $todo.Count) { Write-WHDLog -Message 'Already off - nothing to change.' -Level 'OK'; return }
    if (-not $NoAsk -and -not (Confirm-WHDProceed -What ('turn off the Bluetooth network part on {0} adapter(s)' -f $todo.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($a in $todo) {
        if ($script:WHDState.JournalStop) { break }
        $ifKey = ('{0}\{1}' -f $script:WHDTcpIfRoot, [string]$a.InterfaceGuid)
        foreach ($v in 'EnableDHCP', 'IPAutoconfigurationEnabled') {
            $cur = Get-WHDRegValueState -Path $ifKey -Name $v
            if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B 0 -Type 'DWord')) { continue }
            Set-WHDRegistryValue -Path $ifKey -Name $v -Value 0 -Type 'DWord' | Out-Null
        }
        # The same setting through the network stack (the registry values above are the undo record).
        # A disabled or absent adapter has no IP interface - the registry values already cover it.
        if ([string]$a.Status -in 'Disabled', 'Not Present') { Write-WHDLog -Message ('network stack step not needed: {0} is {1} (registry values set)' -f $a.Name, $a.Status) }
        else {
            $btIdx = [int]$a.ifIndex
            Invoke-WHDChange -Description ('IPv4 DHCP off on {0} (network stack)' -f $a.Name) -Action { Set-NetIPInterface -InterfaceIndex $btIdx -AddressFamily IPv4 -Dhcp Disabled -ErrorAction Stop } | Out-Null
        }
        $dev = (Get-PnpDevice -InstanceId ([string]$a.PnPDeviceID) -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($dev) { Disable-WHDDeviceIfOn -Device $dev }
    }
}

# ---- 2. Wi-Fi Direct virtual adapters ------------------------------------------------------
function Invoke-WHDWifiDirectOff {
    [CmdletBinding()]
    param([switch]$NoAsk)
    Write-WHDLog -Message 'DEVICES 2: Wi-Fi Direct virtual adapters off + re-install blocked' -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text 'Mobile hotspot, casting to a TV (Miracast), Nearby sharing and Phone Link stop working. Normal Wi-Fi and Ethernet are not affected. Services WFDSConMgrSvc (Wi-Fi Direct) + icssvc (Mobile Hotspot) off. Install block: Windows Device Installation policy (Pro and up per Microsoft; on Home it is tried - check ST after a restart). Recorded (automatic undo).'
    $devs = @(Get-WHDWfdDevice)
    foreach ($d in $devs) { Write-WHDLog -Message ('  {0}   {1}' -f $d.FriendlyName, $(if (Test-WHDDeviceDisabled -Device $d) { 'disabled' } else { [string]$d.Status })) }
    if (-not $devs.Count) { Write-WHDLog -Message '  (no Wi-Fi Direct adapter present right now - the block and the services are still set)' }
    if (Test-WHDWfdDone) { Write-WHDLog -Message 'Already off and blocked - nothing to change.' -Level 'OK'; return }
    if (-not $NoAsk -and -not (Confirm-WHDProceed -What 'turn off Wi-Fi Direct adapters + services and block re-install')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $ids = @($script:WHDWfdIds)
    foreach ($d in $devs) { $ids += @(Get-WHDDeviceHwId -Device $d | Where-Object { $_ -match 'vwifimp_wfd' }) }
    Add-WHDDenyDeviceId -Ids $ids
    foreach ($s in $script:WHDWfdServices) { if ($script:WHDState.JournalStop) { break }; Disable-WHDServiceStart -Name $s }
    foreach ($d in $devs) { if ($script:WHDState.JournalStop) { break }; Disable-WHDDeviceIfOn -Device $d }
    Write-WHDLog -Message 'Restart, then Devices ST: the Wi-Fi Direct adapters should stay disabled or gone.'
}

# ---- 3. WAN Miniports ------------------------------------------------------------------------
function Invoke-WHDWanMiniportsOff {
    [CmdletBinding()]
    param([switch]$NoAsk)
    Write-WHDLog -Message 'DEVICES 3: WAN Miniports - block re-install, then remove' -Level 'ACT'
    Write-WHDRisk -Tier 'hard' -Text 'Dial-up, the built-in Windows VPN client and PPPoE connections made by the PC itself will not work. Do not remove them if this PC uses any of those. The block is added FIRST, then each WAN Miniport is removed with pnputil. Undo: the block is automatic; the removed devices come back by removing the block, RasMan back on, then Settings > Network & internet > Advanced network settings > Network reset.'
    $ras = Get-Service -Name 'RasMan' -ErrorAction SilentlyContinue
    if ($ras -and [string]$ras.StartType -ne 'Disabled') { Write-WHDLog -Message 'Note: RasMan (dial-up / VPN) is not disabled - it re-creates WAN Miniports. Turn it off too: Security menu N3.' -Level 'WARN' }
    $devs = @(Get-WHDWanDevice)
    foreach ($d in $devs) { Write-WHDLog -Message ('  {0}' -f $d.FriendlyName) }
    if (-not $devs.Count) { Write-WHDLog -Message '  (no WAN Miniports present right now - the block is still set)' }
    if (Test-WHDWanDone) { Write-WHDLog -Message 'Already blocked and removed - nothing to change.' -Level 'OK'; return }
    if (-not $NoAsk -and -not (Confirm-WHDProceed -What ('block + remove {0} WAN Miniport(s)' -f $devs.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $ids = @($script:WHDWanIds)
    foreach ($d in $devs) { $ids += @(Get-WHDDeviceHwId -Device $d | Where-Object { $_ -match '^ms_' }) }
    Add-WHDDenyDeviceId -Ids $ids
    foreach ($d in $devs) {
        if ($script:WHDState.JournalStop) { break }
        $wmId = [string]$d.InstanceId; $wmName = [string]$d.FriendlyName
        $jr = @{ Kind = 'action'; InstanceId = $wmId; Name = $wmName
                 Hint = 'remove the WAN Miniport block (Undo center, the DenyDeviceIDs lines), turn RasMan back on, then Settings > Network & internet > Advanced network settings > Network reset' }
        Invoke-WHDChange -Description ('remove device {0}' -f $wmName) -Journal $jr -Action {
            $r = Invoke-WHDNative -Exe 'pnputil.exe' -ArgList @('/remove-device', $wmId)
            if ($r.Code -ne 0) { throw ('pnputil exit {0}: {1}' -f $r.Code, (($r.Out | Select-Object -Last 2) -join ' ')) }
        } | Out-Null
    }
    Write-WHDLog -Message 'Restart, then Devices ST: WAN Miniports should stay gone.'
}

# ---- A: all three, ONE question ----------------------------------------------------------------
function Invoke-WHDDevicesAll {
    [CmdletBinding()]
    param()
    $need = @()
    if (@(Get-WHDBtTodo).Count) { $need += 'Bluetooth network part' }
    if (-not (Test-WHDWfdDone)) { $need += 'Wi-Fi Direct' }
    if (-not (Test-WHDWanDone)) { $need += 'WAN Miniports (HARD to undo)' }
    if (-not $need.Count) {
        Write-WHDLog -Message 'DEVICES A: all three are already done - nothing to change.' -Level 'OK'
        return
    }
    if (-not (Confirm-WHDProceed -What ('devices: {0}' -f ($need -join ', ')))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do {
        Invoke-WHDBtNetworkOff -NoAsk
        if (-not $script:WHDState.JournalStop) { Invoke-WHDWifiDirectOff -NoAsk }
        if (-not $script:WHDState.JournalStop) { Invoke-WHDWanMiniportsOff -NoAsk }
    }
}

# ---- ST: status (read-only) ---------------------------------------------------------------------
function Show-WHDDevicesStatus {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message '================ DEVICES STATUS (read-only) ================' -Level 'ACT'
    $bt = @(Get-WHDBtPanAdapter)
    if (-not $bt.Count) { Write-WHDLog -Message 'Bluetooth network adapter : none' -Level 'OK' }
    foreach ($a in $bt) {
        $ifKey = ('{0}\{1}' -f $script:WHDTcpIfRoot, [string]$a.InterfaceGuid)
        $dh = Get-WHDRegValueState -Path $ifKey -Name 'EnableDHCP'; $ac = Get-WHDRegValueState -Path $ifKey -Name 'IPAutoconfigurationEnabled'
        $dhOff = $dh.Exists -and [int]$dh.Value -eq 0; $acOff = $ac.Exists -and [int]$ac.Value -eq 0
        $ok = $dhOff -and $acOff -and ([string]$a.Status -in 'Disabled', 'Not Present')
        Write-WHDLog -Message ('Bluetooth network adapter : {0}  status {1}, DHCP {2}, autoconfig {3}' -f $a.Name, $a.Status, $(if ($dhOff) { 'off' } else { 'ON' }), $(if ($acOff) { 'off' } else { 'ON' })) -Level $(if ($ok) { 'OK' } else { 'WARN' })
    }
    $wfd = @(Get-WHDWfdDevice)
    $wfdOn = @($wfd | Where-Object { $_.Present -and -not (Test-WHDDeviceDisabled -Device $_) }).Count
    Write-WHDLog -Message ('Wi-Fi Direct adapters     : {0} listed, {1} enabled' -f $wfd.Count, $wfdOn) -Level $(if ($wfdOn) { 'WARN' } else { 'OK' })
    foreach ($s in $script:WHDWfdServices) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($svc) { Write-WHDLog -Message ('  service {0,-14}: {1} / {2}' -f $s, $svc.Status, $svc.StartType) -Level $(if ([string]$svc.StartType -eq 'Disabled') { 'OK' } else { 'INFO' }) }
    }
    $wan = @(Get-WHDWanDevice)
    Write-WHDLog -Message ('WAN Miniports             : {0} present' -f $wan.Count) -Level $(if ($wan.Count) { 'WARN' } else { 'OK' })
    foreach ($d in $wan) { Write-WHDLog -Message ('  {0}' -f $d.FriendlyName) }
    $ras = Get-Service -Name 'RasMan' -ErrorAction SilentlyContinue
    if ($ras) { Write-WHDLog -Message ('  RasMan (re-creates them) : {0} / {1}' -f $ras.Status, $ras.StartType) -Level $(if ([string]$ras.StartType -eq 'Disabled') { 'OK' } else { 'INFO' }) }
    $ids = @(Get-WHDDenyId)
    Write-WHDLog -Message ('Install block             : {0}, {1} ID(s) listed' -f $(if (Test-WHDDenyOn) { 'ON' } else { 'off' }), $ids.Count)
    if (($wan.Count -or $wfdOn) -and $ids.Count) {
        Write-WHDLog -Message 'Blocked devices are back or enabled - Windows may be ignoring the install block on this edition. Run the item again; if they keep coming back, this edition of Windows does not apply the install-block policy.' -Level 'WARN'
    }
    Write-WHDLog -Message '================ END ================' -Level 'ACT'
}

# ---- menu ---------------------------------------------------------------------------------------
function Get-WHDDevicesItemState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet(1, 2, 3)][int]$Item)
    switch ($Item) {
        1 { if (-not @(Get-WHDBtPanAdapter).Count) { return 'no adapter' }; if (@(Get-WHDBtTodo).Count) { return 'on' }; return 'off' }
        2 { if (Test-WHDWfdDone) { return 'off + blocked' }; return 'on' }
        3 { if (Test-WHDWanDone) { return 'blocked + removed' }; return ('{0} present' -f @(Get-WHDWanDevice).Count) }
    }
}

function Show-WHDDevicesMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== DEVICES (network adapters you do not use) ===============' -ForegroundColor White
    Write-WHDMenuItem -Key '1' -Label 'Bluetooth network part only (DHCP + autoconfig off, adapter off)' -Hint ('[{0}]' -f (Get-WHDDevicesItemState -Item 1))
    Write-WHDMenuItem -Key '2' -Label 'Wi-Fi Direct virtual adapters off + block re-install' -Hint ('[{0}]' -f (Get-WHDDevicesItemState -Item 2))
    Write-WHDMenuItem -Key '3' -Label 'WAN Miniports: block re-install + remove (hard to undo)' -Hint ('[{0}]' -f (Get-WHDDevicesItemState -Item 3))
    Write-WHDMenuItem -Key 'A' -Label 'All three (one question)'
    Write-WHDMenuItem -Key 'ST' -Label 'Status (read-only)' -Hint '(was S in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDDevicesChoice {
    # One menu choice. Returns $false for B (back).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^1$' { Invoke-WHDBtNetworkOff }
        '^2$' { Invoke-WHDWifiDirectOff }
        '^3$' { Invoke-WHDWanMiniportsOff }
        '^[Aa]$' { Invoke-WHDDevicesAll }
        '^[Ss][Tt]$' { Show-WHDDevicesStatus }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
