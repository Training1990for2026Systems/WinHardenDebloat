#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Security.ps1   ("Security+")
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features and values as WHD Next 2.0 (D8), rewritten for PowerShell 7.6:
   Defender : block unwanted apps (PUA) ON; network protection and ransomware
              folder protection AUDIT (or BLOCK on request); attack-surface
              rules in three groups, all start in AUDIT; list, events, promote.
   Protocols: LLMNR, NetBIOS over TCP/IP, WPAD, Remote Assistance - off.
   Services : file/printer sharing, SMB, dial-up/VPN, IPsec, proxy auto-detect
              switch, fax/phone - off; WinHTTP proxy SERVICE = test only.
   Accounts : UAC "Always notify"; password + lockout rules for local accounts.
   T        : PowerShell 7 telemetry off - POWERSHELL_TELEMETRY_OPTOUT = 1 as a
              machine environment variable (D50, owner's choice beyond D8).
              Recorded as a registry value, so Undo, Verify and the update guard
              (step 7) cover it; already set by hand = taken under watch once,
              and Undo removes it then too (D51).
   Report   : read-only security report.
 Everything goes through the engine: dry-run first, one question per action,
 restore point before the first change, recorded (Undo center), read back.
 Sources: Microsoft Learn - ASR rules reference (works on any edition with
 Microsoft Defender Antivirus, e.g. Windows 11 Home), MSFT_MpPreference,
 disable HTTP proxy features (DisableWpad), SMB v1/v2/v3.
================================================================================
#>

# ---- attack-surface rule catalog (Microsoft Learn) ----------------------------------
$script:WHDAsrRules = @(
    [pscustomobject]@{ Id = '56a863a9-875e-4185-98a7-b882c64b5ce5'; Group = 'standard'; Name = 'Block abuse of exploited vulnerable signed drivers' }
    [pscustomobject]@{ Id = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'; Group = 'standard'; Name = 'Block credential stealing from LSASS' }
    [pscustomobject]@{ Id = 'e6db77e5-3df2-4cf1-b95a-636979351e5b'; Group = 'standard'; Name = 'Block persistence through WMI event subscription' }
    [pscustomobject]@{ Id = '5beb7efe-fd9a-4556-801d-275e5ffc04cc'; Group = 'scripts'; Name = 'Block execution of potentially obfuscated scripts' }
    [pscustomobject]@{ Id = 'd3e037e1-3eb8-44c8-a917-57927947596d'; Group = 'scripts'; Name = 'Block JavaScript/VBScript launching downloaded executables' }
    [pscustomobject]@{ Id = 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'; Group = 'scripts'; Name = 'Block use of copied or impersonated system tools' }
    [pscustomobject]@{ Id = 'c1db55ab-c21a-4637-bb3f-a12568109d35'; Group = 'scripts'; Name = 'Use advanced protection against ransomware' }
    [pscustomobject]@{ Id = '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'; Group = 'office'; Name = 'Block Adobe Reader from creating child processes' }
    [pscustomobject]@{ Id = 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'; Group = 'office'; Name = 'Block all Office apps from creating child processes' }
    [pscustomobject]@{ Id = 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'; Group = 'office'; Name = 'Block executable content from email client and webmail' }
    [pscustomobject]@{ Id = '3b576869-a4ec-4529-8536-b80a7769e899'; Group = 'office'; Name = 'Block Office apps from creating executable content' }
    [pscustomobject]@{ Id = '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'; Group = 'office'; Name = 'Block Office apps from injecting code into other processes' }
    [pscustomobject]@{ Id = '26190899-1602-49e8-8b27-eb1d0a1ce869'; Group = 'office'; Name = 'Block Office communication app from creating child processes' }
    [pscustomobject]@{ Id = '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'; Group = 'office'; Name = 'Block Win32 API calls from Office macros' }
)
$script:WHDAsrGroups = [ordered]@{ standard = 'Microsoft standard 3'; scripts = 'Script + download rules'; office = 'Office / Adobe / email rules' }

# ---- Defender ----------------------------------------------------------------------
function Get-WHDMpComputerStatus { [CmdletBinding()] param() Get-CimInstance -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop }

function Test-WHDDefenderReady {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $mcs = Get-WHDMpComputerStatus
        if (-not $mcs.AntivirusEnabled -or [string]$mcs.AMRunningMode -notmatch 'Normal') {
            Write-WHDLog -Message ('Microsoft Defender Antivirus is not the active antivirus (mode: {0}). These settings only work when it is.' -f $mcs.AMRunningMode) -Level 'WARN'
            return $false
        }
        return $true
    } catch {
        Write-WHDLog -Message ('Microsoft Defender status could not be read: {0}' -f $_.Exception.Message) -Level 'WARN'
        return $false
    }
}

function Get-WHDAsrState {
    # Every WHD rule with its current action (read-only).
    [CmdletBinding()]
    param()
    $map = @{}
    try { $map = Get-WHDAsrCode } catch { Write-Verbose 'ASR state unreadable' }
    foreach ($r in $script:WHDAsrRules) {
        $c = if ($map.ContainsKey($r.Id)) { $map[$r.Id] } else { 0 }
        [pscustomobject]@{ Group = $script:WHDAsrGroups[$r.Group]; Name = $r.Name; Id = $r.Id; Action = (Get-WHDAsrName -Code $c); Code = $c }
    }
}

function Invoke-WHDAsrGroup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('standard', 'scripts', 'office')][string[]]$Groups, [ValidateSet('Audit', 'Block')][string]$Mode = 'Audit')
    if (-not (Test-WHDDefenderReady)) { return }
    $rules = @($script:WHDAsrRules | Where-Object { $Groups -contains $_.Group })
    Write-WHDLog -Message ('ASR RULES -> {0}: {1} rule(s) in {2}' -f $Mode.ToUpperInvariant(), $rules.Count, (($Groups | ForEach-Object { $script:WHDAsrGroups[$_] }) -join ', ')) -Level 'ACT'
    if ($Mode -eq 'Audit') { Write-WHDRisk -Tier 'reversible' -Text 'AUDIT = nothing is blocked; Defender only logs what each rule WOULD block. Review with "what they caught", then switch to Block.' }
    else { Write-WHDRisk -Tier 'caution' -Text 'BLOCK = matching actions are stopped (Windows Security shows a notification). Undo per rule in the Undo center.' }
    if (-not (Confirm-WHDProceed -What ('set {0} ASR rule(s) to {1}' -f $rules.Count, $Mode))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $code = if ($Mode -eq 'Block') { 1 } else { 2 }
    foreach ($r in $rules) { Set-WHDAsrRule -Id $r.Id -Code $code -Name $r.Name | Out-Null }
}

function Invoke-WHDAsrPromote {
    # Every WHD rule now in Audit -> Block.
    [CmdletBinding()]
    param()
    if (-not (Test-WHDDefenderReady)) { return }
    $aud = @(Get-WHDAsrState | Where-Object Code -eq 2)
    if (-not $aud.Count) { Write-WHDLog -Message 'No WHD ASR rules are in Audit.'; return }
    Write-WHDLog -Message ('ASR: switch {0} audited rule(s) to BLOCK' -f $aud.Count) -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text 'Check "what they caught" first: anything listed there would now be blocked.'
    if (-not (Confirm-WHDProceed -What ('switch {0} ASR rule(s) from Audit to Block' -f $aud.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($r in $aud) { Set-WHDAsrRule -Id $r.Id -Code 1 -Name $r.Name | Out-Null }
}

function Get-WHDDefenderEvent {
    # What the rules / network protection / folder protection caught (Defender Operational log).
    #   1121 ASR block, 1122 ASR audit, 1123 folder block, 1124 folder audit, 1125 network audit, 1126 network block
    [CmdletBinding()]
    param([int]$Days = 7, [int]$Max = 500)
    $names = @{}; foreach ($r in $script:WHDAsrRules) { $names[$r.Id] = $r.Name }
    $kind = @{ 1121 = 'ASR block'; 1122 = 'ASR audit'; 1123 = 'Folder block'; 1124 = 'Folder audit'; 1125 = 'Network audit'; 1126 = 'Network block' }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1121, 1122, 1123, 1124, 1125, 1126); StartTime = (Get-Date).AddDays(-1 * $Days) } -MaxEvents $Max -ErrorAction SilentlyContinue)
    foreach ($e in $ev) {
        $x = [xml]$e.ToXml(); $d = @{}
        foreach ($n in @($x.Event.EventData.Data)) { $d[[string]$n.Name] = [string]$n.'#text' }
        $id = ([string]$d['ID']).ToLowerInvariant()
        [pscustomobject]@{
            Time = $e.TimeCreated; Type = $kind[[int]$e.Id]
            Rule = $(if ($names.ContainsKey($id)) { $names[$id] } elseif ($id) { $id } else { '' })
            Program = [string]$d['Process Name']; Target = [string]$d['Path']; User = [string]$d['User']; Data = $d
        }
    }
}

function Get-WHDDefenderEventGroup {
    # The same events, one entry per (type, rule, program, target): count, first and last time. Newest first.
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Events)
    $map = [ordered]@{}
    foreach ($e in @($Events | Where-Object { $_ })) {
        $key = ('{0}|{1}|{2}|{3}' -f $e.Type, $e.Rule, $e.Program, $e.Target).ToLowerInvariant()
        if (-not $map.Contains($key)) { $map[$key] = [pscustomobject]@{ Type = [string]$e.Type; Rule = [string]$e.Rule; Program = [string]$e.Program; Target = [string]$e.Target; User = [string]$e.User; Count = 0; First = $e.Time; Last = $e.Time; Data = $e.Data } }
        $g = $map[$key]
        $g.Count++
        if ($e.Time -lt $g.First) { $g.First = $e.Time }
        if ($e.Time -gt $g.Last) { $g.Last = $e.Time; $g.User = [string]$e.User; $g.Data = $e.Data }
    }
    @($map.Values) | Sort-Object -Property @{ Expression = 'Last'; Descending = $true }, @{ Expression = 'Count'; Descending = $true }, Type, Program, Target
}

function Show-WHDDefenderEvent {
    [CmdletBinding()]
    param([int]$Days = 7, [object[]]$Events)
    if (-not $PSBoundParameters.ContainsKey('Events')) { $Events = @(Get-WHDDefenderEvent -Days $Days) }
    $ev = @($Events | Where-Object { $_ })
    if (-not $ev.Count) { Write-Host ('  (nothing caught in the last {0} days)' -f $Days) -ForegroundColor DarkGray; return }
    $groups = @(Get-WHDDefenderEventGroup -Events $ev)
    Write-Host ''
    Write-Host ('  What Defender caught in the last {0} days: {1} event(s), {2} different - newest first' -f $Days, $ev.Count, $groups.Count) -ForegroundColor White
    Write-Host '  (program = what tried it; target = what it tried to reach or change)' -ForegroundColor DarkGray
    $i = 0
    foreach ($g in $groups) {
        $i++
        $when = if ($g.Count -gt 1) { 'x{0}   last {1:yyyy-MM-dd HH:mm:ss}   first {2:yyyy-MM-dd HH:mm:ss}' -f $g.Count, $g.Last, $g.First } else { 'x1   {0:yyyy-MM-dd HH:mm:ss}' -f $g.Last }
        Write-Host ''
        Write-Host ('  {0,3}. {1,-14} {2}' -f $i, $g.Type, $when) -ForegroundColor $(if ($g.Type -like '*block*') { 'Yellow' } else { 'Gray' })
        if ($g.Rule) { Write-Host ('       rule    : {0}' -f $g.Rule) }
        Write-Host ('       program : {0}' -f $(if ($g.Program) { $g.Program } else { '(not named in the event)' }))
        Write-Host ('       target  : {0}' -f $(if ($g.Target) { $g.Target } else { '(not named in the event)' }))
        if ($g.User) { Write-Host ('       user    : {0}' -f $g.User) -ForegroundColor DarkGray }
        if (-not $g.Program -and -not $g.Target -and $g.Data) {
            foreach ($dk in @($g.Data.Keys | Sort-Object)) { if ($dk -and $g.Data[$dk]) { Write-Host ('       {0} = {1}' -f $dk, $g.Data[$dk]) -ForegroundColor DarkGray } }
        }
    }
    Write-Host ''
}

function Invoke-WHDDefenderProtection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('PUA', 'Network', 'Folders')][string]$Which, [ValidateSet('On', 'Audit', 'Off')][string]$Mode = 'On')
    if (-not (Test-WHDDefenderReady)) { return }
    $setting = @{ PUA = 'PUAProtection'; Network = 'EnableNetworkProtection'; Folders = 'EnableControlledFolderAccess' }[$Which]
    $val = @{ On = 1; Audit = 2; Off = 0 }[$Mode]
    $label = @{ PUA = 'Block potentially unwanted apps'; Network = 'Network protection'; Folders = 'Ransomware folder protection (Controlled folder access)' }[$Which]
    $note = @{
        PUA     = 'Blocks adware / bundleware / unwanted installers. Same as Windows Security > App & browser control > Reputation-based protection.'
        Network = 'Blocks any app from reaching known-malicious sites (not only Edge). AUDIT = log only.'
        Folders = 'Only trusted apps may change protected folders (Documents, Pictures, Desktop...). AUDIT = log only; in Block mode allow an app in Windows Security > Ransomware protection.'
    }[$Which]
    Write-WHDLog -Message ('DEFENDER: {0} -> {1}' -f $label, $Mode.ToUpperInvariant()) -Level 'ACT'
    Write-WHDRisk -Tier $(if ($Mode -eq 'On' -and $Which -eq 'Folders') { 'caution' } else { 'reversible' }) -Text $note
    if (-not (Confirm-WHDProceed -What ('{0} -> {1}' -f $label, $Mode))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDMpPreference -Setting $setting -Value $val | Out-Null
}

# ---- old network protocols (registry, recorded) ---------------------------------------
$script:WHDProtocols = @(
    [pscustomobject]@{ Key = 'llmnr'; Name = 'LLMNR (link-local name lookup)'; Note = 'Off via DNS Client policy EnableMulticast=0. Stops a classic credential-theft trick on shared networks.' }
    [pscustomobject]@{ Key = 'netbios'; Name = 'NetBIOS over TCP/IP (all adapters)'; Note = 'NetbiosOptions=2 on every adapter. Takes full effect after reconnecting or a restart. Very old printers/NAS that browse by NetBIOS name may stop being found.' }
    [pscustomobject]@{ Key = 'wpad'; Name = 'WPAD proxy auto-discovery'; Note = 'WinHttp DisableWpad=1 (Microsoft Learn: disable HTTP proxy features). Home networks do not use WPAD.' }
    [pscustomobject]@{ Key = 'remoteassist'; Name = 'Remote Assistance'; Note = 'No one can be invited to view or control this PC via Windows Remote Assistance.' }
)

function Get-WHDNetBtInterfaceKey {
    [CmdletBinding()]
    param()
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Tcpip_*' } | ForEach-Object { '{0}\{1}' -f $base, $_.PSChildName }
}

function Get-WHDProtocolOp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('llmnr', 'netbios', 'wpad', 'remoteassist')][string]$Key)
    switch ($Key) {
        'llmnr' { [pscustomobject]@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; N = 'EnableMulticast'; V = 0; T = 'DWord' } }
        'netbios' { foreach ($k in Get-WHDNetBtInterfaceKey) { [pscustomobject]@{ P = $k; N = 'NetbiosOptions'; V = 2; T = 'DWord' } } }
        'wpad' { [pscustomobject]@{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp'; N = 'DisableWpad'; V = 1; T = 'DWord' } }
        'remoteassist' {
            [pscustomobject]@{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N = 'fAllowToGetHelp'; V = 0; T = 'DWord' }
            [pscustomobject]@{ P = 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N = 'fAllowFullControl'; V = 0; T = 'DWord' }
        }
    }
}

function Invoke-WHDProtocolOff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)
    $ops = @(Get-WHDProtocolOp -Key $Item.Key)
    Write-WHDLog -Message ('PROTOCOL OFF: {0}' -f $Item.Name) -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text $Item.Note
    if (-not $ops.Count) { Write-WHDLog -Message 'Nothing to set (no matching adapters found).' -Level 'WARN'; return }
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set') { Write-WHDLog -Message 'Already off - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('turn off {0}' -f $Item.Name))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($op in $ops) { Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null }
    if ($Item.Key -eq 'llmnr' -and (Test-WHDRealChange)) { [void](Invoke-WHDNative -Exe 'ipconfig.exe' -ArgList @('/flushdns')) }
}

# ---- network services off ----------------------------------------------------------
# Switched off by the registry Start value (4 = Disabled), not Set-Service: Windows refuses Set-Service for
# some (WinHttpAutoProxySvc), and the registry route keeps "Automatic (Delayed Start)" for an exact undo.
$script:WHDSvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$script:WHDNetServiceGroups = @(
    [pscustomobject]@{ Key = 'fileshare'; Name = 'Workstation + Server (file/printer sharing)'; Services = @('LanmanServer', 'LanmanWorkstation'); Risk = 'caution'; NotInAll = $false
        Note = 'No Windows file or printer sharing, no mapped drives, no \\PC\share paths, no "net use". A few older installers ask the Workstation service for the PC name and may complain. Undo in the Undo center, then restart.' }
    [pscustomobject]@{ Key = 'smb'; Name = 'SMB 1/2/3 protocol (server + client)'; Services = @(); Risk = 'caution'; NotInAll = $false
        Note = 'Server side SMB1=0 + SMB2=0 (SMB2 also covers SMB3; Microsoft Learn: detect/enable/disable SMBv1, v2, v3). Client drivers mrxsmb20/mrxsmb10 Start=4. SMB1 optional feature removed if it is on. Restart needed.' }
    [pscustomobject]@{ Key = 'dialvpn'; Name = 'Dial-up + built-in VPN (RAS, SSTP, Telephony)'; Services = @('RasMan', 'RasAuto', 'SstpSvc', 'RemoteAccess', 'TapiSrv'); Risk = 'caution'; NotInAll = $false
        Note = 'Settings > Network > VPN and Dial-up stop working; Mobile hotspot may too. Third-party VPN apps with their own driver are not affected. If Wi-Fi or Ethernet misbehaves after a restart, undo this group first.' }
    [pscustomobject]@{ Key = 'ipsec'; Name = 'IPsec VPN keying (IKEEXT, PolicyAgent)'; Services = @('IKEEXT', 'PolicyAgent'); Risk = 'reversible'; NotInAll = $false
        Note = 'Only built-in IPsec / IKEv2 / L2TP VPNs and domain IPsec rules use these. Windows Firewall itself keeps working.' }
    [pscustomobject]@{ Key = 'proxy'; Name = 'Proxy auto-detect: Settings switch only (service untouched)'; Services = @(); Risk = 'reversible'; NotInAll = $false
        Note = 'Settings > Network > Proxy "Automatically detect settings" OFF for this user (Microsoft Learn: turn WPAD off in the Settings UI too). The WinHTTP proxy service is NOT touched (disabling it broke Wi-Fi in testing - see N7).' }
    [pscustomobject]@{ Key = 'faxphone'; Name = 'Fax + Phone service'; Services = @('Fax', 'PhoneSvc'); Risk = 'reversible'; NotInAll = $false
        Note = 'Fax (only if present) and Phone Service.' }
    [pscustomobject]@{ Key = 'proxysvc'; Name = 'WinHTTP proxy SERVICE off - TEST ONLY (broke Wi-Fi in testing)'; Services = @('WinHttpAutoProxySvc'); Risk = 'hard'; NotInAll = $true
        Note = 'In testing, with this service disabled WLAN AutoConfig and IP Helper did not run after a restart: Wi-Fi showed "Dormant" and there was no internet. Test-only; meant for Ethernet-only PCs. Never part of NA or a profile.' }
)
$script:WHDProxyConnKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'

function Get-WHDProxyAutoDetectOp {
    # Byte 8 of DefaultConnectionSettings holds the flags; 0x08 = "Automatically detect settings".
    # Bytes 4-7 are a change counter Windows bumps on every edit - bumped too.
    [CmdletBinding()]
    param()
    foreach ($n in 'DefaultConnectionSettings', 'SavedLegacySettings') {
        $rs = Get-WHDRegValueState -Path $script:WHDProxyConnKey -Name $n
        if (-not $rs.Exists) { continue }
        $b = [byte[]]@($rs.Value | ForEach-Object { [byte]$_ })
        if ($b.Length -lt 9) { continue }
        if (($b[8] -band 0x08) -eq 0) { [pscustomobject]@{ P = $script:WHDProxyConnKey; N = $n; V = $b; T = 'Binary' }; continue }
        $nb = [byte[]]$b.Clone()
        $nb[8] = [byte]($nb[8] -band 0xF7)
        $cnt = ([BitConverter]::ToUInt32($nb, 4) + 1) -band 0xFFFFFFFFL
        [Array]::Copy([BitConverter]::GetBytes([uint32]$cnt), 0, $nb, 4, 4)
        [pscustomobject]@{ P = $script:WHDProxyConnKey; N = $n; V = $nb; T = 'Binary' }
    }
}

function Get-WHDNetServiceOp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    $g = ($script:WHDNetServiceGroups | Where-Object Key -eq $Key | Select-Object -First 1)
    if (-not $g) { return }
    foreach ($svc in @($g.Services)) {
        $p = '{0}\{1}' -f $script:WHDSvcRoot, $svc
        if (Test-Path -LiteralPath $p) { [pscustomobject]@{ P = $p; N = 'Start'; V = 4; T = 'DWord' } }
    }
    if ($Key -eq 'smb') {
        $lp = '{0}\LanmanServer\Parameters' -f $script:WHDSvcRoot
        if (Test-Path -LiteralPath $lp) {
            [pscustomobject]@{ P = $lp; N = 'SMB1'; V = 0; T = 'DWord' }
            [pscustomobject]@{ P = $lp; N = 'SMB2'; V = 0; T = 'DWord' }
        }
        foreach ($d in 'mrxsmb20', 'mrxsmb10') {
            $dp = '{0}\{1}' -f $script:WHDSvcRoot, $d
            if (Test-Path -LiteralPath $dp) { [pscustomobject]@{ P = $dp; N = 'Start'; V = 4; T = 'DWord' } }
        }
    }
    if ($Key -eq 'proxy') { Get-WHDProxyAutoDetectOp }
}

function Get-WHDNetServiceState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Key)
    $ops = @(Get-WHDNetServiceOp -Key $Key)
    if (-not $ops.Count) { return 'not present' }
    switch (Get-WHDRegOpsState -Ops $ops) { 'set' { return 'off' } 'partly' { return 'partly off' } default { return 'on' } }
}

function Invoke-WHDNetServiceOff {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)
    Write-WHDLog -Message ('SERVICES OFF: {0}' -f $Item.Name) -Level 'ACT'
    Write-WHDRisk -Tier $Item.Risk -Text $Item.Note
    $ops = @(Get-WHDNetServiceOp -Key $Item.Key)
    $smb1On = $false
    if ($Item.Key -eq 'smb') { try { $smb1On = ([string](Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop).State -eq 'Enabled') } catch { $smb1On = $false } }
    $running = @($Item.Services | ForEach-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue } | Where-Object { [string]$_.Status -ne 'Stopped' })
    if (-not $ops.Count -and -not $smb1On) { Write-WHDLog -Message 'Not present on this PC - nothing to do.' -Level 'OK'; return }
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set' -and -not $smb1On -and -not $running.Count) { Write-WHDLog -Message 'Already off - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('turn off {0}' -f $Item.Name))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($op in $ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }   # already right - no write, no record
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
    foreach ($svc in $running) {
        $nsvcName = [string]$svc.Name
        Invoke-WHDChange -Description ('stop service {0} now' -f $nsvcName) -Action { Stop-Service -Name $nsvcName -Force -ErrorAction Stop } | Out-Null
    }
    if ($smb1On) {
        Invoke-WHDChange -Description 'disable optional feature: SMB1Protocol' -Journal @{ Kind = 'feature'; Feature = 'SMB1Protocol' } -Action {
            [void](Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop)
        } | Out-Null
    }
    if ($Item.Key -eq 'proxy' -and -not @(Get-WHDProxyAutoDetectOp).Count) {
        Write-WHDLog -Message 'Proxy switch: this user has no saved proxy settings yet - open Settings > Network > Proxy once, then run this again.' -Level 'WARN'
    }
    Write-WHDLog -Message 'Restart the PC to finish.'
}

# ---- password + lockout rules (local accounts, net.exe accounts) ----------------------
# Owner's values (2026-09-23): 14 chars, remember 5, never expire, lock after 3 bad tries for 10 min,
# counter resets after 10 min. 0 = never expires / no history / never lock.
$script:WHDPasswordTarget = [ordered]@{ MinLen = 14; History = 5; MaxAge = 0; Threshold = 3; Duration = 10; Window = 10 }
$script:WHDPasswordNames = @{ MinLen = 'minimum password length'; History = 'password history'; MaxAge = 'maximum password age (days)'
                              Threshold = 'lockout threshold (bad tries)'; Duration = 'lockout duration (min)'; Window = 'bad-try counter reset (min)' }

function Get-WHDPasswordText {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Setting, [int]$Value)
    if ($Value -ne 0) { return [string]$Value }
    switch ($Setting) { 'MaxAge' { 'never' } 'History' { 'none' } 'Threshold' { 'never lock' } default { '0' } }
}

function Show-WHDPasswordPolicy {
    [CmdletBinding()]
    param($Policy = (Get-WHDPasswordPolicy))
    if (-not $Policy) { Write-WHDLog -Message 'Password policy unreadable (net accounts output not recognised - non-English Windows?).' -Level 'WARN'; return }
    foreach ($k in $script:WHDPasswordTarget.Keys) {
        $now = [int]$Policy[$k]; $want = [int]$script:WHDPasswordTarget[$k]
        Write-WHDLog -Message ('  {0,-32}: {1,-14} (WHD target: {2})' -f $script:WHDPasswordNames[$k], (Get-WHDPasswordText -Setting $k -Value $now), (Get-WHDPasswordText -Setting $k -Value $want)) -Level $(if ($now -eq $want) { 'OK' } else { 'INFO' })
    }
}

function Test-WHDPasswordPolicySet {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $p = Get-WHDPasswordPolicy
    if (-not $p) { return $false }
    foreach ($k in $script:WHDPasswordTarget.Keys) { if ([int]$p[$k] -ne [int]$script:WHDPasswordTarget[$k]) { return $false } }
    return $true
}

function Get-WHDPasswordOrder {
    # Windows requires the bad-try counter reset <= lockout duration: order the two so every step is valid.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][int]$CurrentDuration)
    $order = @('MinLen', 'History', 'MaxAge', 'Threshold')
    if ([int]$script:WHDPasswordTarget.Window -le $CurrentDuration) { $order += 'Window', 'Duration' } else { $order += 'Duration', 'Window' }
    return $order
}

function Invoke-WHDPasswordPolicy {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'PASSWORD + LOCKOUT RULES (local accounts)' -Level 'ACT'
    $cur = Get-WHDPasswordPolicy
    if (-not $cur) { Write-WHDLog -Message 'Cannot read the current policy (net accounts output not recognised) - nothing changed.' -Level 'ERR'; return }
    Show-WHDPasswordPolicy -Policy $cur
    $todo = @($script:WHDPasswordTarget.Keys | Where-Object { [int]$cur[$_] -ne [int]$script:WHDPasswordTarget[$_] })
    if (-not $todo.Count) { Write-WHDLog -Message 'Already set - nothing to change.' -Level 'OK'; return }
    Write-WHDRisk -Tier 'caution' -Text ('Applies to LOCAL accounts only (a Microsoft-account password is governed online). Your current password keeps working; the {0}-character minimum applies the next time a password is changed. 3 wrong passwords lock the account for 10 minutes - a Windows Hello PIN has its own separate lock. Recorded; undo restores the old values.' -f $script:WHDPasswordTarget.MinLen)
    $what = ($todo | ForEach-Object { '{0}={1}' -f $script:WHDPasswordNames[$_], (Get-WHDPasswordText -Setting $_ -Value $script:WHDPasswordTarget[$_]) }) -join ', '
    if (-not (Confirm-WHDProceed -What ('set password rules: {0}' -f $what))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($k in Get-WHDPasswordOrder -CurrentDuration ([int]$cur['Duration'])) { if ($todo -contains $k) { Set-WHDPasswordSetting -Setting $k -Value ([int]$script:WHDPasswordTarget[$k]) | Out-Null } }
}

# ---- UAC + report --------------------------------------------------------------------
$script:WHDUacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

function Get-WHDUacLevel {
    # Pure: the UAC level name from the three values.
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$EnableLUA, [int]$Consent, [int]$SecureDesktop)
    if ($EnableLUA -eq 0) { return 'OFF (UAC disabled)' }
    if ($Consent -eq 2 -and $SecureDesktop -eq 1) { return 'Always notify' }
    if ($Consent -eq 5 -and $SecureDesktop -eq 1) { return 'Default (notify on app changes)' }
    if ($Consent -eq 5 -and $SecureDesktop -eq 0) { return 'Notify, no dimmed desktop' }
    if ($Consent -eq 0) { return 'Never notify' }
    return ('Custom (ConsentPromptBehaviorAdmin={0}, SecureDesktop={1})' -f $Consent, $SecureDesktop)
}

function Get-WHDUacState {
    [CmdletBinding()]
    param()
    $lua = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'EnableLUA'
    $cpb = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'ConsentPromptBehaviorAdmin'
    $sd = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'PromptOnSecureDesktop'
    $l = if ($lua.Exists) { [int]$lua.Value } else { 1 }
    $c = if ($cpb.Exists) { [int]$cpb.Value } else { 5 }
    $d = if ($sd.Exists) { [int]$sd.Value } else { 1 }
    [pscustomobject]@{ EnableLUA = $l; Consent = $c; SecureDesktop = $d; Level = (Get-WHDUacLevel -EnableLUA $l -Consent $c -SecureDesktop $d); AlwaysNotify = ($l -eq 1 -and $c -eq 2 -and $d -eq 1) }
}

# ---- T: PowerShell 7 telemetry off (D50, D51) ---------------------------------------
# Machine environment variables live in this registry key; PowerShell 7 reads POWERSHELL_TELEMETRY_OPTOUT
# when it starts. [Environment]::SetEnvironmentVariable(..., 'Machine') writes the same value AND tells
# running programs about it (new windows pick it up; sign out / in for everything).
$script:WHDEnvKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
$script:WHDPsTelName = 'POWERSHELL_TELEMETRY_OPTOUT'

function Get-WHDPsTelemetryState {
    # 'off' (variable = 1) | 'on'. Read-only.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $st = Get-WHDRegValueState -Path $script:WHDEnvKey -Name $script:WHDPsTelName
    if ($st.Exists -and [string]$st.Value -eq '1') { return 'off' }
    return 'on'
}

function Test-WHDPsTelemetryWatched {
    # Is there a recorded (not undone) change for the variable? Then Verify and the guard watch it.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return [bool]@(Get-WHDUndoList | Where-Object { $_.Kind -eq 'reg' -and $_.Description -like ('*\{0} *' -f $script:WHDPsTelName) }).Count
}

function Set-WHDMachineEnvironment {
    # Thin wrapper (tests replace it): writes a machine environment variable the Windows way.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    if ($PSCmdlet.ShouldProcess($Name, 'machine environment variable')) { [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine') }
}

function Invoke-WHDPsTelemetryOff {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'SECURITY T: PowerShell 7 telemetry off (POWERSHELL_TELEMETRY_OPTOUT = 1, machine-wide)' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'PowerShell 7 stops sending its start-up usage data to Microsoft. Nothing else changes. Takes effect for PowerShell windows opened afterwards (sign out / in for everything). Recorded: Undo removes the variable; Verify and the update guard report it if it changes or disappears.'
    $state = Get-WHDPsTelemetryState
    $watched = Test-WHDPsTelemetryWatched
    if ($state -eq 'off' -and $watched) { Write-WHDLog -Message 'Already off and watched - nothing to change.' -Level 'OK'; return }
    $what = if ($state -eq 'off') { 'take PowerShell 7 telemetry-off under watch (already set by hand)' } else { 'turn PowerShell 7 telemetry off' }
    if ($state -eq 'off') { Write-WHDLog -Message 'The variable is already 1 (set by hand) - WHD records it once so Verify and the guard watch it; Undo will remove it (D51).' }
    if (-not (Confirm-WHDProceed -What $what)) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $cur = Get-WHDRegValueState -Path $script:WHDEnvKey -Name $script:WHDPsTelName
    $ptKey = $script:WHDEnvKey; $ptName = $script:WHDPsTelName; $ptSet = ($state -ne 'off')
    # Taken under watch: recorded as if WHD had added it (OldExists = false), so Undo removes it (D51).
    $jr = @{ Kind = 'reg'; Path = $ptKey; Name = $ptName; OldKeyExists = $true
             OldExists = $(if ($ptSet) { [bool]$cur.Exists } else { $false }); OldValue = $(if ($ptSet) { $cur.Value } else { $null }); OldType = $(if ($ptSet) { $cur.Type } else { $null })
             NewExists = $true; NewValue = '1'; NewType = 'String' }
    $desc = if ($ptSet) { 'reg set {0}\{1} = 1 (String) - PowerShell 7 telemetry off' -f $ptKey, $ptName } else { 'reg watch {0}\{1} = 1 (String) - already set by hand, now recorded' -f $ptKey, $ptName }
    Invoke-WHDChange -Description $desc -Journal $jr -Action {
        if ($ptSet) {
            Backup-WHDRegistryKey -Path $ptKey
            Set-WHDMachineEnvironment -Name $ptName -Value '1'
        }
        $after = Get-WHDRegValueState -Path $ptKey -Name $ptName
        if (-not $after.Exists -or [string]$after.Value -ne '1') { throw ('read-back mismatch: {0} is {1}' -f $ptName, $(if ($after.Exists) { $after.Value } else { '(missing)' })) }
    } | Out-Null
    if ($ptSet) { Write-WHDLog -Message 'Open a new PowerShell window (or sign out and in) for it to take effect.' }   # a watch-only record is already in effect
}

function Set-WHDUacAlwaysNotify {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $u = Get-WHDUacState
    Write-WHDLog -Message ('UAC: currently "{0}"' -f $u.Level) -Level 'ACT'
    if ($u.AlwaysNotify) { Write-WHDLog -Message 'UAC is already "Always notify" - nothing to change.' -Level 'OK'; return }
    Write-WHDRisk -Tier 'reversible' -Text 'Sets UAC to "Always notify" (also asks when YOU change Windows settings), on the dimmed secure desktop. Recorded.'
    if ($u.EnableLUA -eq 0) { Write-WHDRisk -Tier 'caution' -Text 'UAC is currently OFF; turning it on needs a restart.' }
    if (-not $PSCmdlet.ShouldProcess('UAC', 'Always notify')) { return }
    if (-not (Confirm-WHDProceed -What 'set UAC to Always notify')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    if ($u.EnableLUA -ne 1) { Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'EnableLUA' -Value 1 | Out-Null }
    Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'ConsentPromptBehaviorAdmin' -Value 2 | Out-Null
    Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'PromptOnSecureDesktop' -Value 1 | Out-Null
}

function Show-WHDSecurityReport {
    # One line per finding (read-only).
    [CmdletBinding()]
    param()
    Write-WHDLog -Message '================ SECURITY+ REPORT (read-only) ================' -Level 'ACT'
    try {
        $mcs = Get-WHDMpComputerStatus; $p = Get-WHDMpPreference
        $sigAge = [int]$mcs.AntivirusSignatureAge
        $good = $mcs.AntivirusEnabled -and $mcs.RealTimeProtectionEnabled -and $sigAge -le 7
        Write-WHDLog -Message ('Defender antivirus  : {0}, real-time {1}, tamper protection {2}, signatures {3} day(s) old' -f $(if ($mcs.AntivirusEnabled) { 'on' } else { 'OFF' }), $(if ($mcs.RealTimeProtectionEnabled) { 'on' } else { 'OFF' }), $(if ($mcs.IsTamperProtected) { 'on' } else { 'off' }), $sigAge) -Level $(if ($good) { 'OK' } else { 'WARN' })
        $m = @{ 0 = 'off'; 1 = 'ON'; 2 = 'AUDIT' }
        Write-WHDLog -Message ('  unwanted apps (PUA): {0}   network protection: {1}   folder protection: {2}' -f $m[[int]$p.PUAProtection], $m[[int]$p.EnableNetworkProtection], $m[[int]$p.EnableControlledFolderAccess])
        $asr = @(Get-WHDAsrState)
        Write-WHDLog -Message ('  ASR rules (WHD set): {0} block, {1} audit, {2} off   (of {3})' -f @($asr | Where-Object Code -eq 1).Count, @($asr | Where-Object Code -eq 2).Count, @($asr | Where-Object Code -eq 0).Count, $asr.Count)
    } catch { Write-WHDLog -Message ('Defender status unreadable: {0}' -f $_.Exception.Message) -Level 'WARN' }
    $hv = Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled'
    $hvRunning = $false
    try { $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop; $hvRunning = (@($dg.SecurityServicesRunning) -contains 2) } catch { $hvRunning = $false }
    $hvTxt = if ($hvRunning) { 'ON (running)' } elseif ($hv.Exists -and [int]$hv.Value -eq 1) { 'set ON (not running yet - restart?)' } else { 'OFF' }
    Write-WHDLog -Message ('Memory integrity    : {0}   (Windows Security > Device security > Core isolation)' -f $hvTxt) -Level $(if ($hvRunning) { 'OK' } else { 'WARN' })
    $ppl = Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
    $pplOn = $ppl.Exists -and [int]$ppl.Value -in 1, 2
    Write-WHDLog -Message ('LSA protection      : {0}   (Core isolation > Local Security Authority protection)' -f $(if ($pplOn) { 'ON (RunAsPPL={0})' -f $ppl.Value } else { 'OFF / not configured' })) -Level $(if ($pplOn) { 'OK' } else { 'WARN' })
    try { $sb = Confirm-SecureBootUEFI -ErrorAction Stop; Write-WHDLog -Message ('Secure Boot         : {0}' -f $(if ($sb) { 'ON' } else { 'OFF' })) -Level $(if ($sb) { 'OK' } else { 'WARN' }) }
    catch { Write-WHDLog -Message 'Secure Boot         : not supported / legacy BIOS' -Level 'WARN' }
    $u = Get-WHDUacState
    Write-WHDLog -Message ('UAC                 : {0}' -f $u.Level) -Level $(if ($u.AlwaysNotify) { 'OK' } else { 'WARN' })
    Write-WHDLog -Message 'Password + lockout  : (local accounts; option W sets the WHD targets)'
    $pp = Get-WHDPasswordPolicy
    Show-WHDPasswordPolicy -Policy $pp
    if ($pp -and [int]$pp['Threshold'] -eq 0) { Write-WHDLog -Message '  -> no account lockout: unlimited password guesses are allowed' -Level 'WARN' }
    foreach ($it in $script:WHDProtocols) {
        $ps = Get-WHDRegOpsState -Ops @(Get-WHDProtocolOp -Key $it.Key)
        Write-WHDLog -Message ('{0,-20}: {1}' -f ($it.Name -replace ' \(.*$', ''), $(if ($ps -eq 'set') { 'off (hardened)' } elseif ($ps -eq 'partly') { 'partly off' } else { 'on (Windows default)' })) -Level $(if ($ps -eq 'set') { 'OK' } else { 'INFO' })
    }
    foreach ($g in $script:WHDNetServiceGroups) {
        $gs = Get-WHDNetServiceState -Key $g.Key
        Write-WHDLog -Message ('{0,-20}: {1}' -f $g.Key, $gs) -Level $(if ($gs -in 'off', 'not present') { 'OK' } else { 'INFO' })
    }
    Write-WHDLog -Message '================ END REPORT ================' -Level 'ACT'
}

# ---- terminal menu ---------------------------------------------------------------------
function Show-WHDSecurityMenu {
    [CmdletBinding()]
    param()
    $mp = $null; try { $mp = Get-WHDMpPreference } catch { $mp = $null }
    $mt = @{ 0 = 'off'; 1 = 'BLOCK'; 2 = 'AUDIT'; 6 = 'WARN' }
    $now = { param($n) if ($mp) { $v = [int]$mp.$n; if ($mt.ContainsKey($v)) { $mt[$v] } else { [string]$v } } else { '?' } }
    Write-Host ''
    Write-Host '  ================= SECURITY+ =================' -ForegroundColor White
    Write-Host '   R. Security report (read-only)'
    Write-Host '  Defender' -ForegroundColor DarkGray
    Write-Host ('   1. Block unwanted apps (PUA)      -> ON                     (now: {0})' -f $(if ($mp -and [int]$mp.PUAProtection -eq 1) { 'ON' } else { & $now 'PUAProtection' }))
    Write-Host ('   2. Network protection        -> AUDIT   2B. -> BLOCK      (now: {0})' -f (& $now 'EnableNetworkProtection'))
    Write-Host ('   3. Ransomware folder protect -> AUDIT   3B. -> BLOCK      (now: {0})' -f (& $now 'EnableControlledFolderAccess'))
    Write-Host '  Attack-surface rules (start in AUDIT)' -ForegroundColor DarkGray
    Write-Host '   4. Microsoft standard 3      5. Script + download      6. Office / Adobe / email'
    Write-Host '   L. List ASR rules + state    E. What they caught (events, 7 days)'
    Write-Host '   K. Switch all audited ASR rules to BLOCK'
    Write-Host '  Old network protocols (turn off)' -ForegroundColor DarkGray
    $i = 0
    foreach ($it in $script:WHDProtocols) {
        $i++
        $ps = Get-WHDRegOpsState -Ops @(Get-WHDProtocolOp -Key $it.Key)
        Write-Host ('   P{0}. {1,-38} [{2}]' -f $i, $it.Name, $(if ($ps -eq 'set') { 'off' } elseif ($ps -eq 'partly') { 'partly' } else { 'on' }))
    }
    Write-Host '   PA. all four'
    Write-Host '  Network services (turn off; restart after)' -ForegroundColor DarkGray
    $i = 0
    foreach ($g in $script:WHDNetServiceGroups) { $i++; Write-Host ('   N{0}. {1,-52} [{2}]' -f $i, $g.Name, (Get-WHDNetServiceState -Key $g.Key)) }
    Write-Host '   NA. all safe ones (N1-N6; N7 is never included)'
    Write-Host '  Account' -ForegroundColor DarkGray
    Write-Host ('   U. UAC -> Always notify   (now: {0})' -f (Get-WHDUacState).Level)
    Write-Host ('   W. Password + lockout rules -> 14 chars, remember 5, never expire, 3 tries / 10 min   (now: {0})' -f $(if (Test-WHDPasswordPolicySet) { 'set' } else { 'not set' }))
    Write-Host '  PowerShell' -ForegroundColor DarkGray
    Write-Host ('   T. PowerShell 7 telemetry off (machine-wide; watched)   (now: {0}{1})' -f $(if ((Get-WHDPsTelemetryState) -eq 'off') { 'off' } else { 'ON' }), $(if (Test-WHDPsTelemetryWatched) { ', watched' } else { '' }))
    Write-Host ('  Update guard: {0}  (main menu G)' -f (Get-WHDGuardStatus).Text) -ForegroundColor DarkGray
    Write-WHDMenuCommonKey
}

function Invoke-WHDSecurityChoice {
    # One menu choice. Returns $false for B (back), $true otherwise.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Rr]$' { Show-WHDSecurityReport }
        '^1$' { Invoke-WHDDefenderProtection -Which PUA -Mode On }
        '^2$' { Invoke-WHDDefenderProtection -Which Network -Mode Audit }
        '^2[Bb]$' { Invoke-WHDDefenderProtection -Which Network -Mode On }
        '^3$' { Invoke-WHDDefenderProtection -Which Folders -Mode Audit }
        '^3[Bb]$' { Invoke-WHDDefenderProtection -Which Folders -Mode On }
        '^4$' { Invoke-WHDAsrGroup -Groups standard }
        '^5$' { Invoke-WHDAsrGroup -Groups scripts }
        '^6$' { Invoke-WHDAsrGroup -Groups office }
        '^[Ll]$' { Get-WHDAsrState | Format-Table Group, Action, Name -AutoSize | Out-Host }
        '^[Ee]$' { Show-WHDDefenderEvent }
        '^[Kk]$' { Invoke-WHDAsrPromote }
        '^[Pp][1-4]$' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[[int]$c.Substring(1) - 1] }
        '^[Pp][Aa]$' { foreach ($it in $script:WHDProtocols) { Invoke-WHDProtocolOff -Item $it } }
        '^[Nn][1-7]$' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[[int]$c.Substring(1) - 1] }
        '^[Nn][Aa]$' { foreach ($g in @($script:WHDNetServiceGroups | Where-Object { -not $_.NotInAll })) { Invoke-WHDNetServiceOff -Item $g } }
        '^[Uu]$' { Set-WHDUacAlwaysNotify }
        '^[Ww]$' { Invoke-WHDPasswordPolicy }
        '^[Tt]$' { Invoke-WHDPsTelemetryOff }
        '^[Bb]$' { return $false }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
