<#
================================================================================
 WHD Next  -  modules\Theme.ps1   (optional theme)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Build step 12b part 2: the sound scheme + the menu entry "X. Theme (optional)".
 Build step 12c: the look - 24 pictures as a slide show, dark mode, accent sky
 blue - through a theme file that Windows opens (see "THE LOOK" further down).
 Build steps 12d + 12e: the WHD pictures on the lock screen and sign-in screen
 (a new one at every sign-in and unlock) and sounds at sign-in / lock / unlock,
 through three scheduled tasks and a small Windows PowerShell 5.1 helper.
 Build step 12f (user decisions 2026-10-05):
   * the same look with hot rod red instead of sky blue, as a second theme
     "WHD Next (red)" in Windows' theme list - switched by a click, not by itself;
   * sounds at sign-out and shut-down / restart, as part of the sounds at
     sign-in / lock / unlock (two more tasks, started by a line in Windows'
     event log; Windows is closing programs then, so they may not always play);
   * "everything on" and "everything put back" with one question each;
   * one place where the theme waits for the user (Read-WHDThemeAnswer), so the
     window version (WHD-GUI.ps1, tab "Theme") can ask in its own way.

 The theme is OPTIONAL (user decisions 2026-10-03):
   * its own main-menu entry; never part of a profile (standard.json);
   * Verify and the update guard do not watch it (the journal entry is of the
     kind "action", which Verify leaves out) - a look is the user's choice;
   * everything it sets belongs to the signed-in user (HKCU), for the user
     WHD Next runs as.

 Sounds: 20 original sounds made by tools\New-WHDThemeSounds.ps1 ("an older
 space ship, held together by the crew and its AI"). This module
   1. makes the files (runs that tool)          - writes .wav files only
   2. plays them                                - changes nothing
   3. makes them the Windows sound scheme "WHD Next"   - through the change gate
   4. puts the scheme used before back                 - through the change gate
 What 3 does: the scheme "WHD Next" = the Windows default scheme with 21
 everyday events replaced by our sounds. Events that are silent in Windows stay
 silent; the long alarm / ring loops stay Windows' own. Before the first change
 every event's sound in use is saved to a file, and 4 puts exactly that back.

 Loading this file only defines functions and variables.
 Works on Windows PowerShell 5.1 (SAFE mode) and PowerShell 7. File is ASCII.
================================================================================
#>

$script:WHDThemeSchemeKey  = 'WHDNext'      # the scheme's key name in the registry
$script:WHDThemeSchemeName = 'WHD Next'     # the name shown in Windows' Sound window (user decision 2026-10-03)
$script:WHDThemeSchemesKey = 'AppEvents\Schemes'
$script:WHDThemeAppsKey    = 'AppEvents\Schemes\Apps'
$script:WHDThemeNamesKey   = 'AppEvents\Schemes\Names'

# Windows sound event -> our sound. (Same lists as in tools\New-WHDThemeSounds.ps1; the cloud test compares them.)
# All of these belong to the app ".Default" (Windows itself).
$script:WHDThemeSoundEvents = [ordered]@{
    'Notification.Default'   = 'notify';   'SystemNotification'    = 'notify'
    'Notification.IM'        = 'message';  'Notification.SMS'      = 'message';  'MessageNudge' = 'message'
    'MailBeep'               = 'mail';     'Notification.Mail'     = 'mail';     'FaxBeep'      = 'mail'
    'Notification.Reminder'  = 'reminder'
    'SystemHand'             = 'error'
    'SystemExclamation'      = 'warning'
    'SystemAsterisk'         = 'info'
    '.Default'               = 'beep'
    'DeviceConnect'          = 'connect'
    'DeviceDisconnect'       = 'disconnect'
    'DeviceFail'             = 'devicefail'
    'WindowsUAC'             = 'uac'
    'LowBatteryAlarm'        = 'batterylow'
    'CriticalBatteryAlarm'   = 'batterycritical'
    'Notification.Proximity' = 'proximity'; 'ProximityConnection'  = 'proximity'
}
# All 20 sounds, in the order they are played (the first five are for the scheduled tasks of a later step).
$script:WHDThemeSoundNames = @('signin', 'signout', 'shutdown', 'lock', 'unlock', 'notify', 'message', 'mail', 'reminder', 'error',
                               'warning', 'info', 'beep', 'connect', 'disconnect', 'devicefail', 'uac', 'batterylow', 'batterycritical', 'proximity')

# ---- folders --------------------------------------------------------------------
function Get-WHDThemeBase {
    if (-not $env:ProgramData) { return '' }
    return (Join-Path (Join-Path $env:ProgramData 'WinHardenDebloatNext') 'theme')
}
function Get-WHDThemeSoundDir  { $b = Get-WHDThemeBase; if (-not $b) { return '' }; return (Join-Path $b 'sounds') }
function Get-WHDThemeStateDir  { $b = Get-WHDThemeBase; if (-not $b) { return '' }; return (Join-Path $b 'state') }
function Get-WHDThemeSoundFile { param([string]$Name) return (Join-Path (Get-WHDThemeSoundDir) ('whd-{0}.wav' -f $Name)) }
function Get-WHDThemeStateFile {
    # One file per user: the sounds are a per-user setting.
    $u = ("$env:USERNAME" -replace '[^A-Za-z0-9_.-]', '_'); if (-not $u) { $u = 'user' }
    return (Join-Path (Get-WHDThemeStateDir) ('sound-scheme-before_{0}.json' -f $u))
}
function Get-WHDThemeCodeRoot {
    if ($script:WHDCodeRoot) { return $script:WHDCodeRoot }
    return $script:WHDRoot
}

# ---- the registry, default values only (HKEY_CURRENT_USER) ------------------------
# Sound schemes live in the "(Default)" value of many small keys. These four functions are the only
# place that touches them (the cloud test swaps them for stand-ins).
function Get-WHDThemeRegSubKeys {
    param([string]$SubKey)
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
        if ($null -eq $k) { return @() }
        return @($k.GetSubKeyNames())
    } finally { if ($null -ne $k) { $k.Dispose() } }
}
function Get-WHDThemeRegDefault {
    # Returns Exists (the key), HasValue (a default value is set), Value, Kind ('String' | 'ExpandString').
    param([string]$SubKey)
    $o = [ordered]@{ Exists = $false; HasValue = $false; Value = ''; Kind = 'String' }
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
        if ($null -ne $k) {
            $o.Exists = $true
            if (@($k.GetValueNames()) -contains '') {
                $o.HasValue = $true
                $o.Value = [string]$k.GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $o.Kind  = [string]$k.GetValueKind('')
            }
        }
    } finally { if ($null -ne $k) { $k.Dispose() } }
    return [pscustomobject]$o
}
function Set-WHDThemeRegDefault {
    # Creates the key when needed and sets its default value.
    param([string]$SubKey, [string]$Value, [string]$Kind = 'String')
    $rk = [Microsoft.Win32.RegistryValueKind]::String
    if ($Kind -eq 'ExpandString') { $rk = [Microsoft.Win32.RegistryValueKind]::ExpandString }
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
        if ($null -eq $k) { throw ('registry key could not be opened for writing: HKCU\{0}' -f $SubKey) }
        $k.SetValue('', $Value, $rk)
    } finally { if ($null -ne $k) { $k.Dispose() } }
}
function Remove-WHDThemeRegKey {
    # Removes one key (and what is under it). A key that is not there is fine.
    param([string]$SubKey)
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($SubKey, $false)
}

# ---- read-only state -----------------------------------------------------------------
function Get-WHDThemeSoundFiles {
    # Which of the 20 sound files exist.
    $dir = Get-WHDThemeSoundDir
    $have = New-Object System.Collections.Generic.List[string]
    $miss = New-Object System.Collections.Generic.List[string]
    foreach ($n in $script:WHDThemeSoundNames) {
        if ($dir -and (Test-Path -LiteralPath (Get-WHDThemeSoundFile $n))) { $have.Add($n) } else { $miss.Add($n) }
    }
    [pscustomobject]@{ Dir = $dir; Have = @($have.ToArray()); Missing = @($miss.ToArray()); Total = $script:WHDThemeSoundNames.Count
                       Text = ('{0} of {1} in {2}' -f $have.Count, $script:WHDThemeSoundNames.Count, $dir) }
}
function Get-WHDThemeSchemeState {
    # Which sound scheme is in use, and whether ours is.
    $o = [ordered]@{ Readable = $true; Key = ''; Name = ''; InUse = $false; Registered = $false; Text = '' }
    try {
        $cur = Get-WHDThemeRegDefault $script:WHDThemeSchemesKey
        $o.Key = "$($cur.Value)"
        $o.InUse = ($o.Key -eq $script:WHDThemeSchemeKey)
        $o.Registered = [bool](Get-WHDThemeRegDefault ('{0}\{1}' -f $script:WHDThemeNamesKey, $script:WHDThemeSchemeKey)).Exists
        $o.Name = $o.Key
        if ($o.Key) {
            $nm = Get-WHDThemeRegDefault ('{0}\{1}' -f $script:WHDThemeNamesKey, $o.Key)
            if ($nm.HasValue -and "$($nm.Value)") { $o.Name = "$($nm.Value)" }
        }
        # Windows names its own two schemes with a resource reference; say it in words.
        if ($o.Key -eq '.Default') { $o.Name = 'Windows Default' } elseif ($o.Key -eq '.None') { $o.Name = 'No Sounds' }
        if ($o.InUse) { $o.Text = ('in use ("{0}")' -f $script:WHDThemeSchemeName) }
        elseif ($o.Key) { $o.Text = ('not in use - scheme in use: {0}' -f $o.Name) }
        else { $o.Text = 'not in use - no scheme name set (sounds were changed one by one)' }
    } catch {
        $o.Readable = $false; $o.Text = ('not readable: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject]$o
}
function Get-WHDThemeAllEvents {
    # Every sound event of every app: App, Event, and the key of its sound in use.
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($app in @(Get-WHDThemeRegSubKeys $script:WHDThemeAppsKey)) {
        foreach ($ev in @(Get-WHDThemeRegSubKeys ('{0}\{1}' -f $script:WHDThemeAppsKey, $app))) {
            $out.Add([pscustomobject]@{ App = $app; Event = $ev; Key = ('{0}\{1}\{2}' -f $script:WHDThemeAppsKey, $app, $ev) })
        }
    }
    return @($out.ToArray())
}

# ---- 1. make the sound files ----------------------------------------------------------------
function Invoke-WHDThemeMakeSounds {
    # Runs tools\New-WHDThemeSounds.ps1 on this PowerShell. Writes .wav files only - no Windows setting.
    $tool = Join-Path (Get-WHDThemeCodeRoot) 'tools\New-WHDThemeSounds.ps1'
    $dir  = Get-WHDThemeSoundDir
    Write-WHDLog 'THEME: make the sound files' 'ACT'
    if (-not $dir) { Write-WHDLog 'No ProgramData folder on this PC - the sound files have no place.' 'ERR'; return }
    if (-not (Test-Path -LiteralPath $tool)) { Write-WHDLog ('The sound generator was not found: {0}' -f $tool) 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog ('Needs an administrator window: {0} can only be changed by administrators.' -f $dir) 'ERR'; return }
    $exe = ''
    try { $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $exe = '' }
    if (-not $exe) { Write-WHDLog 'This PowerShell program could not be found to run the generator.' 'ERR'; return }
    Write-WHDLog ('This writes 20 .wav files into {0}. No Windows setting is changed.' -f $dir) 'INFO'
    $global:LASTEXITCODE = 0
    & $exe -NoProfile -ExecutionPolicy Bypass -File $tool -OutDir $dir 2>&1 | ForEach-Object { Write-Host ("  {0}" -f $_) }
    $code = $LASTEXITCODE
    $f = Get-WHDThemeSoundFiles
    if ($code -eq 0 -and -not $f.Missing.Count) { Write-WHDLog ('Sound files: {0}' -f $f.Text) 'OK' }
    else { Write-WHDLog ('The generator ended with code {0}; sound files: {1}' -f $code, $f.Text) 'ERR' }
}

# ---- 2. listen ----------------------------------------------------------------------------------
function Invoke-WHDThemeListen {
    # Plays the sound files (all, or the named ones). Changes nothing.
    param([string[]]$Names)
    $want = @($Names | ForEach-Object { "$_".Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    if ($want -contains '?') { Write-Host ('  names: {0}' -f ($script:WHDThemeSoundNames -join ', ')); return }
    $list = @($script:WHDThemeSoundNames)
    if ($want.Count) {
        $bad = @($want | Where-Object { $script:WHDThemeSoundNames -notcontains $_ })
        if ($bad.Count) { Write-Host ('  unknown sound name(s): {0}' -f ($bad -join ', ')) -ForegroundColor Yellow; Write-Host ('  names: {0}' -f ($script:WHDThemeSoundNames -join ', ')); return }
        $list = $want
    }
    $f = Get-WHDThemeSoundFiles
    if (-not $f.Have.Count) { Write-Host '  The sound files are not made yet - choose 1 first.' -ForegroundColor Yellow; return }
    $player = $null
    try { $player = New-Object System.Media.SoundPlayer } catch { $player = $null }
    if ($null -eq $player) { Write-Host '  The sounds cannot be played in this PowerShell.' -ForegroundColor Yellow; return }
    Write-Host '  Playing - nothing is changed:' -ForegroundColor Cyan
    $i = 0
    foreach ($n in $list) {
        $i++
        $file = Get-WHDThemeSoundFile $n
        if (-not (Test-Path -LiteralPath $file)) { Write-Host ('   {0,2}. {1,-16} (file not found)' -f $i, $n) -ForegroundColor Yellow; continue }
        Write-Host ('   {0,2}. {1}' -f $i, $n)
        try { $player.SoundLocation = $file; $player.Load(); $player.PlaySync() }
        catch { Write-Host ('       could not be played: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
        if ($list.Count -gt 1) { Start-Sleep -Milliseconds 450 }
    }
    try { $player.Dispose() } catch { }
}

# ---- 3. use them as the Windows sound scheme ---------------------------------------------------------
function Save-WHDThemeSchemeBefore {
    # Writes down what is in use now (scheme name + every event's sound), so "put back" restores exactly this.
    # Not when our scheme is already in use - then the file from the first time is the true "before".
    param($State, [object[]]$Events)
    $file = Get-WHDThemeStateFile
    if ($State.InUse -and (Test-Path -LiteralPath $file)) { return $file }
    $dir = Get-WHDThemeStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Events)) {
        $c = Get-WHDThemeRegDefault ('{0}\.Current' -f $e.Key)
        $rows.Add([ordered]@{ App = $e.App; Event = $e.Event; KeyExists = [bool]$c.Exists; HasValue = [bool]$c.HasValue; Value = "$($c.Value)"; Kind = "$($c.Kind)" })
    }
    $doc = [ordered]@{
        What = 'WHD Next theme: the sound scheme in use before "WHD Next" was applied. Used by "put back".'
        SavedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); User = "$env:USERDOMAIN\$env:USERNAME"; Computer = "$env:COMPUTERNAME"
        SchemeKey = "$($State.Key)"; SchemeName = "$($State.Name)"; Events = @($rows.ToArray())
    }
    ($doc | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $file -Encoding UTF8 -EA Stop
    return $file
}
function Set-WHDThemeSoundScheme {
    # The registry writes for "WHD Next". Called inside the change gate only.
    param([object[]]$Events)
    $me = $script:WHDThemeSchemeKey
    Set-WHDThemeRegDefault ('{0}\{1}' -f $script:WHDThemeNamesKey, $me) $script:WHDThemeSchemeName 'String'
    $ours = 0; $others = 0
    foreach ($e in @($Events)) {
        $val = ''; $kind = 'String'
        if ($e.App -eq '.Default' -and $script:WHDThemeSoundEvents.Contains($e.Event)) {
            $val = Get-WHDThemeSoundFile $script:WHDThemeSoundEvents[$e.Event]; $ours++
        } else {
            # every other event keeps what the Windows default scheme has for it (silent stays silent);
            # an event that has no ".Default" entry at all (another program's own event) keeps the sound it has now
            $d = Get-WHDThemeRegDefault ('{0}\.Default' -f $e.Key)
            if (-not $d.Exists) { $d = Get-WHDThemeRegDefault ('{0}\.Current' -f $e.Key) }
            if ($d.HasValue) { $val = "$($d.Value)"; $kind = "$($d.Kind)" }
            if ($kind -ne 'ExpandString') { $kind = 'String' }
            $others++
        }
        Set-WHDThemeRegDefault ('{0}\{1}' -f $e.Key, $me) $val $kind
        Set-WHDThemeRegDefault ('{0}\.Current' -f $e.Key) $val $kind
    }
    Set-WHDThemeRegDefault $script:WHDThemeSchemesKey $me 'String'
    return [pscustomobject]@{ Ours = $ours; Others = $others }
}
function Invoke-WHDThemeSoundSchemeApply {
    Write-WHDLog ('THEME: Windows sound scheme -> "{0}"' -f $script:WHDThemeSchemeName) 'ACT'
    $f = Get-WHDThemeSoundFiles
    if ($f.Missing.Count) { Write-WHDLog ('The sound files are not complete ({0}) - choose 1 first.' -f $f.Text) 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog ('Needs an administrator window: the note of what is in use now is written into {0}.' -f (Get-WHDThemeStateDir)) 'ERR'; return }
    $st = Get-WHDThemeSchemeState
    if (-not $st.Readable) { Write-WHDLog ('The sound schemes of this user could not be read: {0}' -f $st.Text) 'ERR'; return }
    $events = @(Get-WHDThemeAllEvents)
    $known = @($events | Where-Object { $_.App -eq '.Default' -and $script:WHDThemeSoundEvents.Contains($_.Event) })
    if (-not $known.Count) { Write-WHDLog 'None of the Windows sound events WHD knows were found for this user - nothing to set.' 'ERR'; return }
    Write-WHDRisk 'reversible' ('Adds the sound scheme "{0}" for this user ({1}) and makes it the one in use: {2} everyday Windows sounds (notification, message, mail, reminder, error, warning, information, beep, device in / out / failed, administrator prompt, battery, nearby device) become the WHD Next sounds; the other {3} events keep what the Windows default scheme has (silent ones stay silent, alarm and ring loops stay Windows'' own). What is in use now ("{4}") is written to {5} first. Theme menu > 4 puts it back; Windows'' own Sound window can also switch schemes at any time. Verify does not watch this.' -f $script:WHDThemeSchemeName, $env:USERNAME, $known.Count, ($events.Count - $known.Count), $st.Name, (Get-WHDThemeStateFile))
    if (-not (Confirm-WHDProceed ('use the sound scheme "{0}"' -f $script:WHDThemeSchemeName))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'soundscheme'; Hint = 'Theme menu (X) > 4 "Put back the sound scheme used before" - or pick another scheme in Windows'' Sound window' }
    Invoke-WHDChange -Description ('theme: Windows sound scheme -> "{0}" ({1} WHD sounds, {2} events in all; before: {3})' -f $script:WHDThemeSchemeName, $known.Count, $events.Count, $st.Name) -Force -Journal $jr -Action {
        $null = Save-WHDThemeSchemeBefore -State $st -Events $events
        $null = Set-WHDThemeSoundScheme -Events $events
        # read back: the scheme is the one in use and one of our sounds is really set
        $after = Get-WHDThemeSchemeState
        if (-not $after.InUse) { throw ('read-back: the scheme in use is "{0}", not "{1}"' -f $after.Key, $script:WHDThemeSchemeKey) }
        $probe = $known[0]
        $now = Get-WHDThemeRegDefault ('{0}\.Current' -f $probe.Key)
        $wantFile = Get-WHDThemeSoundFile $script:WHDThemeSoundEvents[$probe.Event]
        if ("$($now.Value)" -ne $wantFile) { throw ('read-back: {0} plays "{1}", not "{2}"' -f $probe.Event, $now.Value, $wantFile) }
    } | Out-Null
}

# ---- 4. put the scheme used before back ---------------------------------------------------------------
function Restore-WHDThemeSoundScheme {
    # The registry writes for "put back". Called inside the change gate only.
    param($Before, [object[]]$Events)
    $me = $script:WHDThemeSchemeKey
    $back = 0; $fallback = 0
    $saved = @{}
    if ($Before) { foreach ($r in @($Before.Events)) { $saved[('{0}|{1}' -f $r.App, $r.Event).ToLower()] = $r } }
    foreach ($e in @($Events)) {
        $key = ('{0}|{1}' -f $e.App, $e.Event).ToLower()
        if ($saved.ContainsKey($key)) {
            $r = $saved[$key]
            $kind = 'String'; if ("$($r.Kind)" -eq 'ExpandString') { $kind = 'ExpandString' }
            if ($r.KeyExists -eq $false) { Remove-WHDThemeRegKey ('{0}\.Current' -f $e.Key) }   # there was no entry before
            else { Set-WHDThemeRegDefault ('{0}\.Current' -f $e.Key) "$($r.Value)" $kind }
            $back++
        } else {
            # nothing saved for this event: the Windows default scheme's sound. An event without a ".Default"
            # entry (another program's own event) was never changed by WHD - it is left as it is.
            $d = Get-WHDThemeRegDefault ('{0}\.Default' -f $e.Key)
            if ($d.Exists) {
                $val = ''; $kind = 'String'
                if ($d.HasValue) { $val = "$($d.Value)"; $kind = "$($d.Kind)" }
                if ($kind -ne 'ExpandString') { $kind = 'String' }
                Set-WHDThemeRegDefault ('{0}\.Current' -f $e.Key) $val $kind
            }
            $fallback++
        }
        Remove-WHDThemeRegKey ('{0}\{1}' -f $e.Key, $me)
    }
    $schemeKey = '.Default'
    if ($Before -and "$($Before.SchemeKey)" -and "$($Before.SchemeKey)" -ne $me) { $schemeKey = "$($Before.SchemeKey)" }
    Set-WHDThemeRegDefault $script:WHDThemeSchemesKey $schemeKey 'String'
    Remove-WHDThemeRegKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $me)
    return [pscustomobject]@{ Back = $back; Fallback = $fallback; SchemeKey = $schemeKey }
}
function Invoke-WHDThemeSoundSchemeRemove {
    Write-WHDLog 'THEME: put back the sound scheme used before' 'ACT'
    $st = Get-WHDThemeSchemeState
    if (-not $st.Readable) { Write-WHDLog ('The sound schemes of this user could not be read: {0}' -f $st.Text) 'ERR'; return }
    if (-not $st.InUse -and -not $st.Registered) { Write-WHDLog ('The scheme "{0}" is not on this user''s account - nothing to put back.' -f $script:WHDThemeSchemeName) 'OK'; return }
    $file = Get-WHDThemeStateFile
    $before = $null
    if (Test-Path -LiteralPath $file) { try { $before = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $before = $null } }
    $events = @(Get-WHDThemeAllEvents)
    $toWhat = 'the Windows default scheme (no saved state was found)'
    if ($before) { $toWhat = ('"{0}", as saved {1}' -f $(if ("$($before.SchemeName)") { $before.SchemeName } else { $before.SchemeKey }), $before.SavedAt) }
    Write-WHDRisk 'reversible' ('Puts the sounds of this user ({0}) back to {1}, and takes the scheme "{2}" out of Windows'' list. The sound files stay in {3}; choose 3 to use them again.' -f $env:USERNAME, $toWhat, $script:WHDThemeSchemeName, (Get-WHDThemeSoundDir))
    if (-not (Confirm-WHDProceed 'put back the sound scheme used before')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'soundscheme-remove'; Hint = 'Theme menu (X) > 3 uses the WHD Next sounds again' }
    Invoke-WHDChange -Description ('theme: sound scheme back to {0}' -f $toWhat) -Force -Journal $jr -Action {
        $null = Restore-WHDThemeSoundScheme -Before $before -Events $events
        $after = Get-WHDThemeSchemeState
        if ($after.InUse -or $after.Registered) { throw 'read-back: the scheme "WHD Next" is still there' }
    } | Out-Null
}

# =====================================================================================================
#  THE LOOK - pictures, dark mode, accent colour (build step 12c)
# -----------------------------------------------------------------------------------------------------
#  User decisions 2026-10-03: WHD writes a theme file and has Windows open it (Windows' own way). Found on
#  the user's PC the same day: Windows 11 then LISTS the theme in Settings > Personalization > Themes and
#  waits for a click on it - so WHD asks for that click ("manual selection is needed", user 18:34); "use the look" covers pictures, dark mode and accent only,
#  the sounds stay their own item; the accent also colours Start, the taskbar and window title bars.
#
#  The theme file is the theme the user has NOW with only these parts replaced: name, desktop picture,
#  slide show, dark mode, accent colour. Mouse pointers, desktop icons and everything else stay as they
#  are. Microsoft's Theme File Format page says a theme without a [Sounds] section resets the sounds, so
#  WHD names the scheme in use and, after Windows has applied the theme, puts back any sound it changed.
#  "Colour on Start / taskbar / title bars" is not part of a theme file: two values of the signed-in user
#  (ColorPrevalence) are set beside it. What was there before is saved first; 6 puts it back.
# =====================================================================================================
$script:WHDThemeFileName  = 'WHD Next.theme'
$script:WHDThemeDisplay   = 'WHD Next'
$script:WHDThemeId        = '{57484431-4E58-4C4F-4F4B-0000000012C1}'   # our own id, so the theme is recognised wherever Windows keeps it
$script:WHDThemeAccentSky = '40A4FF'      # sky blue      (user decision 2026-10-03)
$script:WHDThemeAccentRed = 'DA1818'      # hot rod red   (user decision 2026-10-03; its own theme since 2026-10-05)
# The same look in hot rod red is a second theme in Windows' list (user decision 2026-10-05: no automatic swap -
# Windows has no documented way for a program to change the accent colour; a click on the theme switches it).
$script:WHDThemeFileNameRed = 'WHD Next (red).theme'
$script:WHDThemeDisplayRed  = 'WHD Next (red)'
$script:WHDThemeIdRed       = '{57484431-4E58-4C4F-4F4B-0000000012C2}'
# The window version sets this to show a message window instead of asking in the console:
#   { param([string]$Text, [bool]$YesNo) ... }   returns 'y' / 'n' for a yes / no question, '' after OK.
if (-not (Get-Variable -Name WHDThemeAsk -Scope Script -ErrorAction SilentlyContinue)) { $script:WHDThemeAsk = $null }
$script:WHDThemeNoOwnAsk = $false         # "everything on" uses the own-pictures folder as it is, without waiting
$script:WHDThemeInterval  = 1800000       # a new picture every 30 minutes, shuffled
$script:WHDThemeKeyThemes = 'Software\Microsoft\Windows\CurrentVersion\Themes'
$script:WHDThemeKeyPers   = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
$script:WHDThemeKeyDwm    = 'Software\Microsoft\Windows\DWM'
$script:WHDThemePicExt    = @('.jpg', '.jpeg', '.png', '.bmp')

function Get-WHDThemePictureDir    { $b = Get-WHDThemeBase; if (-not $b) { return '' }; return (Join-Path $b 'pictures') }
function Get-WHDThemeOwnDir        { $b = Get-WHDThemeBase; if (-not $b) { return '' }; return (Join-Path $b 'my-pictures') }
function Get-WHDThemeUserThemeDir {
    # Where Windows keeps the signed-in user's own themes (Theme File Format page: "%LOCALAPPDATA%\Microsoft\Windows\Themes").
    if (-not $env:LOCALAPPDATA) { return '' }
    return (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Themes')
}
function Get-WHDThemeFile {
    # The theme file is written straight into the user's themes folder: Windows lists it once under one name.
    # (Opened from anywhere else, Windows makes a new numbered copy on every run - seen on the user's PC 2026-10-03.)
    # -Red: the file of the same look in hot rod red.
    param([switch]$Red)
    $d = Get-WHDThemeUserThemeDir
    if (-not $d) { $d = Get-WHDThemeBase }
    if (-not $d) { return '' }
    if ($Red) { return (Join-Path $d $script:WHDThemeFileNameRed) }
    return (Join-Path $d $script:WHDThemeFileName)
}
function Read-WHDThemeAnswer {
    # The one place where the theme waits for the user. Console: Read-Host with the prompt (the lines above it were
    # printed by the caller). Window version: its own message window with the full text (see $script:WHDThemeAsk).
    param([string]$Prompt, [string]$Text = '', [switch]$YesNo)
    if ($script:WHDThemeAsk) {
        $t = $Text; if (-not $t) { $t = $Prompt.Trim() }
        return "$(& $script:WHDThemeAsk $t ([bool]$YesNo))"
    }
    return (Read-Host $Prompt)
}
function Get-WHDThemeBeforeFile {
    $d = Get-WHDThemeUserThemeDir
    if (-not $d) { $d = Get-WHDThemeBase }
    if (-not $d) { return '' }
    return (Join-Path $d 'Before WHD Next.theme')
}
function Get-WHDThemePictureSource { return (Join-Path (Join-Path (Get-WHDThemeCodeRoot) 'theme') 'pictures') }
function Get-WHDThemeUserTag       { $u = ("$env:USERNAME" -replace '[^A-Za-z0-9_.-]', '_'); if (-not $u) { $u = 'user' }; return $u }
function Get-WHDThemeLookStateFile { return (Join-Path (Get-WHDThemeStateDir) ('look-before_{0}.json' -f (Get-WHDThemeUserTag))) }
function Get-WHDThemeBeforeCopy    { return (Join-Path (Get-WHDThemeStateDir) ('theme-before_{0}.theme' -f (Get-WHDThemeUserTag))) }

# ---- the registry, named values (HKEY_CURRENT_USER) -----------------------------------------------------
function Get-WHDThemeRegValue {
    param([string]$SubKey, [string]$Name)
    $o = [ordered]@{ Exists = $false; Value = $null; Kind = '' }
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
        if ($null -ne $k -and (@($k.GetValueNames()) -contains $Name)) {
            $o.Exists = $true
            $o.Value  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $o.Kind   = [string]$k.GetValueKind($Name)
        }
    } finally { if ($null -ne $k) { $k.Dispose() } }
    return [pscustomobject]$o
}
function Set-WHDThemeRegDword {
    param([string]$SubKey, [string]$Name, [int]$Value)
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
        if ($null -eq $k) { throw ('registry key could not be opened for writing: HKCU\{0}' -f $SubKey) }
        $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::DWord)
    } finally { if ($null -ne $k) { $k.Dispose() } }
}
function Remove-WHDThemeRegValue {
    param([string]$SubKey, [string]$Name)
    $k = $null
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, $true)
        if ($null -ne $k) { $k.DeleteValue($Name, $false) }
    } finally { if ($null -ne $k) { $k.Dispose() } }
}

# ---- Windows itself (the cloud test swaps these three for stand-ins) --------------------------------------
function Open-WHDThemeFile {
    # Opening a .theme file is how Windows wants a theme applied (Theme File Format page: "ShellExecute on a .theme file").
    # WHD Next runs in an administrator window. On the user's PC (2026-10-03, twice) a theme opened straight from
    # there was not taken over by Windows. So the file is handed to Windows Explorer, which opens it on the normal
    # desktop - the same as a double-click.
    param([string]$Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop
}
function Open-WHDThemeFolder {
    param([string]$Path)
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path) -ErrorAction Stop } catch { }
}
function Wait-WHDTheme { param([int]$Ms) Start-Sleep -Milliseconds $Ms }

# ---- theme files are .ini text ---------------------------------------------------------------------------
function Read-WHDThemeIniText {
    # Windows writes theme files with one byte per character; a file with a byte-order mark is read as that says.
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    return [System.Text.Encoding]::GetEncoding(28591).GetString($b)
}
function ConvertFrom-WHDThemeIni {
    # Text -> list of sections { Name; Lines }. Everything is kept: comments, blank lines, order.
    param([string]$Text)
    $secs = New-Object System.Collections.Generic.List[object]
    $cur = [pscustomobject]@{ Name = ''; Lines = (New-Object System.Collections.Generic.List[string]) }
    $secs.Add($cur)
    foreach ($ln in ("$Text" -split "`r?`n")) {
        if ($ln -match '^\s*\[(.+)\]\s*$') {
            $cur = [pscustomobject]@{ Name = $Matches[1]; Lines = (New-Object System.Collections.Generic.List[string]) }
            $secs.Add($cur)
        } else { $cur.Lines.Add($ln) }
    }
    return , $secs
}
function ConvertTo-WHDThemeIniText {
    param($Ini)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Ini) {
        if ($s.Name) { $out.Add(('[{0}]' -f $s.Name)) }
        foreach ($l in $s.Lines) { $out.Add($l) }
    }
    return ($out -join "`r`n")
}
function Get-WHDThemeIniSection {
    param($Ini, [string]$Name, [switch]$Create)
    foreach ($s in $Ini) { if ($s.Name -and ($s.Name -eq $Name)) { return $s } }
    if (-not $Create) { return $null }
    $s = [pscustomobject]@{ Name = $Name; Lines = (New-Object System.Collections.Generic.List[string]) }
    $Ini.Add($s)
    return $s
}
function Get-WHDThemeIniValue {
    param($Ini, [string]$Section, [string]$Key)
    $s = Get-WHDThemeIniSection $Ini $Section
    if ($null -eq $s) { return $null }
    $rx = '^\s*{0}\s*=(.*)$' -f [regex]::Escape($Key)
    foreach ($l in $s.Lines) { if ($l -match $rx) { return $Matches[1] } }
    return $null
}
function Set-WHDThemeIniValue {
    param($Ini, [string]$Section, [string]$Key, [string]$Value)
    $s = Get-WHDThemeIniSection $Ini $Section -Create
    $rx = '^\s*{0}\s*=' -f [regex]::Escape($Key)
    for ($i = 0; $i -lt $s.Lines.Count; $i++) { if ($s.Lines[$i] -match $rx) { $s.Lines[$i] = ('{0}={1}' -f $Key, $Value); return } }
    # new key: before the blank / comment lines at the end (those belong to the next section's heading)
    $at = $s.Lines.Count
    while ($at -gt 0 -and ($s.Lines[$at - 1] -match '^\s*(;.*)?$')) { $at-- }
    $s.Lines.Insert($at, ('{0}={1}' -f $Key, $Value))
}
function Remove-WHDThemeIniKey {
    # Removes one key, or (Key = '*') every key of the section. Comments and blank lines stay.
    param($Ini, [string]$Section, [string]$Key)
    $s = Get-WHDThemeIniSection $Ini $Section
    if ($null -eq $s) { return }
    $rx = '^\s*{0}\s*=' -f [regex]::Escape($Key)
    if ($Key -eq '*') { $rx = '^\s*[^;=\s][^=]*=' }
    for ($i = $s.Lines.Count - 1; $i -ge 0; $i--) { if ($s.Lines[$i] -match $rx) { $s.Lines.RemoveAt($i) } }
}
function New-WHDThemeFileText {
    # The text of "WHD Next.theme": the theme in use now (BaseText) with only name, desktop picture, slide show,
    # dark mode and accent colour replaced. Without a base, the smallest theme Windows accepts is used.
    param([string]$BaseText, [string[]]$Pictures, [string]$PictureDir, [string]$AccentHex, [string]$SoundScheme, [string]$DisplayName = '', [string]$ThemeId = '')
    if (-not $DisplayName) { $DisplayName = $script:WHDThemeDisplay }
    if (-not $ThemeId) { $ThemeId = $script:WHDThemeId }
    if (-not $BaseText) {
        $BaseText = @('[Theme]', '[Control Panel\Desktop]', 'Pattern=', '[VisualStyles]', 'Path=%SystemRoot%\resources\themes\Aero\Aero.msstyles',
                      'ColorStyle=NormalColor', 'Size=NormalSize', 'VisualStyleVersion=10', '[MasterThemeSelector]', 'MTSM=RJSPBS', '') -join "`r`n"
    }
    $ini = ConvertFrom-WHDThemeIni $BaseText
    $ini[0].Lines.Insert(0, ('; WHD Next theme (optional look) - written by WHD Next {0}. It is the theme in use before, with only the name, desktop pictures, slide show, dark mode and accent colour replaced.' -f (Get-Date).ToString('yyyy-MM-dd HH:mm')))
    Set-WHDThemeIniValue $ini 'Theme' 'DisplayName' $DisplayName
    Set-WHDThemeIniValue $ini 'Theme' 'ThemeId' $ThemeId
    $d = 'Control Panel\Desktop'
    Set-WHDThemeIniValue $ini $d 'Wallpaper' $Pictures[0]
    Set-WHDThemeIniValue $ini $d 'TileWallpaper' '0'
    Set-WHDThemeIniValue $ini $d 'WallpaperStyle' '10'      # documented: fill the screen, keep the shape
    Set-WHDThemeIniValue $ini $d 'PicturePosition' '4'      # the same, as Windows 11 writes it
    Set-WHDThemeIniValue $ini $d 'MultimonBackgrounds' '0'
    Set-WHDThemeIniValue $ini $d 'WindowsSpotlight' '0'
    Remove-WHDThemeIniKey $ini $d 'WallpaperWriteTime'
    Remove-WHDThemeIniKey $ini 'Slideshow' '*'
    Set-WHDThemeIniValue $ini 'Slideshow' 'Interval' ("$script:WHDThemeInterval")
    Set-WHDThemeIniValue $ini 'Slideshow' 'Shuffle' '1'
    Set-WHDThemeIniValue $ini 'Slideshow' 'ImagesRootPath' $PictureDir
    for ($i = 0; $i -lt $Pictures.Count; $i++) { Set-WHDThemeIniValue $ini 'Slideshow' ('Item{0}Path' -f $i) $Pictures[$i] }
    $v = 'VisualStyles'
    if ($null -eq (Get-WHDThemeIniValue $ini $v 'Path'))       { Set-WHDThemeIniValue $ini $v 'Path' '%SystemRoot%\resources\themes\Aero\Aero.msstyles' }
    if ($null -eq (Get-WHDThemeIniValue $ini $v 'ColorStyle')) { Set-WHDThemeIniValue $ini $v 'ColorStyle' 'NormalColor' }
    if ($null -eq (Get-WHDThemeIniValue $ini $v 'Size'))       { Set-WHDThemeIniValue $ini $v 'Size' 'NormalSize' }
    Set-WHDThemeIniValue $ini $v 'AutoColorization' '0'
    Set-WHDThemeIniValue $ini $v 'ColorizationColor' ('0XC4{0}' -f $AccentHex.ToUpper())
    Set-WHDThemeIniValue $ini $v 'SystemMode' 'Dark'
    Set-WHDThemeIniValue $ini $v 'AppMode' 'Dark'
    if ($null -eq (Get-WHDThemeIniValue $ini 'MasterThemeSelector' 'MTSM')) { Set-WHDThemeIniValue $ini 'MasterThemeSelector' 'MTSM' 'RJSPBS' }
    if ($SoundScheme) { Set-WHDThemeIniValue $ini 'Sounds' 'SchemeName' $SoundScheme }
    $t = ConvertTo-WHDThemeIniText $ini
    if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
    return $t
}

# ---- read-only state --------------------------------------------------------------------------------------
function Test-WHDThemeIsOurs {
    # Is this theme file ours? By its file name, or by our id inside it (Windows may keep its own copy elsewhere).
    param([string]$Path)
    if (-not $Path) { return $false }
    if (@($script:WHDThemeFileName, $script:WHDThemeFileNameRed) -contains (Split-Path -Leaf $Path)) { return $true }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $ini = ConvertFrom-WHDThemeIni (Read-WHDThemeIniText $Path)
        if (@($script:WHDThemeId, $script:WHDThemeIdRed) -contains "$(Get-WHDThemeIniValue $ini 'Theme' 'ThemeId')".Trim()) { return $true }
        # Windows may take the theme over into its own "Unsaved Theme" file: then the slide-show folder tells.
        $ourDir = "$(Get-WHDThemePictureDir)".TrimEnd('\', '/')
        if (-not $ourDir) { return $false }
        $root = [Environment]::ExpandEnvironmentVariables("$(Get-WHDThemeIniValue $ini 'Slideshow' 'ImagesRootPath')").Trim().TrimEnd('\', '/')
        if ($root -and ($root -eq $ourDir)) { return $true }
        $wp = [Environment]::ExpandEnvironmentVariables("$(Get-WHDThemeIniValue $ini 'Control Panel\Desktop' 'Wallpaper')").Trim()
        return ($wp.Length -gt $ourDir.Length -and $wp.StartsWith($ourDir, [System.StringComparison]::OrdinalIgnoreCase) -and ('\', '/' -contains "$($wp[$ourDir.Length])"))
    } catch { return $false }
}
function Get-WHDThemeLookColour {
    # Which of the two WHD looks a theme file is: 'sky', 'red', or '' when it cannot be told.
    # By its file name, by our id inside it, or (Windows may keep its own copy without either) by its accent colour.
    param([string]$Path)
    if (-not $Path) { return '' }
    $leaf = Split-Path -Leaf $Path
    if ($leaf -eq $script:WHDThemeFileNameRed) { return 'red' }
    if ($leaf -eq $script:WHDThemeFileName) { return 'sky' }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return '' }
        $ini = ConvertFrom-WHDThemeIni (Read-WHDThemeIniText $Path)
        $id = "$(Get-WHDThemeIniValue $ini 'Theme' 'ThemeId')".Trim()
        if ($id -eq $script:WHDThemeIdRed) { return 'red' }
        if ($id -eq $script:WHDThemeId) { return 'sky' }
        $cc = "$(Get-WHDThemeIniValue $ini 'VisualStyles' 'ColorizationColor')".Trim().ToUpper()
        if ($cc.EndsWith($script:WHDThemeAccentRed.ToUpper())) { return 'red' }
        if ($cc.EndsWith($script:WHDThemeAccentSky.ToUpper())) { return 'sky' }
    } catch { }
    return ''
}
function Get-WHDThemeColourWord { param([string]$Colour) if ($Colour -eq 'red') { return 'hot rod red' }; if ($Colour -eq 'sky') { return 'sky blue' }; return 'another accent colour' }
function Get-WHDThemeCurrentMark {
    # A mark of the theme Windows reports right now (which file, and that file's content) - to see whether a click changed anything.
    $ct = Get-WHDThemeRegValue $script:WHDThemeKeyThemes 'CurrentTheme'
    $p = ''; if ($ct.Exists) { $p = [Environment]::ExpandEnvironmentVariables("$($ct.Value)") }
    $m = ''
    if ($p -and (Test-Path -LiteralPath $p)) {
        try { $m = (Get-FileHash -LiteralPath $p -ErrorAction Stop).Hash }
        catch { try { $i = Get-Item -LiteralPath $p -ErrorAction Stop; $m = ('{0}/{1}' -f $i.Length, $i.LastWriteTimeUtc.Ticks) } catch { $m = '' } }
    }
    return ('{0}|{1}' -f $p, $m)
}
function Read-WHDThemeLookBefore {
    $f = Get-WHDThemeLookStateFile
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Get-WHDThemeLookState {
    $o = [ordered]@{ Readable = $true; ThemePath = ''; ThemeName = ''; InUse = $false; Colour = ''; Active = $false; AppliedAt = ''; Dark = $false; Text = ''; RedText = 'not in use' }
    try {
        $ct = Get-WHDThemeRegValue $script:WHDThemeKeyThemes 'CurrentTheme'
        if ($ct.Exists) { $o.ThemePath = [Environment]::ExpandEnvironmentVariables("$($ct.Value)") }
        $o.ThemeName = $(if ($o.ThemePath) { Split-Path -Leaf $o.ThemePath } else { '(none)' })
        if ($o.ThemePath -and (Test-Path -LiteralPath $o.ThemePath)) {
            try {
                $dn = "$(Get-WHDThemeIniValue (ConvertFrom-WHDThemeIni (Read-WHDThemeIniText $o.ThemePath)) 'Theme' 'DisplayName')".Trim()
                if ($dn -and $dn -notmatch '^@') { $o.ThemeName = $dn }
            } catch { }
        }
        $o.InUse = [bool](Test-WHDThemeIsOurs $o.ThemePath)
        if ($o.InUse) { $o.Colour = Get-WHDThemeLookColour $o.ThemePath }
        $b = Read-WHDThemeLookBefore
        if ($b) { $o.Active = [bool]$b.Active; $o.AppliedAt = "$($b.AppliedAt)" }
        $a = Get-WHDThemeRegValue $script:WHDThemeKeyPers 'AppsUseLightTheme'
        $s = Get-WHDThemeRegValue $script:WHDThemeKeyPers 'SystemUsesLightTheme'
        $o.Dark = ($a.Exists -and [int]$a.Value -eq 0 -and $s.Exists -and [int]$s.Value -eq 0)
        if ($o.InUse -and $o.Colour -eq 'red') { $o.Text = ('in use, in hot rod red ("{0}")' -f $script:WHDThemeDisplayRed); $o.RedText = 'in use' }
        elseif ($o.InUse) { $o.Text = ('in use ("{0}")' -f $script:WHDThemeDisplay) }
        elseif ($o.Active) { $o.Text = ('applied {0}; Windows now shows "{1}" (something was changed by hand since - choose 5 to set it again)' -f $o.AppliedAt, $o.ThemeName) }
        else { $o.Text = ('not in use - theme in use: {0}' -f $o.ThemeName) }
    } catch {
        $o.Readable = $false; $o.Text = ('not readable: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject]$o
}
function Get-WHDThemePictureFiles {
    # Picture files of one folder (not its sub-folders), by name.
    param([string]$Dir, [string]$Filter = '*')
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -Filter $Filter -File -ErrorAction SilentlyContinue |
             Where-Object { $script:WHDThemePicExt -contains $_.Extension.ToLower() } | Sort-Object Name)
}
function Get-WHDThemePictureCount {
    $src = @(Get-WHDThemePictureFiles (Get-WHDThemePictureSource) 'whd-*')
    if (-not $src.Count) { $src = @(Get-WHDThemePictureFiles (Get-WHDThemePictureDir) 'whd-*') }
    $own = @(Get-WHDThemePictureFiles (Get-WHDThemeOwnDir))
    [pscustomobject]@{ Whd = $src.Count; Own = $own.Count; Text = ('{0} WHD pictures, {1} of your own' -f $src.Count, $own.Count) }
}

# ---- the user's own pictures (asked before the folder is made; user decision 2026-10-03) ---------------------
function Invoke-WHDThemeOwnPictures {
    $dir = Get-WHDThemeOwnDir
    if (-not $dir) { return }
    if (-not (Test-Path -LiteralPath $dir)) {
        Write-Host ''
        Write-Host '  Your own pictures can be part of the slide show.' -ForegroundColor Cyan
        Write-Host ('  For that WHD Next would make this folder: {0}' -f $dir)
        $a = "$(Read-WHDThemeAnswer -Prompt '  Make the folder for your own pictures? [y/N]' -YesNo -Text ("Your own pictures can be part of the slide show.`n`nFor that WHD Next would make this folder:`n{0}`n`nMake the folder for your own pictures?" -f $dir))".Trim()
        if ($a -notmatch '^[Yy]') { Write-WHDLog 'Own pictures: no folder made - the slide show uses the WHD pictures.' 'INFO'; return }
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
        catch { Write-WHDLog ('The folder could not be made: {0}' -f $_.Exception.Message) 'ERR'; return }
        Write-WHDLog ('Own pictures: folder made - {0}' -f $dir) 'OK'
    }
    if ((Get-Item -LiteralPath $dir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-WHDLog ('Own pictures: {0} is a link to another place, not a plain folder - WHD Next does not use it.' -f $dir) 'WARN'; return
    }
    $granted = $false
    try { Set-WHDThemeFolderGrant $dir; $granted = $true; Write-WHDLog ('Own pictures: your account ({0}) may put files into this ONE folder without the administrator prompt. No other folder is opened up.' -f $env:USERNAME) 'OK' }
    catch { Write-WHDLog ('Own pictures: the permission on the folder could not be set ({0}) - copying into it asks for administrator permission.' -f $_.Exception.Message) 'WARN' }
    $n = @(Get-WHDThemePictureFiles $dir).Count
    Write-Host ''
    Write-Host ('  Your own pictures go here: {0}' -f $dir) -ForegroundColor Cyan
    Write-Host ('  In it before you add any: {0} picture(s). Kinds: .jpg .jpeg .png .bmp - names in plain English letters, digits, spaces, - and _ .' -f $n)
    if ($granted) { Write-Host '  The folder is opened for you. You can copy into it without the administrator prompt - that permission is on this one folder only.' }
    else { Write-Host '  The folder is opened for you. Copying into it asks for administrator permission (it is under ProgramData).' }
    Write-Host '  WHD Next copies your pictures from there into its slide-show folder; your files stay where you put them.' -ForegroundColor DarkGray
    Open-WHDThemeFolder $dir
    $null = Read-WHDThemeAnswer -Prompt '  Put your pictures in now, then press Enter (or press Enter right away to go on without)' -Text ("Your own pictures go here (the folder window is open):`n{0}`n`nIn it now: {1} picture(s). Kinds: .jpg .jpeg .png .bmp - names in plain English letters, digits, spaces, - and _ .`nWHD Next copies your pictures from there into its slide-show folder; your files stay where you put them.`n`nPut your pictures in now, then choose OK (or choose OK right away to go on without)." -f $dir, $n)
    Write-Host ('  Found in your folder now: {0} picture(s).' -f @(Get-WHDThemePictureFiles $dir).Count)
}

# ---- 5. use the look ----------------------------------------------------------------------------------------------
function Copy-WHDThemePictureIfNeeded {
    param([string]$From, [string]$To)
    if (Test-Path -LiteralPath $To) {
        if ((Get-Item -LiteralPath $From).Length -eq (Get-Item -LiteralPath $To).Length -and
            (Get-FileHash -LiteralPath $From -ErrorAction Stop).Hash -eq (Get-FileHash -LiteralPath $To -ErrorAction Stop).Hash) { return $false }
    }
    Copy-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop
    return $true
}
function Sync-WHDThemePictures {
    # Brings the slide-show folder up to date and returns the pictures the slide show uses (full paths).
    # Called inside the change gate only. Nothing is ever removed.
    $dst = Get-WHDThemePictureDir
    if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null }
    $list = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $same = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $copied = 0; $whd = 0; $own = 0
    $src = @(Get-WHDThemePictureFiles (Get-WHDThemePictureSource) 'whd-*')
    if ($src.Count) {
        foreach ($f in $src) { $to = Join-Path $dst $f.Name; if (Copy-WHDThemePictureIfNeeded $f.FullName $to) { $copied++ }; $list.Add($to); $whd++ }
    } else {
        foreach ($f in @(Get-WHDThemePictureFiles $dst 'whd-*')) { $list.Add($f.FullName); $whd++ }      # already there from an earlier run
    }
    $ownDir = Get-WHDThemeOwnDir
    $ownFiles = @()
    if ($ownDir -and (Test-Path -LiteralPath $ownDir) -and -not ((Get-Item -LiteralPath $ownDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $ownFiles = @(Get-WHDThemePictureFiles $ownDir) }
    foreach ($f in $ownFiles) {
        if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $skipped.Add($f.Name + ' (a link, not a file)'); continue }      # only real files from that one folder
        if ($f.Name -match '[^\x20-\x7E]' -or $f.Name -match '%') { $skipped.Add($f.Name); continue }      # a theme file holds one byte per character; % starts a variable
        if (-not $seen.Count) { foreach ($p in $list) { $seen[(Get-FileHash -LiteralPath $p -ErrorAction Stop).Hash] = (Split-Path -Leaf $p) } }
        $h = (Get-FileHash -LiteralPath $f.FullName -ErrorAction Stop).Hash
        if ($seen.ContainsKey($h)) { $same.Add(('{0} (same picture as {1})' -f $f.Name, $seen[$h])); continue }   # shown once, not twice
        $seen[$h] = $f.Name
        $to = Join-Path $dst ('my-' + $f.Name)
        if (Copy-WHDThemePictureIfNeeded $f.FullName $to) { $copied++ }
        $list.Add($to); $own++
    }
    [pscustomobject]@{ List = @($list.ToArray()); Whd = $whd; Own = $own; Copied = $copied; Skipped = @($skipped.ToArray()); Same = @($same.ToArray()); Dir = $dst }
}
function Get-WHDThemeColorUse {
    # "Show the accent colour on Start and taskbar" / "... on title bars and window borders".
    [pscustomobject]@{
        StartTaskbar = (Get-WHDThemeRegValue $script:WHDThemeKeyPers 'ColorPrevalence')
        TitleBars    = (Get-WHDThemeRegValue $script:WHDThemeKeyDwm 'ColorPrevalence')
    }
}
function Set-WHDThemeColorUse {
    # -On: both to 1.  -Before <saved>: exactly what was there (a value that did not exist is removed again).
    # Called inside the change gate only.
    param([switch]$On, $Before)
    $pairs = @(@($script:WHDThemeKeyPers, 'StartTaskbar'), @($script:WHDThemeKeyDwm, 'TitleBars'))
    foreach ($p in $pairs) {
        if ($On) { Set-WHDThemeRegDword $p[0] 'ColorPrevalence' 1; continue }
        $b = $null; if ($Before) { $b = $Before.($p[1]) }
        if ($b -and $b.Exists) { Set-WHDThemeRegDword $p[0] 'ColorPrevalence' ([int]$b.Value) }
        else { Remove-WHDThemeRegValue $p[0] 'ColorPrevalence' }
    }
}
function Get-WHDThemeSoundSnapshot {
    # Every sound in use now, so a theme change cannot quietly change the sounds.
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($e in @(Get-WHDThemeAllEvents)) {
        $c = Get-WHDThemeRegDefault ('{0}\.Current' -f $e.Key)
        $rows.Add([pscustomobject]@{ Key = ('{0}\.Current' -f $e.Key); Exists = [bool]$c.Exists; HasValue = [bool]$c.HasValue; Value = "$($c.Value)"; Kind = "$($c.Kind)" })
    }
    [pscustomobject]@{ Scheme = (Get-WHDThemeRegDefault $script:WHDThemeSchemesKey); Rows = @($rows.ToArray()) }
}
function Restore-WHDThemeSoundSnapshot {
    # Puts back every sound that differs from the snapshot; returns how many. Called inside the change gate only.
    param($Snap)
    $n = 0
    foreach ($r in @($Snap.Rows)) {
        $c = Get-WHDThemeRegDefault $r.Key
        if ([bool]$c.Exists -eq $r.Exists -and "$($c.Value)" -eq $r.Value) { continue }
        # Windows writes the same file as %ALLUSERSPROFILE%\... when a theme is applied: not a change (seen on the user's PC 2026-10-03)
        if ($c.Exists -and $r.Exists -and "$($c.Value)" -and [string]::Equals([Environment]::ExpandEnvironmentVariables("$($c.Value)"), [Environment]::ExpandEnvironmentVariables($r.Value), [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not $r.Exists) { Remove-WHDThemeRegKey $r.Key }
        else { $kind = 'String'; if ($r.Kind -eq 'ExpandString') { $kind = 'ExpandString' }; Set-WHDThemeRegDefault $r.Key $r.Value $kind }
        $n++
    }
    $now = Get-WHDThemeRegDefault $script:WHDThemeSchemesKey
    if ($Snap.Scheme.HasValue -and "$($now.Value)" -ne "$($Snap.Scheme.Value)") { Set-WHDThemeRegDefault $script:WHDThemeSchemesKey "$($Snap.Scheme.Value)" 'String'; $n++ }
    return $n
}
function Save-WHDThemeLookBefore {
    # Writes down the theme in use (its path, and a copy of the file itself) and the two colour-use values.
    # Not while the WHD look is switched on - then the note from the first time is the true "before".
    param($State)
    $file = Get-WHDThemeLookStateFile
    $old = Read-WHDThemeLookBefore
    if ($old -and $old.Active) { return $old }
    if ($State.InUse -and $old -and "$($old.ThemeCopy)" -and (Test-Path -LiteralPath "$($old.ThemeCopy)")) {
        # the WHD look was put on by hand (in Settings) since: the note from before it is still the true "before"
        Set-WHDThemeLookActive $true
        return (Read-WHDThemeLookBefore)
    }
    $dir = Get-WHDThemeStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $copy = ''
    if ($State.ThemePath -and (Test-Path -LiteralPath $State.ThemePath) -and -not $State.InUse) {
        $copy = Get-WHDThemeBeforeCopy
        if ($State.ThemePath -ne $copy) { [System.IO.File]::WriteAllBytes($copy, [System.IO.File]::ReadAllBytes($State.ThemePath)) }
    }
    $cu = Get-WHDThemeColorUse
    $a = Get-WHDThemeRegValue $script:WHDThemeKeyPers 'AppsUseLightTheme'
    $s = Get-WHDThemeRegValue $script:WHDThemeKeyPers 'SystemUsesLightTheme'
    $doc = [ordered]@{
        What = 'WHD Next theme: the look in use before "WHD Next" was applied. Used by "put back".'
        SavedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); User = "$env:USERDOMAIN\$env:USERNAME"; Computer = "$env:COMPUTERNAME"
        Active = $true; AppliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        ThemePath = "$($State.ThemePath)"; ThemeName = "$($State.ThemeName)"; ThemeCopy = $copy
        StartTaskbar = [ordered]@{ Exists = [bool]$cu.StartTaskbar.Exists; Value = $(if ($cu.StartTaskbar.Exists) { [int]$cu.StartTaskbar.Value } else { 0 }) }
        TitleBars    = [ordered]@{ Exists = [bool]$cu.TitleBars.Exists;    Value = $(if ($cu.TitleBars.Exists)    { [int]$cu.TitleBars.Value }    else { 0 }) }
        AppsUseLightTheme = $(if ($a.Exists) { [int]$a.Value } else { $null }); SystemUsesLightTheme = $(if ($s.Exists) { [int]$s.Value } else { $null })
    }
    ($doc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop
    return (Read-WHDThemeLookBefore)
}
function Set-WHDThemeLookActive {
    param([bool]$Active)
    $b = Read-WHDThemeLookBefore
    if (-not $b) { return }
    $b.Active = $Active
    if ($Active) { $b.AppliedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
    ($b | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Get-WHDThemeLookStateFile) -Encoding UTF8 -ErrorAction Stop
}
function Wait-WHDThemeSwitch {
    # Waits (half a second per try) until Windows reports the wanted theme. -Ours: our theme; otherwise: any theme that is not ours.
    # -Colour sky | red (with -Ours): our theme in that colour.
    param([switch]$Ours, [int]$Tries = 40, [string]$Colour = '')
    for ($i = 0; $i -lt $Tries; $i++) {
        $ct = Get-WHDThemeRegValue $script:WHDThemeKeyThemes 'CurrentTheme'
        $p = ''; if ($ct.Exists) { $p = [Environment]::ExpandEnvironmentVariables("$($ct.Value)") }
        $is = [bool](Test-WHDThemeIsOurs $p)
        if ($Ours -and $is -and $Colour -and ((Get-WHDThemeLookColour $p) -ne $Colour)) { Wait-WHDTheme 500; continue }
        if ($Ours -and $is) { return $true }
        if (-not $Ours -and $p -and -not $is) { return $true }
        Wait-WHDTheme 500
    }
    return $false
}
function Invoke-WHDThemeByHand {
    # Windows 11 on the user's PC (found 2026-10-03): opening a theme file puts the theme into the list in
    # Settings > Personalization > Themes, but Windows waits for a click on it there. WHD names the theme,
    # waits for Enter and looks again. Called inside the change gate only.
    param([string]$Name, [switch]$Ours, [switch]$Again, [string]$Colour = '')
    Write-WHDLog ('Windows waits for a click on the theme "{0}" in Settings > Personalization > Themes.' -f $Name) 'INFO'
    $first = 'Windows has the theme in its list now and waits for your click:'
    if ($Again) { $first = 'The look is already on. For Windows to read the new picture list, the theme has to be clicked once more:' }
    $boxText = ("{0}`n`n1. The Settings window shows Personalization > Themes (if it is not open: Settings > Personalization > Themes).`n2. Click the theme named:   {1}`n3. Come back to this message and choose OK.`n`n(Choosing OK without the click gives up.)" -f $first, $Name)
    Write-Host ''
    if ($Again) { Write-Host '  The look is already on. For Windows to read the new picture list, the theme has to be clicked once more:' -ForegroundColor Yellow }
    else { Write-Host '  Windows has the theme in its list now and waits for your click:' -ForegroundColor Yellow }
    Write-Host '    1. The Settings window shows Personalization > Themes  (if it is not open: Settings > Personalization > Themes).'
    Write-Host ('    2. Click the theme named:  {0}' -f $Name) -ForegroundColor Cyan
    if ($Ours) { Write-Host '       Several with that name? The others are copies from earlier tries - right-click one > Delete removes it.' -ForegroundColor DarkGray }
    Write-Host '    3. Come back to this window and press Enter.'
    $mark0 = Get-WHDThemeCurrentMark
    $null = Read-WHDThemeAnswer -Prompt '  Press Enter after the click (or Enter right away to give up)' -Text $boxText
    if ($Ours) { $ok = Wait-WHDThemeSwitch -Ours -Colour $Colour -Tries 20 } else { $ok = Wait-WHDThemeSwitch -Tries 20 }
    if (-not $ok -and $Ours -and $Colour) {
        # Windows reports a WHD look, but its file does not say which colour (Windows may keep its own copy). When the
        # theme Windows reports CHANGED with the click, that is taken as done; when nothing changed, it was not clicked.
        $now = Get-WHDThemeLookState
        if ($now.InUse -and -not $now.Colour -and ((Get-WHDThemeCurrentMark) -ne $mark0)) { $ok = $true; Write-WHDLog ('Windows shows the WHD look; its theme file does not say which accent colour is on - look at the taskbar ({0} was asked for).' -f (Get-WHDThemeColourWord $Colour)) 'WARN' }
    }
    if ($ok) { Write-WHDLog 'The theme was chosen by hand in Settings.' 'INFO' }
    return $ok
}
function Invoke-WHDThemeLookApply {
    # -Red: the same look with hot rod red instead of sky blue (theme "WHD Next (red)").
    param([switch]$Red)
    $colour = 'sky'; $disp = $script:WHDThemeDisplay; $accent = $script:WHDThemeAccentSky; $otherDisp = $script:WHDThemeDisplayRed; $key = '5'; $otherKey = '5R'
    if ($Red) { $colour = 'red'; $disp = $script:WHDThemeDisplayRed; $accent = $script:WHDThemeAccentRed; $otherDisp = $script:WHDThemeDisplay; $key = '5R'; $otherKey = '5' }
    $word = Get-WHDThemeColourWord $colour
    Write-WHDLog ('THEME: the look - pictures, dark mode, accent colour ("{0}")' -f $disp) 'ACT'
    if (-not (Get-WHDThemeBase)) { Write-WHDLog 'No ProgramData folder on this PC - the theme has no place.' 'ERR'; return }
    $pc = Get-WHDThemePictureCount
    if (-not $pc.Whd) { Write-WHDLog ('The WHD pictures were not found in {0}.' -f (Get-WHDThemePictureSource)) 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog ('Needs an administrator window: pictures and the theme file are written into {0}.' -f (Get-WHDThemeBase)) 'ERR'; return }
    $st = Get-WHDThemeLookState
    if (-not $st.Readable) { Write-WHDLog ('The theme of this user could not be read: {0}' -f $st.Text) 'ERR'; return }
    Write-WHDRisk 'reversible' ('Sets the look "{0}" for this user ({1}): desktop pictures as a slide show ({2}; a new one every 30 minutes, shuffled), dark mode for Windows and apps, accent colour {5} - also on Start, the taskbar and window title bars. WHD writes the theme file {3} and has Windows open it: the Settings window shows the theme list, and you click "{0}" there (Windows does not switch by itself). Mouse pointers, desktop icons and the sounds stay as they are. The theme in use now ("{4}") is saved first; Theme menu > 6 puts it back. The same look in the other colour ("{6}") is put into the theme list beside it: Theme menu > {7}, or a click on it in Settings, changes the colour - WHD never changes it by itself. Verify does not watch this.' -f $disp, $env:USERNAME, $pc.Text, (Get-WHDThemeFile -Red:$Red), $st.ThemeName, $word, $otherDisp, $otherKey)
    if (-not (Confirm-WHDProceed ('use the look "{0}"' -f $disp))) { Write-WHDLog 'skipped.' 'WARN'; return }
    if ($script:WHDExecute -and -not $script:WHDSafeMode -and -not $script:WHDThemeNoOwnAsk) { Invoke-WHDThemeOwnPictures }
    $jr = @{ Kind = 'action'; Theme = $(if ($Red) { 'look-red' } else { 'look' }); Hint = 'Theme menu (X) > 6 "Put back the theme used before" - or pick another theme in Settings > Personalization > Themes' }
    Invoke-WHDChange -Description ('theme: look "{0}" (slide show, dark mode, accent {1}; before: {2})' -f $disp, $word, $st.ThemeName) -Force -Journal $jr -Action {
        $wasActive = [bool]$st.Active
        $before = Save-WHDThemeLookBefore -State $st
        $snd = Get-WHDThemeSoundSnapshot
        $pics = Sync-WHDThemePictures
        if (-not $pics.List.Count) { throw 'no pictures for the slide show' }
        foreach ($n in $pics.Skipped) { Write-WHDLog ('Own picture left out (its name has a letter or sign a theme file cannot hold - rename it): {0}' -f $n) 'WARN' }
        if ($pics.Same.Count) { Write-WHDLog ('Own pictures left out because the slide show already has the same picture: {0} - e.g. {1}' -f $pics.Same.Count, $pics.Same[0]) 'INFO' }
        $baseText = ''
        $basePath = $st.ThemePath
        if ($st.InUse -and $before -and "$($before.ThemeCopy)") { $basePath = "$($before.ThemeCopy)" }      # never build on our own theme
        if ($basePath -and (Test-Path -LiteralPath $basePath) -and -not (Test-WHDThemeIsOurs $basePath)) { try { $baseText = Read-WHDThemeIniText $basePath } catch { $baseText = '' } }
        $scheme = ''
        if ((Get-WHDThemeSchemeState).InUse) { $scheme = $script:WHDThemeSchemeName }
        # both colours are written, so both are in Windows' theme list; the one asked for is opened
        $themeFile = Get-WHDThemeFile -Red:$Red
        $themeDir = Split-Path -Parent $themeFile
        if (-not (Test-Path -LiteralPath $themeDir)) { New-Item -ItemType Directory -Path $themeDir -Force -ErrorAction Stop | Out-Null }
        $L1 = [System.Text.Encoding]::GetEncoding(28591)
        $textSky = New-WHDThemeFileText -BaseText $baseText -Pictures $pics.List -PictureDir $pics.Dir -AccentHex $script:WHDThemeAccentSky -SoundScheme $scheme
        $textRed = New-WHDThemeFileText -BaseText $baseText -Pictures $pics.List -PictureDir $pics.Dir -AccentHex $script:WHDThemeAccentRed -SoundScheme $scheme -DisplayName $script:WHDThemeDisplayRed -ThemeId $script:WHDThemeIdRed
        [System.IO.File]::WriteAllBytes((Get-WHDThemeFile), $L1.GetBytes($textSky))
        [System.IO.File]::WriteAllBytes((Get-WHDThemeFile -Red), $L1.GetBytes($textRed))
        Set-WHDThemeColorUse -On
        $already = ([bool]$st.InUse -and "$($st.Colour)" -eq $colour)      # this very look is on: Windows has to be told to read the file again
        $ok = $false
        try {
            Open-WHDThemeFile $themeFile
            if (-not $already) { $ok = Wait-WHDThemeSwitch -Ours -Colour $colour -Tries 12 }      # some Windows versions switch by themselves: give them 6 seconds
        } catch { $ok = $false; Write-WHDLog ('Opening the theme file failed: {0}' -f $_.Exception.Message) 'WARN' }
        if (-not $ok) { $ok = Invoke-WHDThemeByHand -Name $disp -Ours -Colour $colour -Again:$already }
        if (-not $ok) {
            $now = Get-WHDThemeLookState
            if ($now.InUse) {
                # a WHD look is on, but not the one asked for (the other colour was on and the theme was not clicked)
                Set-WHDThemeLookActive $true
                throw ('read-back: Windows still shows the look in {0}, not in {1} - choose {2} again and click the theme "{3}" in Settings' -f (Get-WHDThemeColourWord "$($now.Colour)"), $word, $key, $disp)
            }
            if (-not $wasActive -and -not $st.InUse) { Set-WHDThemeColorUse -Before $before; Set-WHDThemeLookActive $false }
            throw ('read-back: Windows did not switch to the theme "{0}" (theme in use: {1})' -f $disp, $now.ThemeName)
        }
        Set-WHDThemeLookActive $true
        Wait-WHDTheme 3000                                   # let Windows finish applying before looking at what it did
        $cu = Get-WHDThemeColorUse
        if (-not ($cu.StartTaskbar.Exists -and [int]$cu.StartTaskbar.Value -eq 1 -and $cu.TitleBars.Exists -and [int]$cu.TitleBars.Value -eq 1)) {
            Set-WHDThemeColorUse -On
            Write-WHDLog 'Windows switched "accent colour on Start, taskbar and title bars" off while applying the theme - set again. It may only show after signing out and in.' 'WARN'
        }
        $fixed = Restore-WHDThemeSoundSnapshot $snd
        if ($fixed) { Write-WHDLog ('Windows changed {0} sound setting(s) together with the theme - put back as they were.' -f $fixed) 'INFO' }
        if (-not (Get-WHDThemeLookState).Dark) { Write-WHDLog 'Dark mode did not come on from the theme file - Settings > Personalization > Colors > "Choose your mode" sets it by hand.' 'WARN' }
        Write-WHDLog ('Slide show: {0} WHD pictures + {1} of your own, from {2}.' -f $pics.Whd, $pics.Own, $pics.Dir) 'INFO'
        Write-WHDLog ('Accent colour: {0}. The other colour is the theme "{1}" in Settings > Personalization > Themes (or Theme menu > {2}).' -f $word, $otherDisp, $otherKey) 'INFO'
    } | Out-Null
}

# ---- 6. put the theme used before back ---------------------------------------------------------------------------
function Invoke-WHDThemeLookRemove {
    Write-WHDLog 'THEME: put back the theme used before' 'ACT'
    $st = Get-WHDThemeLookState
    if (-not $st.Readable) { Write-WHDLog ('The theme of this user could not be read: {0}' -f $st.Text) 'ERR'; return }
    if (-not $st.InUse -and -not $st.Active) { Write-WHDLog ('The look "{0}" is not switched on for this user - nothing to put back.' -f $script:WHDThemeDisplay) 'OK'; return }
    $before = Read-WHDThemeLookBefore
    $target = ''; $toWhat = ''; $fromCopy = ''; $clickName = ''
    $stockNames = @{ 'aero.theme' = 'Windows (light)'; 'dark.theme' = 'Windows (dark)'; 'spotlight.theme' = 'Windows spotlight'; 'themea.theme' = 'Glow'; 'themeb.theme' = 'Captured Motion'; 'themec.theme' = 'Sunrise'; 'themed.theme' = 'Flow' }
    if ($before) {
        $stock = ''
        if ($env:SystemRoot) { $stock = (Join-Path $env:SystemRoot 'Resources\Themes').TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar }
        $bp = "$($before.ThemePath)"
        if ($stock -and $bp -and $bp.StartsWith($stock, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $bp)) {
            $target = $bp                                   # one of Windows' own themes: the original
            $leaf = (Split-Path -Leaf $bp).ToLower()
            $clickName = $(if ($stockNames.ContainsKey($leaf)) { '{0}   (file {1})' -f $stockNames[$leaf], (Split-Path -Leaf $bp) } else { 'the Windows theme of the file ' + (Split-Path -Leaf $bp) })
        } elseif ("$($before.ThemeCopy)" -and (Test-Path -LiteralPath "$($before.ThemeCopy)")) {
            # otherwise the copy saved at the time: it is put into the user's theme list under a name of its own
            $fromCopy = "$($before.ThemeCopy)"; $target = Get-WHDThemeBeforeFile; $clickName = 'Before WHD Next'
        }
        if ($target) { $toWhat = ('"{0}", as saved {1}' -f $before.ThemeName, $before.SavedAt) }
    }
    if (-not $target -and $env:SystemRoot) {
        $aero = Join-Path $env:SystemRoot 'Resources\Themes\aero.theme'
        if (Test-Path -LiteralPath $aero) { $target = $aero; $clickName = 'Windows (light)   (file aero.theme)'; $toWhat = 'the Windows theme "Windows (light)" (no saved theme was found)' }
    }
    if (-not $target) { Write-WHDLog 'No saved theme and no Windows theme file was found - pick a theme in Settings > Personalization > Themes.' 'ERR'; return }
    Write-WHDRisk 'reversible' ('Puts the look of this user ({0}) back to {1}: WHD has Windows open that theme (the Settings window shows the theme list, and you click it there) and sets "accent colour on Start, taskbar and title bars" back to what it was. The sounds stay as they are. Pictures and the WHD theme file stay in {2}; choose 5 to use them again.' -f $env:USERNAME, $toWhat, (Get-WHDThemeBase))
    if (-not (Confirm-WHDProceed 'put back the theme used before')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'look-remove'; Hint = 'Theme menu (X) > 5 uses the WHD Next look again' }
    Invoke-WHDChange -Description ('theme: look back to {0}' -f $toWhat) -Force -Journal $jr -Action {
        $snd = Get-WHDThemeSoundSnapshot
        if ($before) { Set-WHDThemeColorUse -Before $before }
        if ($fromCopy) {
            $ini = ConvertFrom-WHDThemeIni (Read-WHDThemeIniText $fromCopy)
            Set-WHDThemeIniValue $ini 'Theme' 'DisplayName' 'Before WHD Next'
            $bd = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $bd)) { New-Item -ItemType Directory -Path $bd -Force -ErrorAction Stop | Out-Null }
            [System.IO.File]::WriteAllBytes($target, [System.Text.Encoding]::GetEncoding(28591).GetBytes((ConvertTo-WHDThemeIniText $ini)))
        }
        $ok = $false
        try { Open-WHDThemeFile $target; $ok = Wait-WHDThemeSwitch -Tries 12 } catch { $ok = $false; Write-WHDLog ('Opening the theme file failed: {0}' -f $_.Exception.Message) 'WARN' }
        if (-not $ok) { $ok = Invoke-WHDThemeByHand -Name $clickName }
        if (-not $ok) { throw ('read-back: Windows did not leave the theme "{0}"' -f $script:WHDThemeDisplay) }
        Set-WHDThemeLookActive $false
        Wait-WHDTheme 3000
        if ($before) {
            $cu = Get-WHDThemeColorUse
            $wantS = $(if ($before.StartTaskbar.Exists) { [int]$before.StartTaskbar.Value } else { $null })
            $wantT = $(if ($before.TitleBars.Exists) { [int]$before.TitleBars.Value } else { $null })
            $nowS = $(if ($cu.StartTaskbar.Exists) { [int]$cu.StartTaskbar.Value } else { $null })
            $nowT = $(if ($cu.TitleBars.Exists) { [int]$cu.TitleBars.Value } else { $null })
            if ($wantS -ne $nowS -or $wantT -ne $nowT) { Set-WHDThemeColorUse -Before $before }
        }
        $fixed = Restore-WHDThemeSoundSnapshot $snd
        if ($fixed) { Write-WHDLog ('Windows changed {0} sound setting(s) together with the theme - put back as they were.' -f $fixed) 'INFO' }
    } | Out-Null
}

# =====================================================================================================
#  LOCK SCREEN + SIGN-IN SCREEN PICTURES, and SOUNDS AT SIGN-IN / LOCK / UNLOCK (build steps 12d + 12e)
# -----------------------------------------------------------------------------------------------------
#  User 2026-10-05: "The true background ... i want change is the boot to welcome screen (also Default
#  login screen) ... both backgrounds i would like to rotate through the generated pictures."
#  A theme only changes the desktop of one account. The screen with the clock (power-on, restart, lock)
#  is the LOCK SCREEN; Windows shows its picture behind the sign-in box too. Windows has a call for
#  setting that picture (Windows.System.UserProfile.LockScreen) - it exists in Windows PowerShell 5.1
#  only, so a small 5.1 helper (tools\Invoke-WHDThemeEvent.ps1) does it. "Rotate" = three scheduled
#  tasks start the helper as the signed-in user, without administrator rights, at sign-in, lock and
#  unlock: at sign-in and unlock it sets ANOTHER picture, so every lock / restart shows a new one.
#  The same tasks play the sign-in / lock / unlock sounds when those are switched on.
#  What is switched on is kept in the user's own folder (%LOCALAPPDATA%\WinHardenDebloatNext\theme).
#  Build step 12f: sounds at sign-out and shut-down / restart. Task Scheduler has no trigger for these two
#  moments, so two more tasks (used by the sounds only) are started by a line Windows writes into its
#  System event log: "shut-down / restart was started" (source User32, number 1074 - Microsoft Learn,
#  "Troubleshoot unexpected reboots using system event logs") and the sign-out notice (source Winlogon,
#  number 7002). Windows is closing programs at that moment: the sound may be cut short or not heard.
# =====================================================================================================
$script:WHDThemeTaskPath   = '\WinHardenDebloatNext\'
$script:WHDThemeTasks      = [ordered]@{ 'ThemeSignIn' = 'signin'; 'ThemeLock' = 'lock'; 'ThemeUnlock' = 'unlock' }
$script:WHDThemeSoundTasks = [ordered]@{ 'ThemeSignOut' = 'signout'; 'ThemeShutDown' = 'shutdown' }      # for the sounds only
$script:WHDThemeEventSounds = @('signin', 'lock', 'unlock', 'signout', 'shutdown')
# The event-log lines the two extra tasks wait for (System log).
$script:WHDThemeEventLines = @{
    'signout'  = @{ Providers = @('Microsoft-Windows-Winlogon'); Id = 7002; Words = 'sign-out' }
    'shutdown' = @{ Providers = @('User32', 'USER32');           Id = 1074; Words = 'shut-down / restart' }      # the name is compared letter for letter: both ways of writing it
}
function Get-WHDThemeEventQuery {
    # The event-log query a task trigger takes (Task Scheduler reference: EventTrigger, Subscription).
    param([string]$What)
    $l = $script:WHDThemeEventLines[$What]
    if (-not $l) { throw ('no event-log line is known for "{0}"' -f $What) }
    $prov = (@($l.Providers | ForEach-Object { "Provider[@Name='{0}']" -f $_ }) -join ' or ')
    return ("<QueryList><Query Id='0' Path='System'><Select Path='System'>*[System[({0}) and EventID={1}]]</Select></Query></QueryList>" -f $prov, $l.Id)
}
$script:WHDThemeHelperName = 'Invoke-WHDThemeEvent.ps1'
$script:WHDThemeKeyCdm     = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

function Get-WHDThemeEventDir {
    if (-not $env:LOCALAPPDATA) { return '' }
    return (Join-Path (Join-Path $env:LOCALAPPDATA 'WinHardenDebloatNext') 'theme')
}
function Get-WHDThemeEventFile     { $d = Get-WHDThemeEventDir; if (-not $d) { return '' }; return (Join-Path $d 'events.json') }
function Get-WHDThemeEventLog      { $d = Get-WHDThemeEventDir; if (-not $d) { return '' }; return (Join-Path $d 'events.log') }
function Get-WHDThemeHelperSource  { return (Join-Path (Join-Path (Get-WHDThemeCodeRoot) 'tools') $script:WHDThemeHelperName) }
function Get-WHDThemeHelperFile    { $b = Get-WHDThemeBase; if (-not $b) { return '' }; return (Join-Path $b $script:WHDThemeHelperName) }
function Get-WHDThemeLockStateFile { return (Join-Path (Get-WHDThemeStateDir) ('lock-before_{0}.json' -f (Get-WHDThemeUserTag))) }

function Read-WHDThemeEventSettings {
    $o = [ordered]@{ LockPictures = $false; Sounds = $false; LastPicture = '' }
    $f = Get-WHDThemeEventFile
    if ($f -and (Test-Path -LiteralPath $f)) {
        try { $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json; $o.LockPictures = [bool]$j.LockPictures; $o.Sounds = [bool]$j.Sounds; $o.LastPicture = "$($j.LastPicture)" } catch { }
    }
    return [pscustomobject]$o
}
function Write-WHDThemeEventSettings {
    # The helper reads this file. Called inside the change gate only.
    param($Settings)
    $d = Get-WHDThemeEventDir
    if (-not $d) { throw 'this user has no local application-data folder' }
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
    ([pscustomobject]@{ LockPictures = [bool]$Settings.LockPictures; Sounds = [bool]$Settings.Sounds; LastPicture = "$($Settings.LastPicture)" } | ConvertTo-Json) |
        Set-Content -LiteralPath (Get-WHDThemeEventFile) -Encoding ASCII -ErrorAction Stop
}

# ---- Windows itself (the cloud test swaps these five for stand-ins) ------------------------------------------
function Invoke-WHDThemeHelper {
    # Runs the helper on Windows PowerShell 5.1 and returns its exit code and its output lines.
    param([string]$What, [string]$Picture = '')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $hArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Get-WHDThemeHelperFile), '-What', $What)
    if ($Picture) { $hArgs += @('-Picture', $Picture) }
    $global:LASTEXITCODE = 0
    $out = @(& $ps @hArgs 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}
function Get-WHDThemeTask {
    param([string]$Name)
    return @(Get-ScheduledTask -TaskPath $script:WHDThemeTaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $Name })[0]
}
function Register-WHDThemeTask {
    # One task: starts the helper as the signed-in user, WITHOUT administrator rights, hidden.
    param([string]$Name, [string]$What)
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskArgs = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -What {1}' -f (Get-WHDThemeHelperFile), $What)
    $act = New-ScheduledTaskAction -Execute $ps -Argument $taskArgs
    if ($What -eq 'signin') { $trig = New-ScheduledTaskTrigger -AtLogOn -User $user }
    elseif ($script:WHDThemeEventLines.ContainsKey($What)) {
        # sign-out / shut-down: no trigger of their own - the task starts when Windows writes that line into its System event log
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger' -ErrorAction Stop
        $trig = New-CimInstance -CimClass $cls -ClientOnly -Property @{ Subscription = (Get-WHDThemeEventQuery $What); Enabled = $true }
    }
    else {
        # lock = 7, unlock = 8 (Task Scheduler reference, session state change); the class was found on the user's PC by the probe
        $cls = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskSessionStateChangeTrigger' -ErrorAction Stop
        $trig = New-CimInstance -CimClass $cls -ClientOnly -Property @{ StateChange = [uint32]$(if ($What -eq 'lock') { 7 } else { 8 }); UserId = $user; Enabled = $true }
    }
    $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskPath $script:WHDThemeTaskPath -TaskName $Name -Action $act -Trigger $trig -Principal $prin -Settings $set `
        -Description ('WHD Next theme (optional): at {0} - a new lock-screen picture and / or a sound, as switched on in the Theme menu. Runs as the signed-in user without administrator rights.' -f $What) -Force -ErrorAction Stop | Out-Null
}
function Get-WHDThemeEventSeen {
    # Read-only: the newest line of that kind in Windows' System event log (its time), or $null when there is none
    # or the log cannot be read. Tells whether the sign-out / shut-down tasks have anything to react to.
    param([string]$What)
    $l = $script:WHDThemeEventLines[$What]
    if (-not $l) { return $null }
    try {
        foreach ($ev in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $l.Id } -MaxEvents 25 -ErrorAction Stop)) {
            if (@($l.Providers) -contains "$($ev.ProviderName)") { return $ev.TimeCreated }      # newest first
        }
    } catch { }
    return $null
}
function Unregister-WHDThemeTask {
    param([string]$Name)
    if (Get-WHDThemeTask $Name) { Unregister-ScheduledTask -TaskPath $script:WHDThemeTaskPath -TaskName $Name -Confirm:$false -ErrorAction Stop }
}
function Set-WHDThemeFolderGrant {
    # Gives the signed-in user "modify" on ONE folder (and what is in it). Nothing else is opened up.
    param([string]$Dir)
    _WHDIcacls @($Dir, '/grant', ('{0}\{1}:(OI)(CI)M' -f $env:USERDOMAIN, $env:USERNAME), '/Q')
}

# ---- read-only state --------------------------------------------------------------------------------------
function Get-WHDThemeEventState {
    $s = Read-WHDThemeEventSettings
    $have = 0; $haveSnd = 0; $readable = $true
    try {
        foreach ($n in $script:WHDThemeTasks.Keys) { if (Get-WHDThemeTask $n) { $have++ } }
        foreach ($n in $script:WHDThemeSoundTasks.Keys) { if (Get-WHDThemeTask $n) { $haveSnd++ } }
    } catch { $readable = $false }
    $o = [ordered]@{ LockPictures = [bool]$s.LockPictures; Sounds = [bool]$s.Sounds; LastPicture = "$($s.LastPicture)"; Tasks = $have; SoundTasks = $haveSnd; TasksReadable = $readable; LockText = 'off'; SoundText = 'off' }
    $n1 = $script:WHDThemeTasks.Count; $n2 = $n1 + $script:WHDThemeSoundTasks.Count
    $miss = ''; $missSnd = ''
    if ($readable -and $have -lt $n1) { $miss = (' - but {0} of the {1} tasks are missing: choose it again' -f ($n1 - $have), $n1) }
    if ($readable -and ($have + $haveSnd) -lt $n2) { $missSnd = (' - but {0} of the {1} tasks are missing: choose it again' -f ($n2 - $have - $haveSnd), $n2) }
    if ($o.LockPictures) { $o.LockText = ('on{0}{1}' -f $(if ($o.LastPicture) { ' (now: ' + (Split-Path -Leaf $o.LastPicture) + ')' } else { '' }), $miss) }
    if ($o.Sounds) { $o.SoundText = ('on{0}' -f $missSnd) }
    return [pscustomobject]$o
}
function Read-WHDThemeLockBefore {
    $f = Get-WHDThemeLockStateFile
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---- helpers that only the change gate calls ---------------------------------------------------------------------
function Install-WHDThemeEventParts {
    # The helper file (only when missing or different) and the three tasks. -Sounds: also the two tasks for the
    # sign-out and shut-down sounds.
    param([switch]$Sounds)
    $src = Get-WHDThemeHelperSource; $dst = Get-WHDThemeHelperFile
    $b = Get-WHDThemeBase
    if (-not (Test-Path -LiteralPath $b)) { New-Item -ItemType Directory -Path $b -Force -ErrorAction Stop | Out-Null }
    if (Test-Path -LiteralPath $src) { $null = Copy-WHDThemePictureIfNeeded $src $dst }
    if (-not (Test-Path -LiteralPath $dst)) { throw ('the helper was not found: {0}' -f $src) }
    $all = [ordered]@{}
    foreach ($n in $script:WHDThemeTasks.Keys) { $all[$n] = $script:WHDThemeTasks[$n] }
    if ($Sounds) { foreach ($n in $script:WHDThemeSoundTasks.Keys) { $all[$n] = $script:WHDThemeSoundTasks[$n] } }
    foreach ($n in $all.Keys) { Register-WHDThemeTask -Name $n -What $all[$n] }
    foreach ($n in $all.Keys) { if (-not (Get-WHDThemeTask $n)) { throw ('read-back: the scheduled task {0}{1} is not there' -f $script:WHDThemeTaskPath, $n) } }
}
function Remove-WHDThemeEventTasks {
    # Removes the three shared tasks. -SoundsOnly: only the two that belong to the sounds. -All: all five.
    param([switch]$SoundsOnly, [switch]$All)
    $names = @($script:WHDThemeTasks.Keys)
    if ($SoundsOnly) { $names = @($script:WHDThemeSoundTasks.Keys) }
    elseif ($All) { $names = @($script:WHDThemeTasks.Keys) + @($script:WHDThemeSoundTasks.Keys) }
    foreach ($n in $names) { Unregister-WHDThemeTask $n }
    foreach ($n in $names) { if (Get-WHDThemeTask $n) { throw ('read-back: the scheduled task {0}{1} is still there' -f $script:WHDThemeTaskPath, $n) } }
}
function Save-WHDThemeLockBefore {
    # Notes the lock-screen picture in use and whether Windows spotlight was on. Not while WHD's pictures are on.
    $old = Read-WHDThemeLockBefore
    if ($old -and $old.Active) { return $old }
    $pic = ''
    $q = Invoke-WHDThemeHelper -What 'query'
    foreach ($l in @($q.Out)) { if ("$l" -match '^PICTURE=(.*)$') { $pic = $Matches[1].Trim() } }
    $ourDir = "$(Get-WHDThemePictureDir)"
    if ($pic -and $ourDir -and $pic.StartsWith($ourDir, [System.StringComparison]::OrdinalIgnoreCase) -and $old) { $pic = "$($old.Picture)" }   # never note one of ours as "before"
    $sp = Get-WHDThemeRegValue $script:WHDThemeKeyCdm 'RotatingLockScreenEnabled'
    $dir = Get-WHDThemeStateDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
    $doc = [ordered]@{
        What = 'WHD Next theme: the lock-screen picture in use before the WHD pictures. Used by "put back".'
        SavedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); User = "$env:USERDOMAIN\$env:USERNAME"; Computer = "$env:COMPUTERNAME"
        Active = $false; Picture = $pic; Spotlight = $(if ($sp.Exists) { [int]$sp.Value } else { $null })
    }
    ($doc | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (Get-WHDThemeLockStateFile) -Encoding UTF8 -ErrorAction Stop
    return (Read-WHDThemeLockBefore)
}
function Set-WHDThemeLockActive {
    param([bool]$Active)
    $b = Read-WHDThemeLockBefore
    if (-not $b) { return }
    $b.Active = $Active
    ($b | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath (Get-WHDThemeLockStateFile) -Encoding UTF8 -ErrorAction Stop
}

# ---- 7. lock screen and sign-in screen: the WHD pictures ---------------------------------------------------------
function Invoke-WHDThemeLockApply {
    Write-WHDLog 'THEME: lock screen and sign-in screen - the WHD pictures, a new one at every sign-in and unlock' 'ACT'
    if (-not (Get-WHDThemeBase) -or -not (Get-WHDThemeEventDir)) { Write-WHDLog 'No ProgramData / local application-data folder - the theme has no place.' 'ERR'; return }
    $pc = Get-WHDThemePictureCount
    if (-not $pc.Whd) { Write-WHDLog ('The WHD pictures were not found in {0}.' -f (Get-WHDThemePictureSource)) 'ERR'; return }
    if (-not (Test-Path -LiteralPath (Get-WHDThemeHelperSource)) -and -not (Test-Path -LiteralPath (Get-WHDThemeHelperFile))) { Write-WHDLog ('The helper was not found: {0}' -f (Get-WHDThemeHelperSource)) 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: the helper is copied into ProgramData and scheduled tasks are added.' 'ERR'; return }
    Write-WHDRisk 'reversible' ('Makes the WHD pictures the lock-screen picture of this user ({0}) - the screen with the clock at power-on, restart and lock; Windows shows the same picture behind the sign-in box. A NEW picture is chosen at every sign-in and every unlock, so each lock or restart shows another one ({1}). For that WHD copies a small helper to {2} and adds three scheduled tasks under {3} (ThemeSignIn, ThemeLock, ThemeUnlock) that start it as you, WITHOUT administrator rights; a window may flash for a moment when they run. The lock-screen picture in use now is noted first; Theme menu > 8 puts it back. If Windows spotlight is on for the lock screen, "Picture" may have to be chosen once in Settings > Personalization > Lock screen. Verify does not watch this.' -f $env:USERNAME, $pc.Text, (Get-WHDThemeHelperFile), $script:WHDThemeTaskPath)
    if (-not (Confirm-WHDProceed 'use the WHD pictures on the lock screen and sign-in screen')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'lock'; Hint = 'Theme menu (X) > 8 "Put back the lock-screen picture used before"' }
    Invoke-WHDChange -Description 'theme: lock screen + sign-in screen show the WHD pictures (a new one at every sign-in and unlock; 3 tasks)' -Force -Journal $jr -Action {
        $pics = Sync-WHDThemePictures
        if (-not $pics.List.Count) { throw 'no pictures' }
        $src = Get-WHDThemeHelperSource; $dst = Get-WHDThemeHelperFile
        if (Test-Path -LiteralPath $src) { $null = Copy-WHDThemePictureIfNeeded $src $dst }
        $null = Save-WHDThemeLockBefore
        $s = Read-WHDThemeEventSettings
        $was = [bool]$s.LockPictures
        $s.LockPictures = $true
        Write-WHDThemeEventSettings $s
        $r = Invoke-WHDThemeHelper -What 'now'
        $okLine = @($r.Out | Where-Object { "$_" -match '^RESULT=ok picture=(.+)$' })[0]
        if ($r.Code -ne 0 -or -not $okLine) {
            if (-not $was) { $s2 = Read-WHDThemeEventSettings; $s2.LockPictures = $false; Write-WHDThemeEventSettings $s2 }
            throw ('Windows did not take the lock-screen picture (helper code {0}): {1}' -f $r.Code, ((@($r.Out) | Select-Object -Last 3) -join ' | '))
        }
        Install-WHDThemeEventParts
        Set-WHDThemeLockActive $true
        Write-WHDLog ('Lock-screen picture now: {0}. Lock the PC (Windows key + L) to see it; the next unlock chooses another.' -f (Split-Path -Leaf ("$okLine" -replace '^RESULT=ok picture=', ''))) 'INFO'
        $sp = Get-WHDThemeRegValue $script:WHDThemeKeyCdm 'RotatingLockScreenEnabled'
        if ($sp.Exists -and [int]$sp.Value -eq 1) { Write-WHDLog 'Windows spotlight still shows as on for the lock screen. If the lock screen does not show the WHD picture: Settings > Personalization > Lock screen > "Personalize your lock screen" > Picture.' 'WARN' }
        Write-WHDLog 'Sign-in box: the picture shows behind it when Settings > Personalization > Lock screen > "Show the lock screen background picture on the sign-in screen" is on (Windows has it on unless it was changed).' 'INFO'
    } | Out-Null
}

# ---- 8. put the lock-screen picture used before back --------------------------------------------------------------
function Invoke-WHDThemeLockRemove {
    Write-WHDLog 'THEME: put back the lock-screen picture used before' 'ACT'
    $es = Get-WHDThemeEventState
    $before = Read-WHDThemeLockBefore
    if (-not $es.LockPictures -and -not ($before -and $before.Active)) { Write-WHDLog 'The WHD pictures are not switched on for the lock screen - nothing to put back.' 'OK'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: scheduled tasks are removed.' 'ERR'; return }
    $bp = ''; if ($before) { $bp = "$($before.Picture)" }
    $toWhat = 'no earlier picture is known - choose one in Settings > Personalization > Lock screen'
    if ($bp -and (Test-Path -LiteralPath $bp)) { $toWhat = ('the picture from before ({0})' -f $bp) }
    Write-WHDRisk 'reversible' ('Stops the changing lock-screen pictures for this user ({0}) and sets the lock screen back: {1}.{2} {3} The pictures and the helper file stay; choose 7 to use them again.' -f $env:USERNAME, $toWhat, $(if ($before -and $before.Spotlight -eq 1) { ' Windows spotlight was on before: Settings > Personalization > Lock screen > Windows spotlight brings it back.' } else { '' }), $(if ($es.Sounds) { 'The three tasks stay: the sounds at sign-in / lock / unlock still use them.' } else { 'The three tasks are removed.' }))
    if (-not (Confirm-WHDProceed 'put back the lock-screen picture used before')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'lock-remove'; Hint = 'Theme menu (X) > 7 uses the WHD pictures on the lock screen again' }
    Invoke-WHDChange -Description ('theme: lock screen back ({0})' -f $toWhat) -Force -Journal $jr -Action {
        $s = Read-WHDThemeEventSettings
        $s.LockPictures = $false
        Write-WHDThemeEventSettings $s
        if (-not $s.Sounds) { Remove-WHDThemeEventTasks }
        if ($bp -and (Test-Path -LiteralPath $bp)) {
            $r = Invoke-WHDThemeHelper -What 'restore' -Picture $bp
            if ($r.Code -ne 0) { Write-WHDLog ('The picture from before could not be set ({0}) - choose one in Settings > Personalization > Lock screen.' -f ((@($r.Out) | Select-Object -Last 2) -join ' | ')) 'WARN' }
        }
        Set-WHDThemeLockActive $false
        if ($before -and $before.Spotlight -eq 1) { Write-WHDLog 'Windows spotlight was on for the lock screen before: Settings > Personalization > Lock screen > Windows spotlight brings it back.' 'INFO' }
    } | Out-Null
}

# ---- 9 / 10. sounds at sign-in, lock, unlock, sign-out and shut-down ------------------------------------------------
function Invoke-WHDThemeEventSoundsApply {
    Write-WHDLog 'THEME: sounds at sign-in, lock, unlock, sign-out and shut-down' 'ACT'
    if (-not (Get-WHDThemeBase) -or -not (Get-WHDThemeEventDir)) { Write-WHDLog 'No ProgramData / local application-data folder - the theme has no place.' 'ERR'; return }
    $miss = @($script:WHDThemeEventSounds | Where-Object { -not (Test-Path -LiteralPath (Get-WHDThemeSoundFile $_)) })
    if ($miss.Count) { Write-WHDLog ('Sound files are missing ({0}) - choose 1 first.' -f ($miss -join ', ')) 'ERR'; return }
    if (-not (Test-Path -LiteralPath (Get-WHDThemeHelperSource)) -and -not (Test-Path -LiteralPath (Get-WHDThemeHelperFile))) { Write-WHDLog ('The helper was not found: {0}' -f (Get-WHDThemeHelperSource)) 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: the helper is copied into ProgramData and scheduled tasks are added.' 'ERR'; return }
    Write-WHDRisk 'reversible' ('Plays a WHD sound for this user ({0}) at sign-in, when the PC is locked and when it is unlocked - and, when Windows lets it, at sign-out and at shut-down / restart. Windows has no setting for these sounds any more, so five scheduled tasks under {1} (ThemeSignIn, ThemeLock, ThemeUnlock, ThemeSignOut, ThemeShutDown) start a small helper ({2}) as you, WITHOUT administrator rights; a window may flash for a moment. The sound comes a moment after the event. Sign-out and shut-down: Windows has no trigger for them, so those two tasks start when Windows writes its sign-out or shut-down line into the System event log. Windows is closing programs at that moment - these two sounds may be cut short or not be heard at all. At shut-down only the shut-down sound plays, not the sign-out sound as well. Theme menu > 10 switches all of them off. Verify does not watch this.' -f $env:USERNAME, $script:WHDThemeTaskPath, (Get-WHDThemeHelperFile))
    if (-not (Confirm-WHDProceed 'play sounds at sign-in, lock, unlock, sign-out and shut-down')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'eventsounds'; Hint = 'Theme menu (X) > 10 "Switch the sounds at sign-in, lock, unlock, sign-out and shut-down off"' }
    Invoke-WHDChange -Description 'theme: sounds at sign-in, lock, unlock, sign-out and shut-down (5 tasks)' -Force -Journal $jr -Action {
        $s = Read-WHDThemeEventSettings
        $s.Sounds = $true
        Write-WHDThemeEventSettings $s
        Install-WHDThemeEventParts -Sounds
        # read-only look: has this Windows ever written the two lines the sign-out / shut-down tasks wait for?
        foreach ($w in @($script:WHDThemeSoundTasks.Values)) {
            $l = $script:WHDThemeEventLines[$w]
            $seen = Get-WHDThemeEventSeen $w
            if ($seen) { Write-WHDLog ('Event log: the newest {0} line (System log, {1}, number {2}) is from {3} - the {0} sound has something to react to.' -f $l.Words, $l.Providers[0], $l.Id, ([datetime]$seen).ToString('yyyy-MM-dd HH:mm')) 'INFO' }
            else { Write-WHDLog ('Event log: no {0} line (System log, {1}, number {2}) was found, or the log could not be read. If this Windows does not write that line, the {0} sound never plays - the other sounds are not affected.' -f $l.Words, $l.Providers[0], $l.Id) 'WARN' }
        }
    } | Out-Null
}
function Invoke-WHDThemeEventSoundsRemove {
    Write-WHDLog 'THEME: sounds at sign-in, lock, unlock, sign-out and shut-down - off' 'ACT'
    $es = Get-WHDThemeEventState
    if (-not $es.Sounds -and -not $es.SoundTasks) { Write-WHDLog 'The sounds at sign-in, lock, unlock, sign-out and shut-down are not switched on - nothing to do.' 'OK'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: scheduled tasks are removed.' 'ERR'; return }
    Write-WHDRisk 'reversible' ('Switches the sounds at sign-in, lock, unlock, sign-out and shut-down off for this user ({0}). The two tasks for sign-out and shut-down are removed.{1} Choose 9 to switch them on again.' -f $env:USERNAME, $(if ($es.LockPictures) { ' The three tasks stay: the lock-screen pictures still use them.' } else { ' The three tasks are removed.' }))
    if (-not (Confirm-WHDProceed 'switch the sounds at sign-in, lock, unlock, sign-out and shut-down off')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $jr = @{ Kind = 'action'; Theme = 'eventsounds-remove'; Hint = 'Theme menu (X) > 9 switches them on again' }
    Invoke-WHDChange -Description 'theme: sounds at sign-in, lock, unlock, sign-out and shut-down off' -Force -Journal $jr -Action {
        $s = Read-WHDThemeEventSettings
        $s.Sounds = $false
        Write-WHDThemeEventSettings $s
        Remove-WHDThemeEventTasks -SoundsOnly
        if (-not $s.LockPictures) { Remove-WHDThemeEventTasks }
    } | Out-Null
}

# ---- A / Z. everything on, everything put back (user decision 2026-10-05) -------------------------------------------
function Get-WHDThemeOverview {
    # Read-only: what of the theme is on right now. One line each, for the menu's summary and the window version.
    $f = Get-WHDThemeSoundFiles; $s = Get-WHDThemeSchemeState; $l = Get-WHDThemeLookState; $e = Get-WHDThemeEventState; $pc = Get-WHDThemePictureCount
    [pscustomobject]@{
        SoundFiles = $f; Scheme = $s; Look = $l; Events = $e; Pictures = $pc
        Lines = @(
            ('Sound files          : {0}' -f $f.Text)
            ('Sound scheme         : {0}' -f $s.Text)
            ('Look                 : {0}' -f $l.Text)
            ('Pictures             : {0}' -f $pc.Text)
            ('Lock-screen pictures : {0}' -f $e.LockText)
            ('Sounds at sign-in ...: {0}   (sign-in, lock, unlock, sign-out, shut-down)' -f $e.SoundText)
        )
    }
}
function Invoke-WHDThemeSteps {
    # Runs several theme items one after the other with every inner question answered yes (the caller asked once).
    # Each item still goes through the change gate and gets its own journal entry.
    param([scriptblock[]]$Steps)
    $prevC = $script:WHDConfirm; $prevOwn = $script:WHDThemeNoOwnAsk
    $script:WHDConfirm = { param($m) $true }; $script:WHDThemeNoOwnAsk = $true
    try { foreach ($whdThemeStep in $Steps) { try { & $whdThemeStep } catch { Write-WHDLog ('That step stopped on an error: {0} - going on with the next one.' -f $_.Exception.Message) 'ERR' } } }
    finally { $script:WHDConfirm = $prevC; $script:WHDThemeNoOwnAsk = $prevOwn }
}
function Invoke-WHDThemeEverythingOn {
    Write-WHDLog 'THEME: everything on - sound scheme, lock-screen pictures, sounds at sign-in / lock / unlock / sign-out / shut-down, the look' 'ACT'
    if (-not (Get-WHDThemeBase) -or -not (Get-WHDThemeEventDir)) { Write-WHDLog 'No ProgramData / local application-data folder - the theme has no place.' 'ERR'; return }
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: files are written into ProgramData and scheduled tasks are added.' 'ERR'; return }
    $f = Get-WHDThemeSoundFiles
    Write-WHDRisk 'reversible' ('Switches the whole theme on for this user ({0}), one item after the other, with this ONE question: (1) the sound files{1}; (2) the Windows sound scheme "{2}" [item 3]; (3) the WHD pictures on the lock screen and sign-in screen [item 7]; (4) sounds at sign-in, lock, unlock, sign-out and shut-down [item 9]; (5) the look - pictures, dark mode, sky blue [item 5] - for which the Settings window opens and you click the theme "{3}" there. Your own-pictures folder is used as it is; no waiting. Each item notes what was there before and gets its own line in the change history. Z puts everything back, or each item''s own "put back". Verify does not watch any of this.' -f $env:USERNAME, $(if ($f.Missing.Count) { ' are made (' + $f.Missing.Count + ' are missing)' } else { ' are already there' }), $script:WHDThemeSchemeName, $script:WHDThemeDisplay)
    if (-not (Confirm-WHDProceed 'switch the whole theme on (5 items)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $haveSounds = (-not $f.Missing.Count)
    if (-not $haveSounds) {
        if ($script:WHDExecute -and -not $script:WHDSafeMode) { Invoke-WHDThemeMakeSounds; $haveSounds = (-not (Get-WHDThemeSoundFiles).Missing.Count) }
        else { Write-WHDLog 'would: make the 20 sound files (they are missing). The two sound items can only be shown as a preview once the files exist - they are left out of this preview.' 'DRY' }
    }
    $steps = New-Object System.Collections.Generic.List[scriptblock]
    if ($haveSounds) { $steps.Add({ Invoke-WHDThemeSoundSchemeApply }) }
    $steps.Add({ Invoke-WHDThemeLockApply })
    if ($haveSounds) { $steps.Add({ Invoke-WHDThemeEventSoundsApply }) }
    $steps.Add({ Invoke-WHDThemeLookApply })
    Invoke-WHDThemeSteps -Steps @($steps.ToArray())
    if ($script:WHDExecute -and -not $script:WHDSafeMode) {
        $o = Get-WHDThemeOverview
        $on = 0
        if ($o.Scheme.InUse) { $on++ }; if ($o.Look.InUse) { $on++ }; if ($o.Events.LockPictures) { $on++ }; if ($o.Events.Sounds) { $on++ }
        Write-WHDLog ('Everything on: {0} of 4 items are on now.' -f $on) $(if ($on -eq 4) { 'OK' } else { 'WARN' })
        foreach ($ln in $o.Lines) { Write-WHDLog ('  {0}' -f $ln) 'INFO' }
    }
}
function Invoke-WHDThemeEverythingBack {
    Write-WHDLog 'THEME: everything put back' 'ACT'
    if (-not (Test-WHDAdmin)) { Write-WHDLog 'Needs an administrator window: scheduled tasks are removed.' 'ERR'; return }
    $o = Get-WHDThemeOverview
    if (-not ($o.Scheme.InUse -or $o.Scheme.Registered -or $o.Look.InUse -or $o.Look.Active -or $o.Events.LockPictures -or $o.Events.Sounds -or $o.Events.SoundTasks)) { Write-WHDLog 'Nothing of the theme is switched on for this user - nothing to put back.' 'OK'; return }
    Write-WHDRisk 'reversible' ('Puts everything of the theme back for this user ({0}), one item after the other, with this ONE question: (1) the sounds at sign-in, lock, unlock, sign-out and shut-down off [item 10]; (2) the lock-screen picture used before [item 8]; (3) the sound scheme used before [item 4]; (4) the theme used before [item 6] - for which the Settings window opens and you click the theme WHD names. An item that is not on is passed over. Nothing is deleted: sound files, pictures, theme files and the notes stay, so A switches everything on again.' -f $env:USERNAME)
    if (-not (Confirm-WHDProceed 'put everything of the theme back (4 items)')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Invoke-WHDThemeSteps -Steps @({ Invoke-WHDThemeEventSoundsRemove }, { Invoke-WHDThemeLockRemove }, { Invoke-WHDThemeSoundSchemeRemove }, { Invoke-WHDThemeLookRemove })
    if ($script:WHDExecute -and -not $script:WHDSafeMode) {
        $o = Get-WHDThemeOverview
        $on = 0
        if ($o.Scheme.InUse) { $on++ }; if ($o.Look.InUse) { $on++ }; if ($o.Events.LockPictures) { $on++ }; if ($o.Events.Sounds) { $on++ }
        Write-WHDLog ('Everything put back: {0} of 4 items are still on.' -f $on) $(if ($on -eq 0) { 'OK' } else { 'WARN' })
        foreach ($ln in $o.Lines) { Write-WHDLog ('  {0}' -f $ln) 'INFO' }
    }
}

# ---- menu ----------------------------------------------------------------------------------------------
function Show-WHDThemeMenu {
    $f = Get-WHDThemeSoundFiles
    $s = Get-WHDThemeSchemeState
    Write-Host ''
    Write-Host '  ================= THEME (optional) =================' -ForegroundColor White
    Write-Host '  An old ship, held together by its crew and its AI.' -ForegroundColor DarkGray
    Write-Host '  Optional: not part of any profile, and Verify does not watch it. It is set for the user WHD Next runs as.' -ForegroundColor DarkGray
    Write-Host '  Everything' -ForegroundColor DarkGray
    Write-Host '   A. Everything on         (one question: sound files if missing, 3, 7, 9, then 5 with its click in Settings)'
    Write-Host '   Z. Everything put back   (one question: 10, 8, 4, then 6 with its click in Settings)'
    Write-Host '  Sounds' -ForegroundColor DarkGray
    Write-Host ('   1. Make the sound files                      (now: {0})' -f $f.Text)
    Write-Host '   2. Listen                                    (all 20;  "2 lock" = one;  "2 ?" = the names)'
    Write-Host ('   3. Use them: Windows sound scheme "{0}"   (now: {1})' -f $script:WHDThemeSchemeName, $s.Text)
    Write-Host '   4. Put back the sound scheme used before'
    $l = Get-WHDThemeLookState
    $pc = Get-WHDThemePictureCount
    Write-Host '  Look' -ForegroundColor DarkGray
    Write-Host ('   5. Use the look: pictures, dark mode, sky blue  (now: {0})' -f $l.Text)
    Write-Host ('                                                   ({0}; a new picture every 30 minutes; choose 5 again after adding pictures)' -f $pc.Text) -ForegroundColor DarkGray
    Write-Host ('  5R. The same look with hot rod red                 (now: {0})' -f $l.RedText)
    Write-Host '                                                   (both are in Settings > Personalization > Themes: "WHD Next" and "WHD Next (red)" - a click there changes the colour too; WHD never changes it by itself)' -ForegroundColor DarkGray
    Write-Host '   6. Put back the theme used before'
    $e = Get-WHDThemeEventState
    Write-Host '  Lock screen and sign-in screen  (the screen with the clock at power-on, restart and lock; the picture behind the sign-in box)' -ForegroundColor DarkGray
    Write-Host ('   7. Use the WHD pictures there, a new one at every sign-in and unlock   (now: {0})' -f $e.LockText)
    Write-Host '   8. Put back the lock-screen picture used before'
    Write-Host '  Sounds at sign-in, lock, unlock, sign-out and shut-down  (the last two may not always play: Windows is closing programs then)' -ForegroundColor DarkGray
    Write-Host ('   9. Switch them on                            (now: {0})' -f $e.SoundText)
    Write-Host '  10. Switch them off'
    Write-Host '  The window version (Start-WHD.ps1 -Gui) has the same items on its tab "Theme". Description: docs\theme.md' -ForegroundColor DarkGray
    Write-Host '   B. Back'
}
function Invoke-WHDThemeSubmenu {
    while ($true) {
        if (Get-Command Show-WHDMode -EA SilentlyContinue) { Show-WHDMode }
        Show-WHDThemeMenu
        $c = (Read-Host '  Select').Trim()
        if ((Get-Command Invoke-WHDGuardHotkey -EA SilentlyContinue) -and (Invoke-WHDGuardHotkey $c)) { continue }
        switch -regex ($c) {
            '^[Aa]$'     { Invoke-WHDThemeEverythingOn }
            '^[Zz]$'     { Invoke-WHDThemeEverythingBack }
            '^1$'        { Invoke-WHDThemeMakeSounds }
            '^2$'        { Invoke-WHDThemeListen }
            '^2\s+(.+)$' { Invoke-WHDThemeListen -Names @($Matches[1]) }
            '^3$'        { Invoke-WHDThemeSoundSchemeApply }
            '^4$'        { Invoke-WHDThemeSoundSchemeRemove }
            '^5$'        { Invoke-WHDThemeLookApply }
            '^5\s*[Rr]$' { Invoke-WHDThemeLookApply -Red }
            '^6$'        { Invoke-WHDThemeLookRemove }
            '^7$'        { Invoke-WHDThemeLockApply }
            '^8$'        { Invoke-WHDThemeLockRemove }
            '^9$'        { Invoke-WHDThemeEventSoundsApply }
            '^10$'       { Invoke-WHDThemeEventSoundsRemove }
            '^[Bb]$'     { return }
            '^$'         { return }
            default      { Write-Host '  invalid.' -ForegroundColor Yellow }
        }
    }
}

Write-WHDLog 'Theme.ps1 loaded.' 'INFO'
