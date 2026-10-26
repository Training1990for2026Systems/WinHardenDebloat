#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Updates.ps1   (stop automatic installs)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6. Goal: a PC
 can go online WITHOUT Windows' background installers (Windows Update, Store,
 drivers + manufacturer apps, app self-updaters); updates come in only when the
 owner opens the update gate.
   1. UPDATE GATE (firewall), three positions:
      CLOSED   - outbound default-deny; HTTP/HTTPS only for Microsoft Defender
                 (engine, network inspection, updater, core service, SmartScreen)
                 and DNS-over-HTTPS; every other enabled outbound ALLOW rule (the
                 any-program web rules, Windows' app rules, your program allows)
                 is switched off and remembered.
      PROGRAMS - like CLOSED, but the programs you allowed (Firewall menu V,
                 group WinHardenDebloatNext-AppAllow) stay on.
      OPEN     - everything put back; stays open until you change it.
   2-4. Policies: Windows Update NoAutoUpdate, drivers (Device Installation
      Settings = No + driver policy), Store AutoDownload=2. Documented for Pro+;
      on Home they are TRIED - status shows whether Windows obeys them.
   5. App self-updaters (Edge Update + others): scan -> you choose -> tasks
      disabled / services Disabled.
 Takes over from WHD Next 2.0 (D4): group WinHardenDebloatNext-UpdateGate, rule
 names WHDN-Gate-*, state file restore\update-guard\update-gate.json (per PC).
 Every change goes through the engine (registry / service / task changes are
 recorded for the Undo center and Verify). Menu keys: X / S / B as everywhere
 (D25); status = ST (D29). The update guard comes in build step 7.
================================================================================
#>

$script:WHDFwGroupGate = 'WinHardenDebloatNext-UpdateGate'

# ---- gate state (per PC) ---------------------------------------------------------
function Get-WHDGateStateFile {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Join-Path (Join-Path $script:WHDState.DataRoot 'restore') 'update-guard') 'update-gate.json'
}

function Get-WHDGateState {
    # Closed = the gate recorded "closed" on THIS PC and outbound is still Block (rule states are not used:
    # rebuilding the allow-list briefly re-creates the HTTPS rule, and it must still see the gate as closed).
    [CmdletBinding()]
    param()
    $f = Get-WHDGateStateFile
    $gs = $null
    if (Test-Path -LiteralPath $f) { try { $gs = Get-Content -LiteralPath $f -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { $gs = $null } }
    if ($gs -and [string]$gs['MachineId'] -and ([string]$gs['MachineId']).ToLowerInvariant() -ne (Get-WHDMachineId)) { $gs = $null }   # another PC's file
    $out = @(Get-WHDFwProfile | ForEach-Object { [string]$_.DefaultOutboundAction }) -join ','
    $closed = [bool]($gs -and $gs['Closed']) -and ($out -notmatch 'Allow|NotConfigured') -and $out
    $mode = 'open'
    if ($closed) { $mode = if ([string]$gs['Mode'] -eq 'programs') { 'programs' } else { 'closed' } }
    $since = if ($gs -and $gs['Changed']) { [string]$gs['Changed'] } else { '' }
    [pscustomobject]@{
        Closed = [bool]$closed; Mode = $mode; Outbound = $out; Since = $since
        Disabled = $(if ($gs -and $gs['DisabledRules']) { @($gs['DisabledRules']) } else { @() })
        PrevOutbound = $(if ($gs -and [string]$gs['PrevOutbound']) { [string]$gs['PrevOutbound'] } else { 'Allow' })
        Text = ($mode.ToUpperInvariant() + $(if ($since) { ' since ' + $since } else { '' }))
    }
}

function Test-WHDGateClosed {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [bool](Get-WHDGateState).Closed
}

function Save-WHDGateState {
    [CmdletBinding(SupportsShouldProcess)]
    param([bool]$Closed, [string[]]$DisabledRules, [string]$PrevOutbound, [string]$Mode, [string]$Changed)
    if (-not $Mode) { $Mode = if ($Closed) { 'closed' } else { 'open' } }
    if (-not $Changed) { $Changed = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    $f = Get-WHDGateStateFile
    if (-not $PSCmdlet.ShouldProcess($f, 'save update gate state')) { return }
    $d = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
    [ordered]@{ MachineId = (Get-WHDMachineId); Computer = [Environment]::MachineName; Closed = $Closed; Mode = $Mode
        Changed = $Changed; PrevOutbound = $PrevOutbound; DisabledRules = @($DisabledRules) } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $f -Encoding utf8
}

function Add-WHDGateRemembered {
    # Rule names the gate switches back on when it opens (a program allow made while the gate is closed).
    [CmdletBinding()]
    param([string[]]$Names)
    $st = Get-WHDGateState
    if (-not $st.Closed) { return }
    Save-WHDGateState -Closed $true -Mode $st.Mode -DisabledRules @(@($st.Disabled) + @($Names) | Where-Object { $_ } | Select-Object -Unique) -PrevOutbound $st.PrevOutbound -Changed $st.Since
}

function Get-WHDDefenderPlatformDir {
    # Defender's current platform folder (changes when Defender updates itself).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $p = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name InstallLocation -ErrorAction Stop).InstallLocation
        if ($p -and (Test-Path -LiteralPath (Join-Path $p 'MsMpEng.exe'))) { return $p.TrimEnd('\') }
    } catch { Write-Verbose 'Defender InstallLocation not readable' }
    if (-not $env:ProgramData) { return $null }
    $d = @(Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
    if ($d.Count) { return $d[0].FullName }
    return $null
}

function Get-WHDGateAllowSpec {
    # The only HTTP/HTTPS traffic allowed while the gate is closed (pure, given the platform folder).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Platform, [string]$ProgramFiles = $env:ProgramFiles, [string]$SystemRoot = $env:SystemRoot)
    $specs = [System.Collections.Generic.List[hashtable]]::new()
    $specs.Add(@{ Name = 'WHDN-Gate-Defender'; DisplayName = 'WHD Next Gate: Microsoft Defender engine (WinDefend)'; Service = 'WinDefend' })
    $specs.Add(@{ Name = 'WHDN-Gate-DefenderNis'; DisplayName = 'WHD Next Gate: Defender network inspection (WdNisSvc)'; Service = 'WdNisSvc' })
    $specs.Add(@{ Name = 'WHDN-Gate-MpCmdRun'; DisplayName = 'WHD Next Gate: Defender updater (MpCmdRun, Program Files)'; Program = ('{0}\Windows Defender\MpCmdRun.exe' -f $ProgramFiles) })
    $specs.Add(@{ Name = 'WHDN-Gate-SmartScreen'; DisplayName = 'WHD Next Gate: SmartScreen'; Program = ('{0}\System32\smartscreen.exe' -f $SystemRoot) })
    $specs.Add(@{ Name = 'WHDN-Gate-DoH'; DisplayName = 'WHD Next Gate: DNS over HTTPS (Dnscache) to the pinned resolver'; Service = 'Dnscache'; RemoteAddress = $script:WHDDnsServers; RemotePort = @('443') })
    if ($Platform) {
        $specs.Add(@{ Name = 'WHDN-Gate-MsMpEng'; DisplayName = 'WHD Next Gate: Defender engine (platform folder)'; Program = ('{0}\MsMpEng.exe' -f $Platform) })
        $specs.Add(@{ Name = 'WHDN-Gate-MpCmdRunP'; DisplayName = 'WHD Next Gate: Defender updater (platform folder)'; Program = ('{0}\MpCmdRun.exe' -f $Platform) })
        $specs.Add(@{ Name = 'WHDN-Gate-NisSrv'; DisplayName = 'WHD Next Gate: Defender network inspection (platform folder)'; Program = ('{0}\NisSrv.exe' -f $Platform) })
        $specs.Add(@{ Name = 'WHDN-Gate-MpCore'; DisplayName = 'WHD Next Gate: Defender core service (platform folder)'; Program = ('{0}\MpDefenderCoreService.exe' -f $Platform) })
    }
    foreach ($s in $specs) {
        $s['Group'] = $script:WHDFwGroupGate; $s['Direction'] = 'Outbound'; $s['Action'] = 'Allow'; $s['Enabled'] = 'True'; $s['Profile'] = 'Any'; $s['Protocol'] = 'TCP'
        if (-not $s.ContainsKey('RemotePort')) { $s['RemotePort'] = @('443', '80') }
    }
    return $specs.ToArray()
}

# ---- 1. the gate -------------------------------------------------------------------
function Close-WHDUpdateGate {
    # -Mode closed: Defender + DNS-over-HTTPS only.  -Mode programs: the same + the programs you allowed.
    [CmdletBinding()]
    param([ValidateSet('closed', 'programs')][string]$Mode = 'closed')
    $prog = ($Mode -eq 'programs')
    $old = Get-WHDGateState
    $apps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -ErrorAction SilentlyContinue)
    if ($prog) {
        Write-WHDLog -Message 'UPDATE GATE: PROGRAMS' -Level 'ACT'
        Write-WHDRisk -Tier 'hard' -Text ('Outbound becomes default-deny. Only Microsoft Defender, DNS-over-HTTPS and the programs YOU allowed ({0} rule(s) now) may go out. Windows Update, Store, driver / manufacturer-app downloads, app updaters and every program not on your list are OFFLINE until you open the gate. DNS, DHCP and time keep working. Allow a program: Firewall menu V. Every allow rule the gate switches off is remembered and switched back on when you open it.' -f $apps.Count)
        foreach ($a in $apps) { Write-WHDLog -Message ('  on your list: {0}' -f $a.DisplayName) }
        if (-not $apps.Count) { Write-WHDLog -Message '  Your program list is EMPTY - until you allow a program this works the same as CLOSED.' -Level 'WARN' }
        if (-not (Confirm-WHDProceed -What 'set the update gate to PROGRAMS (outbound default-deny; Defender + DoH + your allowed programs)')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    } else {
        Write-WHDLog -Message 'UPDATE GATE: CLOSE' -Level 'ACT'
        Write-WHDRisk -Tier 'hard' -Text 'Outbound becomes default-deny. Only Microsoft Defender and DNS-over-HTTPS may use HTTP / HTTPS. Windows Update, Store, drivers, app updaters, browsers, the programs you allowed and every other app are OFFLINE until you open the gate (or set it to PROGRAMS). DNS, DHCP and time keep working. Every allow rule the gate switches off is remembered and switched back on when you open it.'
        if (-not (Confirm-WHDProceed -What 'close the update gate (outbound default-deny, Defender + DoH only)')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    }
    Invoke-WHDBlocklistHold -Do {
        if (-not @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -ErrorAction SilentlyContinue).Count) { Invoke-WHDFirewallAllowList }
        # Defender + DoH allows, rebuilt each time so a Defender platform update is picked up
        Remove-WHDFwGroup -Group $script:WHDFwGroupGate
        foreach ($g in Get-WHDGateAllowSpec -Platform (Get-WHDDefenderPlatformDir)) {
            if ($g.ContainsKey('Program') -and -not (Test-Path -LiteralPath $g['Program'])) { Write-WHDLog -Message ('  skipped (not on this PC): {0}' -f $g['Program']); continue }
            New-WHDFwRule -Params $g
        }
    }
    $keep = @($script:WHDFwGroupAllow, $script:WHDFwGroupGate, $script:WHDFwGroupIPv6, $script:WHDFwGroupBlock)
    if ($prog) { $keep += $script:WHDFwGroupApp }
    $toOff = @(Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True -ErrorAction SilentlyContinue | Where-Object { $keep -notcontains [string]$_.Group } | ForEach-Object { [string]$_.Name })
    $anyWeb = @('WHDN-Allow-HTTPS', 'WHDN-Allow-HTTP' | Where-Object { @(Get-NetFirewallRule -Name $_ -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' }).Count })
    $prevOut = @(Get-WHDFwProfile | ForEach-Object { [string]$_.DefaultOutboundAction }) | Select-Object -First 1
    if (-not $prevOut -or $prevOut -eq 'NotConfigured') { $prevOut = 'Allow' }
    $remember = @(@($old.Disabled) + $toOff + $anyWeb | Where-Object { $_ } | Select-Object -Unique)
    $gOn = @()
    if ($prog) {
        $appNames = @($apps | ForEach-Object { [string]$_.Name })
        $gOn = @($appNames | Where-Object { @($old.Disabled) -contains $_ })
        $remember = @($remember | Where-Object { $appNames -notcontains $_ })
    }
    $gOff = @($toOff) + @($anyWeb)
    Write-WHDLog -Message ('  switching off {0} other outbound allow rule(s) + {1} any-program web rule(s){2}' -f $toOff.Count, $anyWeb.Count, $(if ($gOn.Count) { '; {0} of your program allow(s) back on' -f $gOn.Count } else { '' }))
    $desc = if ($prog) { 'gate PROGRAMS: disable {0} outbound allow rule(s), {1} program allow(s) back on, outbound default-deny on all profiles' -f $gOff.Count, $gOn.Count }
            else { 'gate: disable {0} outbound allow rule(s), outbound default-deny on all profiles' -f $gOff.Count }
    $res = Invoke-WHDChange -Description $desc -Action {
        Backup-WHDFirewallOnce
        foreach ($rn in $gOff) { Set-NetFirewallRule -Name $rn -Enabled False -ErrorAction SilentlyContinue }
        foreach ($rn in $gOn) { Set-NetFirewallRule -Name $rn -Enabled True -ErrorAction SilentlyContinue }
        Set-NetFirewallProfile -All -DefaultOutboundAction Block -Confirm:$false -ErrorAction Stop
    }
    if ([string]$res.Status -eq 'done') {
        if (Get-WHDRollbackTask) { Invoke-WHDChange -Description ('remove the default-deny auto-rollback task {0} (the gate keeps outbound Block)' -f $script:WHDFwRollbackTask) -Action { [void](Unregister-WHDRollbackTask) } | Out-Null }
        Save-WHDGateState -Closed $true -Mode $Mode -DisabledRules $remember -PrevOutbound $(if ($old.Closed) { $old.PrevOutbound } else { $prevOut })
        Write-WHDLog -Message $(if ($prog) { 'Update gate on PROGRAMS. Allow a program: Firewall menu V. Updates: open the gate (O).' } else { 'Update gate CLOSED. Open it (O) when you want updates.' }) -Level 'OK'
    }
    Sync-WHDBlocklist -AfterChange
}

function Open-WHDUpdateGate {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'UPDATE GATE: OPEN' -Level 'ACT'
    $st = Get-WHDGateState
    if (-not $st.Closed) { Write-WHDLog -Message ('The gate is already open (outbound: {0}) - nothing to change.' -f $st.Outbound) -Level 'OK'; return }
    Write-WHDRisk -Tier 'caution' -Text ('Puts back the {0} outbound allow rule(s) the gate switched off and outbound {1} (as before the gate closed). Any program may use the web again; Windows Update, Store, drivers and app updaters can download - the policies still apply. Stays open until you change it.' -f @($st.Disabled).Count, $st.PrevOutbound)
    if (-not (Confirm-WHDProceed -What 'open the update gate')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $gOn = @($st.Disabled); $gOut = $st.PrevOutbound
    $res = Invoke-WHDChange -Description ('gate: re-enable {0} rule(s), outbound {1}' -f $gOn.Count, $gOut) -Action {
        foreach ($rn in $gOn) { Set-NetFirewallRule -Name $rn -Enabled True -ErrorAction SilentlyContinue }
        Set-NetFirewallProfile -All -DefaultOutboundAction $gOut -Confirm:$false -ErrorAction Stop
    }
    if ([string]$res.Status -eq 'done') {
        Save-WHDGateState -Closed $false -Mode 'open' -DisabledRules @() -PrevOutbound $gOut
        Write-WHDLog -Message 'Update gate OPEN. Close it again (C, or P for PROGRAMS) when updates are done.' -Level 'OK'
    }
    Sync-WHDBlocklist -AfterChange
}

# ---- 2-4. policies (recorded registry values: automatic undo + Verify) ---------------
$script:WHDUpdatePolicies = @(
    [ordered]@{ Key = 'wu'; Name = 'Windows Update: no automatic updates (NoAutoUpdate)'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; N = 'NoAutoUpdate'; V = 1; T = 'DWord' })
        Note = 'Group Policy "Configure Automatic Updates" = Disabled. Documented for Pro / Enterprise / Education; on Home it is TRIED - status (ST) shows whether updates still install. Updates stay available in Settings > Windows Update.' }
    [ordered]@{ Key = 'drivers'; Name = 'Drivers: Device Installation Settings = No (+ manufacturer apps / icons off)'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching'; N = 'SearchOrderConfig'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata'; N = 'PreventDeviceMetadataFromNetwork'; V = 1; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata'; N = 'PreventDeviceMetadataFromNetwork'; V = 1; T = 'DWord' })
        Note = 'Control Panel "Device installation settings" = No: Windows does not fetch drivers or manufacturer companion apps when hardware appears. A feature update can reset it - Verify shows it.' }
    [ordered]@{ Key = 'driverpolicy'; Name = 'Drivers: "Do not include drivers with Windows Updates" policy'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; N = 'ExcludeWUDriversInQualityUpdate'; V = 1; T = 'DWord' })
        Note = 'Documented for Pro / Enterprise / Education and reported not to work on Home - set as a second lock; harmless if ignored.' }
    [ordered]@{ Key = 'store'; Name = 'Microsoft Store: automatic app updates off (AutoDownload=2)'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'; N = 'AutoDownload'; V = 2; T = 'DWord' })
        Note = 'Group Policy "Turn off Automatic Download and Install of updates". Documented for Pro+; on Home it is TRIED. The update gate is the reliable block.' }
)

function Invoke-WHDUpdatePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Item)
    Write-WHDLog -Message ('UPDATES: {0}' -f $Item['Name']) -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text $Item['Note']
    if ((Get-WHDRegOpsState -Ops $Item['Ops']) -eq 'set') { Write-WHDLog -Message 'Already set - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('set: {0}' -f $Item['Name']))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($op in $Item['Ops']) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
}

# ---- 5. app self-updaters ---------------------------------------------------------------
function Test-WHDTaskEnabled {
    # A disabled task whose last run is still going reports State=Running, so Settings.Enabled is read first.
    [CmdletBinding()]
    [OutputType([bool])]
    param($Task)
    try { if ($null -ne $Task.Settings -and $null -ne $Task.Settings.Enabled) { return [bool]$Task.Settings.Enabled } } catch { Write-Verbose 'task settings unreadable' }
    return ([string]$Task.State -ne 'Disabled')
}

function Get-WHDTaskStateText {
    [CmdletBinding()]
    [OutputType([string])]
    param($Task)
    if (Test-WHDTaskEnabled -Task $Task) { return [string]$Task.State }
    if ([string]$Task.State -eq 'Running') { return 'Disabled, last run still finishing' }
    return 'Disabled'
}

function Find-WHDAppUpdater {
    # Non-Windows scheduled tasks and services whose name says update / updater / maintenance.
    # WHD's own tasks (\WinHardenDebloat*\) are never offered.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $rx = 'update|updater|maintenance'
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notlike '\Microsoft\Windows\*' -and $_.TaskPath -notlike '\WinHardenDebloat*' -and ([string]$_.TaskName -match $rx) })) {
        $ts = Get-WHDTaskStateText -Task $t
        $out.Add([pscustomobject]@{ Kind = 'task'; Id = ('{0}{1}' -f $t.TaskPath, $t.TaskName); TaskPath = [string]$t.TaskPath; TaskName = [string]$t.TaskName; Service = ''
            Name = [string]$t.TaskName; State = $ts; Edge = ([string]$t.TaskName -like 'MicrosoftEdgeUpdate*'); Label = ('[task]    {0}{1}   ({2})' -f $t.TaskPath, $t.TaskName, $ts) })
    }
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object { ('{0} {1}' -f $_.Name, $_.DisplayName) -match $rx -and [string]$_.PathName -notmatch '(?i)\\Windows\\(System32|SysWOW64|servicing)\\' })) {
        $out.Add([pscustomobject]@{ Kind = 'service'; Id = [string]$s.Name; TaskPath = ''; TaskName = ''; Service = [string]$s.Name
            Name = [string]$s.DisplayName; State = ('{0}/{1}' -f $s.State, $s.StartMode); Edge = ([string]$s.Name -like 'edgeupdate*'); Label = ('[service] {0} ({1})   {2}/{3}' -f $s.DisplayName, $s.Name, $s.State, $s.StartMode) })
    }
    return @($out.ToArray() | Sort-Object @{ e = { -not $_.Edge } }, Label)
}

function Disable-WHDAppUpdater {
    # One item: task -> recorded as kind task (Undo switches it back on); service -> kind service (old start type back).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)
    if ($Item.Kind -eq 'task') {
        $t = @(Get-ScheduledTask -TaskPath $Item.TaskPath -ErrorAction SilentlyContinue | Where-Object TaskName -eq $Item.TaskName)
        if (-not $t.Count) { Write-WHDLog -Message ('task not found: {0}' -f $Item.Id) -Level 'WARN'; return }
        if (-not (Test-WHDTaskEnabled -Task $t[0])) { Write-WHDLog -Message ('already disabled: {0}' -f $Item.Id) -Level 'OK'; return }
        $upPath = $Item.TaskPath; $upName = $Item.TaskName
        Invoke-WHDChange -Description ('stop + disable scheduled task {0}{1}' -f $upPath, $upName) -Journal @{ Kind = 'task'; TaskPath = $upPath; TaskName = $upName; OldEnabled = $true; NewEnabled = $false } -Action {
            Stop-ScheduledTask -TaskPath $upPath -TaskName $upName -ErrorAction SilentlyContinue
            [void](Disable-ScheduledTask -TaskPath $upPath -TaskName $upName -ErrorAction Stop)
        } | Out-Null
        return
    }
    $svc = Get-Service -Name $Item.Service -ErrorAction SilentlyContinue
    if (-not $svc) { Write-WHDLog -Message ('service not found: {0}' -f $Item.Service) -Level 'WARN'; return }
    if ([string]$svc.StartType -eq 'Disabled') { Write-WHDLog -Message ('already disabled: {0}' -f $Item.Service) -Level 'OK'; return }
    $upSvc = $Item.Service; $upOld = [string]$svc.StartType
    Invoke-WHDChange -Description ('service {0}: stop + start type {1} -> Disabled' -f $upSvc, $upOld) -Journal @{ Kind = 'service'; Service = $upSvc; OldStartType = $upOld; NewStartType = 'Disabled' } -Action {
        Stop-Service -Name $upSvc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $upSvc -StartupType Disabled -ErrorAction Stop
    } | Out-Null
}

function Disable-WHDAppUpdaterSet {
    # Several at once (one question). -EdgeOnly = the Edge Update tasks + services.
    [CmdletBinding()]
    param([object[]]$Items, [switch]$EdgeOnly)
    $list = if ($Items) { @($Items) } else { @(Find-WHDAppUpdater) }
    if ($EdgeOnly) { $list = @($list | Where-Object Edge) }
    Write-WHDLog -Message ('APP UPDATERS OFF: {0} item(s)' -f $list.Count) -Level 'ACT'
    if (-not $list.Count) { Write-WHDLog -Message 'Nothing found.'; return }
    foreach ($i in $list) { Write-WHDLog -Message ('  {0}' -f $i.Label) }
    Write-WHDRisk -Tier 'caution' -Text 'These programs stop updating themselves (Edge: no automatic security fixes). Update them by hand, or undo in the Undo center. Recorded.'
    if (-not (Confirm-WHDProceed -What ('turn off {0} app updater(s)' -f $list.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($i in $list) { Disable-WHDAppUpdater -Item $i }
}

# ---- status + Defender definitions ---------------------------------------------------------
function Show-WHDUpdatesStatus {
    # Read-only (ST). Every line goes to the log too.
    [CmdletBinding()]
    param()
    Write-WHDLog -Message '================ UPDATES STATUS (read-only) ================' -Level 'ACT'
    $g = Get-WHDGateState
    Write-WHDLog -Message ('Update gate          : {0}   (outbound: {1})' -f $g.Text, $g.Outbound) -Level $(if ($g.Closed) { 'OK' } else { 'WARN' })
    if ($g.Mode -eq 'programs') {
        $apps = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -ErrorAction SilentlyContinue)
        Write-WHDLog -Message ('  programs on your list: {0} rule(s){1}' -f $apps.Count, $(if ($apps.Count) { '' } else { ' - empty: the same as CLOSED until you allow one (Firewall menu V)' })) -Level $(if ($apps.Count) { 'INFO' } else { 'WARN' })
        foreach ($a in $apps) { Write-WHDLog -Message ('    {0}  [{1}]' -f $a.DisplayName, $(if ([string]$a.Enabled -eq 'True') { 'on' } else { 'off' })) }
    }
    try { $bl = Get-WHDBlocklistNeed; Write-WHDLog -Message ('IP block list        : {0}' -f $bl.Text) -Level $bl.Level } catch { Write-Verbose 'block list state unreadable' }
    if ($g.Closed) {
        $plat = Get-WHDDefenderPlatformDir
        $rule = @(Get-NetFirewallRule -Name 'WHDN-Gate-MsMpEng' -ErrorAction SilentlyContinue)
        if ($plat -and $rule.Count) {
            $af = ($rule[0] | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Select-Object -First 1)
            $pf = if ($af) { [string]$af.Program } else { '' }
            if ($pf -and $pf -ne (Join-Path $plat 'MsMpEng.exe')) { Write-WHDLog -Message '  Defender updated its platform since the gate closed - set the gate again (C or P) to refresh its allow rules.' -Level 'WARN' }
        }
    }
    foreach ($it in $script:WHDUpdatePolicies) {
        $ps = Get-WHDRegOpsState -Ops $it['Ops']
        Write-WHDLog -Message ('{0,-20}: {1}' -f $it['Key'], $(switch ($ps) { 'set' { 'set' } 'partly' { 'partly set' } default { 'not set' } })) -Level $(if ($ps -eq 'set') { 'OK' } else { 'INFO' })
    }
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 15 -ErrorAction SilentlyContinue)
    Write-WHDLog -Message ('Windows Update installs (14 days): {0}' -f $ev.Count)
    foreach ($e in @($ev | Select-Object -First 8)) {
        Write-WHDLog -Message ('  {0:yyyy-MM-dd HH:mm}  {1}' -f $e.TimeCreated, ((([string]$e.Message -split "`r?`n")[0]) -replace '^Installation Successful: Windows successfully installed the following update: ', ''))
    }
    $up = @(Find-WHDAppUpdater)
    Write-WHDLog -Message ('App updaters found   : {0}  ({1} still active)' -f $up.Count, @($up | Where-Object { $_.State -notmatch 'Disabled' }).Count)
    foreach ($u in $up) { Write-WHDLog -Message ('  {0}' -f $u.Label) -Level $(if ($u.State -match 'Disabled') { 'OK' } else { 'INFO' }) }
    Write-WHDLog -Message '================ END ================' -Level 'ACT'
}

function Update-WHDDefenderSignature {
    # Definitions straight from Microsoft Malware Protection Center (works while the gate is closed);
    # Windows' own CIM class MSFT_MpSignature, method Update (UpdateSource 2 = MMPC). Not a setting change.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    Write-WHDLog -Message 'DEFENDER: update definitions now (source MMPC - works while the gate is closed)' -Level 'ACT'
    $before = '?'; try { $before = [string](Get-WHDMpComputerStatus).AntivirusSignatureVersion } catch { Write-Verbose 'Defender status unreadable' }
    if (-not (Test-WHDRealChange)) { Write-WHDLog -Message ('would: update Defender definitions from MMPC   (definitions now {0})' -f $before) -Level 'DRY'; return }
    if (-not $PSCmdlet.ShouldProcess('Microsoft Defender', 'update definitions')) { return }
    try {
        [void](Invoke-WHDCimMethod -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpSignature' -Method 'Update' -Arguments @{ UpdateSource = 2 })
        $ds = Get-WHDMpComputerStatus
        $now = [string]$ds.AntivirusSignatureVersion
        if ($now -eq $before) { Write-WHDLog -Message ('Definitions checked: {0} is the newest (age {1} day(s)) - nothing new to download.' -f $now, $ds.AntivirusSignatureAge) -Level 'OK' }
        else { Write-WHDLog -Message ('Definitions updated: {0} -> {1}  (age {2} day(s))' -f $before, $now, $ds.AntivirusSignatureAge) -Level 'OK' }
    } catch { Write-WHDLog -Message ('Defender update failed: {0}' -f $_.Exception.Message) -Level 'ERR' }
}

# ---- menu ----------------------------------------------------------------------------------
function Show-WHDUpdatesMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  ================= Updates (stop automatic installs) =================' -ForegroundColor White
    $g = Get-WHDGateState
    Write-Host ('   Gate now: {0}   (outbound: {1})' -f $g.Text, $g.Outbound) -ForegroundColor $(if ($g.Closed) { 'Green' } else { 'Yellow' })
    Write-Host '  Update gate' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'C' -Label 'CLOSE the update gate' -Hint '(only Defender + DNS-over-HTTPS may use the web)'
    Write-WHDMenuItem -Key 'P' -Label 'PROGRAMS update gate' -Hint '(Defender + DoH + the programs you allowed)'
    Write-WHDMenuItem -Key 'O' -Label 'OPEN the update gate' -Hint '(lets updates in; stays open until you change it)'
    Write-Host '  Policies' -ForegroundColor DarkGray
    for ($i = 0; $i -lt $script:WHDUpdatePolicies.Count; $i++) {
        $it = $script:WHDUpdatePolicies[$i]
        $ps = Get-WHDRegOpsState -Ops $it['Ops']
        Write-WHDMenuItem -Key ([string]($i + 1)) -Label $it['Name'] -Hint ('[{0}]' -f $(switch ($ps) { 'set' { 'set' } 'partly' { 'partly' } default { 'not set' } }))
    }
    Write-WHDMenuItem -Key 'A' -Label 'All four policies above'
    Write-Host '  App updaters, Defender, status' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'E' -Label 'Edge Update off (tasks + services)'
    Write-WHDMenuItem -Key 'F' -Label 'Find other app updaters -> choose which to turn off'
    Write-WHDMenuItem -Key 'D' -Label 'Defender definitions: update now' -Hint '(works with the gate closed)'
    Write-WHDMenuItem -Key 'ST' -Label 'Status (gate, policies, recent Windows Update installs, updaters)' -Hint '(was S in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDUpdatesChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the follow-up question (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Cc]$' { Close-WHDUpdateGate }
        '^[Pp]$' { Close-WHDUpdateGate -Mode programs }
        '^[Oo]$' { Open-WHDUpdateGate }
        '^[1-4]$' { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[[int]$c - 1] }
        '^[Aa]$' { foreach ($it in $script:WHDUpdatePolicies) { Invoke-WHDUpdatePolicy -Item $it } }
        '^[Ee]$' { Disable-WHDAppUpdaterSet -EdgeOnly }
        '^[Ff]$' {
            $all = @(Find-WHDAppUpdater | Where-Object { $_.State -notmatch 'Disabled' })
            if (-not $all.Count) { Write-Host '  (no active app updaters found)' -ForegroundColor DarkGray; break }
            for ($n = 0; $n -lt $all.Count; $n++) { Write-Host ('  {0,3}. {1}' -f ($n + 1), $all[$n].Label) }
            $pick = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Numbers to turn off (e.g. 1,3 or 1-3), A = all, Enter = none').Trim()
            if (-not $pick) { break }
            $sel = if ($pick -match '^[Aa]$') { $all } else { $nums = ConvertFrom-WHDSelection -Text $pick -Max $all.Count; if ($nums) { @($nums | ForEach-Object { $all[$_ - 1] }) } else { @() } }
            if (@($sel).Count) { Disable-WHDAppUpdaterSet -Items $sel } else { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
        '^[Dd]$' { Update-WHDDefenderSignature }
        '^[Ss][Tt]$' { Show-WHDUpdatesStatus }
        '^[Bb]$' { return $false }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
