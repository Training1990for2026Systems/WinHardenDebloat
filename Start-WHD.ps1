<#
================================================================================
 WHD Next  -  Start-WHD.ps1   (launcher)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 BUILD STEP 5:  CHECK + INFORM + OFFER + RUN (starts the real WHD Next program).

 The launcher is the one way to start WHD Next (decision D6 / Option C):
     1. CHECK   read-only look at the PC
     2. INFORM  a short status table
     3. OFFER   only when something is missing (install PowerShell 7.6, safe mode, quit)
     4. RUN     PowerShell 7.6 = FULL mode,  Windows PowerShell 5.1 = SAFE mode

 The launcher never makes a hardening change. The only thing it can install is
 PowerShell 7 (machine-wide MSI), and only after you answer yes:
   * through winget, or
   * from a PowerShell MSI file you downloaded from Microsoft and placed in
     next\installers\  (works without winget and without internet).

 Start it either way:
   * double-click  Start-WHD.cmd
   * or, in an admin terminal:
       powershell -ExecutionPolicy Bypass -File .\next\Start-WHD.ps1

 Switches passed on to WHD Next:  -Execute  -Plan  -Apply <profile>  -Export <file>  -Yes
                                  -Gui (window version)   -Guard -DataRoot <folder> (update guard task)
 Launcher switches:               -SafeMode (start in SAFE mode)   -NoPrompt (never ask, never install)
                                  -CopyToUnlocked (offer to copy WHD Next to C:\ProgramData\WinHardenDebloatNext\app
                                   and run it from there - no folder-protection permission needed)
                                  -Here (stay in this folder even when an unlocked copy exists)

 Test switch (changes nothing, installs nothing - it only pretends):
       ... -File .\next\Start-WHD.ps1 -Simulate missing
   values: missing | old | msix | newer | preview | cfa | nowinget | msifile   (comma-separate to combine)

 Written for Windows PowerShell 5.1 (the only PowerShell on a fresh PC); it also
 runs under PowerShell 7. File is ASCII on purpose.
================================================================================
#>
[CmdletBinding()]
param(
    # ---- passed on to WHD Next ----
    [switch]$Execute,     # start in EXECUTE mode (default is dry-run)
    [switch]$Plan,        # print the full dry-run plan and exit
    [string]$Apply,       # apply a JSON profile, then exit
    [string]$Export,      # write a starter profile to this path, then exit
    [switch]$Yes,         # skip the one upfront gate when applying (scripted runs)
    [switch]$Gui,         # start the window version (WHD-GUI.ps1) instead of the menu
    [switch]$Guard,       # update-guard check (used by the scheduled task)
    [string]$DataRoot,    # project folder for reports/journals when running from the protected guard copy
    # ---- launcher ----
    [switch]$SafeMode,    # skip the offer and start in SAFE mode (PowerShell 5.1)
    [switch]$NoPrompt,    # never ask anything (unattended): FULL if possible, otherwise SAFE; never installs
    [string[]]$Simulate,  # TEST ONLY: pretend the PC is in this state. Nothing real is installed or changed.
                          #   missing | old | msix | newer | preview | cfa | nowinget | msifile
    [switch]$Here,        # stay in THIS folder even when an unlocked copy exists (no hand-over to the copy)
    [switch]$CopyToUnlocked,  # offer the copy to the unlocked folder now (C:\ProgramData\WinHardenDebloatNext\app)
    [switch]$NoElevate    # internal: used when the launcher re-opens itself as administrator
)

$ErrorActionPreference = 'Continue'
$script:WHDStartBuild   = 'build step 12f'
$script:WHDStartVersion = 'Next 2.0 preview 1'                 # the published version name (README, release tag next-2.0-preview1)
$script:WHDStartNextDir = $PSScriptRoot                       # ...\WHD-Next\next  (or the protected guard copy)
$script:WHDStartRoot    = Split-Path -Parent $PSScriptRoot    # ...\WHD-Next
$script:WHDStartPs51    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:WHDStartPwshMsi = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'   # where the machine-wide install lives
$script:WHDStartMinPwsh = [version]'7.6.0'                    # oldest PowerShell 7 that full mode accepts
$script:WHDStartTested  = '7.6'                               # the line WHD Next is tested on
$script:WHDStartInstallArgs = @('install', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--exact', '--installer-type', 'wix')
$script:WHDStartExit    = 0
$script:WHDStartInstallOk = $false
# Unlocked copy (user decision 2026-10-02): next to the update guard, outside every protected folder.
$script:WHDStartCopyBase = ''
$script:WHDStartCopyDir  = ''
$script:WHDStartCopyOk   = $false
if ($env:ProgramData) {
    $script:WHDStartCopyBase = Join-Path $env:ProgramData 'WinHardenDebloatNext'
    $script:WHDStartCopyDir  = Join-Path $script:WHDStartCopyBase 'app'
}

# ---- launcher log (user decision 2026-10-02, gap G15; build step 11) ----------
# One text file per month: <data folder>\logs\launcher_<yyyy-MM>.log. Every start adds a block, so what the
# launcher saw, offered and did can be reviewed afterwards.
# Build step 11: the launcher LOOKS before it writes. When Windows folder protection is on (block) and the
# data folder is inside a protected folder, the launcher does not try to write there - Windows would block
# the write and show a notice. The log then goes to the unlocked copy's "logs" folder when that copy exists
# and this window is administrator (only administrators can write there); otherwise no log is kept for this
# start. The launcher says in one line which of these happened, and it never stops because of its log.
$script:WHDStartLogFile   = ''
$script:WHDStartLogOk     = $true
$script:WHDStartLogChosen = $false
$script:WHDStartLogWhy    = ''      # one plain sentence when the log is somewhere else or not kept
$script:WHDStartMpCache   = $null   # Defender settings read for the log decision ...
$script:WHDStartMpTime    = [datetime]::MinValue   # ... and when, so the start-up check can use them once

function Get-WHDStartMp {
    # Defender settings through Windows' built-in CIM (read-only; works in 5.1 and 7).
    # -Reuse hands out the copy the log decision read a moment ago (once, and only if it is fresh), so a
    # normal start reads the settings one time instead of two.
    param([switch]$Reuse)
    if ($Reuse -and $null -ne $script:WHDStartMpCache) {
        $m = $script:WHDStartMpCache; $age = ((Get-Date) - $script:WHDStartMpTime).TotalSeconds
        $script:WHDStartMpCache = $null
        if ($age -ge 0 -and $age -le 15) { return $m }
    }
    return (Get-CimInstance -Namespace 'root/Microsoft/Windows/Defender' -ClassName 'MSFT_MpPreference' -ErrorAction Stop)
}

function Get-WHDStartProtectedList {
    # Folders Windows protects by default, plus any the user added ($Extra).
    param([object[]]$Extra)
    $prot = New-Object System.Collections.Generic.List[string]
    foreach ($sf in @('MyDocuments', 'MyPictures', 'MyVideos', 'MyMusic', 'DesktopDirectory', 'Favorites')) {
        try { $fp = [Environment]::GetFolderPath($sf); if ($fp) { $prot.Add($fp) } } catch { }
    }
    if ($env:PUBLIC) {
        foreach ($sub in @('Documents', 'Pictures', 'Videos', 'Music', 'Desktop')) { $prot.Add((Join-Path $env:PUBLIC $sub)) }
    }
    foreach ($e in @($Extra)) { if ($e) { $prot.Add([string]$e) } }
    return @($prot.ToArray())
}

function Get-WHDStartLogTarget {
    # Read-only. Where does the launcher log go?  Dir = folder that gets the "logs" folder ('' = no log for
    # this start); Why = one sentence when that is not the usual place. Never throws.
    #   -Mp / -Protected are for tests: the Defender settings object and the protected-folder list to use.
    param([string]$Wanted, [string]$CopyDir, [bool]$IsAdmin, $Mp = $null, [string[]]$Protected = $null)
    $o = [ordered]@{ Dir = $Wanted; Why = ''; Checked = $false; Protected = $false; Redirected = $false }
    try {
        if ($null -eq $Mp) {
            try { $Mp = Get-WHDStartMp; $script:WHDStartMpCache = $Mp; $script:WHDStartMpTime = Get-Date } catch { $Mp = $null }
        }
        if ($null -eq $Mp) { return [pscustomobject]$o }      # folder protection not readable: write as before
        $o.Checked = $true
        $mode = -1
        try { $mode = [int]$Mp.EnableControlledFolderAccess } catch { $mode = -1 }
        if ($mode -ne 1) { return [pscustomobject]$o }         # only "on (block)" blocks a write
        if ($null -eq $Protected) { $Protected = @(Get-WHDStartProtectedList -Extra @($Mp.ControlledFolderAccessProtectedFolders)) }
        $full = $Wanted
        try { if ($Wanted) { $full = [System.IO.Path]::GetFullPath($Wanted) } } catch { $full = $Wanted }
        if (-not (Test-WHDStartUnder -Path $full -Folders $Protected)) { return [pscustomobject]$o }

        $o.Protected = $true
        $copyOk = $false
        if ($CopyDir -and -not (Test-WHDStartSamePath $full $CopyDir) -and -not (Test-WHDStartUnder -Path $CopyDir -Folders $Protected)) {
            $copyOk = (Test-Path -LiteralPath (Join-Path $CopyDir 'Start-WHD.ps1'))
        }
        if ($copyOk -and $IsAdmin) {
            $o.Dir = $CopyDir; $o.Redirected = $true
            $o.Why = ('launcher log: kept in the unlocked copy ({0}) - this folder is protected by Windows folder protection' -f (Join-Path $CopyDir 'logs'))
        } elseif ($copyOk) {
            $o.Dir = ''
            $o.Why = 'launcher log: none for this start - this folder is protected by Windows folder protection, and only an administrator window can write to the unlocked copy'
        } else {
            $o.Dir = ''
            $o.Why = 'launcher log: none for this start - this folder is protected by Windows folder protection and there is no unlocked copy'
        }
    } catch {
        $o.Dir = ''; $o.Why = ('launcher log: none for this start - the check failed: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject]$o
}

function Get-WHDStartGuardLogRoot {
    # Build step 11b (guard question A): a guard run keeps its launcher log under ProgramData - in the WHD
    # folder when that already is there (the unlocked copy), otherwise in ...\WinHardenDebloatNext\guard-data.
    param([string]$Root)
    if (-not $script:WHDStartCopyBase) { return $Root }
    if (Test-WHDStartUnder -Path $Root -Folders @($script:WHDStartCopyBase)) { return $Root }
    return (Join-Path $script:WHDStartCopyBase 'guard-data')
}

function Write-WHDStartLog {
    param([string]$Text)
    if (-not $script:WHDStartLogOk) { return }
    try {
        if (-not $script:WHDStartLogChosen) {
            $script:WHDStartLogChosen = $true
            $logRoot = $script:WHDStartNextDir
            if ($DataRoot) { $logRoot = $DataRoot }
            if ($Guard)    { $logRoot = Get-WHDStartGuardLogRoot -Root $logRoot }
            $whdLogTarget = Get-WHDStartLogTarget -Wanted $logRoot -CopyDir $script:WHDStartCopyDir -IsAdmin ([bool](Test-WHDStartAdmin))
            $script:WHDStartLogWhy = $whdLogTarget.Why
            if ($whdLogTarget.Why) { Write-Host (' ({0})' -f $whdLogTarget.Why) -ForegroundColor DarkGray }
            if (-not $whdLogTarget.Dir) { $script:WHDStartLogOk = $false; return }
            $logDir = Join-Path $whdLogTarget.Dir 'logs'
            if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null }
            $script:WHDStartLogFile = Join-Path $logDir ('launcher_{0}.log' -f (Get-Date -Format 'yyyy-MM'))
        }
        if (-not $script:WHDStartLogFile) { return }
        Add-Content -LiteralPath $script:WHDStartLogFile -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 -ErrorAction Stop
    } catch {
        $script:WHDStartLogOk = $false
        Write-Host (' (launcher log not written: {0})' -f $_.Exception.Message) -ForegroundColor DarkGray
    }
}

# =============================================================================
#  CHECK functions - every one of them only READS
# =============================================================================
function Test-WHDStartAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WHDStartWindows {
    $o = [ordered]@{ Readable = $false; Product = ''; Edition = ''; EditionId = ''; Release = ''; Build = ''; Text = '' }
    try {
        $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $buildNo = 0
        [void][int]::TryParse([string]$cv.CurrentBuild, [ref]$buildNo)
        if ($buildNo -ge 22000) { $o.Product = 'Windows 11' } else { $o.Product = 'Windows 10' }
        $o.EditionId = [string]$cv.EditionID
        switch -Regex ($o.EditionId) {
            '^Core$'                    { $o.Edition = 'Home'; break }
            '^CoreSingleLanguage$'      { $o.Edition = 'Home Single Language'; break }
            '^CoreCountrySpecific$'     { $o.Edition = 'Home (country specific)'; break }
            '^Professional$'            { $o.Edition = 'Pro'; break }
            '^ProfessionalWorkstation$' { $o.Edition = 'Pro for Workstations'; break }
            '^ProfessionalEducation$'   { $o.Edition = 'Pro Education'; break }
            '^Enterprise'               { $o.Edition = 'Enterprise'; break }
            '^Education$'               { $o.Edition = 'Education'; break }
            default                     { $o.Edition = $o.EditionId }
        }
        $o.Release = [string]$cv.DisplayVersion
        $o.Build   = ('{0}.{1}' -f $cv.CurrentBuild, $cv.UBR)
        $o.Text    = ('{0} {1} {2}, build {3}' -f $o.Product, $o.Edition, $o.Release, $o.Build) -replace '\s+', ' '
        $o.Readable = $true
    } catch { $o.Text = 'not readable: ' + $_.Exception.Message }
    return [pscustomobject]$o
}

function Set-WHDStartPwshText {
    # Fills in State + Text from the raw fields (also used after a -Simulate overlay).
    param($P)
    if ($P.MsiVersion) {
        $tested = [version]($script:WHDStartTested + '.0')
        if ($P.MsiVersionText -match '-')                  { $P.State = 'preview' }
        elseif ($P.MsiVersion -lt $script:WHDStartMinPwsh) { $P.State = 'old' }
        elseif ($P.MsiVersion.Major -gt $tested.Major -or
               ($P.MsiVersion.Major -eq $tested.Major -and $P.MsiVersion.Minor -gt $tested.Minor)) { $P.State = 'newer' }
        else                                               { $P.State = 'ok' }
    } elseif ($P.MsiPath)     { $P.State = 'old' }          # file is there but its version could not be read
    elseif ($P.MsixVersion)   { $P.State = 'msix-only' }
    else                      { $P.State = 'missing' }

    switch ($P.State) {
        'ok'        { $P.Text = ('found ({0}, machine-wide)' -f $P.MsiVersionText) }
        'newer'     { $P.Text = ('found ({0}, machine-wide) - newer than the tested {1}' -f $P.MsiVersionText, $script:WHDStartTested) }
        'preview'   { $P.Text = ('found ({0}, machine-wide) - a preview version, untested' -f $P.MsiVersionText) }
        'old'       { $P.Text = ('found ({0}, machine-wide) - older than {1}' -f $P.MsiVersionText, $script:WHDStartTested) }
        'msix-only' { $P.Text = ('only the sandboxed Store version found ({0}) - not used by WHD' -f $P.MsixVersion) }
        default     { $P.Text = 'not installed' }
    }
    if ($P.MsiPath -and $P.MsixVersion) { $P.Text = $P.Text + ('; a sandboxed Store version ({0}) is also present and ignored' -f $P.MsixVersion) }
}

function Get-WHDStartPwsh {
    param([bool]$IsAdmin)
    # State: ok | newer | preview | old | msix-only | missing
    $o = [pscustomobject][ordered]@{ State = 'missing'; MsiPath = ''; MsiVersion = $null; MsiVersionText = ''; MsixVersion = ''; Text = '' }

    # 1. machine-wide install (MSI) lives in Program Files
    $msi = $script:WHDStartPwshMsi
    if (Test-Path -LiteralPath $msi) {
        $o.MsiPath = $msi
        $vi = (Get-Item -LiteralPath $msi).VersionInfo
        $pv = [string]$vi.ProductVersion               # e.g. "7.6.6 SHA: ..." or "7.7.0-preview.3 SHA: ..."
        if (-not $pv) { $pv = [string]$vi.FileVersion }
        if ($pv -match '^(\d+)\.(\d+)\.(\d+)') {
            $o.MsiVersion     = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
            $o.MsiVersionText = $o.MsiVersion.ToString()
            if ($pv -match '^\d+\.\d+\.\d+-([A-Za-z]+[\.\d]*)') { $o.MsiVersionText = $o.MsiVersionText + '-' + $Matches[1] }
        } elseif ($pv) { $o.MsiVersionText = $pv } else { $o.MsiVersionText = 'version not readable' }
    }

    # 2. sandboxed Store/MSIX package (per user)
    try {
        if ($IsAdmin) { $px = @(Get-AppxPackage -AllUsers -Name 'Microsoft.PowerShell' -ErrorAction Stop) }
        else          { $px = @(Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop) }
        if ($px.Count -gt 0) { $o.MsixVersion = [string]$px[0].Version }
    } catch { }

    Set-WHDStartPwshText -P $o
    return $o
}

function Get-WHDStartWinget {
    $o = [ordered]@{ Present = $false; Path = ''; Version = ''; Text = 'not found' }
    $gc = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($gc) {
        $o.Present = $true
        $o.Path = [string]$gc.Source
        try { $o.Version = [string](& $gc.Source --version 2>$null | Select-Object -First 1) } catch { }
        if ($o.Version) { $o.Text = ('found ({0})' -f $o.Version.Trim()) } else { $o.Text = 'found (version not readable)' }
    }
    return [pscustomobject]$o
}

function Get-WHDStartMsiFile {
    # A PowerShell MSI the user downloaded from Microsoft and put in next\installers\ .
    # It is only offered when its digital signature is valid and from Microsoft.
    $o = [ordered]@{ Folder = ''; Found = $false; Usable = $false; Path = ''; Name = ''; Version = $null; Text = '' }
    $o.Folder = Join-Path $script:WHDStartNextDir 'installers'
    $arch = 'x64'
    $pa = [string]$env:PROCESSOR_ARCHITEW6432
    if (-not $pa) { $pa = [string]$env:PROCESSOR_ARCHITECTURE }
    if ($pa -eq 'ARM64') { $arch = 'arm64' } elseif ($pa -eq 'x86') { $arch = 'x86' }
    $o.Text = ('none in next\installers (optional: PowerShell-{0}.x-win-{1}.msi from Microsoft)' -f $script:WHDStartTested, $arch)
    if (-not (Test-Path -LiteralPath $o.Folder)) { return [pscustomobject]$o }

    $best = $null; $bestVer = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $o.Folder -Filter ('PowerShell-*-win-{0}.msi' -f $arch) -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^PowerShell-(\d+)\.(\d+)\.(\d+)-win-') {
            $v = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
            if ($v -ge $script:WHDStartMinPwsh -and (-not $bestVer -or $v -gt $bestVer)) { $best = $f; $bestVer = $v }
        }
    }
    if (-not $best) {
        $o.Text = ('no usable file in next\installers (needs PowerShell-{0}.x-win-{1}.msi or newer)' -f $script:WHDStartTested, $arch)
        return [pscustomobject]$o
    }
    $o.Found = $true; $o.Path = $best.FullName; $o.Name = $best.Name; $o.Version = $bestVer
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $best.FullName -ErrorAction Stop
        $subj = ''
        if ($sig.SignerCertificate) { $subj = [string]$sig.SignerCertificate.Subject }
        if ("$($sig.Status)" -eq 'Valid' -and $subj -match 'O=Microsoft Corporation') {
            $o.Usable = $true
            $o.Text = ('found {0} (signature valid, Microsoft)' -f $best.Name)
        } else {
            $o.Text = ('found {0} but its signature is not a valid Microsoft signature ({1}) - not offered' -f $best.Name, $sig.Status)
        }
    } catch { $o.Text = ('found {0} but its signature could not be checked - not offered' -f $best.Name) }
    return [pscustomobject]$o
}

function Test-WHDStartUnder {
    # Is $Path inside one of $Folders?
    param([string]$Path, [string[]]$Folders)
    if (-not $Path) { return $false }
    $p = ($Path -replace '/', '\').TrimEnd('\') + '\'
    foreach ($f in @($Folders)) {
        if (-not $f) { continue }
        $ff = ($f -replace '/', '\').TrimEnd('\') + '\'
        if ($p.StartsWith($ff, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-WHDStartFolderProtection {
    # Defender "Controlled folder access", read through Windows' built-in CIM (works in 5.1 and 7).
    # $PwshPath = the installed pwsh.exe ('' when not installed); $ExpectedPath = where it would be installed.
    param([string]$PwshPath, [string]$ExpectedPath, [string]$ProjectRoot)
    $o = [ordered]@{ Readable = $false; Mode = -1; ModeText = ''; ProjectProtected = $false; PwshAllowed = $false
                     WouldBlock = $false; Text = ''; Error = '' }
    try {
        $mp = Get-WHDStartMp -Reuse
        $o.Readable = $true
        $o.Mode = [int]$mp.EnableControlledFolderAccess
        $allowed   = @($mp.ControlledFolderAccessAllowedApplications | Where-Object { $_ })
        $extraProt = @($mp.ControlledFolderAccessProtectedFolders   | Where-Object { $_ })
    } catch {
        $o.Error = $_.Exception.Message
        $o.Text  = 'not readable (Microsoft Defender may not be the active antivirus)'
        return [pscustomobject]$o
    }

    # Folders Windows protects by default, plus any the user added.
    $prot = @(Get-WHDStartProtectedList -Extra $extraProt)
    $o.ProjectProtected = Test-WHDStartUnder -Path $ProjectRoot -Folders $prot

    $checkPath = $PwshPath
    if (-not $checkPath) { $checkPath = $ExpectedPath }
    if ($checkPath) {
        foreach ($a in $allowed) {
            if ([string]::Equals(([string]$a).Trim(), $checkPath, [System.StringComparison]::OrdinalIgnoreCase)) { $o.PwshAllowed = $true }
        }
    }

    switch ($o.Mode) {
        0       { $o.ModeText = 'off' }
        1       { $o.ModeText = 'on (block)' }
        2       { $o.ModeText = 'audit only (does not block)' }
        3       { $o.ModeText = 'on for disk sectors only (does not affect WHD files)' }
        4       { $o.ModeText = 'audit for disk sectors only (does not block)' }
        default { $o.ModeText = ('unknown value {0}' -f $o.Mode) }
    }

    if ($o.Mode -ne 1)                         { $o.Text = $o.ModeText }
    elseif (-not $o.ProjectProtected)          { $o.Text = $o.ModeText + ' - the WHD folder is not a protected folder' }
    elseif (-not $PwshPath -and $o.PwshAllowed) { $o.Text = $o.ModeText + ' - pwsh.exe is already on the allowed list (for when PowerShell 7 is installed)' }
    elseif (-not $PwshPath)                    { $o.Text = $o.ModeText + ' - the WHD folder is protected; PowerShell 7 will need to be allowed once installed' }
    elseif ($o.PwshAllowed)                    { $o.Text = $o.ModeText + ' - pwsh.exe is on the allowed list' }
    else                                       { $o.Text = $o.ModeText + ' - pwsh.exe is NOT on the allowed list'; $o.WouldBlock = $true }
    return [pscustomobject]$o
}

function Get-WHDStartEditionFeatures {
    # Things that exist only on some Windows editions (WHD adapts to the PC it runs on).
    $o = [ordered]@{ AppLockerCmdlets = $false; Text = '' }
    $o.AppLockerCmdlets = [bool](Get-Command Get-AppLockerPolicy -ErrorAction SilentlyContinue)
    if ($o.AppLockerCmdlets) { $o.Text = 'available on this edition' } else { $o.Text = 'not part of this Windows edition' }
    return [pscustomobject]$o
}

function Get-WHDStartProgram {
    # The WHD Next program files next to this launcher.
    $o = [ordered]@{ Present = $false; Main = ''; GuiFile = ''; Placeholder = ''; Text = '' }
    $o.Main        = Join-Path $script:WHDStartNextDir 'WHD.ps1'
    $o.GuiFile     = Join-Path $script:WHDStartNextDir 'WHD-GUI.ps1'
    $o.Placeholder = Join-Path $script:WHDStartNextDir 'WHD-Placeholder.ps1'
    $eng  = Join-Path $script:WHDStartNextDir 'modules\Common.ps1'
    if ((Test-Path -LiteralPath $o.Main) -and (Test-Path -LiteralPath $eng)) { $o.Present = $true; $o.Text = 'found' }
    else { $o.Text = 'NOT found next to the launcher (WHD.ps1 / modules\Common.ps1)' }
    return [pscustomobject]$o
}

function Get-WHDStartState {
    param([string[]]$Sim)
    $Sim = @($Sim | Where-Object { $_ })
    $isAdmin = Test-WHDStartAdmin
    $pw      = Get-WHDStartPwsh -IsAdmin $isAdmin
    $wg      = Get-WHDStartWinget
    $mf      = Get-WHDStartMsiFile
    $projRoot = $script:WHDStartRoot
    if ($DataRoot) { $projRoot = $DataRoot }      # guard run from the protected copy: data lives in the project folder
    $fold    = Get-WHDStartFolderProtection -PwshPath $pw.MsiPath -ExpectedPath $script:WHDStartPwshMsi -ProjectRoot $projRoot

    # ---- TEST ONLY: pretend the PC is in another state (nothing real changes) ----
    if ($Sim -contains 'missing') { $pw.MsiPath = ''; $pw.MsiVersion = $null; $pw.MsiVersionText = ''; $pw.MsixVersion = '' }
    if ($Sim -contains 'old')     { $pw.MsiVersion = [version]'7.4.6'; $pw.MsiVersionText = '7.4.6'; if (-not $pw.MsiPath) { $pw.MsiPath = $script:WHDStartPwshMsi } }
    if ($Sim -contains 'msix')    { $pw.MsiPath = ''; $pw.MsiVersion = $null; $pw.MsiVersionText = ''; $pw.MsixVersion = '7.6.6.0' }
    if ($Sim -contains 'newer')   { $pw.MsiVersion = [version]'7.8.0'; $pw.MsiVersionText = '7.8.0' }
    if ($Sim -contains 'preview') { $pw.MsiVersion = [version]'7.7.0'; $pw.MsiVersionText = '7.7.0-preview.3' }
    if ($Sim.Count -gt 0)         { Set-WHDStartPwshText -P $pw }
    if ($Sim -contains 'nowinget') { $wg.Present = $false; $wg.Path = ''; $wg.Text = 'not found' }
    if ($Sim -contains 'msifile') {
        $mf.Found = $true; $mf.Usable = $true; $mf.Name = 'PowerShell-7.6.6-win-x64.msi'; $mf.Version = [version]'7.6.6'
        $mf.Path = Join-Path $mf.Folder $mf.Name; $mf.Text = ('found {0} (signature valid, Microsoft)' -f $mf.Name)
    }
    if ($Sim -contains 'cfa') {
        $fold.Readable = $true; $fold.Mode = 1; $fold.ProjectProtected = $true; $fold.PwshAllowed = $false; $fold.WouldBlock = $true
        $fold.Text = 'on (block) - pwsh.exe is NOT on the allowed list'
    }
    # An install is only PRETENDED when the PowerShell state or the installer file itself is pretended.
    $simInstall = [bool](@($Sim | Where-Object { @('missing', 'old', 'msix', 'newer', 'preview', 'msifile') -contains $_ }).Count)

    $st = [ordered]@{
        IsAdmin  = $isAdmin
        Engine   = ('{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
        Windows  = Get-WHDStartWindows
        Pwsh     = $pw
        Winget   = $wg
        MsiFile  = $mf
        Folder   = $fold
        Edition  = Get-WHDStartEditionFeatures
        Program  = Get-WHDStartProgram
        Copy     = Get-WHDStartCopy
        Sim      = $Sim
        SimInstall = $simInstall
        Usable   = $false
        Mode     = ''     # FULL | FULL-AFTER-ALLOW | SAFE
        Result   = ''
        Notes    = New-Object System.Collections.Generic.List[string]
    }

    # ---- decide which mode this PC can run -----------------------------------
    $st.Usable = ($pw.State -eq 'ok' -or $pw.State -eq 'newer' -or $pw.State -eq 'preview')
    if ($st.Usable -and $fold.WouldBlock) {
        $st.Mode   = 'FULL-AFTER-ALLOW'
        $st.Result = 'FULL mode once pwsh.exe is allowed in folder protection - otherwise SAFE mode (PowerShell 5.1)'
    } elseif ($st.Usable) {
        $st.Mode   = 'FULL'
        $st.Result = ('FULL mode available (PowerShell {0})' -f $pw.MsiVersionText)
    } else {
        $st.Mode   = 'SAFE'
        $st.Result = 'SAFE mode only for now (PowerShell 5.1: checks, Verify, Undo, re-apply)'
    }

    # ---- one plain sentence for every line that is not simply "fine" ----------
    if (-not $isAdmin) {
        $st.Notes.Add('Not running as administrator: WHD needs administrator rights to do its work, and some lines above may be incomplete.')
    }
    switch ($pw.State) {
        'newer'     { $st.Notes.Add(('PowerShell {0} is newer than the tested {1} line. WHD can run on it, but it is untested.' -f $pw.MsiVersionText, $script:WHDStartTested)) }
        'preview'   { $st.Notes.Add(('PowerShell {0} is a preview version. WHD can run on it, but it is untested.' -f $pw.MsiVersionText)) }
        'old'       { $st.Notes.Add(('PowerShell 7 is older than {0}. It can be upgraded now, or WHD can run in safe mode.' -f $script:WHDStartTested)) }
        'msix-only' { $st.Notes.Add('Only the sandboxed Store version of PowerShell 7 is installed. It keeps some changes inside its sandbox, so WHD does not use it. The machine-wide version can be installed next to it now, or WHD can run in safe mode.') }
        'missing'   { $st.Notes.Add(('PowerShell 7 is not installed. PowerShell {0} can be installed now, or WHD can run in safe mode.' -f $script:WHDStartTested)) }
    }
    if (-not $st.Usable -and -not $wg.Present -and -not $mf.Usable) {
        $st.Notes.Add('winget was not found and there is no installer file, so the launcher cannot install PowerShell 7 by itself. Safe mode is still available.')
        $st.Notes.Add(('To install without winget: download the PowerShell {0} MSI from Microsoft (Microsoft Learn: "Install PowerShell on Windows" > MSI), put the file in:' -f $script:WHDStartTested))
        $st.Notes.Add(('    {0}' -f $mf.Folder))
        $st.Notes.Add('then start the launcher again. The launcher checks the file''s Microsoft signature before offering it.')
    }
    if ($fold.WouldBlock) {
        $st.Notes.Add('Folder protection (Controlled folder access) is on and pwsh.exe is not on its allowed list, so PowerShell 7 could not write WHD''s logs and journals in this folder.')
        $st.Notes.Add('To allow it: Windows Security > Virus & threat protection > Ransomware protection > Allow an app through Controlled folder access > add:')
        $st.Notes.Add(('    {0}' -f $pw.MsiPath))
        $st.Notes.Add('The launcher never changes this setting itself.')
        if ($st.Copy.Known -and -not $st.Copy.Exists -and -not $st.Copy.Here) {
            $st.Notes.Add(('Or, without any permission: choice C copies WHD Next to {0} and runs it from there.' -f $st.Copy.Dir))
        }
    } elseif (-not $fold.Readable) {
        $st.Notes.Add('Folder protection could not be read. If another antivirus is active, that is expected.')
    }
    if (-not $st.Program.Present) {
        $st.Notes.Add('The WHD Next program files were not found next to the launcher, so there is nothing to start.')
    }
    return [pscustomobject]$st
}

# =============================================================================
#  INFORM - print the table
# =============================================================================
function Write-WHDStartLine {
    param([string]$Label, [string]$Value, [string]$Color = 'Gray')
    $lab = ($Label + ' ').PadRight(26, '.')
    Write-Host ('   {0} ' -f $lab) -NoNewline
    Write-Host $Value -ForegroundColor $Color
    Write-WHDStartLog ('  {0} {1}' -f $lab, $Value)
}

function Show-WHDStartState {
    param($State)
    $ok = 'Green'; $warn = 'Yellow'; $bad = 'Red'; $info = 'Gray'

    Write-Host ''
    Write-Host ' WHD Next - start-up check' -ForegroundColor Cyan
    Write-Host (' WHD {0} - launcher: {1}' -f $script:WHDStartVersion, $script:WHDStartBuild) -ForegroundColor DarkGray
    if (@($State.Sim).Count -gt 0) {
        Write-Host (' SIMULATION ({0}): the lines below PRETEND. Nothing real is installed or changed.' -f (@($State.Sim) -join ', ')) -ForegroundColor Magenta
    }
    Write-Host ''

    if ($State.IsAdmin) { Write-WHDStartLine 'Administrator' 'yes' $ok } else { Write-WHDStartLine 'Administrator' 'no' $warn }
    Write-WHDStartLine 'Launcher running on' $State.Engine $info
    if ($State.Windows.Readable) { Write-WHDStartLine 'Windows' $State.Windows.Text $info } else { Write-WHDStartLine 'Windows' $State.Windows.Text $warn }

    $pc = $warn
    if ($State.Pwsh.State -eq 'ok') { $pc = $ok }
    Write-WHDStartLine ('PowerShell {0}' -f $script:WHDStartTested) $State.Pwsh.Text $pc

    if ($State.Winget.Present) { Write-WHDStartLine 'winget' $State.Winget.Text $ok } else { Write-WHDStartLine 'winget' $State.Winget.Text $warn }
    # The installer-file line only matters when PowerShell 7 still has to be installed, or a file is there.
    if (-not $State.Usable -or $State.MsiFile.Found) {
        $mc = $info
        if ($State.MsiFile.Usable) { $mc = $ok } elseif ($State.MsiFile.Found) { $mc = $warn }
        Write-WHDStartLine 'Installer file' $State.MsiFile.Text $mc
    }

    $fc = $ok
    if ($State.Folder.WouldBlock) { $fc = $bad } elseif (-not $State.Folder.Readable) { $fc = $warn }
    Write-WHDStartLine 'Folder protection' $State.Folder.Text $fc

    Write-WHDStartLine 'AppLocker commands' $State.Edition.Text $info
    Write-WHDStartLine 'Unlocked copy' $State.Copy.Text $info
    if ($State.Program.Present) { Write-WHDStartLine 'WHD Next program' $State.Program.Text $ok } else { Write-WHDStartLine 'WHD Next program' $State.Program.Text $bad }

    $rc = $ok
    if ($State.Mode -ne 'FULL') { $rc = $warn }
    Write-Host ''
    Write-WHDStartLine 'Result' $State.Result $rc

    if ($State.Notes.Count -gt 0) {
        Write-Host ''
        Write-Host ' What this means:' -ForegroundColor White
        foreach ($n in $State.Notes) { Write-Host ('   - {0}' -f $n) -ForegroundColor Gray; Write-WHDStartLog ('  note: {0}' -f $n) }
    }
    Write-Host ''
}

# =============================================================================
#  OFFER - ask only when something is missing
# =============================================================================
function Read-WHDStartChoice {
    # Shows the choices and returns one upper-case letter from $Valid.
    param([string[]]$Lines, [string]$Valid)
    Write-Host ' Your choices:' -ForegroundColor White
    foreach ($l in $Lines) { Write-Host ('   {0}' -f $l) -ForegroundColor Cyan; Write-WHDStartLog ('  offered: {0}' -f $l) }
    while ($true) {
        $a = (Read-Host (' Type one letter [{0}] then Enter' -f (($Valid.ToCharArray()) -join '/'))).Trim().ToUpper()
        if ($a.Length -eq 1 -and $Valid.ToUpper().Contains($a)) { Write-WHDStartLog ('  chosen: {0}' -f $a); return $a }
        Write-Host '   (not one of the choices)' -ForegroundColor DarkGray
    }
}

function Invoke-WHDStartInstall {
    # Installs / upgrades PowerShell 7 with winget (machine-wide MSI). Only after an explicit yes.
    # Sets $script:WHDStartInstallOk. It returns nothing on purpose, so winget writes straight to the window.
    param($State)
    $script:WHDStartInstallOk = $false
    $cmdText = 'winget ' + ($script:WHDStartInstallArgs -join ' ')
    Write-Host ''
    Write-Host ' The launcher would now run this command:' -ForegroundColor White
    Write-Host ('   {0}' -f $cmdText) -ForegroundColor Cyan
    Write-Host ' It downloads PowerShell 7 from Microsoft through winget and installs the machine-wide (MSI) version.' -ForegroundColor Gray
    Write-Host ' Windows PowerShell 5.1 stays as it is. Nothing else is installed.' -ForegroundColor Gray
    $yn = (Read-Host ' Run it now? [y/N]').Trim()
    Write-WHDStartLog ('  install offered: {0}   answer: {1}' -f $cmdText, $(if ($yn -match '^[Yy]$') { 'yes' } else { 'no' }))
    if ($yn -notmatch '^[Yy]$') { Write-Host ' Not installed.' -ForegroundColor Yellow; return }

    if ($State.SimInstall) {
        Write-Host ' SIMULATION: the command above was NOT run. Pretending it succeeded.' -ForegroundColor Magenta
        Write-WHDStartLog '  SIMULATION: install not run'
        $script:WHDStartInstallOk = $true
        return
    }
    if (-not $State.IsAdmin) { Write-Host ' Note: this window is not elevated; Windows may ask for administrator approval.' -ForegroundColor Yellow }
    $wingetExe  = [string]$State.Winget.Path
    $wingetArgs = $script:WHDStartInstallArgs
    $global:LASTEXITCODE = 0
    try { & $wingetExe @wingetArgs }
    catch { Write-Host (' winget could not be started: {0}' -f $_.Exception.Message) -ForegroundColor Red; Write-WHDStartLog ('  winget could not be started: {0}' -f $_.Exception.Message); return }
    $code = $LASTEXITCODE
    Write-WHDStartLog ('  winget exit code: {0}' -f $code)
    if ($code -eq 0) { Write-Host ' winget reported success. Checking again ...' -ForegroundColor Green; $script:WHDStartInstallOk = $true; return }
    Write-Host (' winget ended with exit code {0}. PowerShell 7 may not be installed. Checking again ...' -f $code) -ForegroundColor Yellow
}

function Invoke-WHDStartInstallFromFile {
    # Installs PowerShell 7 from the MSI file in next\installers (no winget, no download).
    # Only after an explicit yes, and only for a file with a valid Microsoft signature.
    param($State)
    $script:WHDStartInstallOk = $false
    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $argLine = ('/i "{0}" /passive /norestart' -f $State.MsiFile.Path)
    Write-Host ''
    Write-Host ' The launcher would now run this command:' -ForegroundColor White
    Write-Host ('   msiexec.exe {0}' -f $argLine) -ForegroundColor Cyan
    Write-Host (' It installs PowerShell {0} (machine-wide) from the file you provided. Nothing is downloaded.' -f $State.MsiFile.Version) -ForegroundColor Gray
    Write-Host ' Windows PowerShell 5.1 stays as it is. Nothing else is installed.' -ForegroundColor Gray
    $yn = (Read-Host ' Run it now? [y/N]').Trim()
    Write-WHDStartLog ('  install offered: msiexec.exe {0}   answer: {1}' -f $argLine, $(if ($yn -match '^[Yy]$') { 'yes' } else { 'no' }))
    if ($yn -notmatch '^[Yy]$') { Write-Host ' Not installed.' -ForegroundColor Yellow; return }

    if ($State.SimInstall) {
        Write-Host ' SIMULATION: the command above was NOT run. Pretending it succeeded.' -ForegroundColor Magenta
        Write-WHDStartLog '  SIMULATION: install not run'
        $script:WHDStartInstallOk = $true
        return
    }
    if (-not $State.IsAdmin) { Write-Host ' Note: this window is not elevated; Windows will ask for administrator approval.' -ForegroundColor Yellow }
    try {
        $p = Start-Process -FilePath $msiexec -ArgumentList $argLine -Wait -PassThru -ErrorAction Stop
        $code = $p.ExitCode
    } catch { Write-Host (' msiexec could not be started: {0}' -f $_.Exception.Message) -ForegroundColor Red; Write-WHDStartLog ('  msiexec could not be started: {0}' -f $_.Exception.Message); return }
    Write-WHDStartLog ('  msiexec exit code: {0}' -f $code)
    if ($code -eq 0)    { Write-Host ' The installer reported success. Checking again ...' -ForegroundColor Green; $script:WHDStartInstallOk = $true; return }
    if ($code -eq 3010) { Write-Host ' The installer reported success; Windows wants a restart to finish. Checking again ...' -ForegroundColor Yellow; $script:WHDStartInstallOk = $true; return }
    Write-Host (' The installer ended with exit code {0}. PowerShell 7 may not be installed. Checking again ...' -f $code) -ForegroundColor Yellow
}

# =============================================================================
#  UNLOCKED COPY  (user decision 2026-10-02, plan points 1-6)
# =============================================================================
# When Windows folder protection blocks WHD Next in the folder it was unpacked to, the launcher can copy
# the whole "next" folder to  C:\ProgramData\WinHardenDebloatNext\app  (next to the update guard) and run
# it from there - no folder-protection permission is needed in that place.
#   * everything is copied (program, profiles, tools, journal, logs, reports, inventory);
#   * nothing is removed from the old place;
#   * only administrators can change the copy (same permissions as the update guard's folder);
#   * a later start from the old place hands over to the copy (-Here = stay in this folder);
#   * when the program files in the old place differ, the launcher offers to update the copy's program
#     files - the copy's journal, logs, reports, inventory and edited profiles are left alone.
function Test-WHDStartSamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    return [string]::Equals($A.TrimEnd('\', '/'), $B.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
}
# Program files that are missing in, or different from, the copy (relative names).
function Get-WHDStartProgramDiff {
    param([string]$Src, [string]$Dst)
    $rel = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('Start-WHD.ps1', 'Start-WHD.cmd', 'WHD.ps1', 'WHD-GUI.ps1', 'Inventory.ps1')) { if (Test-Path -LiteralPath (Join-Path $Src $n)) { $rel.Add($n) } }
    foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $Src 'modules') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) { $rel.Add(('modules\' + $m.Name)) }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($r in $rel) {
        $a = Join-Path $Src $r; $b = Join-Path $Dst $r
        if (-not (Test-Path -LiteralPath $b)) { $out.Add($r); continue }
        try { if ((Get-FileHash -LiteralPath $a -ErrorAction Stop).Hash -ne (Get-FileHash -LiteralPath $b -ErrorAction Stop).Hash) { $out.Add($r) } } catch { $out.Add($r) }
    }
    return @($out.ToArray())
}
function Get-WHDStartCopy {
    $o = [ordered]@{ Dir = $script:WHDStartCopyDir; Known = [bool]$script:WHDStartCopyDir; Exists = $false; Here = $false; Differ = @(); Text = '' }
    if (-not $o.Known) { $o.Text = 'not available (no ProgramData folder)'; return [pscustomobject]$o }
    $o.Here   = Test-WHDStartSamePath $script:WHDStartNextDir $o.Dir
    $o.Exists = ((Test-Path -LiteralPath (Join-Path $o.Dir 'Start-WHD.ps1')) -and (Test-Path -LiteralPath (Join-Path $o.Dir 'WHD.ps1')) -and (Test-Path -LiteralPath (Join-Path $o.Dir 'modules\Common.ps1')))
    if ($o.Here) { $o.Text = 'this IS the unlocked copy' }
    elseif ($o.Exists) {
        $o.Differ = @(Get-WHDStartProgramDiff -Src $script:WHDStartNextDir -Dst $o.Dir)
        if (@($o.Differ).Count) { $o.Text = ('exists in {0} - {1} program file(s) differ from this folder' -f $o.Dir, @($o.Differ).Count) }
        else { $o.Text = ('exists in {0}' -f $o.Dir) }
    } else { $o.Text = 'none' }
    return [pscustomobject]$o
}
# Our own folder copy: every file is copied one by one, folders are created as needed, nothing is removed.
#   -Top        : only these top-level names (files or folders); empty = everything
#   -NoOverwrite: top-level folders in which existing files are kept as they are
function Copy-WHDStartTree {
    param([string]$Src, [string]$Dst, [string[]]$Top = @(), [string[]]$NoOverwrite = @())
    $r = [ordered]@{ Files = 0; Kept = 0; Bytes = [int64]0; Failed = (New-Object System.Collections.Generic.List[string]) }
    $srcFull = (Get-Item -LiteralPath $Src).FullName.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force -ErrorAction Stop | Out-Null }
    foreach ($item in @(Get-ChildItem -LiteralPath $srcFull -Recurse -Force -ErrorAction SilentlyContinue)) {
        $rel = $item.FullName.Substring($srcFull.Length).TrimStart('\', '/')
        $first = ($rel -split '[\\/]')[0]
        if (@($Top).Count -and (@($Top) -notcontains $first)) { continue }
        $target = Join-Path $Dst $rel
        try {
            if ($item.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null }
                continue
            }
            $tdir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Path $tdir -Force -ErrorAction Stop | Out-Null }
            if ((@($NoOverwrite) -contains $first) -and (Test-Path -LiteralPath $target)) { $r.Kept++; continue }
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
            $r.Files++; $r.Bytes += [int64]$item.Length
        } catch { $r.Failed.Add(('{0}: {1}' -f $rel, $_.Exception.Message)) }
    }
    return [pscustomobject]$r
}
# Same permissions as the update guard's folder: Administrators + SYSTEM full, Users read/execute,
# owner Administrators (well-known SIDs, so it works in any Windows language). Returns '' or an error text.
function Set-WHDStartCopyAcl {
    param([string]$Base, [string]$Dir)
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    $steps = @(
        @($Base, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q'),
        @($Base, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q'),
        @((Join-Path $Base '*'), '/reset', '/T', '/C', '/Q')
    )
    foreach ($s in $steps) {
        $global:LASTEXITCODE = 0
        try { $null = & $icacls @s 2>&1 } catch { return ('icacls could not be started: {0}' -f $_.Exception.Message) }
        if ($LASTEXITCODE -ne 0) { return ('icacls {0} ended with exit code {1}' -f ($s -join ' '), $LASTEXITCODE) }
    }
    return ''
}
# Arguments to pass on when this launcher hands over to the copy's launcher.
function Get-WHDStartPassArgs {
    $a = New-Object System.Collections.Generic.List[string]
    if ($SafeMode) { $a.Add('-SafeMode') }
    if ($Execute)  { $a.Add('-Execute') }
    if ($Plan)     { $a.Add('-Plan') }
    if ($Yes)      { $a.Add('-Yes') }
    if ($Gui)      { $a.Add('-Gui') }
    if ($NoPrompt) { $a.Add('-NoPrompt') }
    if ($Apply)    { $a.Add('-Apply');  $a.Add($Apply) }
    if ($Export)   { $a.Add('-Export'); $a.Add($Export) }
    if (@($Simulate).Count -gt 0 -and $Simulate) { $a.Add('-Simulate'); $a.Add((@($Simulate) -join ',')) }
    $a.Add('-NoElevate')      # the administrator question was already asked in this window
    return @($a.ToArray())
}
# Runs the copy's launcher in this window. Returns nothing; the exit code is left in $script:WHDStartExit.
function Invoke-WHDStartHandOver {
    param([string]$Dir)
    $target = Join-Path $Dir 'Start-WHD.ps1'
    $pass = @(Get-WHDStartPassArgs)
    Write-Host (' Handing over to the unlocked copy: {0}' -f $Dir) -ForegroundColor Cyan
    Write-Host ''
    Write-WHDStartLog ('  handing over to the unlocked copy: {0} {1}' -f $target, ($pass -join ' '))
    $global:LASTEXITCODE = 0
    & $script:WHDStartPs51 -NoProfile -ExecutionPolicy Bypass -File $target @pass
    $script:WHDStartExit = $LASTEXITCODE
    Write-WHDStartLog ('  the unlocked copy ended, exit code {0}' -f $script:WHDStartExit)
}
# Copies the whole "next" folder to the unlocked place. Only after an explicit yes. Sets $script:WHDStartCopyOk.
function Invoke-WHDStartCopyToUnlocked {
    param([switch]$Pretend)
    $script:WHDStartCopyOk = $false
    $src = $script:WHDStartNextDir; $dst = $script:WHDStartCopyDir; $base = $script:WHDStartCopyBase
    Write-Host ''
    if (-not $dst) { Write-Host ' The unlocked folder cannot be worked out on this PC (no ProgramData folder).' -ForegroundColor Red; return }
    Write-Host ' The launcher would now COPY WHD Next:' -ForegroundColor White
    Write-Host ('   from: {0}' -f $src) -ForegroundColor Cyan
    Write-Host ('   to  : {0}' -f $dst) -ForegroundColor Cyan
    Write-Host ' Everything is copied: program, profiles, tools, journal, logs, reports and inventory.' -ForegroundColor Gray
    Write-Host ' Nothing is removed here. Only administrators can change the copy; other users can read it.' -ForegroundColor Gray
    Write-Host ' Windows folder protection does not cover that place, so no permission is needed there.' -ForegroundColor Gray
    Write-Host ' From then on WHD Next runs from the copy (starting it here hands over to the copy).' -ForegroundColor Gray
    $yn = (Read-Host ' Copy it now? [y/N]').Trim()
    Write-WHDStartLog ('  copy to the unlocked folder offered: {0} -> {1}   answer: {2}' -f $src, $dst, $(if ($yn -match '^[Yy]$') { 'yes' } else { 'no' }))
    if ($yn -notmatch '^[Yy]$') { Write-Host ' Not copied.' -ForegroundColor Yellow; return }
    if ($Pretend) {
        Write-Host ' SIMULATION: nothing was copied.' -ForegroundColor Magenta
        Write-WHDStartLog '  SIMULATION: copy not run'
        return
    }
    if (-not (Test-WHDStartAdmin)) {
        Write-Host ' This needs an administrator window. Start the launcher again and answer E at the first question.' -ForegroundColor Red
        Write-WHDStartLog '  copy not run: not administrator'
        return
    }
    try {
        foreach ($d in @($base, $dst)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null } }
    } catch {
        Write-Host (' The folder could not be created: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-WHDStartLog ('  copy failed: folder not created: {0}' -f $_.Exception.Message)
        return
    }
    Write-Host ' Copying ...' -ForegroundColor Cyan
    $res = Copy-WHDStartTree -Src $src -Dst $dst
    $aclErr = Set-WHDStartCopyAcl -Base $base -Dir $dst
    $info = @(
        'WHD Next - unlocked copy',
        ('copied from : {0}' -f $src),
        ('copied on   : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('computer    : {0}' -f $env:COMPUTERNAME),
        ('files       : {0}  ({1:N0} bytes)' -f $res.Files, $res.Bytes),
        'Nothing was removed from the folder it was copied from.'
    )
    try { $info | Set-Content -LiteralPath (Join-Path $dst 'copy-info.txt') -Encoding ASCII -ErrorAction Stop } catch { }
    Write-Host (' Copied {0} file(s), {1:N0} bytes.' -f $res.Files, $res.Bytes) -ForegroundColor Green
    Write-WHDStartLog ('  copied {0} file(s), {1} bytes; failed: {2}; permissions: {3}' -f $res.Files, $res.Bytes, $res.Failed.Count, $(if ($aclErr) { $aclErr } else { 'set' }))
    if ($res.Failed.Count) {
        Write-Host (' {0} file(s) could NOT be copied:' -f $res.Failed.Count) -ForegroundColor Red
        foreach ($f in @($res.Failed | Select-Object -First 10)) { Write-Host ('   {0}' -f $f) -ForegroundColor Red; Write-WHDStartLog ('  not copied: {0}' -f $f) }
    }
    if ($aclErr) {
        Write-Host (' The permissions could not be set: {0}' -f $aclErr) -ForegroundColor Red
        Write-Host ' The copy is NOT used. Nothing was removed; you can keep running WHD Next from this folder.' -ForegroundColor Yellow
        return
    }
    if (@(Get-WHDStartProgramDiff -Src $src -Dst $dst).Count) {
        Write-Host ' The copy is incomplete (program files differ). It is NOT used. Nothing was removed here.' -ForegroundColor Red
        Write-WHDStartLog '  copy incomplete: program files differ'
        return
    }
    $script:WHDStartCopyOk = $true
}
# Brings the copy's PROGRAM files up to date from this folder. The copy's journal, logs, reports, inventory
# and archive are not touched; in "profiles" and "installers" only files that are missing in the copy are added.
function Invoke-WHDStartUpdateCopy {
    param($Copy)
    $script:WHDStartCopyOk = $false
    if (-not (Test-WHDStartAdmin)) {
        Write-Host ' Updating the copy needs an administrator window. Start the launcher again and answer E at the first question.' -ForegroundColor Red
        Write-WHDStartLog '  update of the copy not run: not administrator'
        return
    }
    $src = $script:WHDStartNextDir; $dst = $Copy.Dir
    $data = @('logs', 'restore', 'inventory', 'reports', 'archive')
    $top = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue | Where-Object { $data -notcontains $_.Name } | ForEach-Object { $_.Name })
    Write-Host ' Updating the program files of the unlocked copy (its journal, logs and reports stay as they are) ...' -ForegroundColor Cyan
    $res = Copy-WHDStartTree -Src $src -Dst $dst -Top $top -NoOverwrite @('profiles', 'installers')
    $aclErr = Set-WHDStartCopyAcl -Base $script:WHDStartCopyBase -Dir $dst
    Write-Host (' Updated {0} file(s); {1} existing profile / installer file(s) kept.' -f $res.Files, $res.Kept) -ForegroundColor Green
    Write-WHDStartLog ('  copy updated: {0} file(s), kept {1}, failed {2}; permissions: {3}' -f $res.Files, $res.Kept, $res.Failed.Count, $(if ($aclErr) { $aclErr } else { 'set' }))
    foreach ($f in @($res.Failed | Select-Object -First 10)) { Write-Host ('   not copied: {0}' -f $f) -ForegroundColor Red; Write-WHDStartLog ('  not copied: {0}' -f $f) }
    if ($res.Failed.Count -or $aclErr -or @(Get-WHDStartProgramDiff -Src $src -Dst $dst).Count) {
        Write-Host ' The update did not finish cleanly - the copy is left as it is now.' -ForegroundColor Red
        if ($aclErr) { Write-Host ('   {0}' -f $aclErr) -ForegroundColor Red }
        return
    }
    $script:WHDStartCopyOk = $true
}

# =============================================================================
#  RUN - hand over to the chosen engine
# =============================================================================
function Invoke-WHDStartRun {
    # Returns nothing on purpose, so the started program talks to the window directly.
    # The exit code is left in $script:WHDStartExit.
    param([ValidateSet('Full', 'Safe')][string]$Mode, $State)
    $script:WHDStartExit = 1
    if (-not $State.Program.Present) {
        Write-Host ' Cannot start: the WHD Next program files were not found next to the launcher.' -ForegroundColor Red
        Write-WHDStartLog '  cannot start: program files not found'
        return
    }
    $target = $State.Program.Main
    if ($Gui) { $target = $State.Program.GuiFile }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host (' Cannot start: file not found: {0}' -f $target) -ForegroundColor Red
        return
    }
    if ($Mode -eq 'Full') {
        $exe   = $State.Pwsh.MsiPath
        $label = ('FULL mode (PowerShell {0})' -f $State.Pwsh.MsiVersionText)
        if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
            Write-Host ' Cannot start FULL mode: pwsh.exe was not found.' -ForegroundColor Red
            return
        }
    } else {
        $exe   = $script:WHDStartPs51
        $label = 'SAFE MODE (PowerShell 5.1) - checks, Verify, Undo and re-apply only'
    }

    # Arguments for the program. The engine decides the mode by itself as well
    # (5.1 is always SAFE mode), so a wrong flag here cannot unlock anything.
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
    if ($Mode -eq 'Safe') { $runArgs += '-SafeMode' }
    if ($Gui) {
        if ($State.IsAdmin) { $runArgs += '-NoElevate' }
    } else {
        if ($Execute)  { $runArgs += '-Execute' }
        if ($Plan)     { $runArgs += '-Plan' }
        if ($Yes)      { $runArgs += '-Yes' }
        if ($Apply)    { $runArgs += @('-Apply', $Apply) }
        if ($Export)   { $runArgs += @('-Export', $Export) }
        if ($Guard)    { $runArgs += '-Guard' }
        if ($DataRoot) { $runArgs += @('-DataRoot', $DataRoot) }
        if ($State.IsAdmin -or $Guard) { $runArgs += '-NoElevate' }
    }

    try { $Host.UI.RawUI.WindowTitle = ('WHD Next - {0}' -f $label) } catch { }
    Write-Host (' Starting WHD Next in {0} ...' -f $label) -ForegroundColor Cyan
    Write-Host ''
    Write-WHDStartLog ('  starting: {0}   {1} {2}' -f $label, $exe, ($runArgs -join ' '))
    $global:LASTEXITCODE = 0
    & $exe @runArgs
    $script:WHDStartExit = $LASTEXITCODE
    Write-WHDStartLog ('  WHD Next ended, exit code {0}' -f $script:WHDStartExit)
    Write-Host ''
    Write-Host (' WHD Next ended (exit code {0}). Back in the launcher.' -f $script:WHDStartExit) -ForegroundColor DarkGray
}

# =============================================================================
#  MAIN
# =============================================================================
$whdStartArgText = @(foreach ($whdK in @($PSBoundParameters.Keys)) { $whdV = $PSBoundParameters[$whdK]; if ($whdV -is [switch]) { if ($whdV) { '-' + $whdK } } else { '-{0} {1}' -f $whdK, (@($whdV) -join ',') } }) -join ' '
Write-WHDStartLog ('==== launcher start | {0} | PowerShell {1} | {2}\{3} | administrator: {4} | folder: {5} | switches: {6}' -f ($script:WHDStartBuild + ' | ' + $script:WHDStartVersion), $PSVersionTable.PSVersion, $env:USERDOMAIN, $env:USERNAME, (Test-WHDStartAdmin), $script:WHDStartNextDir, $(if ($whdStartArgText) { $whdStartArgText } else { '(none)' }))
if (-not (Test-WHDStartAdmin) -and -not $NoElevate -and -not $NoPrompt -and -not $Guard) {
    Write-Host ''
    Write-Host ' This window is not running as administrator.' -ForegroundColor Yellow
    Write-Host ' WHD needs administrator rights, and the check is more complete with them.' -ForegroundColor Yellow
    $go = Read-Host ' Press [E] then Enter to open an administrator window, or just Enter to continue without'
    if ($go -match '^[Ee]$') {
        $argList = @('-NoLogo', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path), '-NoElevate')
        if ($SafeMode) { $argList += '-SafeMode' }
        if ($Execute)  { $argList += '-Execute' }
        if ($Plan)     { $argList += '-Plan' }
        if ($Yes)      { $argList += '-Yes' }
        if ($Gui)      { $argList += '-Gui' }
        if ($Here)     { $argList += '-Here' }
        if ($CopyToUnlocked) { $argList += '-CopyToUnlocked' }
        if ($Apply)    { $argList += @('-Apply',  ('"{0}"' -f $Apply)) }
        if ($Export)   { $argList += @('-Export', ('"{0}"' -f $Export)) }
        if (@($Simulate).Count -gt 0 -and $Simulate) { $argList += @('-Simulate', (@($Simulate) -join ',')) }
        try { Start-Process -FilePath $script:WHDStartPs51 -Verb RunAs -ArgumentList $argList; Write-WHDStartLog '  re-opened in an administrator window; this window ends here'; return }
        catch { Write-Host (' Administrator window was declined: {0}' -f $_.Exception.Message) -ForegroundColor Red; Write-WHDStartLog ('  administrator window declined: {0}' -f $_.Exception.Message) }
    }
}

$whdSim = New-Object System.Collections.Generic.List[string]
$whdSimValid = @('missing', 'old', 'msix', 'newer', 'preview', 'cfa', 'nowinget', 'msifile')
foreach ($simItem in @($Simulate)) {
    if (-not $simItem) { continue }
    foreach ($part in ($simItem -split ',')) {
        $pv = $part.Trim().ToLower()
        if (-not $pv) { continue }
        if ($whdSimValid -notcontains $pv) {
            Write-Host (' Unknown -Simulate value "{0}". Use: {1}' -f $pv, ($whdSimValid -join ' | ')) -ForegroundColor Red
            return
        }
        if (-not $whdSim.Contains($pv)) { $whdSim.Add($pv) }
    }
}

# ---- unlocked copy: hand over to it, or offer it on request -------------------
$whdHandled = $false
if (-not $Guard -and $script:WHDStartCopyDir) {
    $whdCopy = Get-WHDStartCopy
    if ($whdCopy.Exists -and -not $whdCopy.Here -and -not $Here) {
        Write-Host ''
        Write-Host (' An unlocked copy of WHD Next exists: {0}' -f $whdCopy.Dir) -ForegroundColor Cyan
        Write-Host ' WHD Next keeps its journal, logs and reports there. (Start with -Here to stay in this folder.)' -ForegroundColor Gray
        Write-WHDStartLog ('  unlocked copy found: {0}; program files that differ: {1}' -f $whdCopy.Dir, @($whdCopy.Differ).Count)
        $whdGo = 'K'
        if (@($whdCopy.Differ).Count -and -not $NoPrompt) {
            Write-Host (' {0} program file(s) in THIS folder differ from the copy:' -f @($whdCopy.Differ).Count) -ForegroundColor Yellow
            foreach ($whdD in @($whdCopy.Differ | Select-Object -First 12)) { Write-Host ('   {0}' -f $whdD) -ForegroundColor Gray }
            $whdGo = Read-WHDStartChoice -Valid 'UKHQ' -Lines @(
                '[U] update the copy''s program files from this folder, then run the copy (its journal and logs stay)',
                '[K] keep the copy as it is and run it',
                '[H] run from this folder instead (this time only)',
                '[Q] quit')
        }
        if ($whdGo -eq 'U') { Invoke-WHDStartUpdateCopy -Copy $whdCopy; if (-not $script:WHDStartCopyOk) { $whdGo = 'Q' } }
        if ($whdGo -eq 'U' -or $whdGo -eq 'K') { Invoke-WHDStartHandOver -Dir $whdCopy.Dir; $whdHandled = $true }
        elseif ($whdGo -eq 'Q') { $whdHandled = $true }
    }
    elseif ($CopyToUnlocked -and -not $NoPrompt) {
        if ($whdCopy.Here)       { Write-Host ' This already is the unlocked copy.' -ForegroundColor Yellow }
        elseif ($whdCopy.Exists) { Write-Host (' An unlocked copy already exists: {0}  (start without -Here to use it).' -f $whdCopy.Dir) -ForegroundColor Yellow }
        else {
            Invoke-WHDStartCopyToUnlocked
            if ($script:WHDStartCopyOk) { Invoke-WHDStartHandOver -Dir $whdCopy.Dir; $whdHandled = $true }
        }
    }
}

:whdMain while (-not $whdHandled) {
    $state = Get-WHDStartState -Sim $whdSim.ToArray()
    Write-WHDStartLog ' start-up check:'
    Show-WHDStartState -State $state

    # ---- unattended: never ask, never install --------------------------------
    if ($NoPrompt) {
        if ($state.Mode -eq 'FULL' -and -not $SafeMode) { Invoke-WHDStartRun -Mode Full -State $state }
        else                                           { Invoke-WHDStartRun -Mode Safe -State $state }
        break whdMain
    }
    if ($SafeMode) { Invoke-WHDStartRun -Mode Safe -State $state; break whdMain }

    switch ($state.Mode) {
        'FULL' {
            if ($state.Pwsh.State -eq 'newer' -or $state.Pwsh.State -eq 'preview') {
                Write-Host (' WARNING: PowerShell {0} is not the tested {1} line. WHD Next has not been tested on it.' -f $state.Pwsh.MsiVersionText, $script:WHDStartTested) -ForegroundColor Yellow
                $c = Read-WHDStartChoice -Valid 'CSQ' -Lines @(
                    '[C] continue in FULL mode on this untested version',
                    '[S] start in SAFE mode on Windows PowerShell 5.1 instead',
                    '[Q] quit')
                if ($c -eq 'C') { Invoke-WHDStartRun -Mode Full -State $state }
                elseif ($c -eq 'S') { Invoke-WHDStartRun -Mode Safe -State $state }
                break whdMain
            }
            Invoke-WHDStartRun -Mode Full -State $state
            break whdMain
        }
        'FULL-AFTER-ALLOW' {
            $whdLines = New-Object System.Collections.Generic.List[string]
            $whdValid = 'R'
            $whdLines.Add('[R] re-check (after you allowed pwsh.exe in Windows Security)')
            if ($state.Copy.Known -and -not $state.Copy.Exists -and -not $state.Copy.Here) {
                $whdLines.Add(('[C] copy WHD Next to the unlocked folder {0} and run it from there (no permission needed)' -f $state.Copy.Dir)); $whdValid += 'C'
            }
            $whdLines.Add('[S] start in SAFE mode on Windows PowerShell 5.1'); $whdValid += 'S'
            $whdLines.Add('[Q] quit'); $whdValid += 'Q'
            $c = Read-WHDStartChoice -Valid $whdValid -Lines $whdLines.ToArray()
            if ($c -eq 'C') {
                Invoke-WHDStartCopyToUnlocked -Pretend:($whdSim.Count -gt 0)
                if ($script:WHDStartCopyOk) { Invoke-WHDStartHandOver -Dir $state.Copy.Dir; break whdMain }
                continue whdMain
            }
            if ($c -eq 'R') { [void]$whdSim.Remove('cfa'); continue whdMain }
            if ($c -eq 'S') { Invoke-WHDStartRun -Mode Safe -State $state }
            break whdMain
        }
        default {
            # SAFE: PowerShell 7 is missing, too old, or only the sandboxed version exists
            $verb = 'install'
            if ($state.Pwsh.State -eq 'old') { $verb = 'upgrade' }
            $lines = New-Object System.Collections.Generic.List[string]
            $valid = ''
            if ($state.Winget.Present) {
                $lines.Add(('[U] {0} PowerShell {1} now (machine-wide, through winget)' -f $verb, $script:WHDStartTested)); $valid += 'U'
            }
            if ($state.MsiFile.Usable) {
                $lines.Add(('[M] {0} PowerShell {1} from the file {2} (no download)' -f $verb, $state.MsiFile.Version, $state.MsiFile.Name)); $valid += 'M'
            }
            $lines.Add('[S] start in SAFE mode on Windows PowerShell 5.1'); $valid += 'S'
            $lines.Add('[Q] quit'); $valid += 'Q'
            $c = Read-WHDStartChoice -Valid $valid -Lines $lines.ToArray()

            if ($c -eq 'U' -or $c -eq 'M') {
                if ($c -eq 'U') { Invoke-WHDStartInstall -State $state } else { Invoke-WHDStartInstallFromFile -State $state }
                if ($script:WHDStartInstallOk -and $state.SimInstall) {
                    foreach ($x in @('missing', 'old', 'msix', 'msifile')) { [void]$whdSim.Remove($x) }   # simulation: now show the real PC
                }
                continue whdMain      # always re-check; the table shows what is really there now
            }
            if ($c -eq 'S') { Invoke-WHDStartRun -Mode Safe -State $state }
            break whdMain
        }
    }
}
Write-Host ''
Write-Host ' Launcher finished.' -ForegroundColor DarkGray
Write-WHDStartLog ('==== launcher finished (exit code {0})' -f $script:WHDStartExit)
if ($NoPrompt) { exit $script:WHDStartExit }
