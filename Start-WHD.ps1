#requires -Version 5.1
<#
================================================================================
 WHD Next 3.0  -  Start-WHD.ps1   (the starting tool - Windows PowerShell 5.1)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The ONLY way to start WHD Next 3.0. Written for Windows PowerShell 5.1 because
 that is the only PowerShell on a fresh Windows PC. Its whole job:

   1. CHECK   administrator, Windows, PowerShell 7, winget, installer file,
              folder protection, program files            (read-only)
   2. INFORM  one short table in plain words
   3. OFFER   only when something is missing: re-open as administrator,
              install / upgrade PowerShell 7 (winget or the MSI in installers\)
   4. RUN     WHD.ps1 under PowerShell 7.6 or newer (stable)

 It never makes a hardening change and never changes a Windows setting.
 The only things it can do, each after your explicit yes: re-open itself as
 administrator, and install the machine-wide PowerShell 7 (Microsoft's MSI).
 Without PowerShell 7.6 or newer, WHD does not run (there is no 5.1 fallback).

 Use:   double-click Start-WHD.cmd     or
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-WHD.ps1 [-SafeMode] [-CheckOnly]
 Testing without changing the PC:  -Simulate missing,old,msix,newer,preview,cfa,nowinget,msifile,notadmin
================================================================================
#>
[CmdletBinding()]
param(
    [switch]$SafeMode,      # D14: start WHD in safe mode (passed on to WHD.ps1)
    [switch]$CheckOnly,     # show the check table and stop (runs nothing)
    [string[]]$Simulate,    # testing only: pretend these situations; installs and runs nothing
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$PassThru   # anything else goes on to WHD.ps1
)
Set-StrictMode -Version 2.0

$script:Root       = $PSScriptRoot
$script:Minimum    = [version]'7.6.0'
$script:PwshPath   = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$script:Ps51       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:WingetArgs = @('install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--exact', '--installer-type', 'wix')
$script:LogFile    = $null
$script:SimNames   = @('missing', 'old', 'msix', 'newer', 'preview', 'cfa', 'nowinget', 'msifile', 'notadmin')

# ------------------------------------------------------------------ logging --
function Write-StartLog {
    param([string]$Text)
    try {
        if (-not $script:LogFile) {
            $dir = Join-Path $script:Root 'logs'
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -ErrorAction Stop) }
            $script:LogFile = Join-Path $dir ('starter_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
        }
        Add-Content -LiteralPath $script:LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -Encoding ASCII -ErrorAction Stop
    } catch { $null = $_ }   # a log that cannot be written must never stop the starter
}

# ------------------------------------------------------------------- checks --
function Test-StartAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-StartWindows {
    $o = [pscustomobject]@{ Text = 'not readable' }
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $ed = [string]$cv.EditionID
        switch ($ed) { 'Core' { $ed = 'Home' } 'CoreSingleLanguage' { $ed = 'Home Single Language' } 'Professional' { $ed = 'Pro' } }
        $o.Text = ('Windows 11 {0}, build {1}.{2}' -f $ed, $cv.CurrentBuild, $cv.UBR)
    } catch { Write-StartLog ('Windows version not readable: {0}' -f $_.Exception.Message) }
    return $o
}

function ConvertTo-StartPwshVersion {
    # "7.6.6 SHA: abc" -> 7.6.6 / ''   ;   "7.7.0-preview.3 SHA: x" -> 7.7.0 / 'preview.3'
    param([string]$ProductVersion)
    $o = [pscustomobject]@{ Version = $null; Label = ''; Text = '' }
    if ($ProductVersion -match '^\s*(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z\.]*))?') {
        $o.Version = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
        if ($Matches[4]) { $o.Label = $Matches[4] }
        $o.Text = $o.Version.ToString()
        if ($o.Label) { $o.Text = $o.Text + '-' + $o.Label }
    }
    return $o
}

function Get-StartPwshState {
    # State: ok | newer | preview | old | msix-only | missing | unreadable
    param([string]$ProductVersion, [bool]$Installed, [string]$MsixVersion)
    if (-not $Installed) {
        if ($MsixVersion) { return 'msix-only' }
        return 'missing'
    }
    $v = ConvertTo-StartPwshVersion -ProductVersion $ProductVersion
    if (-not $v.Version) { return 'unreadable' }
    if ($v.Label)        { return 'preview' }
    if ($v.Version -lt $script:Minimum) { return 'old' }
    if ($v.Version.Major -gt $script:Minimum.Major -or $v.Version.Minor -gt $script:Minimum.Minor) { return 'newer' }
    return 'ok'
}

function Get-StartPwsh {
    param([bool]$IsAdmin)
    $o = [pscustomobject]@{ Installed = $false; ProductVersion = ''; VersionText = ''; MsixVersion = ''; State = 'missing' }
    if (Test-Path -LiteralPath $script:PwshPath) {
        $o.Installed = $true
        $vi = (Get-Item -LiteralPath $script:PwshPath).VersionInfo
        $o.ProductVersion = [string]$vi.ProductVersion
        if (-not $o.ProductVersion) { $o.ProductVersion = [string]$vi.FileVersion }
        $o.VersionText = (ConvertTo-StartPwshVersion -ProductVersion $o.ProductVersion).Text
    }
    try {
        if ($IsAdmin) { $px = @(Get-AppxPackage -AllUsers -Name 'Microsoft.PowerShell' -ErrorAction Stop) }
        else          { $px = @(Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop) }
        if ($px.Count -gt 0) { $o.MsixVersion = [string]$px[0].Version }
    } catch { Write-StartLog ('Store packages not readable: {0}' -f $_.Exception.Message) }
    $o.State = Get-StartPwshState -ProductVersion $o.ProductVersion -Installed $o.Installed -MsixVersion $o.MsixVersion
    return $o
}

function Get-StartWinget {
    $o = [pscustomobject]@{ Present = $false; Path = ''; Version = '' }
    $gc = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gc) {
        $o.Present = $true
        $o.Path = [string]$gc.Source
        try { $o.Version = ([string](& $gc.Source --version 2>$null | Select-Object -First 1)).Trim() } catch { Write-StartLog ('winget version not readable: {0}' -f $_.Exception.Message) }
    }
    return $o
}

function Get-StartMsiFile {
    # A Microsoft-signed PowerShell-7.6.x-win-<arch>.msi (or newer, stable) in installers\
    $o = [pscustomobject]@{ Usable = $false; Path = ''; Name = ''; Version = $null; Why = 'no file in installers\' }
    $arch = 'x64'
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    $dir = Join-Path $script:Root 'installers'
    $best = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter ('PowerShell-*-win-{0}.msi' -f $arch) -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -notmatch '^PowerShell-(\d+\.\d+\.\d+)-win-') { continue }   # a name with -preview / -rc is skipped
        $v = [version]$Matches[1]
        if ($v -lt $script:Minimum) { continue }
        if (-not $best -or $v -gt $best.V) { $best = [pscustomobject]@{ F = $f; V = $v } }
    }
    if (-not $best) { return $o }
    $o.Path = $best.F.FullName; $o.Name = $best.F.Name; $o.Version = $best.V
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $o.Path -ErrorAction Stop
        if ($sig.Status -eq 'Valid' -and [string]$sig.SignerCertificate.Subject -match 'O=Microsoft Corporation') { $o.Usable = $true; $o.Why = '' }
        else { $o.Why = ('{0}: signature is not a valid Microsoft signature ({1})' -f $o.Name, $sig.Status) }
    } catch { $o.Why = ('{0}: signature could not be read' -f $o.Name) }
    return $o
}

function Test-StartUnder {
    param([string]$Path, [string[]]$Folders)
    if (-not $Path) { return $false }
    $p = ($Path -replace '/', '\').TrimEnd('\') + '\'
    foreach ($f in @($Folders)) {
        if (-not $f) { continue }
        $ff = ([Environment]::ExpandEnvironmentVariables([string]$f) -replace '/', '\').TrimEnd('\') + '\'
        if ($p.StartsWith($ff, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-StartFolderProtection {
    # Defender "Controlled folder access", read through Windows' built-in CIM. Read-only.
    $o = [pscustomobject]@{ Readable = $false; Mode = -1; ProjectProtected = $false; PwshAllowed = $false; WouldBlock = $false; Text = 'not readable' }
    try {
        $mp = Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop
        $o.Readable = $true
        $o.Mode = [int]$mp.EnableControlledFolderAccess
    } catch { return $o }
    $protected = @(
        [Environment]::GetFolderPath('MyDocuments'), [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('MyPictures'),  [Environment]::GetFolderPath('MyVideos'),
        [Environment]::GetFolderPath('MyMusic'),     [Environment]::GetFolderPath('Favorites')
    ) + @($mp.ControlledFolderAccessProtectedFolders | Where-Object { $_ })
    $o.ProjectProtected = Test-StartUnder -Path $script:Root -Folders $protected
    foreach ($a in @($mp.ControlledFolderAccessAllowedApplications | Where-Object { $_ })) {
        if ([string]::Equals(([string]$a).Trim(), $script:PwshPath, [System.StringComparison]::OrdinalIgnoreCase)) { $o.PwshAllowed = $true }
    }
    switch ($o.Mode) {
        0 { $o.Text = 'off' }
        1 { $o.Text = 'on (block)' }
        2 { $o.Text = 'audit only (does not block)' }
        3 { $o.Text = 'disk sectors only (does not affect WHD)' }
        4 { $o.Text = 'audit, disk sectors only (does not block)' }
        default { $o.Text = ('unknown value {0}' -f $o.Mode) }
    }
    if ($o.Mode -eq 1) {
        if (-not $o.ProjectProtected) { $o.Text += ' - the WHD folder is not protected' }
        elseif ($o.PwshAllowed)       { $o.Text += ' - pwsh.exe is allowed' }
        else                          { $o.Text += ' - pwsh.exe is NOT allowed'; $o.WouldBlock = $true }
    }
    return $o
}

function Get-StartProgramFile {
    $need = @('WHD.ps1', 'WHDNext\WHDNext.psd1', 'WHDNext\WHDNext.psm1')
    $missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $script:Root $_)) })
    return [pscustomobject]@{ Complete = ($missing.Count -eq 0); Missing = $missing }
}

# ----------------------------------------------------------- whole picture --
function Get-StartUnknownSim {
    # Names given to -Simulate that the starter does not know (a typo must never be ignored).
    param([string[]]$Sim)
    $names = @($Sim | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    return @($names | Where-Object { $script:SimNames -notcontains $_ })
}

function Get-StartState {
    param([string[]]$Sim)
    $sim = @($Sim | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    $st = [pscustomobject]@{
        IsAdmin = (Test-StartAdmin); Windows = (Get-StartWindows); Pwsh = $null; Winget = (Get-StartWinget)
        MsiFile = (Get-StartMsiFile); Folder = (Get-StartFolderProtection); Files = (Get-StartProgramFile)
        Simulated = ($sim.Count -gt 0); SimList = $sim
    }
    $st.Pwsh = Get-StartPwsh -IsAdmin $st.IsAdmin
    # Simulation: overwrite what was read, so every path can be tried without changing the PC.
    if ($sim -contains 'notadmin') { $st.IsAdmin = $false }
    if ($sim -contains 'missing')  { $st.Pwsh.Installed = $false; $st.Pwsh.VersionText = ''; $st.Pwsh.MsixVersion = '' }
    if ($sim -contains 'msix')     { $st.Pwsh.Installed = $false; $st.Pwsh.VersionText = ''; $st.Pwsh.MsixVersion = '7.6.6.0' }
    if ($sim -contains 'old')      { $st.Pwsh.Installed = $true;  $st.Pwsh.ProductVersion = '7.4.13'; $st.Pwsh.VersionText = '7.4.13' }
    if ($sim -contains 'preview')  { $st.Pwsh.Installed = $true;  $st.Pwsh.ProductVersion = '7.7.0-preview.3'; $st.Pwsh.VersionText = '7.7.0-preview.3' }
    if ($sim -contains 'newer')    { $st.Pwsh.Installed = $true;  $st.Pwsh.ProductVersion = '7.7.1'; $st.Pwsh.VersionText = '7.7.1' }
    if ($sim -contains 'nowinget') { $st.Winget.Present = $false; $st.Winget.Path = ''; $st.Winget.Version = '' }
    if ($sim -contains 'msifile')  { $st.MsiFile.Usable = $true; $st.MsiFile.Name = 'PowerShell-7.6.6-win-x64.msi'; $st.MsiFile.Path = (Join-Path $script:Root 'installers\PowerShell-7.6.6-win-x64.msi'); $st.MsiFile.Version = [version]'7.6.6'; $st.MsiFile.Why = '' }
    if ($sim -contains 'cfa')      { $st.Folder.Readable = $true; $st.Folder.Mode = 1; $st.Folder.ProjectProtected = $true; $st.Folder.PwshAllowed = $false; $st.Folder.WouldBlock = $true; $st.Folder.Text = 'on (block) - pwsh.exe is NOT allowed' }
    $st.Pwsh.State = Get-StartPwshState -ProductVersion $st.Pwsh.ProductVersion -Installed $st.Pwsh.Installed -MsixVersion $st.Pwsh.MsixVersion
    return $st
}

function Get-StartDecision {
    # Turns the state into ONE next step. Pure logic - reads nothing, changes nothing.
    # Step: files | admin | install | cfa | warn-newer | run
    param($State)
    $d = [pscustomobject]@{ Step = 'run'; Choices = @(); Notes = New-Object System.Collections.Generic.List[string] }
    if (-not $State.Files.Complete) {
        $d.Step = 'files'; $d.Choices = @('Q')
        $d.Notes.Add(('Program files are missing: {0}. Copy the whole WHD Next folder again.' -f ($State.Files.Missing -join ', ')))
        return $d
    }
    if (-not $State.IsAdmin) {
        $d.Step = 'admin'; $d.Choices = @('A', 'Q')
        $d.Notes.Add('WHD needs an administrator window. A = re-open this starter as administrator (Windows asks first).')
        return $d
    }
    $ps = $State.Pwsh.State
    if (@('missing', 'old', 'preview', 'msix-only', 'unreadable') -contains $ps) {
        $d.Step = 'install'
        $c = New-Object System.Collections.Generic.List[string]
        if ($State.Winget.Present) { $c.Add('U') }
        if ($State.MsiFile.Usable) { $c.Add('M') }
        $c.Add('Q'); $d.Choices = @($c)
        switch ($ps) {
            'missing'    { $d.Notes.Add('PowerShell 7 is not installed. WHD Next 3.0 runs only on PowerShell 7.6 or newer.') }
            'old'        { $d.Notes.Add(('PowerShell {0} is older than 7.6 and must be upgraded.' -f $State.Pwsh.VersionText)) }
            'preview'    { $d.Notes.Add(('PowerShell {0} is a pre-release build. WHD runs only on a stable version.' -f $State.Pwsh.VersionText)) }
            'msix-only'  { $d.Notes.Add('Only the sandboxed Store version of PowerShell 7 is installed. It keeps some changes inside its sandbox, so WHD does not use it. The machine-wide version can be installed next to it.') }
            'unreadable' { $d.Notes.Add('PowerShell 7 is installed, but its version could not be read. Installing the current version repairs it.') }
        }
        if (-not $State.Winget.Present -and -not $State.MsiFile.Usable) {
            $d.Notes.Add('winget was not found and there is no usable installer file, so the starter cannot install PowerShell 7 by itself.')
            $d.Notes.Add('Without winget: get the PowerShell 7.6 MSI from Microsoft (Microsoft Learn: "Install PowerShell on Windows"), put it in the installers folder, then start again.')
            if ($State.MsiFile.Why -and $State.MsiFile.Name) { $d.Notes.Add($State.MsiFile.Why) }
        }
        return $d
    }
    if ($State.Folder.WouldBlock) {
        $d.Step = 'cfa'; $d.Choices = @('R', 'Q')
        $d.Notes.Add('Folder protection (Controlled folder access) is on, the WHD folder is protected, and pwsh.exe is not allowed - PowerShell 7 could not write WHD''s logs and change history here.')
        $d.Notes.Add('To allow it: Windows Security > Virus & threat protection > Ransomware protection > Allow an app through Controlled folder access > add:')
        $d.Notes.Add(('   {0}' -f $script:PwshPath))
        $d.Notes.Add('The starter never changes this setting. R = check again after you allowed it.')
        return $d
    }
    if ($ps -eq 'newer') {
        $d.Step = 'warn-newer'; $d.Choices = @('Y', 'Q')
        $d.Notes.Add(('PowerShell {0} is newer than 7.6. It should work, but WHD Next 3.0 has not been tested on it. Y = run anyway.' -f $State.Pwsh.VersionText))
        return $d
    }
    return $d
}

# ------------------------------------------------------------------ screen --
function Write-StartLine {
    param([string]$Name, [string]$Value, [string]$Color = 'Gray')
    Write-Host ('  {0} {1} ' -f $Name, ('.' * [Math]::Max(2, 24 - $Name.Length))) -NoNewline
    Write-Host $Value -ForegroundColor $Color
}

function Show-StartState {
    param($State, $Decision)
    Write-Host ''
    Write-Host '  WHD Next 3.0 - start-up check' -ForegroundColor Cyan
    if ($State.Simulated) { Write-Host ('  SIMULATION: {0} (nothing is installed or run)' -f ($State.SimList -join ', ')) -ForegroundColor Magenta }
    Write-StartLine -Name 'Administrator' -Value $(if ($State.IsAdmin) { 'yes' } else { 'no' }) -Color $(if ($State.IsAdmin) { 'Green' } else { 'Yellow' })
    Write-StartLine -Name 'Windows' -Value $State.Windows.Text
    $pt = switch ($State.Pwsh.State) {
        'ok'         { 'found ({0}, machine-wide)' -f $State.Pwsh.VersionText }
        'newer'      { 'found ({0}, newer than 7.6 - untested)' -f $State.Pwsh.VersionText }
        'preview'    { 'found ({0}) - pre-release, not used' -f $State.Pwsh.VersionText }
        'old'        { 'found ({0}) - older than 7.6' -f $State.Pwsh.VersionText }
        'msix-only'  { 'only the sandboxed Store version ({0}) - not used' -f $State.Pwsh.MsixVersion }
        'unreadable' { 'found, version not readable' }
        default      { 'not installed' }
    }
    $pc = 'Yellow'; if ($State.Pwsh.State -eq 'ok') { $pc = 'Green' }
    Write-StartLine -Name 'PowerShell 7.6' -Value $pt -Color $pc
    $wt = 'not found'; if ($State.Winget.Present) { $wt = 'found'; if ($State.Winget.Version) { $wt = 'found ({0})' -f $State.Winget.Version } }
    Write-StartLine -Name 'winget' -Value $wt
    $mt = 'none'; if ($State.MsiFile.Usable) { $mt = '{0} (Microsoft-signed)' -f $State.MsiFile.Name } elseif ($State.MsiFile.Name) { $mt = $State.MsiFile.Why }
    Write-StartLine -Name 'Installer file' -Value $mt
    Write-StartLine -Name 'Folder protection' -Value $State.Folder.Text -Color $(if ($State.Folder.WouldBlock) { 'Yellow' } else { 'Gray' })
    Write-StartLine -Name 'Program files' -Value $(if ($State.Files.Complete) { 'complete' } else { 'MISSING' }) -Color $(if ($State.Files.Complete) { 'Green' } else { 'Red' })
    $rt = switch ($Decision.Step) {
        'run'        { 'ready - WHD Next runs on PowerShell {0}' -f $State.Pwsh.VersionText }
        'warn-newer' { 'ready after your OK (untested PowerShell version)' }
        'install'    { 'PowerShell 7.6 or newer is needed first' }
        'admin'      { 'an administrator window is needed first' }
        'cfa'        { 'pwsh.exe must be allowed in folder protection first' }
        default      { 'cannot start' }
    }
    Write-StartLine -Name 'Result' -Value $rt -Color $(if ($Decision.Step -eq 'run') { 'Green' } else { 'Yellow' })
    foreach ($n in $Decision.Notes) { Write-Host ('  {0}' -f $n) -ForegroundColor Gray }
    Write-Host ''
}

function Read-StartChoice {
    param([string[]]$Choices)
    $text = @{ A = 'A = re-open as administrator'; U = 'U = install PowerShell 7 with winget'; M = 'M = install from the file in installers'
               R = 'R = check again'; Y = 'Y = run anyway'; Q = 'Q = quit' }
    Write-Host ('  ' + (($Choices | ForEach-Object { $text[$_] }) -join '   ')) -ForegroundColor White
    while ($true) {
        $a = ([string](Read-Host '  Choice')).Trim().ToUpper()
        if ($Choices -contains $a) { return $a }
        Write-Host ('  Please type one of: {0}' -f ($Choices -join ', ')) -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------- actions --
function ConvertTo-StartArgString {
    # One command line for Start-Process: every argument with a space or quote is put in quotes.
    param([string[]]$ArgList)
    $parts = foreach ($a in @($ArgList)) {
        if ($null -eq $a) { continue }
        if ($a -eq '' -or $a -match '[\s"]') { '"{0}"' -f ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') } else { $a }
    }
    return ($parts -join ' ')
}

function Invoke-StartElevate {
    param([bool]$SafeMode, [bool]$CheckOnly, [string[]]$PassThru)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    if ($SafeMode)  { $argList += '-SafeMode' }
    if ($CheckOnly) { $argList += '-CheckOnly' }
    foreach ($p in @($PassThru)) { if ($p) { $argList += ('"{0}"' -f $p) } }
    Write-StartLog ('re-open as administrator: {0}' -f ($argList -join ' '))
    try { Start-Process -FilePath $script:Ps51 -Verb RunAs -ArgumentList $argList -ErrorAction Stop; return $true }
    catch { Write-Host ('  Windows did not open the administrator window: {0}' -f $_.Exception.Message) -ForegroundColor Red; return $false }
}

function Invoke-StartInstall {
    param($State, [string]$How)
    if ($How -eq 'U') {
        $file = $State.Winget.Path; $argList = $script:WingetArgs
        $show = 'winget ' + ($argList -join ' ')
        $what = 'It downloads PowerShell 7 from Microsoft through winget and installs the machine-wide (MSI) version.'
    } else {
        $file = Join-Path $env:SystemRoot 'System32\msiexec.exe'; $argList = @('/i', ('"{0}"' -f $State.MsiFile.Path), '/passive', '/norestart')
        $show = 'msiexec.exe ' + ($argList -join ' ')
        $what = ('It installs PowerShell {0} (machine-wide) from the file in installers. Nothing is downloaded.' -f $State.MsiFile.Version)
    }
    Write-Host ''
    Write-Host '  The starter would now run:' -ForegroundColor White
    Write-Host ('    {0}' -f $show) -ForegroundColor Cyan
    Write-Host ('  {0}' -f $what) -ForegroundColor Gray
    Write-Host '  Windows PowerShell 5.1 stays as it is. Nothing else is installed or changed.' -ForegroundColor Gray
    $yn = ([string](Read-Host '  Run it now? [y/N]')).Trim()
    Write-StartLog ('install offered: {0}   answer: {1}' -f $show, $yn)
    if ($yn -notmatch '^[Yy]$') { Write-Host '  Not installed.' -ForegroundColor Yellow; return }
    if ($State.Simulated) { Write-Host '  SIMULATION: the command was NOT run.' -ForegroundColor Magenta; Write-StartLog 'SIMULATION: install not run'; return }
    try {
        # Start-Process -NoNewWindow: the program writes straight to this window (no pipe - see Invoke-StartRun).
        if ($How -eq 'U') { $p = Start-Process -FilePath $file -ArgumentList (ConvertTo-StartArgString -ArgList $argList) -NoNewWindow -Wait -PassThru -ErrorAction Stop }
        else { $p = Start-Process -FilePath $file -ArgumentList ($argList -join ' ') -Wait -PassThru -ErrorAction Stop }
        $code = $p.ExitCode
        Write-StartLog ('install exit code: {0}' -f $code)
        if ($code -eq 0 -or $code -eq 3010) { Write-Host '  Install reported success. Checking again ...' -ForegroundColor Green }
        else { Write-Host ('  The install ended with exit code {0}. Checking again ...' -f $code) -ForegroundColor Yellow }
    } catch {
        Write-StartLog ('install could not start: {0}' -f $_.Exception.Message)
        Write-Host ('  The install could not be started: {0}' -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-StartRun {
    param($State, [bool]$SafeMode, [string[]]$PassThru)
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'WHD.ps1'))
    if ($SafeMode) { $argList += '-SafeMode' }
    foreach ($p in @($PassThru)) { if ($p) { $argList += $p } }
    Write-StartLog ('run: "{0}" {1}' -f $script:PwshPath, ($argList -join ' '))
    if ($State.Simulated) { Write-Host '  SIMULATION: WHD.ps1 was NOT started.' -ForegroundColor Magenta; Write-StartLog 'SIMULATION: WHD.ps1 not started'; return 0 }
    # WHD runs in THIS window with the window's own input and output. Not through a pipe: a pipe only shows
    # a line once it ends, so a question without a line end ("Proceed with ...? [y/N] ") stayed hidden
    # until a key was pressed (owner's report 2026-10-14 18:58).
    $p = Start-Process -FilePath $script:PwshPath -ArgumentList (ConvertTo-StartArgString -ArgList $argList) -NoNewWindow -Wait -PassThru
    $code = $p.ExitCode
    Write-StartLog ('WHD.ps1 ended, exit code {0}' -f $code)
    return $code
}

# -------------------------------------------------------------------- main --
function Invoke-StartMain {
    param([bool]$SafeMode, [bool]$CheckOnly, [string[]]$Simulate, [string[]]$PassThru)
    Write-StartLog ('starter on Windows PowerShell {0}; root {1}; SafeMode={2}; CheckOnly={3}; Simulate={4}' -f $PSVersionTable.PSVersion, $script:Root, [bool]$SafeMode, [bool]$CheckOnly, ($Simulate -join ','))
    $unknown = @(Get-StartUnknownSim -Sim $Simulate)
    if ($unknown.Count -gt 0) {
        Write-Host ''
        Write-Host ('  -Simulate does not know: {0}' -f ($unknown -join ', ')) -ForegroundColor Red
        Write-Host ('  Known names: {0}' -f ($script:SimNames -join ', ')) -ForegroundColor Gray
        Write-Host '  Nothing was checked or run.' -ForegroundColor Gray
        Write-StartLog ('stopped: unknown -Simulate name(s): {0}' -f ($unknown -join ', '))
        return 1
    }
    $passes = 0
    while ($true) {
        $passes++
        $state = Get-StartState -Sim $Simulate
        $decision = Get-StartDecision -State $state
        Show-StartState -State $state -Decision $decision
        Write-StartLog ('check {0}: admin={1} pwsh={2} ({3}) winget={4} msi={5} cfaBlock={6} files={7} -> {8}' -f $passes, $state.IsAdmin, $state.Pwsh.State, $state.Pwsh.VersionText, $state.Winget.Present, $state.MsiFile.Usable, $state.Folder.WouldBlock, $state.Files.Complete, $decision.Step)
        if ($CheckOnly) { Write-Host '  -CheckOnly: nothing was run.' -ForegroundColor Gray; return 0 }
        if ($decision.Step -eq 'run') { return (Invoke-StartRun -State $state -SafeMode $SafeMode -PassThru $PassThru) }
        if ($passes -gt 5) { Write-Host '  Stopped after 5 checks.' -ForegroundColor Yellow; return 1 }
        $c = Read-StartChoice -Choices $decision.Choices
        Write-StartLog ('choice: {0}' -f $c)
        switch ($c) {
            'Q' { Write-Host '  Nothing was run.' -ForegroundColor Gray; return 1 }
            'A' { if ($state.Simulated) { Write-Host '  SIMULATION: not re-opened.' -ForegroundColor Magenta; Write-StartLog 'SIMULATION: not re-opened'; return 0 }
                  if (Invoke-StartElevate -SafeMode $SafeMode -CheckOnly $CheckOnly -PassThru $PassThru) { Write-Host '  Continued in the administrator window.' -ForegroundColor Gray; return 0 } else { return 1 } }
            'U' { Invoke-StartInstall -State $state -How 'U'; if ($state.Simulated) { return 0 } }
            'M' { Invoke-StartInstall -State $state -How 'M'; if ($state.Simulated) { return 0 } }
            'R' { if ($state.Simulated) { Write-StartLog 'SIMULATION: re-check not repeated'; return 0 } }
            'Y' { return (Invoke-StartRun -State $state -SafeMode $SafeMode -PassThru $PassThru) }
        }
    }
}

# Run only when started as a script (dot-sourcing it for tests loads the functions only).
if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-StartMain -SafeMode $SafeMode.IsPresent -CheckOnly $CheckOnly.IsPresent -Simulate $Simulate -PassThru $PassThru)
}
