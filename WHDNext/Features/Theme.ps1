#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Theme.ps1   (optional theme: "an old ship")
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6 in three
 parts (D57): a = sounds 1-4 (5.10a), b = the look 5 / 6 (5.10b, ThemeLook.ps1;
 one colour, sky blue - no 5R, D69), c = lock screen 7 / 8, sounds at sign-in
 etc. 9 / 10, A / Z (5.10c, ThemeEvent.ps1; D73-D75). Keys as 2.0 (D62).
   1  make the 20 .wav files     records the ship's voice (Windows' Zira, D67),
                                 asks the effects pitch (Enter = 0.5); all 20 there:
                                 asks before making them again (D86); only with
                                 EXECUTE on (D84); safe mode does not stop it - it
                                 writes only WHD's own folder, no Windows setting
   2  listen                     all 20, "2 lock" = one, "2 ?" = the names
   3  use them                   sound scheme "WHD Next 3.0" for this user (D63)
   4  put back                   ALWAYS the Windows Default scheme (D61); also
                                 takes 2.0's "WHD Next" scheme out of the list
 Files: C:\ProgramData\WinHardenDebloatNext\app\theme\sounds (D60). WHD Next
 2.0's files in ...\theme\sounds are not touched.
 Sound schemes are per user (HKCU\AppEvents); WHD sets them for the user it
 runs as. Optional: not part of any profile; Verify does not watch it.
================================================================================
#>

$script:WHDThemeSchemeKey  = 'WHDNext3'        # the scheme's key name (D63)
$script:WHDThemeSchemeName = 'WHD Next 3.0'    # the name in Windows' Sound window (D63)
$script:WHDThemeOldKeys    = @('WHDNext')      # WHD Next 2.0's scheme: put back takes it out too (D63)
$script:WHDThemeAppsKey    = 'AppEvents\Schemes\Apps'
$script:WHDThemeNamesKey   = 'AppEvents\Schemes\Names'
$script:WHDThemeSchemesKey = 'AppEvents\Schemes'
$script:WHDThemeBaseOverride = $null            # tests only

# $script:WHDThemeSoundEvents (Windows event -> our sound) and $script:WHDThemeSoundNames are built
# from the sound list at the end of ThemeSound.ps1 (it loads after this file), so they never differ.

# ---- folders ----------------------------------------------------------------------------------------
function Get-WHDThemeBase {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDThemeBaseOverride) { return $script:WHDThemeBaseOverride }
    if (-not $env:ProgramData) { return '' }
    return [System.IO.Path]::Combine($env:ProgramData, 'WinHardenDebloatNext', 'app', 'theme')
}
function Get-WHDThemeSoundDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $b = Get-WHDThemeBase; if (-not $b) { return '' }
    return [System.IO.Path]::Combine($b, 'sounds')
}
function Get-WHDThemeSoundFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    return [System.IO.Path]::Combine((Get-WHDThemeSoundDir), ('whd-{0}.wav' -f $Name))
}

# ---- the registry: default values under HKEY_CURRENT_USER ------------------------------------------
# Sound schemes live in the "(Default)" value of many small keys. These four are the only place that
# touches them (the tests swap them for stand-ins).
function Get-WHDThemeRegSubKey {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$SubKey)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($null -eq $k) { return }
    try { return $k.GetSubKeyNames() } finally { $k.Dispose() }
}
function Get-WHDThemeRegDefault {
    # Exists (the key), HasValue (a default value is set), Value (not expanded), Kind ('String' | 'ExpandString').
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubKey)
    $o = [pscustomobject]@{ Exists = $false; HasValue = $false; Value = ''; Kind = 'String' }
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey)
    if ($null -eq $k) { return $o }
    try {
        $o.Exists = $true
        if (@($k.GetValueNames()) -contains '') {
            $o.HasValue = $true
            $o.Value = [string]$k.GetValue('', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $o.Kind = if ([string]$k.GetValueKind('') -eq 'ExpandString') { 'ExpandString' } else { 'String' }
        }
    } finally { $k.Dispose() }
    return $o
}
function Set-WHDThemeRegDefault {
    # Creates the key when needed and sets its default value.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SubKey, [AllowEmptyString()][string]$Value, [string]$Kind = 'String')
    if (-not $PSCmdlet.ShouldProcess("HKCU\$SubKey", 'set default value')) { return }
    $rk = if ($Kind -eq 'ExpandString') { [Microsoft.Win32.RegistryValueKind]::ExpandString } else { [Microsoft.Win32.RegistryValueKind]::String }
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($SubKey)
    if ($null -eq $k) { throw ('registry key could not be opened for writing: HKCU\{0}' -f $SubKey) }
    try { $k.SetValue('', $Value, $rk) } finally { $k.Dispose() }
}
function Remove-WHDThemeRegKey {
    # Removes one key and what is under it. A key that is not there is fine.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$SubKey)
    if (-not $PSCmdlet.ShouldProcess("HKCU\$SubKey", 'remove key')) { return }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($SubKey, $false)
}

# ---- read-only state ----------------------------------------------------------------------------------
function Get-WHDThemeSoundFileState {
    # Which of the 20 files exist.
    [CmdletBinding()]
    param()
    $dir = Get-WHDThemeSoundDir
    $have = @($script:WHDThemeSoundNames | Where-Object { $dir -and (Test-Path -LiteralPath (Get-WHDThemeSoundFile $_)) })
    $miss = @($script:WHDThemeSoundNames | Where-Object { $have -notcontains $_ })
    [pscustomobject]@{ Dir = $dir; Have = $have; Missing = $miss; Text = ('{0} of {1} in {2}' -f $have.Count, $script:WHDThemeSoundNames.Count, $dir) }
}
function Get-WHDThemeSchemeState {
    # The scheme in use, and whether ours (3.0) or 2.0's is on the user's list.
    [CmdletBinding()]
    param()
    $o = [ordered]@{ Readable = $true; Key = ''; Name = ''; InUse = $false; Registered = $false; OldRegistered = $false; Text = '' }
    try {
        $o.Key = [string](Get-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey).Value
        $o.InUse = ($o.Key -eq $script:WHDThemeSchemeKey)
        $o.Registered = [bool](Get-WHDThemeRegDefault -SubKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $script:WHDThemeSchemeKey)).Exists
        $o.OldRegistered = [bool](@($script:WHDThemeOldKeys | Where-Object { (Get-WHDThemeRegDefault -SubKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $_)).Exists }).Count)
        $o.Name = $o.Key
        if ($o.Key) { $nm = Get-WHDThemeRegDefault -SubKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $o.Key); if ($nm.HasValue -and $nm.Value) { $o.Name = [string]$nm.Value } }
        if ($o.Key -eq '.Default') { $o.Name = 'Windows Default' } elseif ($o.Key -eq '.None') { $o.Name = 'No Sounds' }
        $o.Text = if ($o.InUse) { 'in use' } elseif ($o.Key) { ('not in use - in use: {0}' -f $o.Name) } else { 'not in use - no scheme name set (sounds changed one by one)' }
    } catch { $o.Readable = $false; $o.Text = ('not readable: {0}' -f $_.Exception.Message) }
    return [pscustomobject]$o
}
function Get-WHDThemeEventList {
    # Every sound event of every app: App, Event and its key.
    [CmdletBinding()]
    [OutputType([object[]], [System.Array])]
    param()
    @(foreach ($app in @(Get-WHDThemeRegSubKey -SubKey $script:WHDThemeAppsKey)) {
        foreach ($ev in @(Get-WHDThemeRegSubKey -SubKey ('{0}\{1}' -f $script:WHDThemeAppsKey, $app))) {
            [pscustomobject]@{ App = $app; Event = $ev; Key = ('{0}\{1}\{2}' -f $script:WHDThemeAppsKey, $app, $ev) }
        }
    })
}
function Test-WHDThemeOurEvent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Item)
    return ($Item.App -eq '.Default' -and $script:WHDThemeSoundEvents.Contains($Item.Event))
}

# ---- 1. make the files ----------------------------------------------------------------------------------
function Write-WHDThemeWav {
    # The one place that writes a .wav file (tests swap it).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}
function Invoke-WHDThemeSoundMake {
    # Writes the 20 .wav files into WHD's own folder. Only with EXECUTE on - dry-run only says what it would make (D84,
    # replaces D63's dry-run part). No Windows setting, so safe mode does not stop it.
    [CmdletBinding()]
    param([string[]]$Answer)
    $ask = Get-WHDAnswerReader -Answer $Answer
    $dir = Get-WHDThemeSoundDir
    Write-WHDLog -Message 'THEME 1: make the sound files' -Level 'ACT'
    if (-not $dir) { Write-WHDLog -Message 'No ProgramData folder on this PC - the sound files have no place.' -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message ('Needs an administrator window: {0} can only be changed by administrators.' -f $dir) -Level 'WARN'; return }
    if (-not $script:WHDState.Execute) {
        Write-WHDLog -Message ('would: make the {0} sound files in {1} (the effects pitch is asked first; Enter = 0.5). Turn EXECUTE on to make them.' -f $script:WHDThemeSounds.Count, $dir) -Level 'DRY'
        return
    }
    if (-not (Get-WHDThemeSoundFileState).Missing.Count) {
        # all there already: ask before making them again (D86)
        $again = ([string](& $ask ('  All {0} sound files are already there. Make them again (a few minutes)? y/N' -f $script:WHDThemeSounds.Count))).Trim()
        if ($again -notmatch '^[Yy]') { Write-WHDLog -Message 'Kept the sound files that are there.' -Level 'OK'; return }
    }
    $t = ([string](& $ask ('  Pitch of the effects ({0} to {1}; Enter = 0.5; the voice is never pitched)' -f $script:WHDSynthPitchMin, $script:WHDSynthPitchMax))).Trim()
    $pitch = 0.5
    if ($t) {
        $v = 0.0
        if (-not [double]::TryParse($t, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or $v -lt $script:WHDSynthPitchMin -or $v -gt $script:WHDSynthPitchMax) {
            Write-WHDLog -Message ('Pitch "{0}" not understood - give a number from {1} to {2} (e.g. 0.5). Nothing made.' -f $t, $script:WHDSynthPitchMin, $script:WHDSynthPitchMax) -Level 'WARN'; return
        }
        $pitch = $v
    }
    try { if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop) } }
    catch { Write-WHDLog -Message ('The folder could not be made: {0} ({1})' -f $dir, $_.Exception.Message) -Level 'ERR'; return }
    # the ship's voice: Windows' own offline speech, Zira (D66, D67); none = sounds without a voice
    Write-WHDLog -Message ('Recording the ship''s voice ("{0}", Windows'' own speech) ...' -f $script:WHDThemeVoiceName)
    $vdir = [System.IO.Path]::Combine((Get-WHDThemeBase), 'voice')
    $voice = @{ Voice = ''; Files = @{} }
    try { $voice = Invoke-WHDThemeVoiceRecord -Dir $vdir } catch { Write-WHDLog -Message ('The voice could not be recorded: {0}' -f $_.Exception.Message) -Level 'WARN' }
    if ($voice.Files.Count) { Write-WHDLog -Message ('  voice: {0} - {1} of {2} lines recorded' -f $voice.Voice, $voice.Files.Count, $script:WHDThemeSounds.Count) }
    else { Write-WHDLog -Message ('  no "{0}" voice on this PC - the sounds are made without a voice (D67).' -f $script:WHDThemeVoiceName) -Level 'WARN' }
    Write-WHDLog -Message ('Making {0} sounds (effects pitch {1}) in {2}. No Windows setting is changed. This takes a few minutes.' -f $script:WHDThemeSounds.Count, $pitch, $dir)
    $made = 0; $failed = 0; $i = 0
    foreach ($s in $script:WHDThemeSounds) {
        $i++
        Write-Progress -Activity 'Making the theme sounds' -Status $s.Name -PercentComplete ([int](100 * ($i - 1) / $script:WHDThemeSounds.Count))
        try {
            $vp = if ($voice.Files.ContainsKey($s.Name)) { $voice.Files[$s.Name] } else { '' }
            $x = Get-WHDThemeSound -Name $s.Name -Pitch $pitch -VoicePath $vp
            Write-WHDThemeWav -Path (Get-WHDThemeSoundFile $s.Name) -Bytes (ConvertTo-WHDWavData -St $x)
            $made++
            Write-WHDLog -Message ('  made  {0,-16} {1,5:N2} s   {2}{3}' -f $s.Name, ($x[0].Length / [double]$script:WHDSynth.Rate), $s.For, $(if ($vp) { '' } else { '  (no voice)' }))
        } catch {
            $failed++
            Write-WHDLog -Message ('  FAILED {0}: {1}' -f $s.Name, $_.Exception.Message) -Level 'ERR'
        }
    }
    Write-Progress -Activity 'Making the theme sounds' -Completed
    Write-WHDLog -Message ('Sound files: {0} made, {1} failed (effects pitch {2}; voice: {3}).' -f $made, $failed, $pitch, $(if ($voice.Files.Count) { $voice.Voice } else { 'none' })) -Level $(if ($failed) { 'WARN' } else { 'OK' })
}

# ---- 2. listen ---------------------------------------------------------------------------------------------
function Invoke-WHDThemePlayFile {
    # Plays one .wav and waits for it (tests swap it). $false = no player in this PowerShell.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $p = $null
    try { $p = [System.Media.SoundPlayer]::new($Path) } catch { return $false }
    try { $p.Load(); $p.PlaySync() } finally { $p.Dispose() }
    return $true
}
function Invoke-WHDThemeListen {
    # Plays all files, or the named ones. Changes nothing.
    [CmdletBinding()]
    param([string]$Names)
    $want = @(([string]$Names) -split '[,\s]+' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    if ($want -contains '?') { Write-Host ('  names: {0}' -f ($script:WHDThemeSoundNames -join ', ')); return }
    $bad = @($want | Where-Object { $script:WHDThemeSoundNames -notcontains $_ })
    if ($bad.Count) { Write-Host ('  unknown sound name(s): {0}' -f ($bad -join ', ')) -ForegroundColor Yellow; Write-Host ('  names: {0}' -f ($script:WHDThemeSoundNames -join ', ')); return }
    $list = @(if ($want.Count) { $want } else { $script:WHDThemeSoundNames })
    if (-not (Get-WHDThemeSoundFileState).Have.Count) { Write-Host '  The sound files are not made yet - choose 1 first.' -ForegroundColor Yellow; return }
    Write-Host '  Playing - nothing is changed:' -ForegroundColor Cyan
    $i = 0
    foreach ($n in $list) {
        $i++
        $f = Get-WHDThemeSoundFile $n
        $for = @($script:WHDThemeSounds | Where-Object { $_.Name -eq $n } | Select-Object -First 1)[0].For
        if (-not (Test-Path -LiteralPath $f)) { Write-Host ('   {0,2}. {1,-16} (file not found)' -f $i, $n) -ForegroundColor Yellow; continue }
        Write-Host ('   {0,2}. {1,-16} {2}' -f $i, $n, $for)
        try { if (-not (Invoke-WHDThemePlayFile -Path $f)) { Write-Host '  The sounds cannot be played in this PowerShell.' -ForegroundColor Yellow; return } }
        catch { Write-Host ('       could not be played: {0}' -f $_.Exception.Message) -ForegroundColor Yellow }
        if ($list.Count -gt 1) { Start-Sleep -Milliseconds 450 }
    }
}

# ---- 3. use them --------------------------------------------------------------------------------------------
function Get-WHDThemeWindowsDefault {
    # What the Windows Default scheme plays for one event: @{Has; Value; Kind}. Has = $false: no ".Default" entry.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Item)
    $d = Get-WHDThemeRegDefault -SubKey ('{0}\.Default' -f $Item.Key)
    if (-not $d.Exists) { return [pscustomobject]@{ Has = $false; Value = ''; Kind = 'String' } }
    [pscustomobject]@{ Has = $true; Value = $(if ($d.HasValue) { [string]$d.Value } else { '' }); Kind = $d.Kind }
}
function Set-WHDThemeSoundScheme {
    # The registry writes for "WHD Next 3.0". Called inside the change gate only.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Events)
    if (-not $PSCmdlet.ShouldProcess('HKCU\AppEvents', ('sound scheme {0}' -f $script:WHDThemeSchemeName))) { return }
    $me = $script:WHDThemeSchemeKey
    Set-WHDThemeRegDefault -SubKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $me) -Value $script:WHDThemeSchemeName
    foreach ($e in $Events) {
        if (Test-WHDThemeOurEvent -Item $e) { $val = Get-WHDThemeSoundFile $script:WHDThemeSoundEvents[$e.Event]; $kind = 'String' }
        else {
            # every other event: what the Windows Default scheme has (silent stays silent);
            # an event with no ".Default" entry (another program's own) keeps the sound it has now
            $d = Get-WHDThemeWindowsDefault -Item $e
            if (-not $d.Has) { $c = Get-WHDThemeRegDefault -SubKey ('{0}\.Current' -f $e.Key); $d = [pscustomobject]@{ Value = $(if ($c.HasValue) { [string]$c.Value } else { '' }); Kind = $c.Kind } }
            $val = $d.Value; $kind = $d.Kind
        }
        Set-WHDThemeRegDefault -SubKey ('{0}\{1}' -f $e.Key, $me) -Value $val -Kind $kind
        Set-WHDThemeRegDefault -SubKey ('{0}\.Current' -f $e.Key) -Value $val -Kind $kind
    }
    Set-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey -Value $me
}
function Invoke-WHDThemeSchemeApply {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message ('THEME 3: Windows sound scheme -> "{0}"' -f $script:WHDThemeSchemeName) -Level 'ACT'
    $f = Get-WHDThemeSoundFileState
    if ($f.Missing.Count) { Write-WHDLog -Message ('The sound files are not complete ({0}) - choose 1 first.' -f $f.Text) -Level 'WARN'; return }
    $st = Get-WHDThemeSchemeState
    if (-not $st.Readable) { Write-WHDLog -Message ('The sound schemes of this user could not be read: {0}' -f $st.Text) -Level 'ERR'; return }
    $events = @(Get-WHDThemeEventList)
    $ours = @($events | Where-Object { Test-WHDThemeOurEvent -Item $_ })
    if (-not $ours.Count) { Write-WHDLog -Message 'None of the Windows sound events WHD knows were found for this user - nothing to set.' -Level 'WARN'; return }
    Write-WHDRisk -Tier 'reversible' -Text ('Adds the sound scheme "{0}" for this user ({1}) and makes it the one in use: {2} everyday Windows sounds become the WHD sounds; the other {3} events get what the Windows Default scheme has (silent ones stay silent). Now in use: {4}. Theme 4 puts back the Windows Default scheme; Windows'' own Sound window can switch schemes at any time.' -f $script:WHDThemeSchemeName, $env:USERNAME, $ours.Count, ($events.Count - $ours.Count), $st.Name)
    if (-not (Confirm-WHDProceed -What ('use the sound scheme "{0}"' -f $script:WHDThemeSchemeName))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $probe = $ours[0]
    $want = Get-WHDThemeSoundFile $script:WHDThemeSoundEvents[$probe.Event]
    Invoke-WHDChange -Description ('theme: sound scheme -> "{0}" ({1} WHD sounds, {2} events; before: {3})' -f $script:WHDThemeSchemeName, $ours.Count, $events.Count, $st.Name) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 4 puts back the Windows Default sound scheme (or pick a scheme in Windows'' Sound window)' } -Action {
        Set-WHDThemeSoundScheme -Events $events -Confirm:$false
        $after = Get-WHDThemeSchemeState
        if (-not $after.InUse) { throw ('read-back: the scheme in use is "{0}", not "{1}"' -f $after.Key, $script:WHDThemeSchemeKey) }
        $now = [string](Get-WHDThemeRegDefault -SubKey ('{0}\.Current' -f $probe.Key)).Value
        if ($now -ne $want) { throw ('read-back: {0} plays "{1}", not "{2}"' -f $probe.Event, $now, $want) }
    } | Out-Null
}

# ---- 4. put back: always the Windows Default scheme (D61) ---------------------------------------------------
function Restore-WHDThemeWindowsDefault {
    # The registry writes for "put back". Called inside the change gate only.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Events)
    if (-not $PSCmdlet.ShouldProcess('HKCU\AppEvents', 'Windows Default sound scheme')) { return }
    $keys = @($script:WHDThemeSchemeKey) + @($script:WHDThemeOldKeys)
    foreach ($e in $Events) {
        $d = Get-WHDThemeWindowsDefault -Item $e
        if ($d.Has) { Set-WHDThemeRegDefault -SubKey ('{0}\.Current' -f $e.Key) -Value $d.Value -Kind $d.Kind }
        elseif (Test-WHDThemeOurEvent -Item $e) { Set-WHDThemeRegDefault -SubKey ('{0}\.Current' -f $e.Key) -Value '' }   # ours, but Windows has no default: silent
        # an event with no ".Default" entry that is not ours (another program's own) is left as it is
        foreach ($k in $keys) { Remove-WHDThemeRegKey -SubKey ('{0}\{1}' -f $e.Key, $k) -Confirm:$false }
    }
    Set-WHDThemeRegDefault -SubKey $script:WHDThemeSchemesKey -Value '.Default'
    foreach ($k in $keys) { Remove-WHDThemeRegKey -SubKey ('{0}\{1}' -f $script:WHDThemeNamesKey, $k) -Confirm:$false }
}
function Invoke-WHDThemeSchemeRemove {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'THEME 4: put back the Windows Default sound scheme' -Level 'ACT'
    $st = Get-WHDThemeSchemeState
    if (-not $st.Readable) { Write-WHDLog -Message ('The sound schemes of this user could not be read: {0}' -f $st.Text) -Level 'ERR'; return }
    $isOld = ($script:WHDThemeOldKeys -contains $st.Key)
    if (-not ($st.InUse -or $st.Registered -or $st.OldRegistered -or $isOld)) { Write-WHDLog -Message ('Neither "{0}" nor WHD Next 2.0''s scheme is on this user''s account - nothing to put back. In use: {1}.' -f $script:WHDThemeSchemeName, $st.Name) -Level 'OK'; return }
    $events = @(Get-WHDThemeEventList)
    Write-WHDRisk -Tier 'reversible' -Text ('Puts every sound of this user ({0}) back to the Windows Default scheme (D61), and takes "{1}" and WHD Next 2.0''s "WHD Next" out of Windows'' list. Now in use: {2}. The sound files stay in {3}; choose 3 to use them again.' -f $env:USERNAME, $script:WHDThemeSchemeName, $st.Name, (Get-WHDThemeSoundDir))
    if (-not (Confirm-WHDProceed -What 'put back the Windows Default sound scheme')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('theme: sound scheme back to Windows Default ({0} events; before: {1})' -f $events.Count, $st.Name) -Journal @{ Kind = 'action'; Hint = 'Theme menu > 3 uses the WHD sounds again' } -Action {
        Restore-WHDThemeWindowsDefault -Events $events -Confirm:$false
        $after = Get-WHDThemeSchemeState
        if ($after.Key -ne '.Default' -or $after.Registered -or $after.OldRegistered) { throw 'read-back: a WHD sound scheme is still there' }
    } | Out-Null
}

# ---- menu ---------------------------------------------------------------------------------------------------
function Show-WHDThemeMenu {
    [CmdletBinding()]
    param()
    $f = Get-WHDThemeSoundFileState
    $s = Get-WHDThemeSchemeState
    Write-Host ''
    Write-Host '  ================= THEME (optional) =================' -ForegroundColor White
    Write-Host '  An old ship, held together by its crew and its AI.' -ForegroundColor DarkGray
    Write-Host '  Not part of any profile; Verify does not watch it. Set for the user WHD runs as.' -ForegroundColor DarkGray
    Write-Host '  Sounds' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '1' -Label ('Make the sound files  (now: {0})' -f $f.Text) -Hint '[voice: Windows'' Zira; asks the effects pitch; EXECUTE only; a few minutes]'
    Write-WHDMenuItem -Key '2' -Label 'Listen  (all 20;  "2 lock" = one;  "2 ?" = the names)'
    Write-WHDMenuItem -Key '3' -Label ('Use them: sound scheme "{0}"  (now: {1})' -f $script:WHDThemeSchemeName, $s.Text)
    Write-WHDMenuItem -Key '4' -Label 'Put back the Windows Default sound scheme'
    $l = Get-WHDLookState
    Write-Host '  Look' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '5' -Label ('Use the look "{0}": pictures, dark mode, sky blue  (now: {1})' -f $script:WHDLookName, $l.Text) -Hint ('[{0}; a new one every 30 minutes]' -f $l.PicText)
    Write-WHDMenuItem -Key '6' -Label 'Put back Windows'' own dark theme'
    $e = Get-WHDEvState
    Write-Host '  Lock screen  (the screen with the clock; the sign-in box shows the same picture)' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '7' -Label 'Use the WHD pictures there: Windows'' lock-screen slide show' -Hint '[Settings opens; you choose Slideshow and paste the folder]'
    Write-WHDMenuItem -Key '8' -Label 'Put back the lock screen' -Hint '[Settings opens; you choose Picture or Windows spotlight]'
    Write-Host '  Sounds at sign-in, lock and unlock  (none at sign-out / shut-down: Windows does not start tasks then)' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '9' -Label ('Switch them on  (now: {0})' -f $e.Text) -Hint '[3 tasks run as you; a window may flash]'
    Write-WHDMenuItem -Key '10' -Label 'Switch them off'
    if ($e.OldText) { Write-Host ('  Note: {0} - 9, 10, A or Z removes them.' -f $e.OldText) -ForegroundColor DarkGray }
    Write-Host '  Everything' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'A' -Label 'Everything on  (one question: 1 if missing, 3, 9, 5, 7)'
    Write-WHDMenuItem -Key 'Z' -Label 'Everything put back  (one question: 10, 4, 6, 8)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDThemeChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the follow-up questions (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^1$' { Invoke-WHDThemeSoundMake -Answer $Answer }
        '^2$' { Invoke-WHDThemeListen }
        '^2\s+(.+)$' { Invoke-WHDThemeListen -Names $Matches[1] }
        '^3$' { Invoke-WHDThemeSchemeApply }
        '^4$' { Invoke-WHDThemeSchemeRemove }
        '^5$' { Invoke-WHDLookApply -Answer $Answer }
        '^6$' { Invoke-WHDLookRemove -Answer $Answer }
        '^5[Rr]$' { Write-Host '  WHD Next 3.0 has one look, in sky blue (D69) - choose 5.' -ForegroundColor DarkGray }
        '^7$' { Invoke-WHDEvLockApply -Answer $Answer }
        '^8$' { Invoke-WHDEvLockRemove -Answer $Answer }
        '^9$' { Invoke-WHDEvSoundApply }
        '^10$' { Invoke-WHDEvSoundRemove }
        '^[Aa]$' { Invoke-WHDThemeAllOn -Answer $Answer }
        '^[Zz]$' { Invoke-WHDThemeAllBack -Answer $Answer }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
