#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/DebloatWin32.ps1   (installed desktop programs)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features as WHD Next 2.0 (D8), rewritten for PowerShell 7.6. Build step
 5.4c (D30). Traditional (Win32 / desktop) programs - not Store apps; they live
 in the uninstall registry and bring their own vendor uninstaller.
 Win32 programs have no "staged copy", so keeping one away means:
   * uninstall with its own (quiet when possible) uninstaller,
   * remove its Run / RunOnce autostart entries (the key is exported first),
   * remove its scheduled tasks (outside \Microsoft\),
   * K: optionally block a named .exe from launching (Image File Execution
     Options - recorded registry value, Undo center puts it back) (D32; X in 2.0).
 F finds a name everywhere (uninstall entries, autostarts, tasks, program
 folders) - useful for helpers that have no uninstall entry. Edge, WebView2 and
 servicing parts are protected and never uninstalled from here.
================================================================================
#>

$script:WHDWin32Protected = @('Microsoft Edge', 'Microsoft Edge Update', 'WebView2', 'Application Compatibility')
$script:WHDWin32Cache = @()

function Test-WHDWin32Protected {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Name)
    foreach ($p in $script:WHDWin32Protected) { if ($Name -like ('*{0}*' -f $p)) { return $true } }
    return $false
}

function Get-WHDWin32App {
    # Every uninstall entry with a name that is not a system component (machine 64 / 32 bit + this user). Read-only.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $apps = foreach ($r in $roots) {
        foreach ($e in @(Get-ItemProperty -Path $r -ErrorAction SilentlyContinue)) {
            $dn = if ($e.PSObject.Properties['DisplayName']) { [string]$e.DisplayName } else { '' }
            if (-not $dn) { continue }
            if ($e.PSObject.Properties['SystemComponent'] -and [string]$e.SystemComponent -eq '1') { continue }
            $get = { param($n) if ($e.PSObject.Properties[$n]) { [string]$e.$n } else { '' } }
            [pscustomobject]@{ DisplayName = $dn; Version = (& $get 'DisplayVersion'); Publisher = (& $get 'Publisher'); Uninstall = (& $get 'UninstallString')
                QuietUninstall = (& $get 'QuietUninstallString'); InstallLocation = (& $get 'InstallLocation'); Hive = ($r -split ':')[0]; Protected = (Test-WHDWin32Protected -Name $dn) }
        }
    }
    return @(@($apps) | Sort-Object DisplayName -Unique)
}

function Get-WHDUninstallCommand {
    # The command to run: the quiet one when registered; an MSI one is made silent (/X /quiet /norestart). (pure)
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$App)
    $cmd = if ($App.QuietUninstall) { [string]$App.QuietUninstall } else { [string]$App.Uninstall }
    if (-not $cmd) { return '' }
    if ($cmd -match '(?i)msiexec') {
        $cmd = $cmd -replace '(?i)/I(\s*\{)', '/X$1'
        if ($cmd -notmatch '(?i)/quiet') { $cmd = '{0} /quiet /norestart' -f $cmd }
    }
    return $cmd
}

function Get-WHDUninstallExitMeaning {
    # What an uninstaller's exit code means: 'ok', 'restart' or 'check'. (pure)
    # 0 / 1605 (not installed) = ok; 1641 / 3010 = restart. Chromium-style setup programs
    # (Copilot, Edge, Chrome: ...setup.exe --uninstall) report a good uninstall as 19.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Code, [string]$Command = '')
    if ($Code -in 0, 1605) { return 'ok' }
    if ($Code -in 1641, 3010) { return 'restart' }
    if ($Code -eq 19 -and $Command -match '(?i)setup\.exe"?\s.*--uninstall') { return 'ok' }
    return 'check'
}

function Invoke-WHDWin32Uninstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$App, [switch]$NoAsk)
    Write-WHDLog -Message ('UNINSTALL (Win32): {0}' -f $App.DisplayName) -Level 'ACT'
    if ($App.Protected) { Write-WHDLog -Message ('Refused - {0} is protected (Edge / WebView2 / servicing). Not removed from here.' -f $App.DisplayName) -Level 'WARN'; return }
    $unCmd = Get-WHDUninstallCommand -App $App
    if (-not $unCmd) { Write-WHDLog -Message 'No uninstall command is registered for this program.' -Level 'WARN'; return }
    Write-WHDRisk -Tier 'caution' -Text ('runs the vendor uninstaller: {0}' -f $unCmd)
    if (-not $App.QuietUninstall -and $unCmd -notmatch '(?i)msiexec') { Write-WHDLog -Message 'No silent uninstaller registered - the vendor window may appear; finish it there.' }
    if (-not $NoAsk -and -not (Confirm-WHDProceed -What ('uninstall {0}' -f $App.DisplayName))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDChange -Description ('run uninstaller for {0}' -f $App.DisplayName) -Journal @{ Kind = 'action'; Hint = 'reinstall the program from its maker if you want it back' } -Action {
        $up = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $unCmd -Wait -WindowStyle Hidden -PassThru
        if (-not $up) { return }
        switch (Get-WHDUninstallExitMeaning -Code $up.ExitCode -Command $unCmd) {
            'check'   { Write-WHDLog -Message ('  the uninstaller ended with code {0} - check that the program is gone (F).' -f $up.ExitCode) -Level 'WARN'; $script:WHDState.ChangeNote = ('code {0}' -f $up.ExitCode) }
            'restart' { Write-WHDLog -Message '  the uninstaller asks for a restart to finish.' -Level 'WARN' }
        }
    } | Out-Null
}

# ---- autostart entries -----------------------------------------------------------------
function Get-WHDStartupEntry {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Match = '*')
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce')
    $out = foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        $p = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            if ($prop.Name -like ('*{0}*' -f $Match) -or [string]$prop.Value -like ('*{0}*' -f $Match)) { [pscustomobject]@{ Key = $k; Name = $prop.Name; Command = [string]$prop.Value } }
        }
    }
    return @($out)
}

function Remove-WHDStartupEntry {
    # The key is exported to restore\ first; already gone (a vendor uninstaller removed it) counts as done.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Entry)
    $seKey = $Entry.Key; $seName = $Entry.Name
    if (-not $PSCmdlet.ShouldProcess(('{0}\{1}' -f $seKey, $seName), 'remove autostart')) { return }
    Invoke-WHDChange -Description ('remove startup: {0} = {1}' -f $seName, $Entry.Command) -Journal @{ Kind = 'action'; Hint = 'import this session''s .reg backup of the Run key' } -Action {
        if (-not (Test-Path -LiteralPath $seKey)) { return }
        if ($null -eq (Get-ItemProperty -LiteralPath $seKey -Name $seName -ErrorAction SilentlyContinue)) { Write-WHDLog -Message ('startup {0} already gone' -f $seName); return }
        Backup-WHDRegistryKey -Path $seKey
        Remove-ItemProperty -LiteralPath $seKey -Name $seName -ErrorAction Stop
    } | Out-Null
}

# ---- scheduled tasks (not Microsoft's) ----------------------------------------------------
function Get-WHDUserTask {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([string]$Match = '*')
    try {
        return @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and ($_.TaskName -like ('*{0}*' -f $Match) -or $_.TaskPath -like ('*{0}*' -f $Match)) } |
            ForEach-Object { [pscustomobject]@{ TaskName = [string]$_.TaskName; TaskPath = [string]$_.TaskPath; State = [string]$_.State } })
    } catch { return @() }
}

function Remove-WHDTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Task)
    $tkName = $Task.TaskName; $tkPath = $Task.TaskPath
    if (-not $PSCmdlet.ShouldProcess(('{0}{1}' -f $tkPath, $tkName), 'unregister task')) { return }
    Invoke-WHDChange -Description ('unregister scheduled task: {0}{1}' -f $tkPath, $tkName) -Journal @{ Kind = 'action'; Hint = 'reinstall the program to get its task back' } -Action {
        if (-not (Get-ScheduledTask -TaskName $tkName -TaskPath $tkPath -ErrorAction SilentlyContinue)) { Write-WHDLog -Message ('task {0} already gone' -f $tkName); return }
        Unregister-ScheduledTask -TaskName $tkName -TaskPath $tkPath -Confirm:$false -ErrorAction Stop
    } | Out-Null
}

# ---- K: block an .exe from launching (IFEO) ------------------------------------------------
function Get-WHDIfeoKey {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$ExeName)
    $exe = if ($ExeName -match '(?i)\.exe$') { $ExeName } else { '{0}.exe' -f $ExeName }
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\{0}' -f (Split-Path $exe -Leaf)
}

function Block-WHDExecutable {
    # Debugger = systray.exe: Windows starts that instead of the program (it exits at once). Recorded as kind reg.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExeName)
    if ($ExeName -notmatch '^[\w .()+-]+(\.exe)?$') { Write-WHDLog -Message ('not a program file name: {0}' -f $ExeName) -Level 'WARN'; return }
    $key = Get-WHDIfeoKey -ExeName $ExeName
    $exe = Split-Path $key -Leaf
    Write-WHDLog -Message ('BLOCK program from launching: {0}' -f $exe) -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text ('Windows will not start {0} any more (Image File Execution Options). Reversible: Undo center.' -f $exe)
    $cur = Get-WHDRegValueState -Path $key -Name 'Debugger'
    if ($cur.Exists -and [string]$cur.Value -eq '%SystemRoot%\System32\systray.exe') { Write-WHDLog -Message 'Already blocked - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('block {0} from launching' -f $exe))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDRegistryValue -Path $key -Name 'Debugger' -Value '%SystemRoot%\System32\systray.exe' -Type 'String' | Out-Null
}

# ---- F / R: name search across everything --------------------------------------------------
function Find-WHDApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    Write-WHDLog -Message ('SEARCH for "{0}" in uninstall entries / autostarts / tasks / program folders' -f $Name) -Level 'ACT'
    $apps = @(Get-WHDWin32App | Where-Object { $_.DisplayName -like ('*{0}*' -f $Name) })
    $starts = @(Get-WHDStartupEntry -Match $Name)
    $tasks = @(Get-WHDUserTask -Match $Name)
    $dirs = @(foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Programs' }))) {
            if ($base -and (Test-Path -LiteralPath $base)) { Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object Name -like ('*{0}*' -f $Name) | ForEach-Object FullName }
        })
    Write-WHDLog -Message ('  Uninstall entries : {0}' -f $apps.Count)
    foreach ($a in $apps) { Write-WHDLog -Message ('     - {0}  [{1}]{2}' -f $a.DisplayName, $(if ($a.QuietUninstall) { 'silent' } elseif ($a.Uninstall) { 'has uninstaller' } else { 'NO uninstaller' }), $(if ($a.Protected) { ' (protected)' } else { '' })) }
    Write-WHDLog -Message ('  Startup entries   : {0}' -f $starts.Count)
    foreach ($s in $starts) { Write-WHDLog -Message ('     - {0} = {1}' -f $s.Name, $s.Command) }
    Write-WHDLog -Message ('  Scheduled tasks   : {0}' -f $tasks.Count)
    foreach ($t in $tasks) { Write-WHDLog -Message ('     - {0}{1} ({2})' -f $t.TaskPath, $t.TaskName, $t.State) }
    Write-WHDLog -Message ('  Program folders   : {0}' -f $dirs.Count)
    foreach ($d in $dirs) { Write-WHDLog -Message ('     - {0}' -f $d) }
    [pscustomobject]@{ Apps = $apps; Startups = $starts; Tasks = $tasks; Dirs = $dirs }
}

function Remove-WHDAppEverywhere {
    # One question, then: uninstall each match, its autostarts, its tasks. Folders are only shown.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Name)
    if ($Name.Trim().Length -lt 3) { Write-WHDLog -Message 'Give at least 3 letters of the name (a shorter one matches too much).' -Level 'WARN'; return }
    $found = Find-WHDApp -Name $Name
    $n = $found.Apps.Count + $found.Startups.Count + $found.Tasks.Count
    if (-not $n) { Write-WHDLog -Message 'Nothing found to remove.' -Level 'OK'; return }
    if (-not $PSCmdlet.ShouldProcess($Name, 'remove everything matching')) { return }
    if (-not (Confirm-WHDProceed -What ('remove EVERYTHING matching "{0}" ({1} uninstall, {2} startup, {3} task)' -f $Name, $found.Apps.Count, $found.Startups.Count, $found.Tasks.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do {
        foreach ($a in $found.Apps) { if ($script:WHDState.JournalStop) { break }; Invoke-WHDWin32Uninstall -App $a -NoAsk }
        foreach ($s in $found.Startups) { if ($script:WHDState.JournalStop) { break }; Remove-WHDStartupEntry -Entry $s }
        foreach ($t in $found.Tasks) { if ($script:WHDState.JournalStop) { break }; Remove-WHDTask -Task $t }
    }
    Write-WHDLog -Message 'Done. If a helper still starts it again, block its .exe (K).'
}

# ---- menu -------------------------------------------------------------------------------------
function Show-WHDWin32Menu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== Win32 / installed programs ===============' -ForegroundColor White
    $script:WHDWin32Cache = @(Get-WHDWin32App)
    for ($i = 0; $i -lt $script:WHDWin32Cache.Count; $i++) {
        $a = $script:WHDWin32Cache[$i]
        Write-WHDParts -Parts @(('  {0,3}. ' -f ($i + 1)), @(('{0}{1}' -f $a.DisplayName, $(if ($a.Protected) { ' (protected)' } else { '' })), $(if ($a.Protected) { 'DarkGray' } else { 'Green' })), ('   {0}' -f $a.Publisher))
    }
    Write-Host '   #  = uninstall that program' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'F' -Label 'Find a program by name (uninstall + startup + tasks + folders)'
    Write-WHDMenuItem -Key 'R' -Label 'Remove everything matching a name (uninstall + startup + tasks)'
    Write-WHDMenuItem -Key 'K' -Label 'Block an .exe from launching (IFEO, reversible)' -Hint '(was X in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDWin32Choice {
    # One menu choice. Returns $false for B (back). -Answer feeds the name question (tests).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^[Ff]$' { $n = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Program name to find').Trim(); if ($n) { [void](Find-WHDApp -Name $n) } }
        '^[Rr]$' { $n = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  Program name to remove everywhere').Trim(); if ($n) { Remove-WHDAppEverywhere -Name $n } }
        '^[Kk]$' { $n = (Read-WHDMenuAnswer -Answer $Answer -Prompt '  .exe name to block (e.g. LogiDownloadAssistant.exe)').Trim(); if ($n) { Block-WHDExecutable -ExeName $n } }
        '^\d+$' {
            if (-not $script:WHDWin32Cache.Count) { $script:WHDWin32Cache = @(Get-WHDWin32App) }
            $idx = [int]$c - 1
            if ($idx -lt 0 -or $idx -ge $script:WHDWin32Cache.Count) { Write-Host '  invalid.' -ForegroundColor Yellow }
            else { Invoke-WHDWin32Uninstall -App $script:WHDWin32Cache[$idx] }
        }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
