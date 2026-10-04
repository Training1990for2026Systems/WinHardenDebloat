<#
================================================================================
 WinHardenDebloat  -  modules\Updates.ps1   (v1.1: stop auto-installs)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Goal (user, 2026-09-27): a freshly re-imaged PC can go online WITHOUT Windows'
 background installers (Windows Update, Microsoft Store, Device Setup /
 drivers + manufacturer apps, app self-updaters) running. Updates come in only
 AFTER the baseline, when the owner opens the update gate.

 Parts (all user-chosen):
   1. UPDATE GATE (firewall) - closed: outbound default-deny; HTTP/HTTPS only
      for Microsoft Defender (engine, network inspection, command-line updater,
      SmartScreen) + DNS-over-HTTPS; the any-program HTTP/HTTPS allows and every
      other enabled outbound ALLOW rule (Windows' built-in app rules included)
      are switched off and remembered. Open: everything put back. Stays open
      until you close it.
   2. Windows Update policy NoAutoUpdate=1 (Microsoft documents it for Pro+;
      tried on Home - Status shows evidence whether Windows obeys it).
   3. Drivers: Device Installation Settings = No (+ manufacturer apps/icons off)
      and the "don't include drivers" policy (Pro+, tried on Home).
   4. Store: auto-update policy AutoDownload=2 (Pro+, tried on Home).
   5. App self-updaters (Edge Update + others): scan -> you confirm -> the
      scheduled tasks are disabled / services set to Disabled (journaled).
 Every registry/service/task change is journaled (Undo center, Verify, guard).
================================================================================
#>

$script:WHDFwGroupGate   = 'WinHardenDebloat-UpdateGate'
$script:WHDGateStateName = 'update-gate.json'

# ---- gate state (project folder, per PC) -------------------------------------
function _WHDGateStateFile {
    $d = Join-Path $script:WHDRoot 'restore\update-guard'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Join-Path $d $script:WHDGateStateName
}
function Get-WHDGateState {
    $f = _WHDGateStateFile
    $s = $null
    if (Test-Path -LiteralPath $f) { try { $s = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    if ($s -and "$($s.MachineId)" -and "$($s.MachineId)" -ne (Get-WHDMachineId)) { $s = $null }   # another PC's file
    $out = @(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) -join ','
    # Closed = the gate recorded "closed" on THIS PC and outbound is still Block.
    # (Rule states are not used: rebuilding the allow-list briefly re-creates the
    # HTTPS rule, and it must still see the gate as closed to switch it off again.)
    $closed = [bool]($s -and $s.Closed) -and ($out -notmatch 'Allow|NotConfigured')
    [pscustomobject]@{
        Closed   = $closed
        Outbound = $out
        Since    = $(if ($s) { "$($s.Changed)" } else { '' })
        Disabled = $(if ($s -and $s.DisabledRules) { @($s.DisabledRules) } else { @() })
        PrevOutbound = $(if ($s) { "$($s.PrevOutbound)" } else { 'Allow' })
        Text     = $(if ($closed) { 'CLOSED' + $(if ($s) { " since $($s.Changed)" } else { '' }) } else { 'OPEN' + $(if ($s -and $s.Changed) { " since $($s.Changed)" } else { '' }) })
    }
}
function Test-WHDGateClosed { (Get-WHDGateState).Closed }
function _WHDSaveGateState {
    param([bool]$Closed, [string[]]$DisabledRules, [string]$PrevOutbound)
    $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Closed = $Closed
                     Changed = (Get-Date).ToString('yyyy-MM-dd HH:mm'); PrevOutbound = $PrevOutbound; DisabledRules = @($DisabledRules) }
    ([pscustomobject]$o | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (_WHDGateStateFile) -Encoding UTF8
}

# Defender's current platform folder (changes when Defender updates itself).
function Get-WHDDefenderPlatformDir {
    try {
        $p = "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name InstallLocation -EA Stop).InstallLocation)"
        if ($p -and (Test-Path -LiteralPath (Join-Path $p 'MsMpEng.exe'))) { return $p.TrimEnd('\') }
    } catch {}
    $base = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    $d = @(Get-ChildItem -LiteralPath $base -Directory -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    if ($d.Count) { return $d[0].FullName }
    return $null
}
# The only HTTP/HTTPS traffic allowed while the gate is closed.
function Get-WHDGateAllowSpecs {
    $plat = Get-WHDDefenderPlatformDir
    $specs = @(
        @{ n='WHD-Gate-Defender';      d='WHD Gate: Microsoft Defender engine (WinDefend)';          svc='WinDefend' }
        @{ n='WHD-Gate-DefenderNis';   d='WHD Gate: Defender network inspection (WdNisSvc)';         svc='WdNisSvc' }
        @{ n='WHD-Gate-MpCmdRun';      d='WHD Gate: Defender updater (MpCmdRun, Program Files)';      prog=(Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe') }
        @{ n='WHD-Gate-SmartScreen';   d='WHD Gate: SmartScreen';                                     prog=(Join-Path $env:SystemRoot 'System32\smartscreen.exe') }
        @{ n='WHD-Gate-DoH';           d='WHD Gate: DNS over HTTPS (Dnscache) to the pinned resolver'; svc='Dnscache'; raddr=$script:WHDDnsServers; ports=@('443') }
    )
    if ($plat) {
        $specs += @{ n='WHD-Gate-MsMpEng';    d='WHD Gate: Defender engine (platform folder)';  prog=(Join-Path $plat 'MsMpEng.exe') }
        $specs += @{ n='WHD-Gate-MpCmdRunP';  d='WHD Gate: Defender updater (platform folder)'; prog=(Join-Path $plat 'MpCmdRun.exe') }
    }
    $specs
}

# ---- 1. the gate ---------------------------------------------------------------
function Close-WHDUpdateGate {
    Write-WHDLog 'UPDATE GATE: CLOSE' 'ACT'
    Write-WHDRisk 'hard' 'Outbound becomes default-deny. Only Microsoft Defender (engine, network inspection, updater, SmartScreen) and DNS-over-HTTPS may use HTTP/HTTPS. Windows Update, Microsoft Store, driver/manufacturer-app downloads, app updaters, browsers (Edge too) and the Claude desktop app are OFFLINE until you open the gate. DNS, DHCP and time (NTP) keep working. Every outbound allow rule the gate switches off is remembered and switched back on when you open it.'
    if (-not (Confirm-WHDProceed 'close the update gate (outbound default-deny, Defender + DoH only)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    # essentials first: DNS / DHCP / NTP allow-list (also holds the any-program HTTP/HTTPS rules we switch off)
    if (-not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue).Count) { Invoke-WHDFirewallAllowList }
    # Defender + DoH allows (rebuilt each close so a Defender platform update is picked up)
    Remove-WHDFwGroup -Group $script:WHDFwGroupGate
    foreach ($g in @(Get-WHDGateAllowSpecs)) {
        $p = @{ Name=$g.n; DisplayName=$g.d; Group=$script:WHDFwGroupGate; Direction='Outbound'; Action='Allow'
                Enabled='True'; Profile='Any'; Protocol='TCP'; RemotePort=$(if ($g.ports) { $g.ports } else { @('443','80') }) }
        if ($g.svc)   { $p['Service'] = $g.svc }
        if ($g.prog)  { if (-not (Test-Path -LiteralPath $g.prog)) { Write-WHDLog ("  skipped (not on this PC): {0}" -f $g.prog) 'INFO'; continue }; $p['Program'] = $g.prog }
        if ($g.raddr) { $p['RemoteAddress'] = $g.raddr }
        New-WHDFwRule $p
    }
    # everything else that could let traffic out: enabled outbound ALLOW rules outside our essentials/gate groups
    $keepGroups = @($script:WHDFwGroupAllow, $script:WHDFwGroupGate, $script:WHDFwGroupIPv6, $script:WHDFwGroupBlock)
    $toOff = @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -EA SilentlyContinue |
               Where-Object { $keepGroups -notcontains "$($_.Group)" } | ForEach-Object { "$($_.Name)" })
    $anyWeb = @('WHD-Allow-HTTPS','WHD-Allow-HTTP') | Where-Object { @(Get-NetFirewallRule -Name $_ -EA SilentlyContinue | Where-Object { "$($_.Enabled)" -eq 'True' }).Count }
    $prevOut = (@(Get-WHDFwProfiles | ForEach-Object { "$($_.DefaultOutboundAction)" }) | Select-Object -First 1)
    if (-not $prevOut -or $prevOut -eq 'NotConfigured') { $prevOut = 'Allow' }
    $old = Get-WHDGateState
    $remember = @(@($old.Disabled) + $toOff + @($anyWeb) | Where-Object { $_ } | Select-Object -Unique)
    Write-WHDLog ("  switching off {0} other outbound allow rule(s) + {1} any-program web rule(s)" -f $toOff.Count, @($anyWeb).Count) 'INFO'
    $gOff = @($toOff) + @($anyWeb)
    Invoke-WHDChange -Description ("gate: disable {0} outbound allow rule(s), outbound default-deny on all profiles" -f $gOff.Count) -Force -Action {
        Backup-WHDFirewallOnce
        foreach ($rn in $gOff) { Set-NetFirewallRule -Name $rn -Enabled False -EA SilentlyContinue }
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -EA Stop
    } | Out-Null
    if ($script:WHDExecute) {
        Remove-WHDRollbackTask
        _WHDSaveGateState -Closed $true -DisabledRules $remember -PrevOutbound $(if ($old.Closed) { $old.PrevOutbound } else { $prevOut })
        Write-WHDLog 'Update gate CLOSED. Open it (Updates menu O) when you want updates.' 'OK'
    }
}
function Open-WHDUpdateGate {
    Write-WHDLog 'UPDATE GATE: OPEN' 'ACT'
    $st = Get-WHDGateState
    Write-WHDRisk 'caution' ("Puts back the {0} outbound allow rule(s) the gate switched off and outbound '{1}' (as before the gate closed). Windows Update, Store, drivers and app updaters can then download - the Windows Update / driver / Store policies still apply. Stays open until you close it." -f @($st.Disabled).Count, $st.PrevOutbound)
    if (-not (Confirm-WHDProceed 'open the update gate')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $gOn = @($st.Disabled); $gOut = if ($st.PrevOutbound) { $st.PrevOutbound } else { 'Allow' }
    Invoke-WHDChange -Description ("gate: re-enable {0} rule(s), outbound {1}" -f $gOn.Count, $gOut) -Force -Action {
        foreach ($rn in $gOn) { Set-NetFirewallRule -Name $rn -Enabled True -EA SilentlyContinue }
        Set-NetFirewallProfile -All -DefaultOutboundAction $gOut -Confirm:$false -EA Stop
    } | Out-Null
    if ($script:WHDExecute) {
        _WHDSaveGateState -Closed $false -DisabledRules @() -PrevOutbound $gOut
        Write-WHDLog 'Update gate OPEN. Close it again (Updates menu C) when updates are done.' 'OK'
    }
}

# ---- 2-4. policies (journaled registry, auto undo + Verify) --------------------
$script:WHDUpdatePolicies = @(
    [ordered]@{ Key='wu'; Name='Windows Update: no automatic updates (NoAutoUpdate)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N='NoAutoUpdate'; V=1; T='DWord' })
        Note='Group Policy "Configure Automatic Updates" = Disabled. Microsoft documents Windows Update policies for Pro/Enterprise/Education; on Home it is TRIED - Status shows whether updates still install while it is set. Updates remain available in Settings > Windows Update (you choose).' }
    [ordered]@{ Key='drivers'; Name='Drivers: Device Installation Settings = No (+ manufacturer apps/icons off)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; N='SearchOrderConfig'; V=0; T='DWord' }
              @{ P='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata'; N='PreventDeviceMetadataFromNetwork'; V=1; T='DWord' }
              @{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N='PreventDeviceMetadataFromNetwork'; V=1; T='DWord' })
        Note='The Control Panel "Device installation settings" = No: Windows does not fetch drivers or manufacturer companion apps (Intel/Elevoc-type) when hardware appears. A feature update can reset SearchOrderConfig - Verify / the update guard will flag it.' }
    [ordered]@{ Key='driverpolicy'; Name='Drivers: "Do not include drivers with Windows Updates" policy'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N='ExcludeWUDriversInQualityUpdate'; V=1; T='DWord' })
        Note='Microsoft documents it for Pro/Enterprise/Education and it is reported not to work on Home - set as a second lock; harmless if ignored.' }
    [ordered]@{ Key='store'; Name='Microsoft Store: automatic app updates off (AutoDownload=2)'
        Ops=@(@{ P='HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N='AutoDownload'; V=2; T='DWord' })
        Note='Group Policy "Turn off Automatic Download and Install of updates". Documented for Pro+; on Home it is TRIED (the consumer Store otherwise only pauses 1-5 weeks). The update gate is the reliable block.' }
)
function Invoke-WHDUpdatePolicy {
    param([Parameter(Mandatory)]$Item)
    Write-WHDLog ("UPDATES: {0}" -f $Item.Name) 'ACT'
    Write-WHDRisk 'reversible' $Item.Note
    if ((Get-WHDRegOpsState -Ops $Item.Ops) -eq 'set') { Write-WHDLog 'Already set - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed ("set: {0}" -f $Item.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in $Item.Ops) { Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T }
}

# ---- 5. app self-updaters ------------------------------------------------------
# Non-Windows scheduled tasks and services whose name says update / updater /
# maintenance (Edge Update, OneDrive, Google, Zoom, Adobe, Mozilla ...).
# A disabled task whose instance is still running reports State=Running, so read Settings.Enabled.
function Test-WHDTaskEnabled {
    param($Task)
    try { if ($null -ne $Task.Settings -and $null -ne $Task.Settings.Enabled) { return [bool]$Task.Settings.Enabled } } catch { }
    return ("$($Task.State)" -ne 'Disabled')
}
function Get-WHDTaskStateText {
    param($Task)
    if (Test-WHDTaskEnabled -Task $Task) { return "$($Task.State)" }
    if ("$($Task.State)" -eq 'Running') { return 'Disabled, last run still finishing' }
    return 'Disabled'
}
function Find-WHDAppUpdaters {
    $rx = 'update|updater|maintenance'
    $out = New-Object System.Collections.Generic.List[object]
    # WHD's own tasks (\WinHardenDebloat\) are never offered.
    foreach ($t in @(Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' -and $_.TaskPath -notlike '\WinHardenDebloat\*' -and ("$($_.TaskName)" -match $rx) })) {
        $isEdge = "$($t.TaskName)" -like 'MicrosoftEdgeUpdate*'
        $tState = Get-WHDTaskStateText -Task $t
        $out.Add([pscustomobject]@{ Kind='task'; Id=("{0}{1}" -f $t.TaskPath, $t.TaskName); TaskPath="$($t.TaskPath)"; TaskName="$($t.TaskName)"; Service=''
            Name="$($t.TaskName)"; State=$tState; Edge=$isEdge; Label=("[task]    {0}{1}   ({2})" -f $t.TaskPath, $t.TaskName, $tState) })
    }
    foreach ($s in @(Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object {
            ("$($_.Name) $($_.DisplayName)" -match $rx) -and "$($_.PathName)" -notmatch '(?i)\\Windows\\(System32|SysWOW64|servicing)\\' })) {
        $isEdge = "$($s.Name)" -like 'edgeupdate*'
        $out.Add([pscustomobject]@{ Kind='service'; Id=$s.Name; TaskPath=''; TaskName=''; Service="$($s.Name)"
            Name="$($s.DisplayName)"; State=("{0}/{1}" -f $s.State, $s.StartMode); Edge=$isEdge; Label=("[service] {0} ({1})   {2}/{3}" -f $s.DisplayName, $s.Name, $s.State, $s.StartMode) })
    }
    @($out.ToArray() | Sort-Object @{ e = { -not $_.Edge } }, Label)
}
function Disable-WHDAppUpdater {
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'task') {
        $t = @(Get-ScheduledTask -TaskPath $Item.TaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $Item.TaskName })[0]
        if (-not $t) { Write-WHDLog ("task not found: {0}" -f $Item.Id) 'WARN'; return }
        if (-not (Test-WHDTaskEnabled -Task $t)) { Write-WHDLog ("already disabled: {0}" -f $Item.Id) 'OK'; return }
        $upPath = $Item.TaskPath; $upName = $Item.TaskName
        $jr = @{ Kind = 'task'; TaskPath = $upPath; TaskName = $upName; OldEnabled = $true; NewEnabled = $false }
        Invoke-WHDChange -Description ("stop + disable scheduled task {0}{1}" -f $upPath, $upName) -Force -Journal $jr -Action {
            Stop-ScheduledTask -TaskPath $upPath -TaskName $upName -EA SilentlyContinue
            Disable-ScheduledTask -TaskPath $upPath -TaskName $upName -EA Stop | Out-Null
        } | Out-Null
    } else {
        $svc = Get-Service -Name $Item.Service -EA SilentlyContinue
        if (-not $svc) { Write-WHDLog ("service not found: {0}" -f $Item.Service) 'WARN'; return }
        if ("$($svc.StartType)" -eq 'Disabled') { Write-WHDLog ("already disabled: {0}" -f $Item.Service) 'OK'; return }
        $upSvc = $Item.Service
        $jr = @{ Kind = 'service'; Service = $upSvc; OldStartType = "$($svc.StartType)"; NewStartType = 'Disabled' }
        Invoke-WHDChange -Description ("service {0}: stop + start type {1} -> Disabled" -f $upSvc, $svc.StartType) -Force -Journal $jr -Action {
            Stop-Service -Name $upSvc -Force -EA SilentlyContinue
            Set-Service -Name $upSvc -StartupType Disabled -EA Stop
        } | Out-Null
    }
}
function Invoke-WHDAppUpdatersOff {
    param([object[]]$Items, [switch]$EdgeOnly)
    $list = if ($Items) { @($Items) } else { @(Find-WHDAppUpdaters) }
    if ($EdgeOnly) { $list = @($list | Where-Object { $_.Edge }) }
    Write-WHDLog ("APP UPDATERS OFF: {0} item(s)" -f $list.Count) 'ACT'
    if (-not $list.Count) { Write-WHDLog 'Nothing found.' 'INFO'; return }
    foreach ($i in $list) { Write-WHDLog ("  {0}" -f $i.Label) 'INFO' }
    Write-WHDRisk 'caution' 'These programs stop updating themselves (Edge: no automatic security fixes). Update them by hand, or undo in the Undo center. Journaled.'
    if (-not (Confirm-WHDProceed ("turn off {0} app updater(s)" -f $list.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($i in $list) { Disable-WHDAppUpdater -Item $i }
}

# ---- status ---------------------------------------------------------------------
function Show-WHDUpdatesStatus {
    Write-WHDLog '================ UPDATES STATUS (read-only) ================' 'ACT'
    $g = Get-WHDGateState
    Write-WHDLog ("Update gate          : {0}   (outbound: {1})" -f $g.Text, $g.Outbound) $(if ($g.Closed) { 'OK' } else { 'WARN' })
    if ($g.Closed) {
        $plat = Get-WHDDefenderPlatformDir
        $rule = @(Get-NetFirewallRule -Name 'WHD-Gate-MsMpEng' -EA SilentlyContinue)
        if ($plat -and $rule.Count) {
            $pf = "$(@($rule[0] | Get-NetFirewallApplicationFilter -EA SilentlyContinue)[0].Program)"
            if ($pf -and $pf -ne (Join-Path $plat 'MsMpEng.exe')) { Write-WHDLog '  Defender updated its platform since the gate closed - close the gate again (C) to refresh its allow rules.' 'WARN' }
        }
    }
    foreach ($it in $script:WHDUpdatePolicies) {
        $s = Get-WHDRegOpsState -Ops $it.Ops
        Write-WHDLog ("{0,-20}: {1}" -f ($it.Key), $(if ($s -eq 'set') { 'set' } elseif ($s -eq 'partly') { 'partly set' } else { 'not set' })) $(if ($s -eq 'set') { 'OK' } else { 'INFO' })
    }
    # Evidence: what Windows Update installed recently (System log, WindowsUpdateClient event 19)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 15 -EA SilentlyContinue)
    Write-WHDLog ("Windows Update installs (14 days): {0}" -f $ev.Count) 'INFO'
    foreach ($e in $ev | Select-Object -First 8) {
        $t = (("$($e.Message)" -split "`r?`n")[0]) -replace '^Installation Successful: Windows successfully installed the following update: ', ''
        Write-WHDLog ("  {0:yyyy-MM-dd HH:mm}  {1}" -f $e.TimeCreated, $t) 'INFO'
    }
    $up = @(Find-WHDAppUpdaters)
    Write-WHDLog ("App updaters found   : {0}  ({1} still active)" -f $up.Count, @($up | Where-Object { $_.State -notmatch 'Disabled' }).Count) 'INFO'
    foreach ($u in $up) { Write-WHDLog ("  {0}" -f $u.Label) $(if ($u.State -match 'Disabled') { 'OK' } else { 'INFO' }) }
    Write-WHDLog '================ END ================' 'ACT'
}
# Defender definitions through the closed gate (direct from Microsoft Malware Protection Center).
function Invoke-WHDDefenderUpdateTest {
    Write-WHDLog 'DEFENDER: update definitions now (source MMPC - works while the gate is closed)' 'ACT'
    try { $before = (Get-MpComputerStatus -EA Stop).AntivirusSignatureVersion } catch { $before = '?' }
    if (-not $script:WHDExecute) { Write-WHDLog ("would: Update-MpSignature -UpdateSource MMPC   (definitions now {0})" -f $before) 'DRY'; return }
    try {
        Update-MpSignature -UpdateSource MMPC -EA Stop
        $s = Get-MpComputerStatus -EA Stop
        Write-WHDLog ("Definitions {0} -> {1}  (age {2} day(s))" -f $before, $s.AntivirusSignatureVersion, $s.AntivirusSignatureAge) 'OK'
    } catch { Write-WHDLog ("Defender update failed: {0}" -f $_.Exception.Message) 'ERR' }
}

# ---- menu ------------------------------------------------------------------------
function Show-WHDUpdatesMenu {
    Write-Host ''
    Write-Host '  ================= UPDATES (stop auto-installs) =================' -ForegroundColor White
    Write-Host ('   Gate now: {0}' -f (Get-WHDGateState).Text)
    Write-Host '   C. CLOSE update gate   (only Defender + DNS-over-HTTPS may use the web)'
    Write-Host '   O. OPEN update gate    (let updates in; stays open until you close it)'
    $i = 0
    foreach ($it in $script:WHDUpdatePolicies) {
        $i++
        $st = Get-WHDRegOpsState -Ops $it.Ops
        Write-Host ('   {0}. {1,-74} [{2}]' -f $i, $it.Name, $(if ($st -eq 'set') { 'set' } elseif ($st -eq 'partly') { 'partly' } else { 'not set' }))
    }
    Write-Host '   A. All four policies above'
    Write-Host '   E. Edge Update off (tasks + services)'
    Write-Host '   F. Find other app updaters -> choose which to turn off'
    Write-Host '   D. Defender definitions: update now (works with the gate closed)'
    Write-Host '   S. Status (gate, policies, recent Windows Update installs, updaters)'
    Write-Host '   B. Back'
}
function Invoke-WHDUpdatesSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDUpdatesMenu
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^[Cc]$'    { Close-WHDUpdateGate }
            '^[Oo]$'    { Open-WHDUpdateGate }
            '^[1-4]$'   { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[[int]$c - 1] }
            '^[Aa]$'    { foreach ($it in $script:WHDUpdatePolicies) { Invoke-WHDUpdatePolicy -Item $it } }
            '^[Ee]$'    { Invoke-WHDAppUpdatersOff -EdgeOnly }
            '^[Ff]$'    {
                $all = @(Find-WHDAppUpdaters | Where-Object { $_.State -notmatch 'Disabled' })
                if (-not $all.Count) { Write-Host '  (no active app updaters found)' -ForegroundColor DarkGray; continue }
                $n = 0; foreach ($u in $all) { $n++; Write-Host ('  {0,3}. {1}' -f $n, $u.Label) }
                $pick = (Read-Host '  Numbers to turn off (e.g. 1,3,4), A = all, Enter = none').Trim()
                if (-not $pick) { continue }
                $sel = if ($pick -match '^[Aa]$') { $all } else { @($pick -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { $all[[int]$_ - 1] } | Where-Object { $_ }) }
                if ($sel.Count) { Invoke-WHDAppUpdatersOff -Items $sel }
            }
            '^[Dd]$'    { Invoke-WHDDefenderUpdateTest }
            '^[Ss]$'    { Show-WHDUpdatesStatus }
            '^[Bb]$'    { return }
            default     { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Updates.ps1 loaded.' 'INFO'
