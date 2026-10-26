#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/ThemeEvent.ps1   (theme part c)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 5.10c. Same features as WHD Next 2.0 (D8), written new for 7.6:
   7  lock screen: the WHD pictures as Windows' own lock-screen slide show
      (D73). WHD brings the picture folder up to date, copies its path to the
      clipboard and opens Settings > Personalization > Lock screen; you choose
      "Slideshow" and add the folder once. Windows rotates the pictures itself.
      No helper, no tasks, no Windows PowerShell 5.1.
   8  put back: opens the same page; you choose "Picture" or
      "Windows spotlight". WHD cannot read this setting, so it never guesses.
   9  sounds at sign-in, lock and unlock (D74): three scheduled tasks in
      \WinHardenDebloatNext3\ start a small PowerShell 7.6 script as you,
      WITHOUT administrator rights, that plays the sound. A console window
      may flash for an instant. No sign-out / shut-down sound (D76): Task
      Scheduler does not start tasks while Windows signs out or shuts down
      (seen on the test PC, P42) - 9 and 10 remove those two tasks if present.
  10  switch them off: the three tasks are removed.
   A  everything on: sound files if missing, 3, 9, 5, 7 - one question.
   Z  everything put back: 10, 4, 6, 8 - one question.
 7, 9, 10, A and Z also remove WHD Next 2.0's five theme tasks
 (\WinHardenDebloatNext\Theme*) so 2.0 stops playing its sounds and changing
 the lock screen (D75). 2.0's files are not touched.
================================================================================
#>

$script:WHDEvTaskPath  = '\WinHardenDebloatNext3\'
$script:WHDEvTasks     = [ordered]@{ 'Sound-SignIn' = 'signin'; 'Sound-Lock' = 'lock'; 'Sound-Unlock' = 'unlock' }
$script:WHDEvGone      = @('Sound-SignOut', 'Sound-ShutDown')    # dropped (D76): removed by 9 and 10 when present
$script:WHDEvOldPath   = '\WinHardenDebloatNext\'
$script:WHDEvOldTasks  = @('ThemeSignIn', 'ThemeLock', 'ThemeUnlock', 'ThemeSignOut', 'ThemeShutDown')   # WHD Next 2.0's theme tasks (D75)
$script:WHDEvPlayer    = 'Invoke-WHDThemeEvent.ps1'
$script:WHDEvLockPage  = 'ms-settings:lockscreen'

# ---- places ------------------------------------------------------------------------------------------
function Get-WHDEvPlayerSource {
    # The player script shipped with WHD Next 3.0: <WHD folder>\tools\Invoke-WHDThemeEvent.ps1.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::Combine($script:WHDState.Root, 'tools', $script:WHDEvPlayer)
}
function Get-WHDEvPlayerFile {
    # Where the tasks start it from: next to the sounds, in ProgramData (only administrators can change it).
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $b = Get-WHDThemeBase; if (-not $b) { return '' }
    return [System.IO.Path]::Combine($b, $script:WHDEvPlayer)
}
function Get-WHDEvPwsh {
    # The PowerShell 7 the tasks start: the one WHD runs in.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $p = [Environment]::ProcessPath
    if ($p -and [System.IO.Path]::GetFileNameWithoutExtension($p) -eq 'pwsh') { return $p }
    return [System.IO.Path]::Combine($PSHOME, 'pwsh.exe')
}
# ---- Windows itself (tests swap these) -----------------------------------------------------------------
function Get-WHDEvTask {
    # One task, or $null. (No [0] on the list: strict mode stops on an empty one - seen on the test PC, P38.)
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    return (Get-ScheduledTask -TaskPath $Path -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $Name } | Select-Object -First 1)
}
function Register-WHDEvTask {
    # One task: starts the player as the signed-in user, WITHOUT administrator rights, window hidden.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$What, [Parameter(Mandatory)][string]$Pwsh, [Parameter(Mandatory)][string]$Player)
    if (-not $PSCmdlet.ShouldProcess(($script:WHDEvTaskPath + $Name), 'register')) { return }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $act = New-ScheduledTaskAction -Execute $Pwsh -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -What {1}' -f $Player, $What)
    if ($What -eq 'signin') { $trig = New-ScheduledTaskTrigger -AtLogOn -User $user }
    else {
        # session state change: 7 = workstation lock, 8 = workstation unlock (Task Scheduler reference)
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger' -ErrorAction Stop
        $trig = New-CimInstance -CimClass $cls -ClientOnly -Property @{ StateChange = [uint32]$(if ($What -eq 'lock') { 7 } else { 8 }); UserId = $user; Enabled = $true }
    }
    $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskPath $script:WHDEvTaskPath -TaskName $Name -Action $act -Trigger $trig -Principal $prin -Settings $set `
        -Description ('WHD Next 3.0 theme (optional): plays the {0} sound. Runs as the signed-in user without administrator rights. Theme menu > 10 removes it.' -f $What) -Force -ErrorAction Stop | Out-Null
}
function Unregister-WHDEvTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if (-not $PSCmdlet.ShouldProcess(($Path + $Name), 'remove')) { return }
    if (Get-WHDEvTask -Path $Path -Name $Name) { Unregister-ScheduledTask -TaskPath $Path -TaskName $Name -Confirm:$false -ErrorAction Stop }
}
function Open-WHDEvLockPage {
    [CmdletBinding()]
    param()
    Start-Process -FilePath $script:WHDEvLockPage -ErrorAction Stop
}
function Set-WHDEvClipboard {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Text)
    if (-not $PSCmdlet.ShouldProcess('clipboard', 'copy the folder path')) { return }
    Set-Clipboard -Value $Text -ErrorAction Stop
}

# ---- read-only state ----------------------------------------------------------------------------------------
function Get-WHDEvState {
    # The three 3.0 tasks, the two dropped ones (D76) and 2.0's five: how many are there.
    [CmdletBinding()]
    param()
    $o = [ordered]@{ Readable = $true; Have = 0; Gone = 0; Old = 0; Text = ''; OldText = ''; Why = '' }
    try {
        foreach ($n in $script:WHDEvTasks.Keys) { if (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $n) { $o.Have++ } }
        foreach ($n in $script:WHDEvGone) { if (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $n) { $o.Gone++ } }
        foreach ($n in $script:WHDEvOldTasks) { if (Get-WHDEvTask -Path $script:WHDEvOldPath -Name $n) { $o.Old++ } }
    } catch { $o.Readable = $false; $o.Why = $_.Exception.Message }
    $all = $script:WHDEvTasks.Count
    $o.Text = if (-not $o.Readable) { 'not readable' } elseif ($o.Have -eq $all) { 'on' } elseif ($o.Have) { ('only {0} of {1} tasks - choose 9 again' -f $o.Have, $all) } else { 'off' }
    $notes = @()
    if ($o.Gone) { $notes += ('{0} sign-out / shut-down task(s) are still there' -f $o.Gone) }
    if ($o.Old) { $notes += ('{0} of WHD Next 2.0''s theme tasks are still there' -f $o.Old) }
    $o.OldText = $notes -join '; '
    return [pscustomobject]$o
}

# ---- helpers that only the change gate calls ------------------------------------------------------------------
function Remove-WHDEvOldTask {
    # WHD Next 2.0's five theme tasks (D75). Returns how many were removed.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:WHDEvOldPath, 'remove WHD Next 2.0''s theme tasks')) { return 0 }
    $n = 0
    foreach ($t in $script:WHDEvOldTasks) {
        if (Get-WHDEvTask -Path $script:WHDEvOldPath -Name $t) { Unregister-WHDEvTask -Path $script:WHDEvOldPath -Name $t -Confirm:$false; $n++ }
    }
    foreach ($t in $script:WHDEvOldTasks) { if (Get-WHDEvTask -Path $script:WHDEvOldPath -Name $t) { throw ('read-back: WHD Next 2.0''s task {0}{1} is still there' -f $script:WHDEvOldPath, $t) } }
    if ($n) { Write-WHDLog -Message ('WHD Next 2.0''s theme tasks removed: {0} (its files stay).' -f $n) }
    return $n
}
function Remove-WHDEvGoneTask {
    # The sign-out / shut-down tasks of the first 5.10c build (D76). Returns how many were removed.
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:WHDEvTaskPath, 'remove the sign-out / shut-down tasks')) { return 0 }
    $n = 0
    foreach ($t in $script:WHDEvGone) {
        if (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $t) { Unregister-WHDEvTask -Path $script:WHDEvTaskPath -Name $t -Confirm:$false; $n++ }
    }
    foreach ($t in $script:WHDEvGone) { if (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $t) { throw ('read-back: the task {0}{1} is still there' -f $script:WHDEvTaskPath, $t) } }
    if ($n) { Write-WHDLog -Message ('Sign-out / shut-down tasks removed: {0} (D76 - Windows never started them).' -f $n) }
    return $n
}
function Copy-WHDEvPlayer {
    # The player into ProgramData (only when missing or different).
    [CmdletBinding()]
    param()
    $dst = Get-WHDEvPlayerFile
    $d = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
    if (Copy-WHDLookPicture -From (Get-WHDEvPlayerSource) -To $dst) { Write-WHDLog -Message ('Player copied: {0}' -f $dst) }
}

# ---- 7. lock screen: Windows' own slide show with the WHD pictures (D73) ----------------------------------------
function Invoke-WHDEvLockApply {
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message 'THEME 7: lock screen - the WHD pictures as Windows'' lock-screen slide show' -Level 'ACT'
    if (-not (Get-WHDThemeBase)) { Write-WHDLog -Message 'No ProgramData folder on this PC - the pictures have no place.' -Level 'ERR'; return }
    $st = Get-WHDLookState
    if (-not $st.Ours) { Write-WHDLog -Message ('The WHD pictures were not found in {0}.' -f (Get-WHDLookPictureSource)) -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message ('Needs an administrator window: the pictures go into {0}.' -f (Get-WHDThemeBase)) -Level 'WARN'; return }
    $dir = Get-WHDLookDir -What slideshow
    $ev = Get-WHDEvState
    Write-WHDRisk -Tier 'reversible' -Text ('Brings the picture folder {0} up to date ({1}), copies its path to the clipboard and opens Settings > Personalization > Lock screen. There you choose "Slideshow" and add that folder (Browse, paste the path) - Windows then changes the lock-screen picture by itself; the sign-in box shows the same picture. WHD changes no lock-screen setting itself and cannot read it. {2}Theme menu > 8 opens the same page to put it back.' -f $dir, $st.PicText, $(if ($ev.Old) { ('WHD Next 2.0''s {0} theme tasks are removed (D75). ' -f $ev.Old) } else { '' }))
    if (-not (Confirm-WHDProceed -What 'use the WHD pictures on the lock screen')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('theme: lock-screen slide show with the WHD pictures ({0})' -f $dir) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 8 opens Settings > Lock screen: choose "Picture" or "Windows spotlight"' } -Action {
        $pics = Sync-WHDLookPicture
        if (-not $pics.List.Count) { throw 'no pictures for the slide show' }
        Write-WHDLog -Message ('Picture folder: {0} WHD pictures + {1} of your own in {2}.' -f $pics.Whd, $pics.Own, $pics.Dir)
        [void](Remove-WHDEvOldTask -Confirm:$false)
        $clip = $true
        try { Set-WHDEvClipboard -Text $pics.Dir -Confirm:$false } catch { $clip = $false; Write-WHDLog -Message ('The clipboard could not be used ({0}) - type the path by hand.' -f $_.Exception.Message) -Level 'WARN' }
        try { Open-WHDEvLockPage } catch { Write-WHDLog -Message ('Settings did not open ({0}) - open Settings > Personalization > Lock screen by hand.' -f $_.Exception.Message) -Level 'WARN' }
        Write-Host '    1. Settings > Personalization > Lock screen: "Personalize your lock screen" -> Slideshow.' -ForegroundColor Yellow
        Write-Host ('    2. "Add a folder" (Browse photos) -> {0}' -f $(if ($clip) { 'paste the path into the folder box (Ctrl+V) and choose "Choose this folder".' } else { 'go to the folder below and choose "Choose this folder".' })) -ForegroundColor Yellow
        Write-Host ('       {0}' -f $pics.Dir) -ForegroundColor Cyan
        Write-Host '    3. Under the slide show''s advanced settings, UNCHECK "Only use pictures that fit my screen" - otherwise Windows may skip them all (P41).' -ForegroundColor Yellow
        Write-Host '    4. Remove other folders from the slide-show list if you want only these pictures; lock (Windows key + L) to see it.' -ForegroundColor Yellow
        [void](& $ask '  Press Enter when done (or right away to do it later)')
        $script:WHDState.ChangeNote = 'done by hand in Settings - WHD cannot read it'
    } | Out-Null
}

# ---- 8. put the lock screen back --------------------------------------------------------------------------------
function Invoke-WHDEvLockRemove {
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    Write-WHDLog -Message 'THEME 8: put back the lock screen' -Level 'ACT'
    if (-not (Test-WHDRealChange)) { Write-WHDLog -Message 'would: open Settings > Personalization > Lock screen, where you choose "Picture" or "Windows spotlight" (WHD changes nothing itself).' -Level 'DRY'; return }
    try { Open-WHDEvLockPage } catch { Write-WHDLog -Message ('Settings did not open ({0}) - open Settings > Personalization > Lock screen by hand.' -f $_.Exception.Message) -Level 'WARN' }
    Write-Host '    Settings > Personalization > Lock screen: "Personalize your lock screen" -> Windows spotlight or Picture.' -ForegroundColor Yellow
    Write-Host ('    The WHD pictures stay in {0}; choose 7 to use them again.' -f (Get-WHDLookDir -What slideshow)) -ForegroundColor DarkGray
    [void](& $ask '  Press Enter when done')
    Write-WHDLog -Message 'Lock screen: Settings opened to put it back (WHD cannot read this setting).'
}

# ---- 9. sounds at sign-in, lock and unlock (D74, D76) -------------------------------------------------------------
function Invoke-WHDEvSoundApply {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'THEME 9: sounds at sign-in, lock and unlock' -Level 'ACT'
    if (-not (Get-WHDThemeBase)) { Write-WHDLog -Message 'No ProgramData folder on this PC - the theme has no place.' -Level 'ERR'; return }
    $miss = @($script:WHDEvTasks.Values | Where-Object { -not (Test-Path -LiteralPath (Get-WHDThemeSoundFile $_)) })
    if ($miss.Count) { Write-WHDLog -Message ('Sound files are missing ({0}) - choose 1 first.' -f ($miss -join ', ')) -Level 'WARN'; return }
    if (-not (Test-Path -LiteralPath (Get-WHDEvPlayerSource))) { Write-WHDLog -Message ('The player was not found: {0}' -f (Get-WHDEvPlayerSource)) -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window: the player goes into ProgramData and scheduled tasks are added.' -Level 'WARN'; return }
    $ev = Get-WHDEvState
    if (-not $ev.Readable) { Write-WHDLog -Message ('The scheduled tasks could not be read: {0}' -f $ev.Why) -Level 'ERR'; return }
    $pwsh = Get-WHDEvPwsh
    $player = Get-WHDEvPlayerFile
    $extra = ''
    if ($ev.Gone) { $extra += (' The {0} sign-out / shut-down task(s) are removed (D76).' -f $ev.Gone) }
    if ($ev.Old) { $extra += (' WHD Next 2.0''s {0} theme tasks are removed (D75).' -f $ev.Old) }
    Write-WHDRisk -Tier 'reversible' -Text ('Plays a WHD sound for this user ({0}) at sign-in, lock and unlock. Three scheduled tasks in {1} ({2}) start {3} with {4} as you, WITHOUT administrator rights; a console window may flash for an instant, and the sound comes a moment after the event. No sound at sign-out or shut-down: Windows does not start tasks then (D76). If PowerShell 7 moves to another folder, choose 9 again.{5} Theme menu > 10 switches them off.' -f $env:USERNAME, $script:WHDEvTaskPath, (@($script:WHDEvTasks.Keys) -join ', '), $player, $pwsh, $extra)
    if (-not (Confirm-WHDProceed -What 'play sounds at sign-in, lock and unlock')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('theme: sounds at sign-in, lock and unlock (3 tasks in {0})' -f $script:WHDEvTaskPath) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 10 switches the sounds at sign-in / lock / unlock off' } -Action {
        Copy-WHDEvPlayer
        [void](Remove-WHDEvOldTask -Confirm:$false)
        [void](Remove-WHDEvGoneTask -Confirm:$false)
        foreach ($n in $script:WHDEvTasks.Keys) { Register-WHDEvTask -Name $n -What $script:WHDEvTasks[$n] -Pwsh $pwsh -Player $player -Confirm:$false }
        foreach ($n in $script:WHDEvTasks.Keys) { if (-not (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $n)) { throw ('read-back: the task {0}{1} is not there' -f $script:WHDEvTaskPath, $n) } }
        Write-WHDLog -Message 'Try it: lock (Windows key + L) and unlock. What the player did is written to %LOCALAPPDATA%\WinHardenDebloatNext\app\theme\events.log.'
    } | Out-Null
}

# ---- 10. switch them off ------------------------------------------------------------------------------------------
function Invoke-WHDEvSoundRemove {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'THEME 10: sounds at sign-in, lock and unlock - off' -Level 'ACT'
    $ev = Get-WHDEvState
    if (-not $ev.Readable) { Write-WHDLog -Message ('The scheduled tasks could not be read: {0}' -f $ev.Why) -Level 'ERR'; return }
    if (-not ($ev.Have -or $ev.Gone -or $ev.Old)) { Write-WHDLog -Message 'The sounds at sign-in, lock and unlock are off, and none of WHD Next 2.0''s theme tasks are there - nothing to do.' -Level 'OK'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window: scheduled tasks are removed.' -Level 'WARN'; return }
    $all = $ev.Have + $ev.Gone
    Write-WHDRisk -Tier 'reversible' -Text ('Removes the {0} task(s) in {1} that play the theme sounds for this user ({2}).{3} The sound files and the player stay; choose 9 to switch them on again.' -f $all, $script:WHDEvTaskPath, $env:USERNAME, $(if ($ev.Old) { (' WHD Next 2.0''s {0} theme tasks are removed too (D75).' -f $ev.Old) } else { '' }))
    if (-not (Confirm-WHDProceed -What 'switch the sounds at sign-in, lock and unlock off')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('theme: sounds at sign-in, lock and unlock off ({0} tasks)' -f $all) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 9 switches them on again' } -Action {
        foreach ($n in $script:WHDEvTasks.Keys) { Unregister-WHDEvTask -Path $script:WHDEvTaskPath -Name $n -Confirm:$false }
        foreach ($n in $script:WHDEvTasks.Keys) { if (Get-WHDEvTask -Path $script:WHDEvTaskPath -Name $n) { throw ('read-back: the task {0}{1} is still there' -f $script:WHDEvTaskPath, $n) } }
        [void](Remove-WHDEvGoneTask -Confirm:$false)
        [void](Remove-WHDEvOldTask -Confirm:$false)
    } | Out-Null
}

# ---- A / Z. everything on, everything put back (as 2.0) ----------------------------------------------------------
function Invoke-WHDThemeStep {
    # Runs several items with every inner question answered yes (the caller asked once). Each item still goes
    # through the change gate and gets its own line in the history. One that stops does not stop the rest.
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock[]]$Steps)
    $prev = $script:WHDState.Confirm
    $script:WHDState.Confirm = { param($w) $true }
    try {
        foreach ($whdStep in $Steps) {
            try { & $whdStep } catch { Write-WHDLog -Message ('That step stopped on an error: {0} - going on with the next one.' -f $_.Exception.Message) -Level 'ERR' }
        }
    } finally { $script:WHDState.Confirm = $prev }
}
function Get-WHDThemeOverview {
    [CmdletBinding()]
    param()
    $f = Get-WHDThemeSoundFileState; $s = Get-WHDThemeSchemeState; $l = Get-WHDLookState; $e = Get-WHDEvState
    [pscustomobject]@{
        Files = $f; Scheme = $s; Look = $l; Events = $e
        Lines = @(
            ('Sound files   : {0}' -f $f.Text)
            ('Sound scheme  : {0}' -f $s.Text)
            ('Look          : {0}' -f $l.Text)
            ('Event sounds  : {0}' -f $e.Text)
            'Lock screen   : set by hand in Settings (WHD cannot read it)'
        )
    }
}
function Invoke-WHDThemeAllOn {
    [CmdletBinding()]
    param([string[]]$Answer)
    Write-WHDLog -Message 'THEME A: everything on' -Level 'ACT'
    if (-not (Get-WHDThemeBase)) { Write-WHDLog -Message 'No ProgramData folder on this PC - the theme has no place.' -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window: files go into ProgramData and scheduled tasks are added.' -Level 'WARN'; return }
    $f = Get-WHDThemeSoundFileState
    Write-WHDRisk -Tier 'reversible' -Text ('Switches the whole theme on for this user ({0}), item by item, with this ONE question: the sound files{1}; 3 the sound scheme "{2}"; 9 sounds at sign-in, lock and unlock; 5 the look (Settings may wait for your click on "{3}"; your own-pictures folder is used as it is); 7 the lock-screen slide show (Settings opens for your clicks). Each item gets its own line in the history. Z puts everything back.' -f $env:USERNAME, $(if ($f.Missing.Count) { (' are made first ({0} missing, effects pitch 0.5)' -f $f.Missing.Count) } else { ' are there' }), $script:WHDThemeSchemeName, $script:WHDLookName)
    if (-not (Confirm-WHDProceed -What 'switch the whole theme on')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    if ($f.Missing.Count) {
        if (Test-WHDRealChange) { Invoke-WHDThemeSoundMake -Answer @('') }
        else { Write-WHDLog -Message 'would: make the 20 sound files first (they are missing); 3 and 9 need them, so their preview shows "choose 1 first".' -Level 'DRY' }
    }
    Invoke-WHDThemeStep -Steps @(
        { Invoke-WHDThemeSchemeApply }
        { Invoke-WHDEvSoundApply }
        { Invoke-WHDLookApply -Answer $Answer -NoOwnAsk }
        { Invoke-WHDEvLockApply -Answer $Answer }
    )
    if (Test-WHDRealChange) { foreach ($ln in (Get-WHDThemeOverview).Lines) { Write-WHDLog -Message ('  {0}' -f $ln) } }
}
function Invoke-WHDThemeAllBack {
    [CmdletBinding()]
    param([string[]]$Answer)
    Write-WHDLog -Message 'THEME Z: everything put back' -Level 'ACT'
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window: scheduled tasks are removed.' -Level 'WARN'; return }
    Write-WHDRisk -Tier 'reversible' -Text ('Puts the whole theme back for this user ({0}), item by item, with this ONE question: 10 the sounds at sign-in / lock / unlock off (and WHD Next 2.0''s theme tasks removed); 4 the Windows Default sound scheme; 6 Windows'' own dark theme (Settings may wait for your click); 8 Settings opens for the lock screen. An item that is not on is passed over. Nothing is deleted: sound files, pictures and the player stay, so A switches everything on again.' -f $env:USERNAME)
    if (-not (Confirm-WHDProceed -What 'put the whole theme back')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDThemeStep -Steps @(
        { Invoke-WHDEvSoundRemove }
        { Invoke-WHDThemeSchemeRemove }
        { Invoke-WHDLookRemove -Answer $Answer }
        { Invoke-WHDEvLockRemove -Answer $Answer }
    )
    if (Test-WHDRealChange) { foreach ($ln in (Get-WHDThemeOverview).Lines) { Write-WHDLog -Message ('  {0}' -f $ln) } }
}
