<#
================================================================================
 WHD Next  -  modules\Permissions.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 App-permission profiles = Settings > Privacy & security > App permissions.

 Backed by the Capability Access Manager consent store:
   HKCU\...\CapabilityAccessManager\ConsentStore\<capability>  Value = Allow|Deny|Prompt
   HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\<capability>
 Setting the capability's GLOBAL Value is the "Let apps access X" master switch
 (covers Store + Win32). Precedence: an HKCU Deny overrides an HKLM Allow, so
 profiles write BOTH hives to keep the effective state unambiguous.

 Profiles: Lockdown (deny all) / Balanced (deny sensitive, libraries prompt) /
 Open (reset to Allow) / Custom (per-capability). Same dry-run/commit safety.
 Reuses Common.ps1.
================================================================================
#>

# Sensitive=$true -> denied by the Balanced profile. Library flags handled below.
$script:WHDCapabilities = @(
    [ordered]@{ Cap='webcam';                 Name='Camera';               Sensitive=$true }
    [ordered]@{ Cap='microphone';             Name='Microphone';           Sensitive=$true }
    [ordered]@{ Cap='location';               Name='Location';             Sensitive=$true }
    [ordered]@{ Cap='contacts';               Name='Contacts';             Sensitive=$true }
    [ordered]@{ Cap='appointments';           Name='Calendar';             Sensitive=$true }
    [ordered]@{ Cap='phoneCallHistory';       Name='Call history';         Sensitive=$true }
    [ordered]@{ Cap='email';                  Name='Email';                Sensitive=$true }
    [ordered]@{ Cap='chat';                   Name='Messaging';            Sensitive=$true }
    [ordered]@{ Cap='userAccountInformation'; Name='Account info';         Sensitive=$true }
    [ordered]@{ Cap='phoneCall';              Name='Phone calls';          Sensitive=$true }
    [ordered]@{ Cap='radios';                 Name='Radios (BT toggle)';   Sensitive=$true }
    [ordered]@{ Cap='bluetoothSync';          Name='Bluetooth sync';       Sensitive=$true }
    [ordered]@{ Cap='cellularData';           Name='Cellular data';        Sensitive=$false }
    [ordered]@{ Cap='userDataTasks';          Name='Tasks';                Sensitive=$true }
    [ordered]@{ Cap='userNotificationListener';Name='Notifications access';Sensitive=$true }
    [ordered]@{ Cap='activity';               Name='Activity/timeline';    Sensitive=$true }
    [ordered]@{ Cap='documentsLibrary';       Name='Documents library';    Sensitive=$false; Library=$true }
    [ordered]@{ Cap='picturesLibrary';        Name='Pictures library';     Sensitive=$false; Library=$true }
    [ordered]@{ Cap='videosLibrary';          Name='Videos library';       Sensitive=$false; Library=$true }
    [ordered]@{ Cap='broadFileSystemAccess';  Name='Full filesystem';      Sensitive=$true }
)

$script:WHDConsentHKCU = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:WHDConsentHKLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'

function Get-WHDCapabilityValue {
    param([string]$Cap)
    $p = Join-Path $script:WHDConsentHKCU $Cap
    # WHD Next: no -EA Stop + catch here - a missing key is normal and left a TerminatingError line per switch in the log.
    if (-not (Test-Path -LiteralPath $p)) { return '(unset)' }
    $k = Get-Item -LiteralPath $p -EA SilentlyContinue
    if (-not $k -or ($k.GetValueNames() -notcontains 'Value')) { return '(unset)' }
    return "$($k.GetValue('Value'))"
}

function Set-WHDCapability {
    param([string]$Cap, [ValidateSet('Allow','Deny','Prompt')]$Value, [switch]$MachineToo)
    Set-WHDRegistryValue -Path (Join-Path $script:WHDConsentHKCU $Cap) -Name 'Value' -Value $Value -Type String
    if ($MachineToo) {
        Set-WHDRegistryValue -Path (Join-Path $script:WHDConsentHKLM $Cap) -Name 'Value' -Value $Value -Type String
    }
}

function Get-WHDProfileValue {
    param($CapEntry, [string]$Profile)
    switch ($Profile) {
        'Lockdown' { return 'Deny' }
        'Open'     { return 'Allow' }
        'Balanced' {
            if ($CapEntry.Library)   { return 'Prompt' }   # libraries ask, not blanket-deny
            if ($CapEntry.Sensitive) { return 'Deny' }
            return 'Allow'
        }
    }
}

function Invoke-WHDPermissionProfile {
    param([ValidateSet('Lockdown','Balanced','Open')]$Profile)
    Write-WHDLog ("PERMISSION PROFILE: {0}" -f $Profile) 'ACT'
    $tier = if ($Profile -eq 'Open') { 'caution' } else { 'reversible' }
    Write-WHDRisk $tier ("Sets the global 'Let apps access ...' switches (HKCU + HKLM). {0}" -f `
        $(switch($Profile){'Lockdown'{'Denies every listed capability.'}'Balanced'{'Denies sensitive capabilities; libraries set to Prompt.'}'Open'{'Resets everything to Allow.'}}))
    if (-not (Confirm-WHDProceed ("apply {0} permission profile" -f $Profile))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($c in $script:WHDCapabilities) {
        $v = Get-WHDProfileValue -CapEntry $c -Profile $Profile
        Set-WHDCapability -Cap $c.Cap -Value $v -MachineToo
    }
    Write-WHDLog ("Profile {0} planned/applied across {1} capabilities." -f $Profile, $script:WHDCapabilities.Count) 'OK'
}

# ---- Lock (v1.2, user's choice 2026-09-27) ---------------------------------------
# Plain registry Deny (the profiles above) is not always what Settings shows: the
# Capability Access Manager keeps per-user values and can write them back, so switches
# can look ON. Windows' own App Privacy policy ("Force Deny", value 2) is what makes
# Settings show a switch OFF and greyed out ("managed by your organization").
# Microsoft lists these policies for Pro/Enterprise/Education; on Home they are TRIED -
# check Settings after a restart. Camera + microphone + radios + location: user's choice = OFF but NOT locked
# (radios added 2026-09-28: a locked radio switch left Bluetooth/Wi-Fi 'on but dormant';
#  location added 2026-09-29, user decision. Verify/re-apply leave these four switches alone.)
# (can be allowed per app later). Library / cellular / file-system switches have no
# policy - they get registry Deny only.
$script:WHDAppPrivacyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy'
$script:WHDAppPrivacyPolicy = [ordered]@{
    location = 'LetAppsAccessLocation'; contacts = 'LetAppsAccessContacts'; appointments = 'LetAppsAccessCalendar'
    phoneCallHistory = 'LetAppsAccessCallHistory'; email = 'LetAppsAccessEmail'; chat = 'LetAppsAccessMessaging'
    userAccountInformation = 'LetAppsAccessAccountInfo'; phoneCall = 'LetAppsAccessPhone'; radios = 'LetAppsAccessRadios'
    bluetoothSync = 'LetAppsSyncWithDevices'; userDataTasks = 'LetAppsAccessTasks'; userNotificationListener = 'LetAppsAccessNotifications'
    activity = 'LetAppsAccessMotion'; webcam = 'LetAppsAccessCamera'; microphone = 'LetAppsAccessMicrophone'
}
$script:WHDPrivacyLockKeep = @('webcam', 'microphone', 'radios', 'location')
function Get-WHDPrivacyLockOps {
    $ops = @()
    foreach ($c in $script:WHDCapabilities) {
        $ops += [pscustomobject]@{ P = (Join-Path $script:WHDConsentHKCU $c.Cap); N = 'Value'; V = 'Deny'; T = 'String' }
        $ops += [pscustomobject]@{ P = (Join-Path $script:WHDConsentHKLM $c.Cap); N = 'Value'; V = 'Deny'; T = 'String' }
        # "Let desktop apps access ..." switch - only where Windows already has it
        $np = Join-Path (Join-Path $script:WHDConsentHKCU $c.Cap) 'NonPackaged'
        if (Test-Path -LiteralPath $np) { $ops += [pscustomobject]@{ P = $np; N = 'Value'; V = 'Deny'; T = 'String' } }
        if ($script:WHDAppPrivacyPolicy.Contains($c.Cap) -and ($script:WHDPrivacyLockKeep -notcontains $c.Cap)) {
            $ops += [pscustomobject]@{ P = $script:WHDAppPrivacyKey; N = $script:WHDAppPrivacyPolicy[$c.Cap]; V = 2; T = 'DWord' }
        }
    }
    $ops
}
# Policy values that must NOT exist (unlocked categories) - removed by Lock if an older run set them.
function Get-WHDPrivacyLockStale {
    @(foreach ($cap in $script:WHDPrivacyLockKeep) {
        if (-not $script:WHDAppPrivacyPolicy.Contains($cap)) { continue }
        $n = $script:WHDAppPrivacyPolicy[$cap]
        if ((Get-WHDRegValueState -Path $script:WHDAppPrivacyKey -Name $n).Exists) { $n }
    })
}
function Get-WHDPrivacyLockState {
    $st = Get-WHDRegOpsState -Ops @(Get-WHDPrivacyLockOps)
    if ($st -eq 'set' -and @(Get-WHDPrivacyLockStale).Count) { return 'partly' }
    $st
}
function Invoke-WHDPrivacyLock {
    Write-WHDLog 'PERMISSION PROFILE: Lock (App Privacy policy = Force Deny; camera + microphone + radios + location off, not locked)' 'ACT'
    Write-WHDRisk 'reversible' ('Every listed switch -> Deny (this user + PC-wide + desktop apps). Policy Force Deny for {0} categories, so Settings shows them OFF and greyed out. Camera, microphone, radios (Bluetooth/Wi-Fi control) and location: OFF but NOT locked - you can switch them on in Settings, and Verify leaves your choice alone. An older Lock on radios or location is removed. Documents/Pictures/Videos/Cellular/File system: no Windows policy exists - Deny only. Microsoft lists the policy for Pro and up; on Home it is tried - check Settings after a restart. Journaled (Undo center).' -f @($script:WHDAppPrivacyPolicy.Keys | Where-Object { $script:WHDPrivacyLockKeep -notcontains $_ }).Count)
    $ops = @(Get-WHDPrivacyLockOps)
    $stale = @(Get-WHDPrivacyLockStale)
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set' -and -not $stale.Count) { Write-WHDLog 'Already locked - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed 'apply the Lock permission profile')) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($sn in $stale) { Remove-WHDRegistryValue -Path $script:WHDAppPrivacyKey -Name $sn | Out-Null }
    $n = 0
    foreach ($op in $ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual $cur.Value $op.V $op.T)) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
        $n++
    }
    Write-WHDLog ("Lock: {0} value(s) written, {1} already right." -f $n, ($ops.Count - $n)) 'OK'
    Write-WHDLog 'Restart the PC, then open Settings > Privacy & security: locked switches show OFF and greyed. If any still show ON, Windows Home is not applying that policy; run Verify (main menu V, or the Inventory / Undo tab of the window version) to see which values stuck.' 'INFO'
}

function Invoke-WHDPermissionCustom {
    Write-WHDLog 'PERMISSION PROFILE: Custom (per-capability)' 'ACT'
    foreach ($c in $script:WHDCapabilities) {
        $cur = Get-WHDCapabilityValue -Cap $c.Cap
        if ($script:WHDExecute) {
            $ans = (Read-Host ("  {0,-22} (now: {1})  a=Allow d=Deny p=Prompt s=skip" -f $c.Name, $cur)).Trim()
            switch -regex ($ans) {
                '^[Aa]$' { Set-WHDCapability -Cap $c.Cap -Value 'Allow'  -MachineToo }
                '^[Dd]$' { Set-WHDCapability -Cap $c.Cap -Value 'Deny'   -MachineToo }
                '^[Pp]$' { Set-WHDCapability -Cap $c.Cap -Value 'Prompt' -MachineToo }
                default  { Write-WHDLog ("skip {0}" -f $c.Name) 'INFO' }
            }
        } else {
            Write-WHDLog ("would prompt for: {0} (now: {1})" -f $c.Name, $cur) 'DRY'
        }
    }
}

# =============================================================================
#  Phase 7 (C11): WHO USED THE CAMERA / MICROPHONE / LOCATION, AND WHEN
# -----------------------------------------------------------------------------
#  Windows records per-app use in the same consent store, per user (HKCU):
#    ConsentStore\<cap>\<PackageFamilyName>          (Store apps)
#    ConsentStore\<cap>\NonPackaged\<C:#path#app.exe> (desktop apps)
#  with LastUsedTimeStart / LastUsedTimeStop (FILETIME). Stop = 0 while in use.
#  Read-only.
# =============================================================================
function ConvertFrom-WHDFileTime {
    param($Value)
    try { $v = [int64]$Value } catch { return $null }
    if ($v -le 0) { return $null }
    try { return [DateTime]::FromFileTime($v) } catch { return $null }
}

function Get-WHDStoreAppNames {
    # PackageFamilyName -> friendly package name, for the current user.
    if ($script:WHDPfnNames) { return $script:WHDPfnNames }
    $m = @{}
    foreach ($p in @(Get-AppxPackage -EA SilentlyContinue)) { if ($p.PackageFamilyName) { $m[$p.PackageFamilyName] = "$($p.Name)" } }
    $script:WHDPfnNames = $m
    return $m
}

function Get-WHDCapabilityUsage {
    param([string[]]$Caps = @('webcam','microphone','location'))
    $names = Get-WHDStoreAppNames
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($cap in $Caps) {
        $base = Join-Path $script:WHDConsentHKCU $cap
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $capName = @($script:WHDCapabilities | Where-Object { $_.Cap -eq $cap } | ForEach-Object { $_.Name })[0]
        if (-not $capName) { $capName = $cap }
        $keys = @(Get-ChildItem -LiteralPath $base -EA SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' })
        $np = Join-Path $base 'NonPackaged'
        if (Test-Path -LiteralPath $np) { $keys += @(Get-ChildItem -LiteralPath $np -EA SilentlyContinue) }
        foreach ($k in $keys) {
            $start = ConvertFrom-WHDFileTime ($k.GetValue('LastUsedTimeStart', 0))
            $stop  = ConvertFrom-WHDFileTime ($k.GetValue('LastUsedTimeStop', 0))
            if (-not $start) { continue }                      # never used
            $isDesktop = ($k.PSParentPath -like '*NonPackaged')
            $app = if ($isDesktop) { $k.PSChildName -replace '#', '\' } else { $k.PSChildName }
            $friendly = if ($isDesktop) { Split-Path $app -Leaf } elseif ($names.ContainsKey($app)) { $names[$app] } else { ($app -split '_')[0] }
            $out.Add([pscustomobject]@{
                Capability = $capName; App = $friendly; Type = $(if ($isDesktop) { 'desktop' } else { 'Store' })
                LastStart = $start; LastStop = $stop; InUse = [bool](-not $stop -or $stop -lt $start)
                Permission = "$($k.GetValue('Value', ''))"; Id = $app
            })
        }
    }
    @($out.ToArray() | Sort-Object LastStart -Descending)
}

function Show-WHDCapabilityUsage {
    $rows = @(Get-WHDCapabilityUsage)
    Write-Host ''
    Write-Host '  CAMERA / MICROPHONE / LOCATION - last use per app (this user)' -ForegroundColor White
    if (-not $rows.Count) { Write-Host '  (no recorded use)' -ForegroundColor DarkGray; return }
    Write-Host ('  {0,-12} {1,-30} {2,-8} {3,-17} {4}' -f 'what', 'app', 'type', 'last started', 'last stopped') -ForegroundColor White
    foreach ($r in $rows) {
        $stopTxt = if ($r.InUse) { 'IN USE NOW' } else { $r.LastStop.ToString('yyyy-MM-dd HH:mm') }
        $col = if ($r.InUse) { 'Yellow' } else { 'Gray' }
        Write-Host ('  {0,-12} {1,-30} {2,-8} {3,-17} {4}' -f $r.Capability, $(if ($r.App.Length -gt 30) { $r.App.Substring(0, 29) + '~' } else { $r.App }), $r.Type, $r.LastStart.ToString('yyyy-MM-dd HH:mm'), $stopTxt) -ForegroundColor $col
    }
}

# =============================================================================
#  Phase 7 (C12): PER-APP PERMISSIONS - STORE APPS ONLY (user decision)
# -----------------------------------------------------------------------------
#  Settings only offers per-app switches for Store (packaged) apps; desktop apps
#  share the "Let desktop apps access..." switch. Per-app values live at
#  HKCU ConsentStore\<cap>\<PackageFamilyName>  Value = Allow|Deny  (journaled).
#  The global switch still wins: if it is Deny, no app gets access.
# =============================================================================
function Get-WHDAppPermissions {
    param([Parameter(Mandatory)][string]$Cap)
    $names = Get-WHDStoreAppNames
    $base = Join-Path $script:WHDConsentHKCU $Cap
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    @(Get-ChildItem -LiteralPath $base -EA SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' } | ForEach-Object {
        $pfn = $_.PSChildName
        [pscustomobject]@{
            Capability = $Cap; Pfn = $pfn
            App = $(if ($names.ContainsKey($pfn)) { $names[$pfn] } else { ($pfn -split '_')[0] })
            Installed = $names.ContainsKey($pfn)
            Value = "$($_.GetValue('Value', '(unset)'))"
        }
    } | Sort-Object App)
}

function Set-WHDAppPermission {
    param([Parameter(Mandatory)][string]$Cap, [Parameter(Mandatory)][string]$Pfn, [ValidateSet('Allow','Deny')][string]$Value)
    Set-WHDRegistryValue -Path (Join-Path (Join-Path $script:WHDConsentHKCU $Cap) $Pfn) -Name 'Value' -Value $Value -Type String | Out-Null
}

function Invoke-WHDAppPermission {
    param([Parameter(Mandatory)][string]$Cap, [Parameter(Mandatory)][object[]]$Apps, [ValidateSet('Allow','Deny')][string]$Value)
    $capName = @($script:WHDCapabilities | Where-Object { $_.Cap -eq $Cap } | ForEach-Object { $_.Name })[0]
    Write-WHDLog ("PER-APP PERMISSION: {0} -> {1} for {2} Store app(s)" -f $capName, $Value, @($Apps).Count) 'ACT'
    Write-WHDRisk 'reversible' 'Same switch as Settings > Privacy & security > (permission) > per-app list. Journaled (Undo center).'
    $global = Get-WHDCapabilityValue -Cap $Cap
    if ($Value -eq 'Allow' -and $global -eq 'Deny') { Write-WHDLog ("Note: the global '{0}' switch is Deny, so the app still gets no access until the global switch allows it." -f $capName) 'WARN' }
    if (-not (Confirm-WHDProceed ("{0} {1} for {2} app(s)" -f $Value.ToLower(), $capName, @($Apps).Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($a in @($Apps)) { Set-WHDAppPermission -Cap $Cap -Pfn $a.Pfn -Value $Value }
}

function Show-WHDPermMenu {
    Write-Host ''
    Write-Host '  APP PERMISSIONS  (Privacy & security > App permissions)' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '  Current global state per capability (HKCU):'
    foreach ($c in $script:WHDCapabilities) {
        $cur = Get-WHDCapabilityValue -Cap $c.Cap
        $col = switch ($cur) { 'Deny' {'Green'} 'Prompt' {'Yellow'} 'Allow' {'Gray'} default {'DarkGray'} }
        Write-WHDParts @(("    {0,-24} " -f $c.Name), @("$cur", $col))
    }
    Write-Host '  ----------------------------------------------------------------'
    Write-Host ('   L. Lock      (deny all + Windows policy lock; camera/mic/radios off, not locked)   [{0}]' -f (Get-WHDPrivacyLockState))
    Write-Host '   1. Lockdown  (deny everything)'
    Write-Host '   2. Balanced  (deny sensitive; libraries prompt)'
    Write-Host '   3. Open      (reset everything to Allow)'
    Write-Host '   4. Custom    (choose per capability)'
    Write-Host '   5. Usage history  (who used camera / microphone / location, and when)'
    Write-Host '   6. Per-app        (Store apps: allow / deny one app at a time)'
    Write-Host '   B. Back'
}
