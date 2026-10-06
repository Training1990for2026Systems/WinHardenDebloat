<#
================================================================================
 WHD Next  -  modules\Debloat-Win32.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Traditional (Win32 / desktop) program removal + re-appearance blocking.
 These are NOT Store/Appx apps - they live in the uninstall registry and run
 their own vendor uninstaller (e.g. Logi Download Assistant, Zoom).

 Because Win32 apps have no "provisioning", "prevent reinstall" here means:
   * uninstall via the app's own (quiet) uninstaller,
   * remove its Run/RunOnce autostart entries and Startup-folder shortcuts,
   * remove/disable its scheduled tasks,
   * optionally BLOCK a named .exe from launching via Image File Execution
     Options (reversible) - this stops a helper/updater from bringing it back.

 A name search covers uninstall entries, autostarts, scheduled tasks and the
 Program Files folders - useful for helpers (like "WhatsUp") that have no
 uninstall entry.

 Reuses Common.ps1.
================================================================================
#>

# Names we refuse to uninstall from here (breakage / servicing).
$script:WHDWin32Protected = @('Microsoft Edge','Microsoft Edge Update','WebView2','Application Compatibility')

function Test-WHDWin32Protected {
    param([string]$Name)
    foreach ($p in $script:WHDWin32Protected) { if ($Name -like "*$p*") { return $true } }
    return $false
}

function Get-WHDWin32Apps {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $apps = foreach ($r in $roots) {
        Get-ItemProperty $r -EA SilentlyContinue |
            Where-Object { $_.DisplayName -and ($_.SystemComponent -ne 1) } | ForEach-Object {
                [pscustomobject]@{
                    DisplayName     = $_.DisplayName
                    Version         = $_.DisplayVersion
                    Publisher       = $_.Publisher
                    Uninstall       = $_.UninstallString
                    QuietUninstall  = $_.QuietUninstallString
                    InstallLocation = $_.InstallLocation
                    Hive            = ($r -split ':')[0]
                    Protected       = (Test-WHDWin32Protected $_.DisplayName)
                }
            }
    }
    @($apps | Sort-Object DisplayName -Unique)
}

function Invoke-WHDWin32Uninstall {
    param($App)
    Write-WHDLog ("UNINSTALL (Win32): {0}" -f $App.DisplayName) 'ACT'
    if ($App.Protected) {
        Write-WHDLog ("Refused - '{0}' is protected (Edge/WebView2/servicing). Not removing from here." -f $App.DisplayName) 'WARN'
        return
    }
    $cmd = if ($App.QuietUninstall) { $App.QuietUninstall } else { $App.Uninstall }
    if (-not $cmd) { Write-WHDLog 'No uninstall string registered for this app.' 'WARN'; return }
    # Normalize an MSI uninstall to a silent one.
    if ($cmd -match 'msiexec') {
        $cmd = $cmd -replace '/I','/X'
        if ($cmd -notmatch '/quiet') { $cmd = "$cmd /quiet /norestart" }
    }
    Write-WHDRisk 'caution' ("runs the vendor uninstaller: {0}" -f $cmd)
    if (-not $App.QuietUninstall -and $cmd -notmatch 'msiexec') {
        Write-WHDLog 'No silent uninstaller registered - the vendor UI may appear; complete it manually.' 'INFO'
    }
    if (-not (Confirm-WHDProceed ("uninstall {0}" -f $App.DisplayName))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Invoke-WHDChange -Description ("run uninstaller for {0}" -f $App.DisplayName) -Force -Action {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -WindowStyle Hidden
    }
}

# ---- autostart entries ------------------------------------------------------
function Get-WHDStartupEntries {
    param([string]$Match = '*')
    $runKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    $out = foreach ($k in $runKeys) {
        if (-not (Test-Path $k)) { continue }
        $p = Get-ItemProperty $k -EA SilentlyContinue
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if (($prop.Name -like "*$Match*") -or ($prop.Value -like "*$Match*")) {
                [pscustomobject]@{ Key=$k; Name=$prop.Name; Command="$($prop.Value)" }
            }
        }
    }
    @($out)
}

function Remove-WHDStartupEntry {
    param($Entry)
    # Idempotent: a vendor uninstaller run just before may already have removed
    # its own Run value, so treat "already absent" as done, not a failure.
    Invoke-WHDChange -Description ("remove startup: {0} = {1}" -f $Entry.Name, $Entry.Command) -Force -Action {
        if (-not (Test-Path -LiteralPath $Entry.Key)) { return }
        $present = $null -ne (Get-ItemProperty -Path $Entry.Key -Name $Entry.Name -EA SilentlyContinue)
        if (-not $present) { Write-WHDLog ("startup '{0}' already gone (nothing to remove)" -f $Entry.Name) 'INFO'; return }
        Backup-WHDRegistryKey -PsPath $Entry.Key
        Remove-ItemProperty -Path $Entry.Key -Name $Entry.Name -EA Stop
    }
}

# ---- scheduled tasks (non-Microsoft) ----------------------------------------
function Get-WHDUserTasks {
    param([string]$Match = '*')
    try {
        @(Get-ScheduledTask -EA Stop | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -and $_.TaskPath -ne '\Microsoft\' -and
            (($_.TaskName -like "*$Match*") -or ($_.TaskPath -like "*$Match*"))
        } | Select-Object TaskName, TaskPath, State)
    } catch { @() }
}

function Remove-WHDTask {
    param($Task)
    Invoke-WHDChange -Description ("unregister scheduled task: {0}{1}" -f $Task.TaskPath, $Task.TaskName) -Force -Action {
        $still = Get-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -EA SilentlyContinue
        if (-not $still) { Write-WHDLog ("task '{0}' already gone" -f $Task.TaskName) 'INFO'; return }
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -Confirm:$false -EA Stop
    }
}

# ---- IFEO execution block (reversible) --------------------------------------
function Block-WHDExecutable {
    param([string]$ExeName)   # e.g. LogiDownloadAssistant.exe
    if ($ExeName -notmatch '\.exe$') { $ExeName = "$ExeName.exe" }
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\$ExeName"
    Write-WHDRisk 'caution' ("blocks {0} from launching (Image File Execution Options). Reversible: delete the key." -f $ExeName)
    if (-not (Confirm-WHDProceed ("block execution of {0}" -f $ExeName))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Set-WHDRegistryValue -Path $key -Name 'Debugger' -Value '%SystemRoot%\System32\systray.exe' -Type String
}

# ---- name search across everything ------------------------------------------
function Find-WHDApp {
    param([Parameter(Mandatory)][string]$Name)
    Write-WHDLog ("SEARCH for '{0}' across uninstall / startup / tasks / Program Files" -f $Name) 'ACT'
    $apps  = @(Get-WHDWin32Apps | Where-Object { $_.DisplayName -like "*$Name*" })
    $starts= Get-WHDStartupEntries -Match $Name
    $tasks = Get-WHDUserTasks -Match $Name
    $dirs  = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($base -and (Test-Path $base)) {
            $dirs += @(Get-ChildItem $base -Directory -EA SilentlyContinue | Where-Object { $_.Name -like "*$Name*" } | Select-Object -ExpandProperty FullName)
        }
    }
    Write-Host ("  Uninstall entries : {0}" -f $apps.Count)
    foreach ($a in $apps)   { Write-Host ("     - {0}  [{1}]" -f $a.DisplayName, $(if($a.QuietUninstall){'silent'}elseif($a.Uninstall){'has-uninstaller'}else{'NO uninstaller'})) }
    Write-Host ("  Startup entries   : {0}" -f $starts.Count)
    foreach ($s in $starts) { Write-Host ("     - {0} = {1}" -f $s.Name, $s.Command) }
    Write-Host ("  Scheduled tasks   : {0}" -f $tasks.Count)
    foreach ($t in $tasks)  { Write-Host ("     - {0}{1} ({2})" -f $t.TaskPath, $t.TaskName, $t.State) }
    Write-Host ("  Program folders   : {0}" -f $dirs.Count)
    foreach ($d in $dirs)   { Write-Host ("     - {0}" -f $d) }
    [pscustomobject]@{ Apps=$apps; Startups=$starts; Tasks=$tasks; Dirs=$dirs }
}

function Remove-WHDAppEverywhere {
    param([Parameter(Mandatory)][string]$Name)
    $found = Find-WHDApp -Name $Name
    if (-not (Confirm-WHDProceed ("remove EVERYTHING matching '{0}' (uninstall + startup + tasks)" -f $Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($a in $found.Apps)     { Invoke-WHDWin32Uninstall -App $a }
    foreach ($s in $found.Startups) { Remove-WHDStartupEntry -Entry $s }
    foreach ($t in $found.Tasks)    { Remove-WHDTask -Task $t }
    Write-WHDLog ("Done. If a helper still relaunches it, use the IFEO block on its .exe (menu X)." -f $Name) 'INFO'
}

function Show-WHDWin32Menu {
    Write-Host ''
    Write-Host '  WIN32 / INSTALLED PROGRAMS' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    $script:WHDWin32Cache = Get-WHDWin32Apps
    $i = 0
    foreach ($a in $script:WHDWin32Cache) {
        $i++
        $tag = if ($a.Protected) { ' (protected)' } else { '' }
        $col = if ($a.Protected) { 'DarkGray' } else { 'Green' }
        Write-WHDParts @(("  {0,2}. " -f $i), @(("{0}{1}" -f $a.DisplayName, $tag), $col), ("   {0}" -f $a.Publisher))
    }
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '   F. Find an app by name (uninstall + startup + tasks + folders)'
    Write-Host '   R. Remove everything matching a name (uninstall + startup + tasks)'
    Write-Host '   X. Block an .exe from launching (IFEO, reversible)'
    Write-Host '   B. Back'
}
