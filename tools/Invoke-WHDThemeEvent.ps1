<#
================================================================================
 WHD Next  -  tools\Invoke-WHDThemeEvent.ps1   (optional theme: the small helper)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Runs on WINDOWS POWERSHELL 5.1 (the lock-screen call below does not exist in
 PowerShell 7). WHD Next copies this file to
     C:\ProgramData\WinHardenDebloatNext\theme\Invoke-WHDThemeEvent.ps1
 (a folder only administrators can change) and scheduled tasks start it from
 there, as the signed-in user, WITHOUT administrator rights:
     at sign-in, when the PC is locked, when it is unlocked - and, for the
     sounds only, at sign-out and at shut-down / restart (those two tasks are
     started by a line Windows writes into its System event log).

 What it does - only what is switched on in the user's own settings file
 %LOCALAPPDATA%\WinHardenDebloatNext\theme\events.json  (written by WHD Next):
   LockPictures : at sign-in and at unlock it picks another picture from
                  ...\theme\pictures and makes it the lock-screen picture, so
                  the NEXT time the lock screen shows (lock, restart, power-on)
                  a different picture is there. Windows shows the same picture
                  behind the sign-in box (password / PIN).
   Sounds       : plays whd-signin.wav / whd-lock.wav / whd-unlock.wav /
                  whd-signout.wav / whd-shutdown.wav. At shut-down only the
                  shut-down sound plays: the sign-out that is part of it
                  stays silent. Windows is closing programs at sign-out and
                  shut-down, so these two sounds may be cut short.
 It writes one line per run to ...\theme\events.log in the same user folder.

 -What  signin | lock | unlock   what just happened (from the tasks)
        signout | shutdown        the same, for the sounds only
        now                       set a new lock-screen picture right now
        query                     only say which picture the lock screen has
        restore                   put -Picture back as the lock-screen picture
 It changes nothing else: no registry value, no policy, no file outside the
 user's own WinHardenDebloatNext folder. Exit code 0 = fine.
================================================================================
#>
param(
    [ValidateSet('signin', 'lock', 'unlock', 'signout', 'shutdown', 'now', 'query', 'restore')][string]$What = 'now',
    [string]$Picture = ''
)
$ErrorActionPreference = 'Stop'
$whdBase    = Split-Path -Parent $MyInvocation.MyCommand.Path
$whdUserDir = Join-Path $env:LOCALAPPDATA 'WinHardenDebloatNext\theme'
$whdSetFile = Join-Path $whdUserDir 'events.json'
$whdLogFile = Join-Path $whdUserDir 'events.log'

function Write-WHDEventLog {
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $whdUserDir)) { New-Item -ItemType Directory -Path $whdUserDir -Force | Out-Null }
        $line = '{0}  {1,-8} {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $What, $Text
        Add-Content -LiteralPath $whdLogFile -Value $line -Encoding ASCII
        # keep the log small: when it grows past 100 KB only the newest 300 lines stay
        if ((Get-Item -LiteralPath $whdLogFile).Length -gt 100KB) {
            $keep = @(Get-Content -LiteralPath $whdLogFile -Tail 300)
            Set-Content -LiteralPath $whdLogFile -Value $keep -Encoding ASCII
        }
    } catch { }
}
function Get-WHDEventSettings {
    $s = @{ LockPictures = $false; Sounds = $false; LastPicture = '' }
    try {
        if (Test-Path -LiteralPath $whdSetFile) {
            $j = Get-Content -LiteralPath $whdSetFile -Raw | ConvertFrom-Json
            $s.LockPictures = [bool]$j.LockPictures; $s.Sounds = [bool]$j.Sounds; $s.LastPicture = "$($j.LastPicture)"
        }
    } catch { }
    return $s
}
function Save-WHDEventSettings {
    param($Settings)
    try {
        if (-not (Test-Path -LiteralPath $whdUserDir)) { New-Item -ItemType Directory -Path $whdUserDir -Force | Out-Null }
        ([pscustomobject]@{ LockPictures = [bool]$Settings.LockPictures; Sounds = [bool]$Settings.Sounds; LastPicture = "$($Settings.LastPicture)" } | ConvertTo-Json) |
            Set-Content -LiteralPath $whdSetFile -Encoding ASCII
    } catch { }
}

# ---- Windows' own lock-screen call (Windows.System.UserProfile.LockScreen) -----------------------
$script:whdAsTaskOp = $null; $script:whdAsTaskAct = $null
function Initialize-WHDLockCall {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.System.UserProfile.LockScreen, Windows.System.UserProfile, ContentType = WindowsRuntime]
    $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods()
    $script:whdAsTaskOp  = @($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $script:whdAsTaskAct = @($m | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    if ($null -eq $script:whdAsTaskOp -or $null -eq $script:whdAsTaskAct) { throw 'the wait helper for the lock-screen call was not found' }
}
function Get-WHDLockPicture {
    # The file the lock screen was last given. Empty when Windows does not say (e.g. Windows spotlight).
    try {
        $u = [Windows.System.UserProfile.LockScreen]::OriginalImageFile
        if ($null -eq $u) { return '' }
        if ($u.IsFile) { return $u.LocalPath }
        return "$u"
    } catch { return '' }
}
function Set-WHDLockPicture {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw ('picture not found: {0}' -f $Path) }
    $t = $script:whdAsTaskOp.MakeGenericMethod([Windows.Storage.StorageFile]).Invoke($null, @([Windows.Storage.StorageFile]::GetFileFromPathAsync($Path)))
    if (-not $t.Wait(20000)) { throw 'Windows did not open the picture file within 20 seconds' }
    $file = $t.Result
    $t2 = $script:whdAsTaskAct.Invoke($null, @([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($file)))
    if (-not $t2.Wait(20000)) { throw 'Windows did not take the lock-screen picture within 20 seconds' }
}
function Test-WHDShutdownStarted {
    # True when Windows wrote its "shut-down / restart was started" line (System log, source User32, number 1074)
    # within the last minute. Read-only. If the log cannot be read the answer is "no".
    try {
        $q = "*[System[(Provider[@Name='User32'] or Provider[@Name='USER32']) and EventID=1074 and TimeCreated[timediff(@SystemTime) <= 60000]]]"
        $query = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery('System', [System.Diagnostics.Eventing.Reader.PathType]::LogName, $q)
        $reader = New-Object System.Diagnostics.Eventing.Reader.EventLogReader($query)
        try {
            $ev = $reader.ReadEvent()
            if ($null -ne $ev) { $ev.Dispose(); return $true }
        } finally { $reader.Dispose() }
    } catch { }
    return $false
}
function Get-WHDEventPictures {
    $dir = Join-Path $whdBase 'pictures'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { @('.jpg', '.jpeg', '.png', '.bmp') -contains $_.Extension.ToLower() } | Sort-Object Name)
}

$whdCode = 0
try {
    if ($What -eq 'query') {
        Initialize-WHDLockCall
        Write-Output ('PICTURE=' + (Get-WHDLockPicture))
        exit 0
    }
    if ($What -eq 'restore') {
        Initialize-WHDLockCall
        Set-WHDLockPicture $Picture
        Write-WHDEventLog ('lock-screen picture put back: {0}' -f $Picture)
        Write-Output ('RESULT=ok picture=' + $Picture)
        exit 0
    }
    $s = Get-WHDEventSettings
    $did = New-Object System.Collections.Generic.List[string]
    if ($s.Sounds -and @('signin', 'lock', 'unlock', 'signout', 'shutdown') -contains $What) {
        $wav = Join-Path (Join-Path $whdBase 'sounds') ('whd-{0}.wav' -f $What)
        if ($What -eq 'signout' -and (Test-WHDShutdownStarted)) {
            # Windows is shutting down or restarting: its sign-out is part of that, and the shut-down sound is the one to hear
            $did.Add('no sign-out sound: Windows is shutting down or restarting (the shut-down sound plays)')
        }
        elseif (Test-Path -LiteralPath $wav) {
            # at sign-out / shut-down this run may be ended by Windows before it finishes: say first that it started
            if (@('signout', 'shutdown') -contains $What) { Write-WHDEventLog 'started - playing the sound (Windows is closing programs; it may be cut short)' }
            try { $p = New-Object System.Media.SoundPlayer $wav; $p.PlaySync(); $p.Dispose(); $did.Add('sound') }
            catch { $did.Add('sound FAILED: ' + $_.Exception.Message); $whdCode = 4 }
        } else { $did.Add('sound file missing') }
    }
    if ($s.LockPictures -and @('signin', 'unlock', 'now') -contains $What) {
        $pics = @(Get-WHDEventPictures)
        if (-not $pics.Count) { $did.Add('no pictures in ' + (Join-Path $whdBase 'pictures')); $whdCode = 2 }
        else {
            $pool = @($pics | Where-Object { $_.FullName -ne $s.LastPicture })
            if (-not $pool.Count) { $pool = $pics }
            $pick = ($pool | Get-Random).FullName
            try {
                Initialize-WHDLockCall
                Set-WHDLockPicture $pick
                $s.LastPicture = $pick
                Save-WHDEventSettings $s
                $did.Add('lock-screen picture: ' + (Split-Path -Leaf $pick))
                Write-Output ('RESULT=ok picture=' + $pick)
            } catch {
                $did.Add('lock-screen picture FAILED: ' + $_.Exception.Message); $whdCode = 3
                Write-Output ('RESULT=error ' + $_.Exception.Message)
            }
        }
    }
    if (-not $did.Count) { $did.Add('nothing to do (not switched on)') }
    Write-WHDEventLog ($did -join '; ')
} catch {
    $whdCode = 1
    Write-WHDEventLog ('FAILED: ' + $_.Exception.Message)
    Write-Output ('RESULT=error ' + $_.Exception.Message)
}
exit $whdCode
