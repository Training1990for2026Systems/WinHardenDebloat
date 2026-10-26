#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Permissions.ps1   (app permissions)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Settings > Privacy & security > App permissions. Rewritten for PowerShell 7.6
 from WHD Next 2.0's Permissions (read for reference, not copied). Build step
 5.6a (D41): L Lock / 1 Lockdown / 2 Balanced / 3 Open / 4 Custom. 5.6b: 5 usage
 history (camera / microphone / location, read-only) and 6 per-app: allow /
 deny one Store app (Settings has per-app switches only for Store apps) and,
 owner's choice D47, R = remove an app's entry from a permission's list (Store
 or desktop; the entry is saved to a .reg file first).
 Owner's choices: the FULL list as Settings shows it on this PC, in that order
 (D43, beyond D8); Lock locks every new switch that has a Windows lock (D44);
 Passkeys is in Lock (D43) - Windows removes passkeys already saved when it is
 locked; Balanced counts the new switches as sensitive (D46); Open also removes
 WHD's lock policy values (D42).
 Where Windows keeps it:
   switch  : CapabilityAccessManager\ConsentStore\<name> Value = Allow | Deny | Prompt
             (this user HKCU + PC-wide HKLM; "desktop apps" = ...\NonPackaged)
   lock    : HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy <policy> = 2 (force deny)
             - names checked against this PC's own AppPrivacy.admx (2026-10-15).
 Camera, microphone, radios, location: OFF but NOT locked by Lock (2.0 rule) -
 Verify leaves the owner's choice there alone.
================================================================================
#>

$script:WHDConsentHKCU = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:WHDConsentHKLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:WHDAppPrivacyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'

# Settings order on the test PC (owner, 2026-10-15). Caps = consent-store switches; Pol = lock policies.
# Keep = off but not locked by Lock. Lib = library (Balanced: Prompt). Sens = Balanced: Deny.
# Win = set by Windows only (no switch). Hard = turning it off loses data (passkeys).
$script:WHDPermList = @(
    [pscustomobject]@{ Name = 'Location'; Caps = @('location'); Pol = @('LetAppsAccessLocation'); Keep = $true; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Camera'; Caps = @('webcam'); Pol = @('LetAppsAccessCamera'); Keep = $true; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Microphone'; Caps = @('microphone'); Pol = @('LetAppsAccessMicrophone'); Keep = $true; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Voice activation'; Caps = @(); Pol = @('LetAppsActivateWithVoice', 'LetAppsActivateWithVoiceAboveLock'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Notifications'; Caps = @('userNotificationListener'); Pol = @('LetAppsAccessNotifications'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Account info'; Caps = @('userAccountInformation'); Pol = @('LetAppsAccessAccountInfo'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Contacts'; Caps = @('contacts'); Pol = @('LetAppsAccessContacts'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Calendar'; Caps = @('appointments'); Pol = @('LetAppsAccessCalendar'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Phone calls'; Caps = @('phoneCall'); Pol = @('LetAppsAccessPhone'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Call history'; Caps = @('phoneCallHistory'); Pol = @('LetAppsAccessCallHistory'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Email'; Caps = @('email'); Pol = @('LetAppsAccessEmail'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Tasks'; Caps = @('userDataTasks'); Pol = @('LetAppsAccessTasks'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Messaging'; Caps = @('chat'); Pol = @('LetAppsAccessMessaging'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Radios'; Caps = @('radios'); Pol = @('LetAppsAccessRadios'); Keep = $true; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Other devices'; Caps = @('bluetoothSync'); Pol = @('LetAppsSyncWithDevices'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'App diagnostics'; Caps = @('appDiagnostics'); Pol = @('LetAppsGetDiagnosticInfo'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Automatic file downloads'; Caps = @(); Pol = @(); Keep = $false; Lib = $false; Sens = $false; Win = $true; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Documents'; Caps = @('documentsLibrary'); Pol = @(); Keep = $false; Lib = $true; Sens = $false; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Downloads folder'; Caps = @('downloadsFolder'); Pol = @(); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Music library'; Caps = @('musicLibrary'); Pol = @(); Keep = $false; Lib = $true; Sens = $false; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Pictures'; Caps = @('picturesLibrary'); Pol = @(); Keep = $false; Lib = $true; Sens = $false; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Videos'; Caps = @('videosLibrary'); Pol = @(); Keep = $false; Lib = $true; Sens = $false; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'File system'; Caps = @('broadFileSystemAccess'); Pol = @(); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Screenshot borders'; Caps = @('graphicsCaptureWithoutBorder'); Pol = @('LetAppsAccessGraphicsCaptureWithoutBorder'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Screenshots and screen recording'; Caps = @('graphicsCaptureProgrammatic'); Pol = @('LetAppsAccessGraphicsCaptureProgrammatic'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Text and image generation'; Caps = @('systemAIModels'); Pol = @('LetAppsAccessSystemAIModels'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    [pscustomobject]@{ Name = 'Passkeys'; Caps = @('passkeys', 'passkeysEnumeration'); Pol = @('LetAppsAccessPasskeys', 'LetAppsAccessPasskeysEnumeration'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $true; New = $true }
    [pscustomobject]@{ Name = 'Foreground text access'; Caps = @(); Pol = @('LetAppsAccessForegroundText'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $true }
    # In WHD Next 2.0's list, not on this PC's Settings page - kept (D8).
    [pscustomobject]@{ Name = 'Cellular data (not on this Settings page)'; Caps = @('cellularData'); Pol = @(); Keep = $false; Lib = $false; Sens = $false; Win = $false; Hard = $false; New = $false }
    [pscustomobject]@{ Name = 'Motion / activity (not on this Settings page)'; Caps = @('activity'); Pol = @('LetAppsAccessMotion'); Keep = $false; Lib = $false; Sens = $true; Win = $false; Hard = $false; New = $false }
)
$script:WHDPasskeyWarning = 'Passkeys: Windows removes the passkeys already saved on this PC when this switch is turned off / locked (owner''s finding, D43). Undo puts the switch back, NOT the deleted passkeys - sign-ins that used them need a new passkey or another way in.'

# ---- reading (read-only) -------------------------------------------------------------------------
function Get-WHDCapabilityValue {
    # This user's switch: Allow | Deny | Prompt | (unset).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Cap)
    $st = Get-WHDRegValueState -Path ('{0}\{1}' -f $script:WHDConsentHKCU, $Cap) -Name 'Value'
    if ($st.Exists) { return [string]$st.Value }
    return '(unset)'
}

function Test-WHDPolicyLocked {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Policy)
    $st = Get-WHDRegValueState -Path $script:WHDAppPrivacyKey -Name $Policy
    return ($st.Exists -and (Test-WHDRegValueEqual -A $st.Value -B 2 -Type 'DWord'))
}

function Get-WHDPermState {
    # One line of the list: the switch value(s) and whether Windows' lock is on.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Item)
    if ($Item.Win) { return 'set in Windows' }
    $vals = @($Item.Caps | ForEach-Object { Get-WHDCapabilityValue -Cap $_ } | Select-Object -Unique)
    $txt = if ($vals.Count) { $vals -join ' / ' } else { 'no switch' }
    $locked = @($Item.Pol | Where-Object { Test-WHDPolicyLocked -Policy $_ }).Count
    if ($Item.Pol.Count -and $locked -eq $Item.Pol.Count) { $txt += ', LOCKED' }
    elseif ($locked) { $txt += ', partly locked' }
    return $txt
}

function Get-WHDPermSwitchOp {
    # Registry writes for one switch value on one item: this user + PC-wide (+ desktop apps when Windows has it).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][ValidateSet('Allow', 'Deny', 'Prompt')][string]$Value, [switch]$Desktop)
    $ops = foreach ($c in $Item.Caps) {
        [pscustomobject]@{ P = ('{0}\{1}' -f $script:WHDConsentHKCU, $c); N = 'Value'; V = $Value; T = 'String' }
        [pscustomobject]@{ P = ('{0}\{1}' -f $script:WHDConsentHKLM, $c); N = 'Value'; V = $Value; T = 'String' }
        $np = '{0}\{1}\NonPackaged' -f $script:WHDConsentHKCU, $c
        if ($Desktop -and (Test-Path -LiteralPath $np)) { [pscustomobject]@{ P = $np; N = 'Value'; V = $Value; T = 'String' } }
    }
    return @($ops)
}

function Get-WHDPrivacyLockOp {
    # Lock: every switch Deny (this user + PC-wide + desktop apps) and force deny for every lock that is not "Keep".
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $ops = foreach ($it in $script:WHDPermList) {
        if ($it.Win) { continue }
        Get-WHDPermSwitchOp -Item $it -Value 'Deny' -Desktop
        if (-not $it.Keep) { foreach ($p in $it.Pol) { [pscustomobject]@{ P = $script:WHDAppPrivacyKey; N = $p; V = 2; T = 'DWord' } } }
    }
    return @($ops)
}

function Get-WHDPrivacyLockStale {
    # Lock values that must NOT be there (camera / microphone / radios / location stay unlocked).
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(foreach ($it in @($script:WHDPermList | Where-Object Keep)) { foreach ($p in $it.Pol) { if ((Get-WHDRegValueState -Path $script:WHDAppPrivacyKey -Name $p).Exists) { $p } } })
}

function Get-WHDPrivacyLockState {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $st = Get-WHDRegOpsState -Ops @(Get-WHDPrivacyLockOp)
    if ($st -eq 'set' -and @(Get-WHDPrivacyLockStale).Count) { return 'partly' }
    return $st
}

function Get-WHDProfileValue {
    # The switch value a profile wants for one item. (pure)
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][ValidateSet('Lockdown', 'Balanced', 'Open')][string]$ProfileName)
    switch ($ProfileName) {
        'Lockdown' { return 'Deny' }
        'Open' { return 'Allow' }
        'Balanced' { if ($Item.Lib) { return 'Prompt' }; if ($Item.Sens) { return 'Deny' }; return 'Allow' }
    }
}

# ---- writing ---------------------------------------------------------------------------------------
function Invoke-WHDPermOp {
    # Writes only the values that are not right yet (no record for values already right). Returns how many were written.
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyCollection()][object[]]$Ops)
    $n = 0
    foreach ($op in @($Ops)) {
        if ($script:WHDState.JournalStop) { break }
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
        $n++
    }
    return $n
}

function Test-WHDPasskeyDenyIn {
    # True when the writes turn a Passkeys switch to Deny or lock it (the data-loss case).
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyCollection()][object[]]$Ops)
    $pk = @($script:WHDPermList | Where-Object Hard)
    foreach ($op in @($Ops)) {
        foreach ($it in $pk) {
            if ($op.N -in $it.Pol -and [int]$op.V -eq 2) { return $true }
            foreach ($c in $it.Caps) { if ($op.P -like ('*\ConsentStore\{0}*' -f $c) -and [string]$op.V -eq 'Deny') {
                    $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
                    if (-not ($cur.Exists -and [string]$cur.Value -eq 'Deny')) { return $true } } }
        }
    }
    return $false
}

function Invoke-WHDPrivacyLock {
    [CmdletBinding()]
    param()
    $locked = @($script:WHDPermList | Where-Object { -not $_.Keep -and $_.Pol.Count }).Count
    Write-WHDLog -Message 'PERMISSIONS L: Lock (every switch Deny + Windows lock; camera / microphone / radios / location off, not locked)' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text ('Every listed switch -> Deny (this user + PC-wide + desktop apps). Windows lock (force deny) for {0} entries, so Settings shows them OFF and greyed. Camera, microphone, radios and location: OFF but NOT locked - you can switch them on, and Verify leaves your choice alone. Libraries, Downloads folder, File system, Cellular data: no Windows lock exists - Deny only. Voice activation and Foreground text access: Windows lock only (no switch found). Automatic file downloads: set by Windows, not changed. Microsoft lists the lock for Pro and up; on Home it is tried - check Settings after a restart. Recorded (Undo center).' -f $locked)
    $ops = @(Get-WHDPrivacyLockOp)
    $stale = @(Get-WHDPrivacyLockStale)
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set' -and -not $stale.Count) { Write-WHDLog -Message 'Already locked - nothing to change.' -Level 'OK'; return }
    if (Test-WHDPasskeyDenyIn -Ops $ops) { Write-WHDRisk -Tier 'hard' -Text $script:WHDPasskeyWarning }
    if (-not (Confirm-WHDProceed -What 'apply the Lock permission profile (Passkeys included)')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($sn in $stale) { Remove-WHDRegistryValue -Path $script:WHDAppPrivacyKey -Name $sn | Out-Null }
    $n = Invoke-WHDPermOp -Ops $ops
    Write-WHDLog -Message ('Lock: {0} value(s) written, {1} already right.' -f $n, ($ops.Count - $n)) -Level 'OK'
    Write-WHDLog -Message 'Restart the PC, then open Settings > Privacy & security: locked switches show OFF and greyed. If any still show ON, Windows Home is not applying that lock; Verify shows which values stuck.'
}

function Invoke-WHDPermissionProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Lockdown', 'Balanced', 'Open')][string]$ProfileName)
    Write-WHDLog -Message ('PERMISSIONS: {0} profile' -f $ProfileName) -Level 'ACT'
    $what = switch ($ProfileName) {
        'Lockdown' { 'Every switch -> Deny.' }
        'Balanced' { 'Sensitive switches (and every new one) -> Deny; Documents / Music / Pictures / Videos -> Prompt; Cellular data -> Allow.' }
        'Open' { 'Every switch -> Allow, and WHD''s Windows locks (force deny) are removed (D42).' }
    }
    Write-WHDRisk -Tier $(if ($ProfileName -eq 'Open') { 'caution' } else { 'reversible' }) -Text ('{0} This user + PC-wide switches. Entries without a switch (Voice activation, Foreground text access, Automatic file downloads) are not changed by a profile. Recorded (Undo center).' -f $what)
    $ops = @(foreach ($it in @($script:WHDPermList | Where-Object { -not $_.Win })) { Get-WHDPermSwitchOp -Item $it -Value (Get-WHDProfileValue -Item $it -ProfileName $ProfileName) })
    $unlock = @(if ($ProfileName -eq 'Open') { foreach ($it in $script:WHDPermList) { foreach ($p in $it.Pol) { if (Test-WHDPolicyLocked -Policy $p) { $p } } } })
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set' -and -not $unlock.Count) { Write-WHDLog -Message ('Already {0} - nothing to change.' -f $ProfileName) -Level 'OK'; return }
    if (Test-WHDPasskeyDenyIn -Ops $ops) { Write-WHDRisk -Tier 'hard' -Text $script:WHDPasskeyWarning }
    if ($unlock.Count) { Write-WHDLog -Message ('Open also removes {0} Windows lock value(s): {1}' -f $unlock.Count, ($unlock -join ', ')) }
    if (-not (Confirm-WHDProceed -What ('apply the {0} permission profile' -f $ProfileName))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($p in $unlock) { if ($script:WHDState.JournalStop) { break }; Remove-WHDRegistryValue -Path $script:WHDAppPrivacyKey -Name $p | Out-Null }
    $n = Invoke-WHDPermOp -Ops $ops
    Write-WHDLog -Message ('{0}: {1} value(s) written, {2} already right.' -f $ProfileName, $n, ($ops.Count - $n)) -Level 'OK'
}

function Invoke-WHDPermissionCustom {
    # One switch at a time: a = Allow, d = Deny, p = Prompt, Enter / s = skip. -Answer feeds the answers (tests).
    [CmdletBinding()]
    param([string[]]$Answer)
    Write-WHDLog -Message 'PERMISSIONS 4: Custom (one switch at a time)' -Level 'ACT'
    $items = @($script:WHDPermList | Where-Object { $_.Caps.Count })
    if (-not (Test-WHDRealChange)) {
        foreach ($it in $items) { Write-WHDLog -Message ('would ask: {0} (now: {1})' -f $it.Name, (Get-WHDPermState -Item $it)) -Level 'DRY' }
        return
    }
    $i = 0
    foreach ($it in $items) {
        if ($script:WHDState.JournalStop) { break }
        $a = if ($null -ne $Answer -and $i -lt $Answer.Count) { $Answer[$i] } else { Read-Host ('  {0,-34} (now: {1})  a=Allow d=Deny p=Prompt, Enter=skip' -f $it.Name, (Get-WHDPermState -Item $it)) }
        $a = [string]$a   # an empty answer (Enter) is a skip
        $i++
        $v = switch -regex ($a.Trim()) { '^[Aa]$' { 'Allow' } '^[Dd]$' { 'Deny' } '^[Pp]$' { 'Prompt' } default { $null } }
        if (-not $v) { continue }
        $ops = @(Get-WHDPermSwitchOp -Item $it -Value $v)
        if ($it.Hard -and (Test-WHDPasskeyDenyIn -Ops $ops)) {
            Write-WHDRisk -Tier 'hard' -Text $script:WHDPasskeyWarning
            if (-not (Confirm-WHDProceed -What 'turn Passkeys off')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; continue }
        }
        [void](Invoke-WHDPermOp -Ops $ops)
    }
}

# ---- 5.6b: who used camera / microphone / location (read-only) ---------------------------------------
$script:WHDPfnNames = $null

function Get-WHDStoreAppName {
    # PackageFamilyName -> package name for this user (read once per session).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($null -ne $script:WHDPfnNames) { return $script:WHDPfnNames }
    $map = @{}
    foreach ($p in @(Get-AppxPackage -ErrorAction SilentlyContinue)) { if ([string]$p.PackageFamilyName) { $map[[string]$p.PackageFamilyName] = [string]$p.Name } }
    $script:WHDPfnNames = $map
    return $map
}

function Get-WHDConsentSubkey {
    # The app entries under one permission: Store apps (<PackageFamilyName>) and desktop apps (NonPackaged\<C:#path#app.exe>).
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$Cap)
    $base = '{0}\{1}' -f $script:WHDConsentHKCU, $Cap
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $keys = @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' } | ForEach-Object { [pscustomobject]@{ Key = $_; Desktop = $false; Path = ('{0}\{1}' -f $base, $_.PSChildName) } })
    $np = '{0}\NonPackaged' -f $base
    if (Test-Path -LiteralPath $np) { $keys += @(Get-ChildItem -LiteralPath $np -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ Key = $_; Desktop = $true; Path = ('{0}\{1}' -f $np, $_.PSChildName) } }) }
    return @(foreach ($k in $keys) {
            [pscustomobject]@{ Id = [string]$k.Key.PSChildName; Path = $k.Path; Desktop = $k.Desktop
                Value = [string]$k.Key.GetValue('Value', '(unset)'); Start = $k.Key.GetValue('LastUsedTimeStart', 0); Stop = $k.Key.GetValue('LastUsedTimeStop', 0) }
        })
}

function ConvertFrom-WHDFileTime {
    # FILETIME number -> date; $null for 0 / bad values. (pure)
    [CmdletBinding()]
    [OutputType([datetime])]
    param($Value)
    try { $v = [int64]$Value } catch { return $null }
    if ($v -le 0) { return $null }
    try { return [DateTime]::FromFileTime($v) } catch { return $null }
}

function Get-WHDAppEntry {
    # Every app entry under the item's switch(es), with a readable name. Read-only.
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Item)
    $names = Get-WHDStoreAppName
    $out = foreach ($cap in $Item.Caps) {
        foreach ($e in @(Get-WHDConsentSubkey -Cap $cap)) {
            $id = if ($e.Desktop) { $e.Id -replace '#', '\' } else { $e.Id }
            # A web site (passkeys: apple.com, claude.ai) is a plain domain - no "_publisher" part like a Store package.
            $site = (-not $e.Desktop) -and -not $names.ContainsKey($id) -and $id -notmatch '_' -and $id -match '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
            $type = if ($e.Desktop) { 'desktop' } elseif ($site) { 'site' } else { 'Store' }
            $app = if ($e.Desktop) { Split-Path $id -Leaf } elseif ($names.ContainsKey($id)) { $names[$id] } elseif ($site) { $id } else { ($id -split '_')[0] }
            [pscustomobject]@{ Cap = $cap; Id = $id; Path = $e.Path; App = $app; Type = $type
                Installed = ($e.Desktop -or $site -or $names.ContainsKey($id)); Value = $e.Value; Start = (ConvertFrom-WHDFileTime -Value $e.Start); Stop = (ConvertFrom-WHDFileTime -Value $e.Stop) }
        }
    }
    return @($out | Sort-Object App, Cap)
}

function Show-WHDCapabilityUsage {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'PERMISSIONS 5: camera / microphone / location - last use per app (this user, read-only)' -Level 'ACT'
    $rows = @(foreach ($n in 'Camera', 'Microphone', 'Location') {
            $it = $script:WHDPermList | Where-Object Name -eq $n
            foreach ($e in @(Get-WHDAppEntry -Item $it)) { if ($e.Start) { $e | Add-Member -NotePropertyName What -NotePropertyValue $n -PassThru } }
        })
    if (-not $rows.Count) { Write-WHDLog -Message '  (no recorded use)'; return }
    Write-WHDLog -Message ('  {0,-11} {1,-30} {2,-8} {3,-17} {4}' -f 'what', 'app', 'type', 'last started', 'last stopped')
    foreach ($r in @($rows | Sort-Object Start -Descending)) {
        $inUse = (-not $r.Stop) -or ($r.Stop -lt $r.Start)
        $app = if ($r.App.Length -gt 30) { $r.App.Substring(0, 29) + '~' } else { $r.App }
        Write-WHDLog -Message ('  {0,-11} {1,-30} {2,-8} {3,-17} {4}' -f $r.What, $app, $r.Type, $r.Start.ToString('yyyy-MM-dd HH:mm'), $(if ($inUse) { 'IN USE NOW' } else { $r.Stop.ToString('yyyy-MM-dd HH:mm') })) -Level $(if ($inUse) { 'WARN' } else { 'INFO' })
    }
}

# ---- 5.6b: per-app ----------------------------------------------------------------------------------
function Remove-WHDAppEntry {
    # Removes one app's entry from a permission's list. The key is exported to restore\<session>\ first.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Entry)
    $raPath = [string]$Entry.Path
    if (-not $PSCmdlet.ShouldProcess($raPath, 'remove app entry')) { return }
    $stamp = $script:WHDState.Stamp
    Invoke-WHDChange -Description ('remove app entry: {0} ({1}, {2})' -f $Entry.App, $Entry.Cap, $Entry.Type) -Journal @{ Kind = 'action'; Path = $raPath
        Hint = ('import this session''s .reg backup: Restore-WHDSessionBackup -Session {0} -RegFiles (the app may also ask again by itself)' -f $stamp) } -Action {
        if (-not (Test-Path -LiteralPath $raPath)) { Write-WHDLog -Message 'already gone'; return }
        Backup-WHDRegistryKey -Path $raPath
        Remove-Item -LiteralPath $raPath -Recurse -Force -ErrorAction Stop
    } | Out-Null
}

function Invoke-WHDPerAppAction {
    # a / d: Store apps and web sites (they have their own switch); desktop apps follow the main switch. r: remove any entry. ONE question.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)][object[]]$Entries, [Parameter(Mandatory)][ValidateSet('Allow', 'Deny', 'Remove')][string]$Action)
    Write-WHDLog -Message ('PER-APP: {0} -> {1} for {2} entr(y/ies)' -f $Item.Name, $Action, $Entries.Count) -Level 'ACT'
    $todo = @($Entries)
    if ($Action -ne 'Remove') {
        $desk = @($todo | Where-Object Type -eq 'desktop')
        if ($desk.Count) { Write-WHDLog -Message ('{0} desktop app(s) skipped: Windows has no per-app switch for them (they follow the "desktop apps" switch). Use r to remove the entry.' -f $desk.Count) -Level 'WARN' }
        $todo = @($todo | Where-Object Type -in 'Store', 'site')
        if (-not $todo.Count) { return }
        Write-WHDRisk -Tier 'reversible' -Text 'Same switch as Settings > Privacy & security > (permission) > per-app list. Recorded (Undo center).'
        if ($Action -eq 'Allow' -and @($Item.Caps | Where-Object { (Get-WHDCapabilityValue -Cap $_) -eq 'Deny' }).Count) { Write-WHDLog -Message ('Note: the main "{0}" switch is Deny (or locked), so the app still gets no access until the main switch allows it.' -f $Item.Name) -Level 'WARN' }
    } else {
        Write-WHDRisk -Tier 'reversible' -Text 'Removes the app from this permission''s list in Settings. The entry is saved to a .reg file in this session''s restore folder first (Undo center hint: import it). If the app asks again later, Windows lists it again.'
    }
    if (-not (Confirm-WHDProceed -What ('{0} {1} entr(y/ies) under {2}' -f $Action.ToLowerInvariant(), $todo.Count, $Item.Name))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($e in $todo) {
        if ($script:WHDState.JournalStop) { break }
        if ($Action -eq 'Remove') { Remove-WHDAppEntry -Entry $e }
        else { Set-WHDRegistryValue -Path $e.Path -Name 'Value' -Value $Action -Type 'String' | Out-Null }
    }
}

function Invoke-WHDPerAppMenu {
    # Pick a permission, then "#(s) a|d|r". -Answer feeds the questions (tests).
    [CmdletBinding()]
    param([string[]]$Answer)
    $q = [System.Collections.Generic.Queue[string]]::new()
    foreach ($a in @($Answer)) { if ($null -ne $a) { $q.Enqueue([string]$a) } }
    $ask = { param($prompt) if ($null -ne $Answer) { if ($q.Count) { return $q.Dequeue() }; return '' }; return [string](Read-Host $prompt) }
    $items = @($script:WHDPermList | Where-Object { $_.Caps.Count })
    Write-Host ''
    Write-Host '  PER-APP - pick a permission:' -ForegroundColor White
    for ($i = 0; $i -lt $items.Count; $i++) { Write-Host ('  {0,3}. {1,-46} {2}' -f ($i + 1), $items[$i].Name, (Get-WHDPermState -Item $items[$i])) }
    $c = ([string](& $ask '  Select # (Enter = back)')).Trim()
    if ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $items.Count) { return }
    $it = $items[[int]$c - 1]
    while ($true) {
        $apps = @(Get-WHDAppEntry -Item $it)
        Write-Host ''
        Write-Host ('  {0} - apps in its list   (main switch: {1})' -f $it.Name, (Get-WHDPermState -Item $it)) -ForegroundColor White
        if (-not $apps.Count) { Write-WHDLog -Message ('  (no app entries under {0})' -f $it.Name); return }
        for ($j = 0; $j -lt $apps.Count; $j++) {
            $a = $apps[$j]
            $label = '{0}{1}{2}' -f $a.App, $(if ($it.Caps.Count -gt 1) { ' [' + $a.Cap + ']' } else { '' }), $(if (-not $a.Installed) { ' (not installed)' } else { '' })
            Write-WHDParts -Parts @(('  {0,3}. {1,-52} {2,-8} ' -f ($j + 1), $label, $a.Type), @($a.Value, $(if ($a.Value -eq 'Deny') { 'Green' } elseif ($a.Value -eq 'Allow') { 'Yellow' } else { 'Gray' })))
        }
        $pick = ([string](& $ask '  #(s) then a=allow / d=deny / r=remove entry (e.g. "3 d", "1,4 r"), Enter = back')).Trim()
        if (-not $pick) { return }
        if ($pick -notmatch '^([\d,\s-]+)\s+([AaDdRr])$') { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
        $nums = ConvertFrom-WHDSelection -Text $Matches[1] -Max $apps.Count
        $act = switch -regex ($Matches[2]) { '[Aa]' { 'Allow' } '[Dd]' { 'Deny' } default { 'Remove' } }
        if ($null -eq $nums) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
        Invoke-WHDPerAppAction -Item $it -Entries @($nums | ForEach-Object { $apps[$_ - 1] }) -Action $act
    }
}

# ---- menu --------------------------------------------------------------------------------------------
function Show-WHDPermissionsMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== APP PERMISSIONS (Settings > Privacy & security) ===============' -ForegroundColor White
    $n = 0
    foreach ($it in $script:WHDPermList) {
        $n++
        $st = Get-WHDPermState -Item $it
        $col = if ($st -match 'LOCKED') { 'Green' } elseif ($st -match '^Deny') { 'Green' } elseif ($st -match '^Prompt') { 'Yellow' } elseif ($st -match '^Allow') { 'Gray' } else { 'DarkGray' }
        Write-WHDParts -Parts @(('  {0,3}. {1,-46} ' -f $n, $it.Name), @($st, $col))
    }
    Write-Host ''
    Write-WHDMenuItem -Key 'L' -Label 'Lock (every switch Deny + Windows lock; camera / mic / radios / location off, not locked)' -Hint ('[{0}]' -f (Get-WHDPrivacyLockState))
    Write-WHDMenuItem -Key '1' -Label 'Lockdown (every switch Deny)'
    Write-WHDMenuItem -Key '2' -Label 'Balanced (sensitive + new Deny; libraries Prompt)'
    Write-WHDMenuItem -Key '3' -Label 'Open (every switch Allow + WHD''s Windows locks removed)'
    Write-WHDMenuItem -Key '4' -Label 'Custom (choose one switch at a time)'
    Write-WHDMenuItem -Key '5' -Label 'Usage history (who used camera / microphone / location, and when)'
    Write-WHDMenuItem -Key '6' -Label 'Per-app (allow / deny a Store app; r = remove an app from a permission''s list)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDPermissionsChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds Custom (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^[Ll]$' { Invoke-WHDPrivacyLock }
        '^1$' { Invoke-WHDPermissionProfile -ProfileName 'Lockdown' }
        '^2$' { Invoke-WHDPermissionProfile -ProfileName 'Balanced' }
        '^3$' { Invoke-WHDPermissionProfile -ProfileName 'Open' }
        '^4$' { Invoke-WHDPermissionCustom -Answer $Answer }
        '^5$' { Show-WHDCapabilityUsage }
        '^6$' { Invoke-WHDPerAppMenu -Answer $Answer }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
