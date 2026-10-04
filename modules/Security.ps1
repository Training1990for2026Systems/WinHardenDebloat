<#
================================================================================
 WinHardenDebloat  -  modules\Security.ps1   ("Security+")
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The Security+ module. Everything goes through the
 Common.ps1 engine: dry-run by default, one confirm per action, restore point
 before the first change, journaled (Undo center) and verified (read-back).

 What it offers:
   B6 Defender : PUA blocking ON; Network protection + Controlled folder access:
                 the menu options set AUDIT (log-only) or Block; ASR groups =
                 Microsoft standard 3, script/download, Office/Adobe/email - the
                 menu options start them in AUDIT (K switches audited rules to
                 Block); a profile can set Audit or Block.
                 (Stronger cloud protection and "strict extras" are not included.)
   B7 Protocols: LLMNR, NetBIOS over TCP/IP, WPAD, Remote Assistance - off.
   B8 Report   : memory integrity, LSA protection = REPORT ONLY. Password +
                 lockout: report, and option W sets the WHD targets.
                 UAC: report, and set "Always notify" if it isn't.

 Sources: Microsoft Learn - ASR rules reference (GUIDs; "available on any
 edition of Windows that includes Microsoft Defender Antivirus (for example,
 Windows 11 Home)"), Defender PowerShell (Set-MpPreference), Disable HTTP proxy
 features (DisableWpad). Offline at run time; no APIs.
================================================================================
#>

# ---- ASR rule catalog (Microsoft Learn ASR reference) ------------------------
$script:WHDAsrRules = @(
    # Microsoft "standard protection" rules
    [ordered]@{ Id='56a863a9-875e-4185-98a7-b882c64b5ce5'; Group='standard'; Name='Block abuse of exploited vulnerable signed drivers' }
    [ordered]@{ Id='9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'; Group='standard'; Name='Block credential stealing from LSASS' }
    [ordered]@{ Id='e6db77e5-3df2-4cf1-b95a-636979351e5b'; Group='standard'; Name='Block persistence through WMI event subscription' }
    # script + download
    [ordered]@{ Id='5beb7efe-fd9a-4556-801d-275e5ffc04cc'; Group='scripts'; Name='Block execution of potentially obfuscated scripts' }
    [ordered]@{ Id='d3e037e1-3eb8-44c8-a917-57927947596d'; Group='scripts'; Name='Block JavaScript/VBScript launching downloaded executables' }
    [ordered]@{ Id='c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'; Group='scripts'; Name='Block use of copied or impersonated system tools' }
    [ordered]@{ Id='c1db55ab-c21a-4637-bb3f-a12568109d35'; Group='scripts'; Name='Use advanced protection against ransomware' }
    # Office / Adobe / email
    [ordered]@{ Id='7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'; Group='office'; Name='Block Adobe Reader from creating child processes' }
    [ordered]@{ Id='d4f940ab-401b-4efc-aadc-ad5f3c50688a'; Group='office'; Name='Block all Office apps from creating child processes' }
    [ordered]@{ Id='be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'; Group='office'; Name='Block executable content from email client and webmail' }
    [ordered]@{ Id='3b576869-a4ec-4529-8536-b80a7769e899'; Group='office'; Name='Block Office apps from creating executable content' }
    [ordered]@{ Id='75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'; Group='office'; Name='Block Office apps from injecting code into other processes' }
    [ordered]@{ Id='26190899-1602-49e8-8b27-eb1d0a1ce869'; Group='office'; Name='Block Office communication app from creating child processes' }
    [ordered]@{ Id='92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'; Group='office'; Name='Block Win32 API calls from Office macros' }
)
$script:WHDAsrGroups = [ordered]@{ standard = 'Microsoft standard 3'; scripts = 'Script + download rules'; office = 'Office / Adobe / email rules' }
function _WHDAsrActionName([int]$a) { switch ($a) { 0 { 'Off' } 1 { 'Block' } 2 { 'Audit' } 6 { 'Warn' } default { "$a" } } }

# ---- Defender availability ---------------------------------------------------
function Test-WHDDefenderReady {
    if (-not (Get-Command Get-MpPreference -EA SilentlyContinue)) { Write-WHDLog 'Defender PowerShell commands are not available.' 'ERR'; return $false }
    try {
        $s = Get-MpComputerStatus -EA Stop
        if (-not $s.AntivirusEnabled -or "$($s.AMRunningMode)" -notmatch 'Normal') {
            Write-WHDLog ("Microsoft Defender Antivirus is not the active antivirus (mode: {0}). These settings only work when it is." -f $s.AMRunningMode) 'WARN'
            return $false
        }
    } catch { Write-WHDLog ("could not read Defender status: {0}" -f $_.Exception.Message) 'WARN'; return $false }
    return $true
}

# ---- journaled Defender preference (PUA / network protection / CFA) ----------
function Set-WHDMpPreference {
    param([Parameter(Mandatory)][ValidateSet('PUAProtection','EnableNetworkProtection','EnableControlledFolderAccess')][string]$Setting,
          [Parameter(Mandatory)][int]$Value)
    $old = $null
    try { $old = [int](Get-MpPreference -EA Stop).$Setting } catch {}
    if ($null -ne $old -and $old -eq $Value) { Write-WHDLog ("{0} already {1}." -f $Setting, $Value) 'INFO'; return }
    $jr = @{ Kind = 'mppref'; Setting = $Setting; OldValue = $old; NewValue = $Value }
    Invoke-WHDChange -Description ("Defender {0}: {1} -> {2}" -f $Setting, $old, $Value) -Force -Journal $jr -Action {
        $p = @{ ErrorAction = 'Stop' }; $p[$Setting] = $Value
        Set-MpPreference @p
        $now = [int](Get-MpPreference -EA Stop).$Setting
        if ($now -ne $Value) { throw ("read-back mismatch: {0} is {1} (Tamper Protection or policy may block it)" -f $Setting, $now) }
    } | Out-Null
}

# ---- ASR ---------------------------------------------------------------------
function Get-WHDAsrState {
    $map = @{}
    try {
        $p = Get-MpPreference -EA Stop
        $ids = @($p.AttackSurfaceReductionRules_Ids); $acts = @($p.AttackSurfaceReductionRules_Actions)
        for ($i = 0; $i -lt $ids.Count; $i++) { if ($ids[$i]) { $map["$($ids[$i])".ToLower()] = [int]$acts[$i] } }
    } catch {}
    @(foreach ($r in $script:WHDAsrRules) {
        $a = if ($map.ContainsKey($r.Id)) { $map[$r.Id] } else { 0 }
        [pscustomobject]@{ Group = $script:WHDAsrGroups[$r.Group]; Name = $r.Name; Id = $r.Id; Action = (_WHDAsrActionName $a); Code = $a }
    })
}

function Set-WHDAsrRule {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet(0,1,2,6)][int]$Action, [string]$Name = $Id)
    $cur = @(Get-WHDAsrState | Where-Object { $_.Id -eq $Id })
    $old = if ($cur.Count) { [int]$cur[0].Code } else { 0 }
    if ($old -eq $Action) { Write-WHDLog ("ASR already {0}: {1}" -f (_WHDAsrActionName $Action), $Name) 'INFO'; return }
    # NOTE: copy to $asrAct - inside the -Action block, "$Action" would resolve to
    # Invoke-WHDChange's own -Action parameter (PowerShell dynamic scoping).
    $asrAct = $Action; $asrId = $Id
    $jr = @{ Kind = 'asr'; RuleId = $Id; RuleName = $Name; OldAction = $old; NewAction = $asrAct }
    Invoke-WHDChange -Description ("ASR {0} -> {1}: {2}" -f (_WHDAsrActionName $old), (_WHDAsrActionName $asrAct), $Name) -Force -Journal $jr -Action {
        Add-MpPreference -AttackSurfaceReductionRules_Ids $asrId -AttackSurfaceReductionRules_Actions $asrAct -EA Stop
        $now = @(Get-WHDAsrState | Where-Object { $_.Id -eq $asrId })[0]
        if ([int]$now.Code -ne $asrAct) { throw ("read-back mismatch: rule is {0}" -f $now.Action) }
    } | Out-Null
}

# Apply one or more groups in a mode (default Audit - user decision).
function Invoke-WHDAsrGroups {
    param([Parameter(Mandatory)][ValidateSet('standard','scripts','office')][string[]]$Groups, [ValidateSet('Audit','Block')][string]$Mode = 'Audit')
    if (-not (Test-WHDDefenderReady)) { return }
    $rules = @($script:WHDAsrRules | Where-Object { $Groups -contains $_.Group })
    Write-WHDLog ("ASR RULES -> {0}: {1} rule(s) in {2}" -f $Mode.ToUpper(), $rules.Count, (($Groups | ForEach-Object { $script:WHDAsrGroups[$_] }) -join ', ')) 'ACT'
    if ($Mode -eq 'Audit') { Write-WHDRisk 'reversible' 'AUDIT = nothing is blocked; Defender only logs what each rule WOULD block. Review with "ASR events", then switch to Block.' }
    else { Write-WHDRisk 'caution' 'BLOCK = matching actions are stopped (Windows Security shows a notification). Undo per rule in the Undo center.' }
    if (-not (Confirm-WHDProceed ("set {0} ASR rule(s) to {1}" -f $rules.Count, $Mode))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $code = if ($Mode -eq 'Block') { 1 } else { 2 }
    foreach ($r in $rules) { Set-WHDAsrRule -Id $r.Id -Action $code -Name $r.Name }
}

# Promote every WHD ASR rule currently in Audit to Block.
function Invoke-WHDAsrPromote {
    if (-not (Test-WHDDefenderReady)) { return }
    $aud = @(Get-WHDAsrState | Where-Object { $_.Code -eq 2 })
    if (-not $aud.Count) { Write-WHDLog 'No WHD ASR rules are in Audit.' 'INFO'; return }
    Write-WHDLog ("ASR: switch {0} audited rule(s) to BLOCK" -f $aud.Count) 'ACT'
    Write-WHDRisk 'caution' 'Check "ASR events" first: anything listed there would now be blocked.'
    if (-not (Confirm-WHDProceed ("switch {0} ASR rule(s) from Audit to Block" -f $aud.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($r in $aud) { Set-WHDAsrRule -Id $r.Id -Action 1 -Name $r.Name }
}

# What the rules / NP / CFA caught (Defender Operational log).
#   1121 ASR block, 1122 ASR audit, 1125 NP audit, 1126 NP block,
#   1123 CFA block, 1124 CFA audit
function Get-WHDDefenderEvents {
    param([int]$Days = 7, [int]$Max = 500)
    $names = @{}; foreach ($r in $script:WHDAsrRules) { $names[$r.Id] = $r.Name }
    $kind = @{ 1121 = 'ASR block'; 1122 = 'ASR audit'; 1123 = 'Folder block'; 1124 = 'Folder audit'; 1125 = 'Network audit'; 1126 = 'Network block' }
    $gwe = $null
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = @(1121,1122,1123,1124,1125,1126); StartTime = (Get-Date).AddDays(-1 * $Days) } -MaxEvents $Max -EA SilentlyContinue -ErrorVariable gwe)
    @(foreach ($e in $ev) {
        $x = [xml]$e.ToXml(); $d = @{}
        foreach ($n in @($x.Event.EventData.Data)) { $d["$($n.Name)"] = "$($n.'#text')" }
        $id = "$($d['ID'])".ToLower()
        [pscustomobject]@{
            Time = $e.TimeCreated; Type = $kind[[int]$e.Id]
            Rule = $(if ($names.ContainsKey($id)) { $names[$id] } elseif ($id) { $id } else { '' })
            Program = "$($d['Process Name'])"; Target = "$($d['Path'])"
        }
    })
}

# ---- Defender protections (PUA on; NP + CFA audit) ---------------------------
function Invoke-WHDDefenderProtection {
    param([Parameter(Mandatory)][ValidateSet('PUA','Network','Folders')][string]$Which, [ValidateSet('On','Audit','Off')][string]$Mode = 'On')
    if (-not (Test-WHDDefenderReady)) { return }
    $setting = switch ($Which) { 'PUA' { 'PUAProtection' } 'Network' { 'EnableNetworkProtection' } 'Folders' { 'EnableControlledFolderAccess' } }
    $val = switch ($Mode) { 'On' { 1 } 'Audit' { 2 } 'Off' { 0 } }
    $label = switch ($Which) { 'PUA' { 'Block potentially unwanted apps' } 'Network' { 'Network protection' } 'Folders' { 'Ransomware folder protection (Controlled folder access)' } }
    Write-WHDLog ("DEFENDER: {0} -> {1}" -f $label, $Mode.ToUpper()) 'ACT'
    $note = switch ($Which) {
        'PUA'     { 'Blocks adware / bundleware / unwanted installers. Same as Windows Security > App & browser control > Reputation-based protection.' }
        'Network' { 'Blocks any app from reaching known-malicious sites (not only Edge). AUDIT = log only.' }
        'Folders' { 'Only trusted apps may change protected folders (Documents, Pictures, Desktop...). AUDIT = log only; in Block mode allow an app in Windows Security > Ransomware protection.' }
    }
    Write-WHDRisk $(if ($Mode -eq 'On' -and $Which -eq 'Folders') { 'caution' } else { 'reversible' }) $note
    if (-not (Confirm-WHDProceed ("{0} -> {1}" -f $label, $Mode))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Set-WHDMpPreference -Setting $setting -Value $val
}

# ---- B7 old network protocols (all registry, journaled) ----------------------
function Get-WHDNetBtInterfaceKeys {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces'
    @(Get-ChildItem -LiteralPath $base -EA SilentlyContinue | Where-Object { $_.PSChildName -like 'Tcpip_*' } | ForEach-Object { Join-Path $base $_.PSChildName })
}
function Get-WHDProtocolOps {
    param([ValidateSet('llmnr','netbios','wpad','remoteassist')][string]$Key)
    switch ($Key) {
        'llmnr'        { @(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient'; N='EnableMulticast'; V=0; T='DWord' }) }
        'netbios'      { @(foreach ($k in Get-WHDNetBtInterfaceKeys) { @{ P=$k; N='NetbiosOptions'; V=2; T='DWord' } }) }
        'wpad'         { @(@{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp'; N='DisableWpad'; V=1; T='DWord' }) }
        'remoteassist' { @(@{ P='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N='fAllowToGetHelp'; V=0; T='DWord' },
                           @{ P='HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance'; N='fAllowFullControl'; V=0; T='DWord' }) }
    }
}
$script:WHDProtocols = @(
    [ordered]@{ Key='llmnr';        Name='LLMNR (link-local name lookup)';     Note='Off via DNS Client policy EnableMulticast=0. Stops a classic credential-theft trick on shared networks.' }
    [ordered]@{ Key='netbios';      Name='NetBIOS over TCP/IP (all adapters)'; Note='NetbiosOptions=2 on every adapter. Takes full effect after reconnecting or a restart. Very old printers/NAS that browse by NetBIOS name may stop being found.' }
    [ordered]@{ Key='wpad';         Name='WPAD proxy auto-discovery';          Note='WinHttp DisableWpad=1 (Microsoft Learn: disable HTTP proxy features). Home networks do not use WPAD.' }
    [ordered]@{ Key='remoteassist'; Name='Remote Assistance';                  Note='No one can be invited to view or control this PC via Windows Remote Assistance.' }
)
function Invoke-WHDProtocolOff {
    param([Parameter(Mandatory)]$Item)
    $ops = @(Get-WHDProtocolOps -Key $Item.Key)
    Write-WHDLog ("PROTOCOL OFF: {0}" -f $Item.Name) 'ACT'
    Write-WHDRisk 'reversible' $Item.Note
    if (-not $ops.Count) { Write-WHDLog 'Nothing to set (no matching adapters found).' 'WARN'; return }
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set') { Write-WHDLog 'Already off - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed ("turn off {0}" -f $Item.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in $ops) { Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T }
    if ($Item.Key -eq 'llmnr' -and $script:WHDExecute) { & ipconfig.exe /flushdns | Out-Null }
}

# ---- Network services off (v1.2, user's choices 2026-09-27) ------------------
# Every service is switched off by its registry Start value (4 = Disabled), not
# Set-Service: Windows refuses Set-Service for some (WinHttpAutoProxySvc), and the
# registry route keeps "Automatic (Delayed Start)" intact for an exact undo.
# Journal kind 'reg' -> auto undo + Verify. Running services are stopped now;
# the new start type is certain after a restart.
$script:WHDSvcRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$script:WHDNetServiceGroups = @(
    [ordered]@{ Key='fileshare'; Name='Workstation + Server (file/printer sharing)'; Services=@('LanmanServer','LanmanWorkstation'); Risk='caution'
                Note='No Windows file or printer sharing, no mapped drives, no \\PC\share paths, no "net use". A few older installers ask the Workstation service for the PC name and may complain. Undo in the Undo center, then restart.' }
    [ordered]@{ Key='smb';       Name='SMB 1/2/3 protocol (server + client)'; Services=@(); Risk='caution'
                Note='Server side SMB1=0 + SMB2=0 (SMB2 also covers SMB3; Microsoft Learn: detect/enable/disable SMBv1, v2, v3). Client drivers mrxsmb20/mrxsmb10 Start=4. Disabling the SMB client driver also stops the Workstation service from starting. SMB1 optional feature removed if it is on. Restart needed.' }
    [ordered]@{ Key='dialvpn';   Name='Dial-up + built-in VPN (RAS, SSTP, Telephony)'; Services=@('RasMan','RasAuto','SstpSvc','RemoteAccess','TapiSrv'); Risk='caution'
                Note='Settings > Network > VPN and Dial-up stop working; Mobile hotspot may too. Third-party VPN apps with their own driver are not affected. If Wi-Fi or Ethernet misbehaves after a restart, undo this group first.' }
    [ordered]@{ Key='ipsec';     Name='IPsec VPN keying (IKEEXT, PolicyAgent)'; Services=@('IKEEXT','PolicyAgent'); Risk='reversible'
                Note='Only built-in IPsec / IKEv2 / L2TP VPNs and domain IPsec rules use these. Windows Firewall itself keeps working.' }
    # v1.3.2 (2026-09-29, user decision "option 1 + 3"): round 4 of the radio test showed that disabling the WinHTTP
    # proxy SERVICE left WLAN AutoConfig + IP Helper not running after a restart -> Wi-Fi "Dormant", no internet.
    # N5 now keeps the intent (no proxy auto-discovery) WITHOUT touching the service: Settings switch only
    # (WPAD itself is already off by P3 = WinHttp DisableWpad=1). The service switch-off is kept as N7 with a
    # red warning; it is never part of NA and profiles refuse it.
    [ordered]@{ Key='proxy';     Name='Proxy auto-detect: Settings switch only (service untouched)'; Services=@(); Risk='reversible'
                Note='Settings > Network > Proxy "Automatically detect settings" OFF for this user (Microsoft Learn: turn WPAD off in the Settings UI too). The WinHTTP proxy service is NOT touched (disabling it broke Wi-Fi in testing - see N7). With P3 on, WinHTTP no longer does WPAD look-ups at all.' }
    [ordered]@{ Key='faxphone';  Name='Fax + Phone service'; Services=@('Fax','PhoneSvc'); Risk='reversible'
                Note='Fax (only if present) and Phone Service.' }
    [ordered]@{ Key='proxysvc';  Name='WinHTTP proxy SERVICE off - TEST ONLY (broke Wi-Fi in testing)'; Services=@('WinHttpAutoProxySvc'); Risk='hard'; NotInAll=$true
                Note='In testing, with this service disabled Windows Connection Manager, WLAN AutoConfig and IP Helper did not start after a restart: Wi-Fi showed "Dormant" and there was no internet. Test-only; meant for Ethernet-only PCs. Never part of NA or a profile. Undo: Undo center, that session, then restart.' }
)
$script:WHDProxyConnKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
# Byte 8 of DefaultConnectionSettings holds the flags; 0x08 = "Automatically detect settings".
# Bytes 4-7 are a change counter Windows bumps on every edit - bumped too.
function _WHDProxyAutoDetectOps {
    $ops = @()
    foreach ($n in 'DefaultConnectionSettings', 'SavedLegacySettings') {
        $st = Get-WHDRegValueState -Path $script:WHDProxyConnKey -Name $n
        if (-not $st.Exists) { continue }
        $b = [byte[]]@($st.Value | ForEach-Object { [byte]$_ })
        if ($b.Length -lt 9) { continue }
        if (($b[8] -band 0x08) -eq 0) { $ops += [pscustomobject]@{ P = $script:WHDProxyConnKey; N = $n; V = $b; T = 'Binary' }; continue }
        $nb = [byte[]]$b.Clone()
        $nb[8] = [byte]($nb[8] -band 0xF7)
        $cnt = ([BitConverter]::ToUInt32($nb, 4) + 1) -band 0xFFFFFFFFL
        [Array]::Copy([BitConverter]::GetBytes([uint32]$cnt), 0, $nb, 4, 4)
        $ops += [pscustomobject]@{ P = $script:WHDProxyConnKey; N = $n; V = $nb; T = 'Binary' }
    }
    $ops
}
function Get-WHDNetServiceOps {
    param([Parameter(Mandatory)][string]$Key)
    $g = @($script:WHDNetServiceGroups | Where-Object { $_.Key -eq $Key })[0]
    if (-not $g) { return @() }
    $ops = @()
    foreach ($s in @($g.Services)) {
        $p = Join-Path $script:WHDSvcRoot $s
        if (Test-Path -LiteralPath $p) { $ops += [pscustomobject]@{ P = $p; N = 'Start'; V = 4; T = 'DWord' } }
    }
    if ($Key -eq 'smb') {
        $lp = Join-Path $script:WHDSvcRoot 'LanmanServer\Parameters'
        if (Test-Path -LiteralPath $lp) {
            $ops += [pscustomobject]@{ P = $lp; N = 'SMB1'; V = 0; T = 'DWord' }
            $ops += [pscustomobject]@{ P = $lp; N = 'SMB2'; V = 0; T = 'DWord' }
        }
        foreach ($d in 'mrxsmb20', 'mrxsmb10') {
            $dp = Join-Path $script:WHDSvcRoot $d
            if (Test-Path -LiteralPath $dp) { $ops += [pscustomobject]@{ P = $dp; N = 'Start'; V = 4; T = 'DWord' } }
        }
    }
    if ($Key -eq 'proxy') { $ops += @(_WHDProxyAutoDetectOps) }
    $ops
}
function Get-WHDNetServiceState {
    param([Parameter(Mandatory)][string]$Key)
    $ops = @(Get-WHDNetServiceOps -Key $Key)
    if (-not $ops.Count) { return 'not present' }
    switch (Get-WHDRegOpsState -Ops $ops) { 'set' { 'off' } 'partly' { 'partly off' } default { 'on' } }
}
function Invoke-WHDNetServiceOff {
    param([Parameter(Mandatory)]$Item)
    Write-WHDLog ("SERVICES OFF: {0}" -f $Item.Name) 'ACT'
    Write-WHDRisk $Item.Risk $Item.Note
    $ops = @(Get-WHDNetServiceOps -Key $Item.Key)
    $smb1On = $false
    if ($Item.Key -eq 'smb') { try { $smb1On = ("$((Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -EA Stop).State)" -eq 'Enabled') } catch { } }
    $running = @($Item.Services | ForEach-Object { Get-Service -Name $_ -EA SilentlyContinue } | Where-Object { "$($_.Status)" -ne 'Stopped' })
    if ($Item.Key -eq 'proxy' -and -not $ops.Count) { Write-WHDLog 'Proxy switch: this user has no saved proxy settings yet - open Settings > Network > Proxy once, then run this again.' 'WARN'; return }
    if (-not $ops.Count -and -not $smb1On) { Write-WHDLog 'Not present on this PC - nothing to do.' 'OK'; return }
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set' -and -not $smb1On -and -not $running.Count) { Write-WHDLog 'Already off - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed ("turn off {0}" -f $Item.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in $ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual $cur.Value $op.V $op.T)) { continue }   # already right - no write, no journal line
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
    foreach ($svc in $running) {
        $nsvcName = "$($svc.Name)"
        Invoke-WHDChange -Description ("stop service {0} now" -f $nsvcName) -Force -Action {
            Stop-Service -Name $nsvcName -Force -EA Stop
        } | Out-Null
    }
    if ($smb1On) {
        $jr = @{ Kind = 'feature'; Feature = 'SMB1Protocol' }
        Invoke-WHDChange -Description 'disable optional feature: SMB1Protocol' -Force -Journal $jr -Action {
            Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -EA Stop | Out-Null
        } | Out-Null
    }
    Write-WHDLog 'Restart the PC to finish.' 'INFO'
}

# ---- Password + lockout rules (local accounts, via net.exe accounts) ---------
# User's chosen values (2026-09-23): 14 chars, remember 5, never expire,
# lock after 3 bad tries for 10 min, counter resets after 10 min.
# 0 means: MaxAge = never expires, History = none, Threshold = never lock.
$script:WHDPasswordTarget = [ordered]@{ MinLen = 14; History = 5; MaxAge = 0; Threshold = 3; Duration = 10; Window = 10 }
$script:WHDPasswordNames  = @{ MinLen = 'minimum password length'; History = 'password history'; MaxAge = 'maximum password age (days)'
                               Threshold = 'lockout threshold (bad tries)'; Duration = 'lockout duration (min)'; Window = 'bad-try counter reset (min)' }
function Get-WHDPasswordPolicy {
    $na = Invoke-WHDNative -Exe 'net.exe' -ArgList @('accounts')
    if ($na.Code -ne 0) { return $null }
    $map = [ordered]@{ MinLen = 'Minimum password length'; History = 'Length of password history'; MaxAge = 'Maximum password age'
                       Threshold = 'Lockout threshold'; Duration = 'Lockout duration'; Window = 'Lockout observation window' }
    $o = [ordered]@{}
    foreach ($k in $map.Keys) {
        $line = @($na.Out | Where-Object { $_ -like "$($map[$k])*" })
        if (-not $line.Count) { return $null }   # non-English Windows or unexpected output
        $raw = (($line[0] -split ':', 2)[1]).Trim()
        if ($raw -match '^\d+$') { $o[$k] = [int]$raw }
        elseif ($raw -match '^(Never|None|Unlimited)$') { $o[$k] = 0 }
        else { return $null }
    }
    [pscustomobject]$o
}
function _WHDPwText {
    param([string]$Setting, [int]$Value)
    if ($Value -ne 0) { return "$Value" }
    switch ($Setting) { 'MaxAge' { 'never expires' } 'History' { 'none' } 'Threshold' { 'never lock' } default { '0' } }
}
function Set-WHDPasswordSetting {
    param([Parameter(Mandatory)][ValidateSet('MinLen','History','MaxAge','Threshold','Duration','Window')][string]$Setting, [Parameter(Mandatory)][int]$Value)
    $cur = Get-WHDPasswordPolicy
    $old = if ($cur) { [int]$cur.$Setting } else { $null }
    $pwSet = $Setting; $pwVal = $Value
    $arg = switch ($pwSet) {
        'MinLen'    { "/minpwlen:$pwVal" }
        'History'   { "/uniquepw:$pwVal" }
        'MaxAge'    { if ($pwVal -eq 0) { '/maxpwage:unlimited' } else { "/maxpwage:$pwVal" } }
        'Threshold' { "/lockoutthreshold:$pwVal" }
        'Duration'  { "/lockoutduration:$pwVal" }
        'Window'    { "/lockoutwindow:$pwVal" }
    }
    $jr = @{ Kind = 'netacct'; Setting = $pwSet; OldValue = $old; NewValue = $pwVal }
    Invoke-WHDChange -Description ("password policy: {0} {1} -> {2}" -f $script:WHDPasswordNames[$pwSet], $(if ($null -eq $old) { '?' } else { _WHDPwText $pwSet $old }), (_WHDPwText $pwSet $pwVal)) -Force -Journal $jr -Action {
        $r = Invoke-WHDNative -Exe 'net.exe' -ArgList @('accounts', $arg)
        if ($r.Code -ne 0) { throw ("net accounts exit {0}: {1}" -f $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
        $now = Get-WHDPasswordPolicy
        if (-not $now -or [int]$now.$pwSet -ne $pwVal) { throw 'read-back mismatch: password setting did not stick' }
    } | Out-Null
}
function Show-WHDPasswordPolicy {
    param($Policy = (Get-WHDPasswordPolicy))
    if (-not $Policy) { Write-WHDLog 'Password policy unreadable (net accounts output not recognised - non-English Windows?).' 'WARN'; return }
    foreach ($k in $script:WHDPasswordTarget.Keys) {
        $now = [int]$Policy.$k; $want = [int]$script:WHDPasswordTarget[$k]
        Write-WHDLog ("  {0,-32}: {1,-14} (WHD target: {2})" -f $script:WHDPasswordNames[$k], (_WHDPwText $k $now), (_WHDPwText $k $want)) $(if ($now -eq $want) { 'OK' } else { 'INFO' })
    }
}
function Test-WHDPasswordPolicySet {
    $p = Get-WHDPasswordPolicy
    if (-not $p) { return $false }
    foreach ($k in $script:WHDPasswordTarget.Keys) { if ([int]$p.$k -ne [int]$script:WHDPasswordTarget[$k]) { return $false } }
    $true
}
function Invoke-WHDPasswordPolicy {
    Write-WHDLog 'PASSWORD + LOCKOUT RULES (local accounts)' 'ACT'
    $cur = Get-WHDPasswordPolicy
    if (-not $cur) { Write-WHDLog 'Cannot read the current policy (net accounts output not recognised) - nothing changed.' 'ERR'; return }
    Show-WHDPasswordPolicy -Policy $cur
    $todo = @($script:WHDPasswordTarget.Keys | Where-Object { [int]$cur.$_ -ne [int]$script:WHDPasswordTarget[$_] })
    if (-not $todo.Count) { Write-WHDLog 'Already set - nothing to change.' 'OK'; return }
    Write-WHDRisk 'caution' ("Applies to LOCAL accounts only (a Microsoft-account password is governed online). Your current password keeps working; the {0}-character minimum applies the next time a password is changed. 3 wrong passwords lock the account for 10 minutes - a Windows Hello PIN has its own separate lock. Journaled; undo restores the old values." -f $script:WHDPasswordTarget.MinLen)
    if (-not (Confirm-WHDProceed ("set password rules: {0}" -f (($todo | ForEach-Object { "$($script:WHDPasswordNames[$_])=$(_WHDPwText $_ $script:WHDPasswordTarget[$_])" }) -join ', ')))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # Windows requires counter-reset window <= lockout duration: order the two so every step is valid.
    $order = @('MinLen','History','MaxAge','Threshold')
    if ([int]$script:WHDPasswordTarget.Window -le [int]$cur.Duration) { $order += @('Window','Duration') } else { $order += @('Duration','Window') }
    foreach ($k in $order) { if ($todo -contains $k) { Set-WHDPasswordSetting -Setting $k -Value ([int]$script:WHDPasswordTarget[$k]) } }
}

# ---- B8 report (read-only) + UAC ---------------------------------------------
$script:WHDUacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
function Get-WHDUacState {
    $lua = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'EnableLUA'
    $cpb = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'ConsentPromptBehaviorAdmin'
    $sd  = Get-WHDRegValueState -Path $script:WHDUacKey -Name 'PromptOnSecureDesktop'
    $l = if ($lua.Exists) { [int]$lua.Value } else { 1 }
    $c = if ($cpb.Exists) { [int]$cpb.Value } else { 5 }
    $s = if ($sd.Exists)  { [int]$sd.Value }  else { 1 }
    $level = if ($l -eq 0) { 'OFF (UAC disabled)' }
             elseif ($c -eq 2 -and $s -eq 1) { 'Always notify' }
             elseif ($c -eq 5 -and $s -eq 1) { 'Default (notify on app changes)' }
             elseif ($c -eq 5 -and $s -eq 0) { 'Notify, no dimmed desktop' }
             elseif ($c -eq 0) { 'Never notify' }
             else { "Custom (ConsentPromptBehaviorAdmin=$c, SecureDesktop=$s)" }
    [pscustomobject]@{ EnableLUA = $l; Consent = $c; SecureDesktop = $s; Level = $level; AlwaysNotify = ($l -eq 1 -and $c -eq 2 -and $s -eq 1) }
}
function Set-WHDUacAlwaysNotify {
    $u = Get-WHDUacState
    Write-WHDLog ("UAC: currently '{0}'" -f $u.Level) 'ACT'
    if ($u.AlwaysNotify) { Write-WHDLog 'UAC is already "Always notify" - nothing to change.' 'OK'; return }
    Write-WHDRisk 'reversible' 'Sets UAC to "Always notify" (also asks when YOU change Windows settings), on the dimmed secure desktop. Journaled.'
    if ($u.EnableLUA -eq 0) { Write-WHDRisk 'caution' 'UAC is currently OFF; turning it on needs a restart.' }
    if (-not (Confirm-WHDProceed 'set UAC to Always notify')) { Write-WHDLog 'skipped.' 'WARN'; return }
    if ($u.EnableLUA -ne 1) { Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'EnableLUA' -Value 1 }
    Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'ConsentPromptBehaviorAdmin' -Value 2
    Set-WHDRegistryValue -Path $script:WHDUacKey -Name 'PromptOnSecureDesktop' -Value 1
}

# One line per finding; level OK/WARN so the GUI pane colors it. Read-only.
function Show-WHDSecurityReport {
    Write-WHDLog '================ SECURITY+ REPORT (read-only) ================' 'ACT'
    # Defender
    try {
        $s = Get-MpComputerStatus -EA Stop; $p = Get-MpPreference -EA Stop
        $sigAge = [int]$s.AntivirusSignatureAge
        Write-WHDLog ("Defender antivirus  : {0}, real-time {1}, tamper protection {2}, signatures {3} day(s) old" -f $(if ($s.AntivirusEnabled) {'on'} else {'OFF'}), $(if ($s.RealTimeProtectionEnabled) {'on'} else {'OFF'}), $(if ($s.IsTamperProtected) {'on'} else {'off'}), $sigAge) $(if ($s.AntivirusEnabled -and $s.RealTimeProtectionEnabled -and $sigAge -le 7) {'OK'} else {'WARN'})
        $m = @{ 0 = 'off'; 1 = 'ON'; 2 = 'AUDIT' }
        Write-WHDLog ("  unwanted apps (PUA): {0}   network protection: {1}   folder protection: {2}" -f $m[[int]$p.PUAProtection], $m[[int]$p.EnableNetworkProtection], $m[[int]$p.EnableControlledFolderAccess]) 'INFO'
        $asr = @(Get-WHDAsrState)
        Write-WHDLog ("  ASR rules (WHD set): {0} block, {1} audit, {2} off   (of {3})" -f @($asr | ? Code -eq 1).Count, @($asr | ? Code -eq 2).Count, @($asr | ? Code -eq 0).Count, $asr.Count) 'INFO'
    } catch { Write-WHDLog ("Defender status unreadable: {0}" -f $_.Exception.Message) 'WARN' }
    # Memory integrity (HVCI) + VBS
    $hv = Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name 'Enabled'
    $running = $null
    try { $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -EA Stop; $running = (@($dg.SecurityServicesRunning) -contains 2) } catch {}
    $hvTxt = if ($running) { 'ON (running)' } elseif ($hv.Exists -and [int]$hv.Value -eq 1) { 'set ON (not running yet - restart?)' } else { 'OFF' }
    Write-WHDLog ("Memory integrity    : {0}   (Windows Security > Device security > Core isolation)" -f $hvTxt) $(if ($running) {'OK'} else {'WARN'})
    # LSA protection
    $ppl = Get-WHDRegValueState -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'RunAsPPL'
    $pplTxt = if ($ppl.Exists -and [int]$ppl.Value -in @(1,2)) { "ON (RunAsPPL=$($ppl.Value))" } else { 'OFF / not configured' }
    Write-WHDLog ("LSA protection      : {0}   (Core isolation > Local Security Authority protection)" -f $pplTxt) $(if ($ppl.Exists -and [int]$ppl.Value -in @(1,2)) {'OK'} else {'WARN'})
    # Secure Boot
    try { $sb = Confirm-SecureBootUEFI -EA Stop; Write-WHDLog ("Secure Boot         : {0}" -f $(if ($sb) {'ON'} else {'OFF'})) $(if ($sb) {'OK'} else {'WARN'}) }
    catch { Write-WHDLog 'Secure Boot         : not supported / legacy BIOS' 'WARN' }
    # UAC
    $u = Get-WHDUacState
    Write-WHDLog ("UAC                 : {0}" -f $u.Level) $(if ($u.AlwaysNotify) {'OK'} else {'WARN'})
    # Password / lockout (local accounts)
    Write-WHDLog 'Password + lockout  : (local accounts; option W sets the WHD targets)' 'INFO'
    $pp = Get-WHDPasswordPolicy
    Show-WHDPasswordPolicy -Policy $pp
    if ($pp -and [int]$pp.Threshold -eq 0) { Write-WHDLog '  -> no account lockout: unlimited password guesses are allowed' 'WARN' }
    # Protocols
    foreach ($it in $script:WHDProtocols) {
        $st = Get-WHDRegOpsState -Ops @(Get-WHDProtocolOps -Key $it.Key)
        Write-WHDLog ("{0,-20}: {1}" -f ($it.Name -replace ' \(.*$', ''), $(if ($st -eq 'set') {'off (hardened)'} elseif ($st -eq 'partly') {'partly off'} else {'on (Windows default)'})) $(if ($st -eq 'set') {'OK'} else {'INFO'})
    }
    foreach ($g in $script:WHDNetServiceGroups) {
        $st = Get-WHDNetServiceState -Key $g.Key
        Write-WHDLog ("{0,-20}: {1}" -f ($g.Key), $st) $(if ($st -eq 'off' -or $st -eq 'not present') {'OK'} else {'INFO'})
    }
    Write-WHDLog '================ END REPORT ================' 'ACT'
}

# ---- terminal menu -----------------------------------------------------------
function Show-WHDSecurityMenu {
    Write-Host ''
    Write-Host '  ================= SECURITY+ =================' -ForegroundColor White
    Write-Host '   R. Security report (read-only)'
    Write-Host '  Defender' -ForegroundColor DarkGray
    $mp = $null; try { $mp = Get-MpPreference -EA Stop } catch {}
    $mt = @{ 0 = 'off'; 1 = 'BLOCK'; 2 = 'AUDIT'; 6 = 'WARN' }
    $now = { param($n) if ($mp) { $v = [int]$mp.$n; if ($mt.ContainsKey($v)) { $mt[$v] } else { "$v" } } else { '?' } }
    Write-Host ('   1. Block unwanted apps (PUA)      -> ON                     (now: {0})' -f $(if ($mp) { if ([int]$mp.PUAProtection -eq 1) { 'ON' } else { & $now 'PUAProtection' } } else { '?' }))
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
        $st = Get-WHDRegOpsState -Ops @(Get-WHDProtocolOps -Key $it.Key)
        Write-Host ('   P{0}. {1,-38} [{2}]' -f $i, $it.Name, $(if ($st -eq 'set') {'off'} elseif ($st -eq 'partly') {'partly'} else {'on'}))
    }
    Write-Host '   PA. all four'
    Write-Host '  Network services (turn off; restart after)' -ForegroundColor DarkGray
    $i = 0
    foreach ($g in $script:WHDNetServiceGroups) {
        $i++
        Write-Host ('   N{0}. {1,-52} [{2}]' -f $i, $g.Name, (Get-WHDNetServiceState -Key $g.Key))
    }
    Write-Host '   NA. all safe ones (N1-N6; N7 is never included)'
    Write-Host '  Account' -ForegroundColor DarkGray
    Write-Host ('   U. UAC -> Always notify   (now: {0})' -f (Get-WHDUacState).Level)
    Write-Host ('   W. Password + lockout rules -> 14 chars, remember 5, never expire, 3 tries / 10 min   (now: {0})' -f $(if (Test-WHDPasswordPolicySet) { 'set' } else { 'not set' }))
    Write-Host '  Update guard (alert only - checks after Windows updates)' -ForegroundColor DarkGray
    $gs = if (Get-Command Get-WHDGuardStatus -EA SilentlyContinue) { (Get-WHDGuardStatus).Text } else { '?' }
    Write-Host ('   G. Install / refresh guard   (now: {0})' -f $gs)
    Write-Host '   GR. Run the check now        GO. Open the last report        GX. Remove guard'
    Write-Host '   B. Back'
}
function Invoke-WHDSecuritySubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDSecurityMenu
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^[Rr]$'   { Show-WHDSecurityReport }
            '^1$'      { Invoke-WHDDefenderProtection -Which PUA -Mode On }
            '^2$'      { Invoke-WHDDefenderProtection -Which Network -Mode Audit }
            '^2[Bb]$'  { Invoke-WHDDefenderProtection -Which Network -Mode On }
            '^3$'      { Invoke-WHDDefenderProtection -Which Folders -Mode Audit }
            '^3[Bb]$'  { Invoke-WHDDefenderProtection -Which Folders -Mode On }
            '^4$'      { Invoke-WHDAsrGroups -Groups standard }
            '^5$'      { Invoke-WHDAsrGroups -Groups scripts }
            '^6$'      { Invoke-WHDAsrGroups -Groups office }
            '^[Ll]$'   { Get-WHDAsrState | Format-Table Group, Action, Name -AutoSize | Out-Host }
            '^[Ee]$'   { $ev = @(Get-WHDDefenderEvents); if ($ev.Count) { $ev | Format-Table Time, Type, Rule, Program, Target -AutoSize -Wrap | Out-Host } else { Write-Host '  (nothing caught in the last 7 days)' -ForegroundColor DarkGray } }
            '^[Kk]$'   { Invoke-WHDAsrPromote }
            '^[Pp][1-4]$' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[[int]$c.Substring(1) - 1] }
            '^[Pp][Aa]$'  { foreach ($it in $script:WHDProtocols) { Invoke-WHDProtocolOff -Item $it } }
            '^[Nn][1-7]$' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[[int]$c.Substring(1) - 1] }
            '^[Nn][Aa]$'  { foreach ($g in @($script:WHDNetServiceGroups | Where-Object { -not $_.NotInAll })) { Invoke-WHDNetServiceOff -Item $g } }
            '^[Uu]$'   { Set-WHDUacAlwaysNotify }
            '^[Ww]$'   { Invoke-WHDPasswordPolicy }
            '^[Gg]$'       { Install-WHDUpdateGuard }
            '^[Gg][Rr]$'   { Invoke-WHDUpdateGuard -Now | Out-Null }
            '^[Gg][Oo]$'   { $st = Get-WHDGuardState; if ($st -and $st.LastReport -and (Test-Path -LiteralPath $st.LastReport)) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $st.LastReport) } else { Write-Host '  (no guard report yet)' -ForegroundColor DarkGray } }
            '^[Gg][Xx]$'   { Uninstall-WHDUpdateGuard }
            '^[Bb]$'   { return }
            default    { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Security.ps1 loaded.' 'INFO'
