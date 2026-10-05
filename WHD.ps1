<#
================================================================================
 WinHardenDebloat  -  WHD.ps1   (console launcher)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Menu-driven front end. Self-elevates (UAC). DRY-RUN by default: nothing is
 changed until you switch to EXECUTE mode from the menu (or pass -Execute).

   powershell -ExecutionPolicy Bypass -File .\WHD.ps1
   powershell -ExecutionPolicy Bypass -File .\WHD.ps1 -Execute
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$Execute,     # start in EXECUTE mode (default is dry-run)
    [switch]$Plan,        # non-interactive: print the dry-run plan (AI, apps, privacy, permissions, component store) and exit
    [string]$Apply,       # non-interactive: apply a JSON profile, then exit
    [string]$Export,      # write a starter profile to this path, then exit
    [switch]$Yes,         # skip the one upfront gate when applying (scripted runs)
    [switch]$NoElevate,
    [switch]$Guard,       # run the update-guard check (read-only) and exit (used by the scheduled task)
    [string]$DataRoot     # project folder for reports/journals when running from the protected copy
)

$ErrorActionPreference = 'Stop'

# ---- Windows PowerShell 5.1 only (checked before anything else runs) --------
# The update guard task and the self-elevation below both start/reuse powershell.exe 5.1,
# so they always pass this check.
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host ''
    Write-Host (' WinHardenDebloat (Classic) needs Windows PowerShell 5.1 - this is PowerShell {0}.' -f $PSVersionTable.PSVersion) -ForegroundColor Yellow
    Write-Host ' Start it with powershell.exe (not pwsh):' -ForegroundColor Yellow
    Write-Host '   powershell -ExecutionPolicy Bypass -File .\WHD.ps1' -ForegroundColor Yellow
    exit 1
}

# ---- self-elevation ---------------------------------------------------------
function _isAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $NoElevate -and -not $Guard -and -not (_isAdmin)) {
    Write-Host ''
    Write-Host ' This session is not elevated.' -ForegroundColor Yellow
    if ($Plan -or $Apply -or $Export) {
        # Non-interactive: spawning a separate elevated window is fine.
        Write-Host ' Opening an elevated window to run...' -ForegroundColor Yellow
    } else {
        # Interactive menu: a spawned window causes the focus/second-window
        # problem. Best experience is to run inside an ALREADY-admin terminal.
        Write-Host ''
        Write-Host ' For the interactive menu, the most reliable way is to run this from a' -ForegroundColor Cyan
        Write-Host ' terminal that is ALREADY elevated, so the menu appears in THIS window:' -ForegroundColor Cyan
        Write-Host '   1. Close this window.' -ForegroundColor Cyan
        Write-Host '   2. Start menu > type "PowerShell" > right-click > Run as administrator.' -ForegroundColor Cyan
        Write-Host ('   3. cd "{0}"' -f $PSScriptRoot) -ForegroundColor Cyan
        Write-Host '   4. powershell -ExecutionPolicy Bypass -File .\WHD.ps1' -ForegroundColor Cyan
        Write-Host ''
        $go = Read-Host ' Or press [E] to open an elevated window now, anything else to cancel'
        if ($go -notmatch '^[Ee]$') { return }
    }
    $psExe = (Get-Process -Id $PID).Path
    # -NoExit keeps the elevated window open; it comes to the foreground on UAC accept.
    $argList = @('-NoExit','-ExecutionPolicy','Bypass','-NoProfile','-File', "`"$($MyInvocation.MyCommand.Path)`"",'-NoElevate')
    if ($Execute) { $argList += '-Execute' }
    if ($Plan)    { $argList += '-Plan' }
    if ($Yes)     { $argList += '-Yes' }
    if ($Apply)   { $argList += @('-Apply',  "`"$Apply`"") }
    if ($Export)  { $argList += @('-Export', "`"$Export`"") }
    try { Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList; return }
    catch { Write-Host "Elevation declined: $($_.Exception.Message)" -ForegroundColor Red; return }
}

# ---- load engine + modules --------------------------------------------------
$Root = $PSScriptRoot
$script:WHDRoot    = $Root
$script:WHDCodeRoot = $Root
if ($Guard -and $DataRoot) { $script:WHDRoot = $DataRoot }
$script:WHDExecute = [bool]$Execute
. (Join-Path $Root 'modules\Common.ps1')
. (Join-Path $Root 'modules\Debloat-AI.ps1')
. (Join-Path $Root 'modules\Debloat-General.ps1')
. (Join-Path $Root 'modules\Permissions.ps1')
. (Join-Path $Root 'modules\Debloat-Win32.ps1')
. (Join-Path $Root 'modules\Maintenance.ps1')
. (Join-Path $Root 'modules\Firewall.ps1')
. (Join-Path $Root 'modules\Security.ps1')
. (Join-Path $Root 'modules\Updates.ps1')
. (Join-Path $Root 'modules\Devices.ps1')
. (Join-Path $Root 'modules\TimeRegion.ps1')
. (Join-Path $Root 'modules\Profiles.ps1')
$script:WHDYes = [bool]$Yes
$script:WHDQuit = $false

# ---- Phase 9: update guard (scheduled task) - read-only, no transcript -------
if ($Guard) {
    $script:WHDExecute = $false
    try { Invoke-WHDUpdateGuard | Out-Null }
    catch {
        try {
            $gd = Join-Path $script:WHDRoot 'restore\update-guard'
            if (-not (Test-Path -LiteralPath $gd)) { New-Item -ItemType Directory -Path $gd -Force | Out-Null }
            ("{0}  guard error: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message) | Add-Content -LiteralPath (Join-Path $gd 'guard-errors.txt') -Encoding UTF8
        } catch {}
    }
    return
}
try { Start-WHDTranscript } catch { $startErr = $_; Write-WHDProtectedFolderWarning; throw $startErr }   # if the WHD folder cannot be written, say why first
Update-WHDGuardIfStale
Write-WHDAccountWarning   # never reached in guard mode (returned above)
Write-WHDProtectedFolderWarning
try { $Host.UI.RawUI.WindowTitle = 'WinHardenDebloat (Administrator) - type in this window' } catch {}
$elevated = _isAdmin

# ---- non-interactive: export a starter profile, then exit -------------------
if ($Export) {
    Export-WHDProfile -Path $Export
    Stop-WHDTranscript
    return
}
# ---- non-interactive: apply a profile, then exit ----------------------------
if ($Apply) {
    Invoke-WHDApplyProfile -Path $Apply
    Stop-WHDTranscript
    Write-WHDLog 'Apply finished. See logs\ for the full transcript.' 'OK'
    return
}

# ---- non-interactive plan (no Read-Host anywhere) ---------------------------
function Invoke-WHDPlanAll {
    $script:WHDExecute = $false   # -Plan is always a preview
    Write-WHDLog '================ DRY-RUN PLAN (AI, apps, privacy, permissions, component store) - no changes ================' 'DRY'
    foreach ($m in $script:WHDAiModules) {
        $p = Get-WHDModulePresence -Module $m
        Write-Host ''
        Write-Host ("### {0}   [{1}]" -f $m.Name, $(if($p.Installed){'present'}else{'absent'})) -ForegroundColor White
        Invoke-WHDAiFeatureOff -Module $m
        Invoke-WHDAiRemove     -Module $m
    }
    Write-Host ''
    Invoke-WHDStoreSuppression
    Write-Host ''
    Write-WHDLog '---- GENERAL (non-AI) apps ----' 'DRY'
    foreach ($e in $script:WHDGeneralApps) {
        $gp = Test-WHDAppPresent -Package $e.Package
        Write-Host ("### {0}   [{1}]{2}" -f $e.Name, $(if($gp){'present'}else{'absent'}), $(if($e.Rec){'  *recommended'}else{''})) -ForegroundColor White
        Invoke-WHDGeneralRemove -Entry $e
    }
    Write-Host ''
    Invoke-WHDPrivacyHardening
    Invoke-WHDDisableDiagTrack
    Write-Host ''
    Write-WHDLog '---- APP PERMISSIONS (Balanced profile shown as example) ----' 'DRY'
    Invoke-WHDPermissionProfile -Profile 'Balanced'
    Write-Host ''
    Write-WHDLog '---- COMPONENT STORE (analysis is read-only; cleanup shown as plan) ----' 'DRY'
    Invoke-WHDComponentAnalyze
    Invoke-WHDComponentCleanup
    Write-Host ''
    Write-WHDLog '---- FIREWALL (current state, read-only) ----' 'DRY'
    Show-WHDFirewallSummary
    Write-WHDLog '================ END PLAN ================' 'DRY'
}
if ($Plan) {
    Invoke-WHDPlanAll
    Stop-WHDTranscript
    Write-WHDLog 'Plan written to logs\. No changes were made.' 'OK'
    return
}

function Show-WHDMode {
    if ($script:WHDExecute) {
        Write-Host ''
        Write-Host '  *** EXECUTE MODE - changes WILL be applied (with confirm + restore point) ***' -ForegroundColor Red
    } else {
        Write-Host ''
        Write-Host '  --- DRY-RUN MODE - nothing changes; actions are only previewed ---' -ForegroundColor Cyan
    }
    $gtx = if (Get-Command Get-WHDGuardStatus -EA SilentlyContinue) { (Get-WHDGuardStatus).Text } else { '?' }
    Write-Host ('  GU = refresh update guard (works in every menu)   guard: {0}' -f $gtx) -ForegroundColor DarkGray
}

function Show-WHDMain {
    Write-Host ''
    Write-Host '  ================= WinHardenDebloat =================' -ForegroundColor White
    Write-Host '  Provided as is, with no warranty (MIT License) - use at your own risk. Dry run first.' -ForegroundColor DarkGray
    Write-Host ('  Root: {0}' -f $script:WHDRoot) -ForegroundColor DarkGray
    if (-not $elevated) { Write-Host '  (NOT elevated - inventory/removal will be limited)' -ForegroundColor Yellow }
    Write-Host '  Type a number/letter below and press Enter.' -ForegroundColor DarkGray
    Show-WHDMode
    Write-Host ''
    Write-Host '   1. Run inventory (read-only)'
    Write-Host '   2. AI debloat        (feature-off / remove, per surface)'
    Write-Host '   3. General debloat   (non-AI Store apps + privacy/telemetry)'
    Write-Host '   4. App permissions   (Lockdown / Balanced / Open / Custom)'
    Write-Host '   5. Win32 programs     (uninstall + block re-appearance)'
    Write-Host '   6. Component store    (WinSxS analyze / cleanup via DISM)'
    Write-Host '   9. Firewall           (IPv6 off / clean listing / allow-list / block lists from your own files)'
    Write-Host '   S. Security+          (Defender, attack-surface rules, old protocols, UAC, report)'
    Write-Host '   W. Updates            (update gate, Windows Update / driver / Store policies, app updaters)'
    Write-Host '   N. Devices            (Bluetooth network, Wi-Fi Direct adapters, WAN Miniports)'
    Write-Host '   T. Time & region      (time zone, set date and time)'
    Write-Host '   7. Create a System Restore point now'
    Write-Host ('   8. Toggle mode  (currently: {0})' -f $(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'}))
    Write-Host '   P. Apply a profile      E. Export starter profile'
    Write-Host '   D. Compare inventory scans (what changed)'
    Write-Host '   U. Undo center (list / undo past changes)'
    Write-Host '   V. Verify changes are still in place'
    Write-Host '   Q. Quit'
    Write-Host ''
}

function Invoke-WHDAiSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDAiMenu
        Write-Host ''
        $c = (Read-Host '  Select # (then f=feature-off / r=remove), S, or B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^[Ss]$') { Invoke-WHDStoreSuppression; continue }
        if ($c -match '^\d+$') {
            $idx = [int]$c - 1
            if ($idx -lt 0 -or $idx -ge $script:WHDAiModules.Count) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
            $m = $script:WHDAiModules[$idx]
            $act = (Read-Host ("  [{0}]  f = feature-off,  r = remove,  c = cancel" -f $m.Name)).Trim()
            switch -regex ($act) {
                '^[Ff]$' { Invoke-WHDAiFeatureOff -Module $m }
                '^[Rr]$' { Invoke-WHDAiRemove     -Module $m }
                default  { Write-Host '  cancelled.' -ForegroundColor DarkGray }
            }
        } else { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
}

function Invoke-WHDGeneralSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDGeneralMenu
        Write-Host ''
        $c = (Read-Host '  Select # to remove, A / P / D / S, or B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^[Ss]$') { Invoke-WHDPrivacySubmenu; continue }
        if ($c -match '^[Aa]$') { Invoke-WHDRemoveRecommended; continue }
        if ($c -match '^[Pp]$') { Invoke-WHDPrivacyHardening;  continue }
        if ($c -match '^[Dd]$') { Invoke-WHDDisableDiagTrack;  continue }
        if ($c -match '^\d+$') {
            $idx = [int]$c - 1
            if ($idx -lt 0 -or $idx -ge @($script:WHDGenCatalog).Count) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
            Invoke-WHDGeneralRemove -Entry $script:WHDGenCatalog[$idx]
        } else { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
}

function Invoke-WHDPrivacySubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDPrivacyMenu
        $c = (Read-Host '  Select # / A / B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        if ($c -match '^[Bb]$' -or -not $c) { return }
        if ($c -match '^[Aa]$') { foreach ($it in $script:WHDPrivacyItems) { Invoke-WHDPrivacyItem -Item $it }; continue }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $script:WHDPrivacyItems.Count) { Invoke-WHDPrivacyItem -Item $script:WHDPrivacyItems[[int]$c - 1]; continue }
        Write-Host '  invalid.' -ForegroundColor Yellow
    }
}

function Invoke-WHDPerAppSubmenu {
    $i = 0
    Write-Host ''
    Write-Host '  PER-APP PERMISSIONS (Store apps)  - pick a permission:' -ForegroundColor White
    foreach ($cp in $script:WHDCapabilities) { $i++; Write-Host ("  {0,2}. {1,-24} global: {2}" -f $i, $cp.Name, (Get-WHDCapabilityValue -Cap $cp.Cap)) }
    $c = (Read-Host '  Select # (Enter = back)').Trim()
    if ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $script:WHDCapabilities.Count) { return }
    $cap = $script:WHDCapabilities[[int]$c - 1]
    while ($true) {
        $apps = @(Get-WHDAppPermissions -Cap $cap.Cap)
        Write-Host ''
        Write-Host ("  {0} - Store apps that asked for it   (global switch: {1})" -f $cap.Name, (Get-WHDCapabilityValue -Cap $cap.Cap)) -ForegroundColor White
        if (-not $apps.Count) { Write-Host '  (no Store apps have requested this permission)' -ForegroundColor DarkGray; return }
        $j = 0
        foreach ($a in $apps) {
            $j++
            $col = switch ($a.Value) { 'Deny' { 'Green' } 'Allow' { 'Yellow' } default { 'Gray' } }
            Write-Host ("  {0,3}. {1,-40} " -f $j, $(if ($a.Installed) { $a.App } else { $a.App + ' (not installed)' })) -NoNewline
            Write-Host $a.Value -ForegroundColor $col
        }
        $pick = (Read-Host '  #(s) then a=allow / d=deny  (e.g. "3 d" or "1,4 a"), Enter = back').Trim()
        if (-not $pick) { return }
        if ($pick -notmatch '^([\d,\s]+)\s+([AaDd])$') { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
        $nums = @($matches[1] -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 1 -and $_ -le $apps.Count })
        $val = if ($matches[2] -match '[Aa]') { 'Allow' } else { 'Deny' }
        if ($nums.Count) { Invoke-WHDAppPermission -Cap $cap.Cap -Apps @($nums | ForEach-Object { $apps[$_ - 1] }) -Value $val }
    }
}

function Invoke-WHDPermSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDPermMenu
        Write-Host ''
        $c = (Read-Host '  Select L, 1-6 or B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^5$'   { Show-WHDCapabilityUsage }
            '^6$'   { Invoke-WHDPerAppSubmenu }
            '^[Ll]$'{ Invoke-WHDPrivacyLock }
            '^1$'   { Invoke-WHDPermissionProfile -Profile 'Lockdown' }
            '^2$'   { Invoke-WHDPermissionProfile -Profile 'Balanced' }
            '^3$'   { Invoke-WHDPermissionProfile -Profile 'Open' }
            '^4$'   { Invoke-WHDPermissionCustom }
            '^[Bb]$'{ return }
            default { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

function Invoke-WHDWin32Submenu {
    while ($true) {
        Show-WHDMode
        Show-WHDWin32Menu
        Write-Host ''
        $c = (Read-Host '  Select # to uninstall, or F / R / X / B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        if ($c -match '^[Bb]$') { return }
        if ($c -match '^[Ff]$') { $n = (Read-Host '  App name to find').Trim(); if ($n) { Find-WHDApp -Name $n | Out-Null }; continue }
        if ($c -match '^[Rr]$') { $n = (Read-Host '  App name to remove everywhere').Trim(); if ($n) { Remove-WHDAppEverywhere -Name $n }; continue }
        if ($c -match '^[Xx]$') { $n = (Read-Host '  .exe name to block (e.g. LogiDownloadAssistant.exe)').Trim(); if ($n) { Block-WHDExecutable -ExeName $n }; continue }
        if ($c -match '^\d+$') {
            $idx = [int]$c - 1
            if ($idx -lt 0 -or $idx -ge $script:WHDWin32Cache.Count) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
            Invoke-WHDWin32Uninstall -App $script:WHDWin32Cache[$idx] | Out-Null
        } else { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
}

function Invoke-WHDMaintenanceSubmenu {
    while ($true) {
        Show-WHDMode
        Show-WHDMaintenanceMenu
        Write-Host ''
        $c = (Read-Host '  Select A / C / R / B').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        switch -regex ($c) {
            '^[Aa]$' { Invoke-WHDComponentAnalyze }
            '^[Cc]$' { Invoke-WHDComponentCleanup }
            '^[Rr]$' { Invoke-WHDComponentCleanup -ResetBase }
            '^[Bb]$' { return }
            default  { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

# ---- Phase 5: Undo center ----------------------------------------------------
function Invoke-WHDUndoSubmenu {
    while ($true) {
        Show-WHDMode
        $sessions = @(Get-WHDUndoSessions)
        Write-Host ''
        Write-Host '  UNDO CENTER - sessions with recorded changes or backups (newest first)' -ForegroundColor White
        Write-Host '  ----------------------------------------------------------------'
        if (-not $sessions.Count) { Write-Host '  (nothing recorded yet)'; Write-Host '   B. Back'; }
        $i = 0
        foreach ($s in $sessions) { $i++; Write-Host ("  {0,3}. {1}" -f $i, $s.Label) }
        Write-Host '  ----------------------------------------------------------------'
        $hiddenN = @(Get-WHDUndoSessions -IncludeOtherPCs | Where-Object { $_.Owner -in @('other','legacy-other') }).Count
        Write-Host '   #. Open a session     B. Back'
        Write-Host ('   H. History from other PCs / previous Windows installs: {0} hidden -> archive + tag the current PC''s sessions' -f $hiddenN)
        $c = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $c) { continue }
        if ($c -match '^[Bb]$' -or -not $c) { return }
        if ($c -match '^[Hh]$') { Invoke-WHDArchiveOtherHistory; continue }
        if ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $sessions.Count) { Write-Host '  invalid.' -ForegroundColor Yellow; continue }
        $sess = $sessions[[int]$c - 1]
        while ($true) {
            $entries = @(Get-WHDJournal -SessionPath $sess.Path)
            Write-Host ''
            Write-Host ("  SESSION {0}" -f $sess.Stamp) -ForegroundColor White
            Write-Host '  [auto] = can be undone automatically   [manual] = see hint   [undone] = already undone' -ForegroundColor DarkGray
            if ($entries.Count) { Show-WHDUndoEntries -Entries $entries } else { Write-Host '  (no journal - this session is from before the change journal existed; use its backups below)' }
            Write-Host ''
            Write-Host '   #   Undo one change (e.g. 3, or 3,5,7)'
            Write-Host '   A.  Undo ALL automatic changes in this session (newest first)'
            if ($sess.HasWfw)   { Write-Host '   F.  Restore the firewall saved before this session' }
            if ($sess.HasHosts) { Write-Host '   H.  Restore the hosts file saved before this session' }
            if ($sess.RegFiles) { Write-Host ('   R.  Import this session''s {0} .reg backup(s)  (older sessions)' -f $sess.RegFiles) }
            Write-Host '   V.  Verify this session''s changes are still in place'
            Write-Host '   B.  Back'
            $a = (Read-Host '  Select').Trim()
            if ($a -match '^[Bb]$' -or -not $a) { break }
            switch -regex ($a) {
                '^[Aa]$' { Invoke-WHDUndoSession -SessionPath $sess.Path }
                '^[Ff]$' { Restore-WHDSessionFirewall -SessionPath $sess.Path }
                '^[Hh]$' { Restore-WHDSessionHosts -SessionPath $sess.Path }
                '^[Rr]$' { Import-WHDLegacyRegBackups -SessionPath $sess.Path }
                '^[Vv]$' { Invoke-WHDVerify -SessionPath $sess.Path | Out-Null }
                '^[\d,\s]+$' {
                    $pick = @($a -split '[,\s]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } |
                              Where-Object { $_ -ge 1 -and $_ -le $entries.Count } | ForEach-Object { $entries[$_ - 1] })
                    if ($pick.Count) { Invoke-WHDUndo -Entries $pick } else { Write-Host '  invalid.' -ForegroundColor Yellow }
                }
                default { Write-Host '  invalid.' -ForegroundColor Yellow }
            }
        }
    }
}

# ---- main loop --------------------------------------------------------------
# Labeled loop so 'Q' can break the WHILE (a bare 'break' only exits the switch).
try {
    :mainloop while ($true) {
        Show-WHDMain
        $choice = (Read-Host '  Select').Trim()
        if (Invoke-WHDGuardHotkey $choice) { continue }
        # An error in one menu action must not end the session: report it and show the menu again.
        # ('break mainloop' still leaves the loop from inside this try; the switch keeps its indentation.)
        try {
        switch -regex ($choice) {
            '^1$' {
                $inv = Join-Path $script:WHDRoot 'Inventory.ps1'
                if (Test-Path $inv) { & $inv -NoElevate } else { Write-WHDLog 'Inventory.ps1 not found at root.' 'ERR' }
            }
            '^2$' { Invoke-WHDAiSubmenu }
            '^3$' { Invoke-WHDGeneralSubmenu }
            '^4$' { Invoke-WHDPermSubmenu }
            '^5$' { Invoke-WHDWin32Submenu }
            '^6$' { Invoke-WHDMaintenanceSubmenu }
            '^9$' { Invoke-WHDFirewallSubmenu; if ($script:WHDQuit) { break mainloop } }
            '^7$' { New-WHDCheckpointNow }
            '^8$' {
                $script:WHDExecute = -not $script:WHDExecute
                Write-WHDLog ("mode -> {0}" -f $(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'})) 'ACT'
                if ($script:WHDExecute) {
                    Write-Host '  You just enabled EXECUTE mode. Each action still asks y/N and a restore point is made first.' -ForegroundColor Yellow
                }
            }
            '^[Pp]$' {
                $def = Join-Path $script:WHDRoot 'profiles\lean.json'
                $pp = (Read-Host ("  Profile path [{0}]" -f $def)).Trim().Trim('"')
                if (-not $pp) { $pp = $def }
                Invoke-WHDApplyProfile -Path $pp
            }
            '^[Ee]$' {
                $def = Join-Path $script:WHDRoot 'profiles\lean.json'
                $pp = (Read-Host ("  Export starter profile to [{0}]" -f $def)).Trim().Trim('"')
                if (-not $pp) { $pp = $def }
                Export-WHDProfile -Path $pp
            }
            '^[Dd]$' {
                $inv = Join-Path $script:WHDRoot 'Inventory.ps1'
                if (Test-Path $inv) { & $inv -Compare -NoElevate | ForEach-Object { Write-Host $_ } } else { Write-WHDLog 'Inventory.ps1 not found at root.' 'ERR' }
            }
            '^[Uu]$' { Invoke-WHDUndoSubmenu }
            '^[Ss]$' { Invoke-WHDSecuritySubmenu }
            '^[Ww]$' { Invoke-WHDUpdatesSubmenu }
            '^[Nn]$' { Invoke-WHDDevicesSubmenu }
            '^[Tt]$' { Invoke-WHDTimeRegionSubmenu }
            '^[Vv]$' {
                $vr = @(Invoke-WHDVerify -All)
                if (@($vr | Where-Object { $_.Result -eq 'RETURNED' -and "$($_.Entry.Kind)" -in @('appx','provisioned') }).Count) { Invoke-WHDReRemoveReturned -Results $vr }
                if (@($vr | Where-Object { $_.Result -eq 'CHANGED' }).Count) { Invoke-WHDReApplyChanged -Results $vr }
            }
            '^[Qq]$' { Write-WHDLog 'Quit selected.' 'INFO'; break mainloop }
            default  { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
        } catch { Write-WHDLog ("error: {0} - back at the main menu." -f $_.Exception.Message) 'ERR' }
    }
}
finally {
    Stop-WHDTranscript
    Write-Host ''
    Write-WHDLog 'Session ended.' 'INFO'
}
