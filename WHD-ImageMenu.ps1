<#
  WHD-ImageMenu.ps1   (WHD Imaging Helper 1.5 preview 1 - the menu)

  One terminal menu that builds the Home install stick in ONE session, step by step:

    1  Open image source    ISO file, Windows USB stick, or the install.wim kept in the work folder.
                            The Home edition is taken out (install.wim), copied (install-custom.wim) and
                            opened. It stays open between the steps.
    2  Inventory            the open image: bundled apps, optional features, capabilities, the AI system
                            packages (and Recall / AIX); this running Windows: its driver packages (copied
                            fresh every session; your on/off choices are kept by package name).
    3  Choose               switch items on and off inside the menu: apps, features, capabilities,
                            settings groups, drivers, first sign-in parts, AI packages. Saved into the
                            same list files the build script uses.
    4  Apply                the choices go into the open image (apps out, features off, capabilities
                            out, drivers in, services and registry values, "deprovisioned" marks, first
                            sign-in script + answer file).
    5  AI packages          the AI packages switched on in ai-list.txt are BLOCKED (deprovisioned mark,
                            AppLocker deny rule, first sign-in recheck) and REMOVED (their SystemApps
                            folder and their app entries in the image's registry).
    6  Save                 the image is saved (commit), checked to be one Home image, and split into
                            pieces under 4 GB (usb-custom).
    7  Make the stick       ERASES the stick after you typed  ERASE <letter> , copies the setup files and
                            the pieces, compares every checksum.
    X  Exit                 with the image still open it asks: keep it open, or close it without saving.

  THE AI PACKAGE REMOVAL (step 5) IS NOT SUPPORTED BY MICROSOFT. Use it only knowing
  this: Windows' health check (DISM /ScanHealth, SFC) on the installed PC can report the
  missing files as damage, a repair (/RestoreHealth) can put them back, and a cumulative update can fail
  or bring them back. Their component files in WinSxS are NOT touched (that would break servicing).
  On the first test install (Windows 11 Home, build 26300.9457) Windows took the AppLocker rules in.

  Needs: PowerShell 7 (stops and says so on Windows PowerShell 5.1), an administrator window, the work
  folder on an NTFS drive. Uses only PowerShell, DISM, reg.exe, takeown, icacls and the disk commands
  built into Windows. No downloads, no web calls.

  Every start begins clean: an image this menu left open is closed WITHOUT saving, its registry names
  are closed. Nothing in the work folder is deleted: older work files are renamed (_old_<date_time>).
  Everything is written to WHD-ImageMenu.log next to this script.

  Run in an administrator PowerShell 7 window, in the folder that holds this script:
    pwsh -ExecutionPolicy Bypass -File .\WHD-ImageMenu.ps1
  Work files on another NTFS drive:
    pwsh -ExecutionPolicy Bypass -File .\WHD-ImageMenu.ps1 -WorkDir D:\WHD-work
#>
param(
    [string]$WorkDir = '',
    [string]$HomeName = 'Windows 11 Home'
)

# This check comes first and uses only what Windows PowerShell 5.1 can read, so 5.1 gets a clear message.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host ('WHD-ImageMenu needs PowerShell 7. This window is Windows PowerShell {0}.' -f $PSVersionTable.PSVersion)
    Write-Host 'Install PowerShell 7 yourself, then start this menu with:  pwsh -ExecutionPolicy Bypass -File .\WHD-ImageMenu.ps1'
    Write-Host 'Nothing was changed.'
    exit 1
}

$ErrorActionPreference = 'Stop'

# ---- names and places -----------------------------------------------------------------------------
$root      = $PSScriptRoot
$log       = Join-Path $root 'WHD-ImageMenu.log'
$listFile  = Join-Path $root 'lists\remove-list.txt'
$setFile   = Join-Path $root 'lists\image-settings.txt'
$aiFile    = Join-Path $root 'lists\ai-list.txt'
$drvDir    = Join-Path $root 'drivers'
$drvList   = Join-Path $root 'drivers-list.txt'
$fsDir     = Join-Path $root 'first-signin'
$fsScript  = Join-Path $fsDir 'WHD-FirstSignIn.ps1'
$fsList    = Join-Path $fsDir 'first-signin-list.txt'
$fsAnswer  = Join-Path $fsDir 'Autounattend.xml'
$contents  = Join-Path $root 'image-contents.txt'
$imageAnswer     = 'Windows\Panther\unattend.xml'
$imageScriptsDir = 'Windows\Setup\Scripts'
$stickMarkName   = 'WHD-USB-Image.txt'
$stickLabel      = 'WHD-USB'
$hiveSys   = 'WHDMENUSYS'
$hiveSw    = 'WHDMENUSW'
$buildHives = @('WHDIMG', 'WHDIMGSW', 'WHDINVSW')
$stamp     = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$neverOff  = @('WinHttpAutoProxySvc')
$maxStickBytes = 256GB
$fatPartBytes  = 30GB
# The AI system packages, by the words in their names (whole word, any case).
$aiWords   = @('CoreAI', 'AIX', 'AIFabric', 'AugLoop', 'Voiess', 'Livtop', 'Speion')
# The broad rule that lets every packaged app run. Added together with the deny rules, because with
# AppLocker enforced and no allow rule NO packaged app could start (Start menu, Settings ...).
$allowAllId = 'a9e18c21-ff8f-43cf-b9fc-db40eed693ba'
$appxPolicyKey = 'Policies\Microsoft\Windows\SrpV2\Appx'

# ---- what this session knows ----------------------------------------------------------------------
$S = [ordered]@{
    Work = $root; SrcWim = ''; SrcNote = ''; NewWim = ''; NewDir = ''; SetupDir = ''
    Mount = ''; Mounted = $false
    SourceKind = ''; SourceText = ''; SourceSha = ''
    IsoPath = ''; IsoOpenedByUs = $false
    SetupFrom = ''        # 'iso' or 'folder' or ''
    Steps = @{ 1 = $false; 2 = $false; 3 = $false; 4 = $false; 5 = $false; 6 = $false; 7 = $false }
    Inv = $null
    Done = @(); Skipped = @(); Failed = @()
    Families = @()        # apps removed in step 4 (for their marks)
    BackupDone = @{}      # list files copied once before the menu's first edit
    Pieces = @()
}

# ===================================================================================================
# small helpers
# ===================================================================================================
function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -LiteralPath $log -Value ($line -replace '[^\x09\x20-\x7E]', '?') -Encoding Ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Host '    (that line could not be written to the log file)'
}

function Stop-Run([string]$Why) { throw "STOPPED - $Why" }

function Fmt([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Ask([string]$Prompt) {
    return ([string](Read-Host $Prompt)).Trim()
}

function Confirm-Yes([string]$Prompt) {
    $a = Ask "$Prompt (y = yes, anything else = no)"
    return ($a -match '^(y|yes)$')
}

function Add-Done([string]$T)    { $S.Done    += $T; Say "    done:    $T" }
function Add-Skipped([string]$T) { $S.Skipped += $T; Say "    skipped: $T" }
function Add-Failed([string]$T)  { $S.Failed  += $T; Say "    FAILED:  $T" }

function Invoke-Dism([string[]]$DismArgs, [switch]$AllowFail, [switch]$Quiet) {
    if (-not $Quiet) { Say ('dism ' + ($DismArgs -join ' ')) }
    $out  = & dism.exe @DismArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($l in $out) {
            $ln = ([string]$l).Trim()
            if ($ln -and ($ln -notmatch '^\[[=\s]*\d')) { Say ('    ' + $ln) }
        }
        if (-not $AllowFail) { Stop-Run "DISM ended with code $code" }
    }
    return [pscustomobject]@{ Code = $code; Out = @($out) }
}

# Runs a program and returns its exit code and all its text, error output included.
function Invoke-Program([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out  = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($o in @($out)) { $text += [string]$o }
    return [pscustomobject]@{ Code = $code; Out = $text }
}

function Invoke-Reg([string[]]$RegArgs) { return (Invoke-Program 'reg.exe' $RegArgs) }

function Open-Hive([string]$Name, [string]$File) {
    $r = $null
    for ($i = 0; $i -lt 3; $i++) {
        $r = Invoke-Reg @('load', "HKLM\$Name", $File)
        if ($r.Code -eq 0) { return $r }
        Start-Sleep -Seconds 2
    }
    return $r
}

function Close-Hive([string]$Name) {
    for ($i = 0; $i -lt 5; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $r = Invoke-Reg @('unload', "HKLM\$Name")
        if ($r.Code -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Test-HiveLoaded([string]$Name) {
    return ((Invoke-Reg @('query', "HKLM\$Name", '/ve')).Code -eq 0)
}

# Opens the image's SOFTWARE (and SYSTEM) registry for a block of work and always closes it again.
function Use-ImageRegistry([switch]$System, [scriptblock]$Work) {
    $sysOpen = $false; $swOpen = $false
    try {
        $r = Open-Hive $hiveSw (Join-Path $S.Mount 'Windows\System32\config\SOFTWARE')
        if ($r.Code -ne 0) { Stop-Run ("the image's registry (SOFTWARE) could not be opened: " + (($r.Out | Where-Object { $_ }) -join ' ')) }
        $swOpen = $true
        $controlSet = ''
        if ($System) {
            $r = Open-Hive $hiveSys (Join-Path $S.Mount 'Windows\System32\config\SYSTEM')
            if ($r.Code -ne 0) { Stop-Run ("the image's registry (SYSTEM) could not be opened: " + (($r.Out | Where-Object { $_ }) -join ' ')) }
            $sysOpen = $true
            $setNumber = 1
            foreach ($l in (Invoke-Reg @('query', "HKLM\$hiveSys\Select", '/v', 'Current')).Out) {
                if (([string]$l) -match 'Current\s+REG_DWORD\s+0x([0-9A-Fa-f]+)') { $setNumber = [Convert]::ToInt32($Matches[1], 16) }
            }
            $controlSet = 'ControlSet{0:D3}' -f $setNumber
        }
        & $Work $controlSet
    }
    finally {
        if ($swOpen -and (-not (Close-Hive $hiveSw))) { Say "WARNING: the image's registry is still open. Close it by hand:  reg unload HKLM\$hiveSw" }
        if ($sysOpen -and (-not (Close-Hive $hiveSys))) { Say "WARNING: the image's registry is still open. Close it by hand:  reg unload HKLM\$hiveSys" }
    }
}

function Get-RegValue([string]$Key, [string]$Name) {
    $q = Invoke-Reg @('query', $Key, '/v', $Name)
    if ($q.Code -eq 0) {
        $rx = '^\s+' + [regex]::Escape($Name) + '\s+(REG_[A-Z_]+)\s*(.*)$'
        foreach ($l in $q.Out) {
            if (([string]$l) -match $rx) { return [pscustomobject]@{ Exists = $true; Type = $Matches[1]; Data = ([string]$Matches[2]).Trim() } }
        }
    }
    return [pscustomobject]@{ Exists = $false; Type = ''; Data = '' }
}

function Test-RegSame($Have, [string]$Type, [string]$Data) {
    if (-not $Have.Exists) { return $false }
    if ($Type -eq 'dword') {
        if ($Have.Type -ne 'REG_DWORD') { return $false }
        if ($Have.Data -notmatch '^0x([0-9A-Fa-f]+)$') { return $false }
        return ([Convert]::ToUInt32($Matches[1], 16) -eq [uint32]$Data)
    }
    if ($Have.Type -ne 'REG_SZ') { return $false }
    return ($Have.Data -ceq $Data)
}

function Get-RegText($Have) { if (-not $Have.Exists) { return 'not set' }; return $Have.Data }

# The names of the subkeys right below a key ("" when the key is not there).
function Get-SubKeys([string]$Key) {
    $q = Invoke-Reg @('query', $Key)
    $list = @()
    if ($q.Code -ne 0) { return ,@() }
    $prefix = $Key.TrimEnd('\') + '\'
    foreach ($l in $q.Out) {
        $ln = ([string]$l).Trim()
        $full = $ln -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\'
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rest = $full.Substring($prefix.Length)
            if ($rest -and ($rest -notmatch '\\')) { $list += $rest }
        }
    }
    return ,@($list)
}

function Get-ImageList([string]$File, [string]$SwmPattern = '') {
    $a = @('/English', '/Get-WimInfo', "/WimFile:$File")
    $r = Invoke-Dism $a -Quiet
    $list = @(); $idx = 0
    foreach ($l in $r.Out) {
        $ln = [string]$l
        if ($ln -match '^\s*Index\s*:\s*(\d+)\s*$') { $idx = [int]$Matches[1] }
        elseif ($ln -match '^\s*Name\s*:\s*(.+?)\s*$') { $list += [pscustomobject]@{ Index = $idx; Name = $Matches[1] }; $idx = 0 }
    }
    return ,@($list)
}

function Test-HomeOnly([string]$File) {
    $l = Get-ImageList $File
    return (($l.Count -eq 1) -and ($l[0].Name -eq $HomeName))
}

function Get-Sha([string]$File) { return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }

function Get-LetterText($Letter) {
    $t = "$Letter"
    if ($t -match '^[A-Za-z]$') { return $t.ToUpperInvariant() }
    return ''
}

function Get-IsoLetter([string]$IsoPath) {
    for ($i = 0; $i -lt 10; $i++) {
        $l = ''
        try { $l = Get-LetterText (Get-Volume -DiskImage (Get-DiskImage -ImagePath $IsoPath) -ErrorAction Stop).DriveLetter } catch { $l = '' }
        if ($l) { return $l }
        Start-Sleep -Seconds 1
    }
    return ''
}

# Renames a file or folder to <name>_old_<stamp><ext>. Nothing is deleted.
function Move-Old([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item   = Get-Item -LiteralPath $Path -Force
    $parent = Split-Path -Parent $item.FullName
    if ($item.PSIsContainer) { $base = $item.Name; $ext = '' }
    else { $base = [IO.Path]::GetFileNameWithoutExtension($item.Name); $ext = $item.Extension }
    $try = '{0}_old_{1}{2}' -f $base, $stamp, $ext
    $n = 1
    while (Test-Path -LiteralPath (Join-Path $parent $try)) { $n++; $try = '{0}_old_{1}-{2}{3}' -f $base, $stamp, $n, $ext }
    Rename-Item -LiteralPath $item.FullName -NewName $try
    Say "    renamed $($item.Name) to $try (nothing deleted)"
}

# Whole-word match of the AI words; returns the words found.
function Get-AiWords([string]$Text) {
    $hit = @()
    foreach ($w in $aiWords) {
        if ($Text -match ('(?i)(^|[^A-Za-z0-9])' + [regex]::Escape($w) + '($|[^A-Za-z0-9])')) { $hit += $w }
    }
    return ,@($hit)
}

# "Microsoft.Copilot_0.25061.2.0_neutral_~_8wekyb3d8bbwe" -> "Microsoft.Copilot_8wekyb3d8bbwe"
function Get-FamilyName([string]$PackageName) {
    $parts = @($PackageName -split '_')
    if ($parts.Count -lt 5) { return '' }
    $fam = '{0}_{1}' -f $parts[0], $parts[$parts.Count - 1]
    if ($fam -notmatch '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$') { return '' }
    return $fam
}

# A copy of a list file is kept once per session, before the menu's first edit of it.
function Backup-ListOnce([string]$File) {
    if ($S.BackupDone.ContainsKey($File)) { return }
    if (Test-Path -LiteralPath $File -PathType Leaf) {
        $dest = Join-Path (Split-Path $File) ('{0}_before-menu_{1}{2}' -f [IO.Path]::GetFileNameWithoutExtension($File), $stamp, [IO.Path]::GetExtension($File))
        Copy-Item -LiteralPath $File -Destination $dest
        Say "    a copy of $(Split-Path -Leaf $File) as it was is kept as $(Split-Path -Leaf $dest)"
    }
    $S.BackupDone[$File] = $true
}

function Read-Lines([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return ,@() }
    return ,@(Get-Content -LiteralPath $File)
}

function Write-Lines([string]$File, $Lines) {
    $clean = @()
    foreach ($l in $Lines) { $clean += ([string]$l -replace '[^\x09\x20-\x7E]', '?') }
    Set-Content -LiteralPath $File -Value $clean -Encoding Ascii
}

# ===================================================================================================
# the lists (read) - the same formats the build script reads
# ===================================================================================================
function Read-Lists {
    $plan = [pscustomobject]@{
        Apps = @(); Features = @(); Capabilities = @(); Services = @(); RegOps = @()
        PartSettings = $false; PartMarks = $false; PartFirstSignIn = $false; GroupsOn = @(); GroupsOff = @()
    }
    if (-not (Test-Path -LiteralPath $listFile)) { Stop-Run "$listFile not found" }
    foreach ($raw in (Get-Content -LiteralPath $listFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^app:([A-Za-z0-9._-]+)$') { $plan.Apps += $Matches[1] }
        elseif ($t -match '^feature:([A-Za-z0-9._-]+)$') { $plan.Features += $Matches[1] }
        elseif ($t -match '^capability:([A-Za-z0-9._~-]+)$') { $plan.Capabilities += $Matches[1] }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') {
            if ($neverOff -contains $Matches[1]) { Stop-Run "remove-list.txt asks to switch off $($Matches[1]); refused (Wi-Fi did not come up without it in WHD's tests)" }
            $plan.Services += [pscustomobject]@{ Name = $Matches[1]; Group = 'remove-list' }
        }
        else { Stop-Run "remove-list.txt has a line that is not understood: $t" }
    }
    if (-not (Test-Path -LiteralPath $setFile)) { return $plan }
    $group = ''; $groupOn = $false
    foreach ($raw in (Get-Content -LiteralPath $setFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^part:(machine-settings|removed-app-marks|first-signin)\s+(on|off)$') {
            $on = ($Matches[2] -eq 'on')
            switch ($Matches[1]) {
                'machine-settings'  { $plan.PartSettings = $on }
                'removed-app-marks' { $plan.PartMarks = $on }
                'first-signin'      { $plan.PartFirstSignIn = $on }
            }
        }
        elseif ($t -match '^group:([a-z0-9-]+)\s+(on|off)$') {
            $group = $Matches[1]; $groupOn = ($Matches[2] -eq 'on')
            if (($plan.GroupsOn -contains $group) -or ($plan.GroupsOff -contains $group)) { Stop-Run "image-settings.txt names the group '$group' twice" }
            if ($groupOn) { $plan.GroupsOn += $group } else { $plan.GroupsOff += $group }
        }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') {
            if (-not $group) { Stop-Run "image-settings.txt: a line before the first group: line: $t" }
            if ($neverOff -contains $Matches[1]) { Stop-Run "image-settings.txt asks to switch off $($Matches[1]); refused" }
            if ($groupOn) { $plan.Services += [pscustomobject]@{ Name = $Matches[1]; Group = $group } }
        }
        elseif ($t.StartsWith('reg:')) {
            if (-not $group) { Stop-Run "image-settings.txt: a line before the first group: line: $t" }
            $f = @($t.Substring(4) -split '\|')
            if ($f.Count -ne 5) { Stop-Run "image-settings.txt: a reg: line needs 5 fields (hive|key|value name|type|data): $t" }
            $hive = $f[0]; $key = $f[1]; $name = $f[2]; $type = $f[3]; $data = $f[4]
            if ($t -match '["%&<>^]') { Stop-Run "image-settings.txt: a reg: line must not contain any of these characters: `" % & < > ^ : $t" }
            if (@('SOFTWARE', 'SYSTEM') -cnotcontains $hive) { Stop-Run "image-settings.txt: the hive must be SOFTWARE or SYSTEM: $t" }
            if (@('dword', 'string') -cnotcontains $type) { Stop-Run "image-settings.txt: the type must be dword or string: $t" }
            if ((-not $key) -or $key.StartsWith('\') -or $key.EndsWith('\') -or ($key -match '\\\\') -or ($key -match '[/*?]')) { Stop-Run "image-settings.txt: the key is not usable: $t" }
            if (($hive -eq 'SYSTEM') -and ($key -notmatch '^(Services|Control)\\')) { Stop-Run "image-settings.txt: a SYSTEM key must start with Services\ or Control\ : $t" }
            if (($hive -eq 'SYSTEM') -and ($key -match '^Services\\([^\\]+)') -and ($neverOff -contains $Matches[1]) -and ($name -eq 'Start')) { Stop-Run "image-settings.txt changes the start of $($Matches[1]); refused" }
            if ((-not $name) -or ($name -match '\s')) { Stop-Run "image-settings.txt: the value name is empty or has a space in it: $t" }
            if ($type -eq 'dword') {
                if (($data -notmatch '^\d{1,10}$') -or ([double]$data -gt 4294967295)) { Stop-Run "image-settings.txt: dword data must be a whole number from 0 to 4294967295: $t" }
            } elseif ((-not $data) -or ($data -ne $data.Trim()) -or $data.EndsWith('\')) { Stop-Run "image-settings.txt: string data is empty or ends with a backslash: $t" }
            if ($groupOn) { $plan.RegOps += [pscustomobject]@{ Group = $group; Hive = $hive; Key = $key; Name = $name; Type = $type; Data = $data } }
        }
        else { Stop-Run "image-settings.txt has a line that is not understood: $t" }
    }
    if (-not $plan.PartSettings) {
        $plan.RegOps = @()
        $plan.Services = @($plan.Services | Where-Object { $_.Group -eq 'remove-list' })
    }
    return $plan
}

function Read-DriverList {
    $list = @(); $seen = @()
    foreach ($raw in (Read-Lines $drvList)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^driver:([A-Za-z0-9._-]+)\s+(on|off)$') { Stop-Run "drivers-list.txt has a line that is not understood: $t" }
        $name = $Matches[1]; $on = ($Matches[2] -eq 'on')
        if ($seen -contains $name.ToLowerInvariant()) { Stop-Run "drivers-list.txt names the package '$name' twice" }
        $seen += $name.ToLowerInvariant()
        $list += [pscustomobject]@{ Name = $name; On = $on; Dir = (Join-Path $drvDir $name) }
    }
    return ,@($list)
}

# ai-list.txt: "ai:<package family name> on|off". on = block and remove in step 5.
function Read-AiList {
    $list = @(); $seen = @()
    foreach ($raw in (Read-Lines $aiFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -notmatch '^ai:([A-Za-z0-9.\-]+_[a-z0-9]{13})\s+(on|off)$') { Stop-Run "ai-list.txt has a line that is not understood: $t" }
        if ($seen -contains $Matches[1].ToLowerInvariant()) { Stop-Run "ai-list.txt names '$($Matches[1])' twice" }
        $seen += $Matches[1].ToLowerInvariant()
        $list += [pscustomobject]@{ Family = $Matches[1]; On = ($Matches[2] -eq 'on') }
    }
    return ,@($list)
}

# ===================================================================================================
# the lists (write) - edits in place, comments stay
# ===================================================================================================
# A line "<prefix><name> on|off": set it. Returns $false when there is no such line.
function Set-OnOffLine([string]$File, [string]$Prefix, [string]$Name, [bool]$On) {
    $lines = Read-Lines $File
    $rx = '^\s*' + [regex]::Escape($Prefix + $Name) + '\s+(on|off)\s*$'
    $hit = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([string]$lines[$i] -match $rx) { $lines[$i] = '{0}{1} {2}' -f $Prefix, $Name, $(if ($On) { 'on' } else { 'off' }); $hit = $true }
    }
    if ($hit) { Write-Lines $File $lines }
    return $hit
}

# remove-list.txt: an "app:X" line present = remove. Off = the line becomes "# app:X (off - menu)".
# On again = that line is made active again, or a new line is added at the end.
function Set-PresenceLine([string]$File, [string]$Entry, [bool]$Present) {
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($l in (Read-Lines $File)) { $lines.Add([string]$l) }
    $active = '^\s*' + [regex]::Escape($Entry) + '\s*$'
    $parked = '^\s*#\s*' + [regex]::Escape($Entry) + '\s*(\(off - menu\))?\s*$'
    $ia = -1; $ip = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if (($ia -lt 0) -and ($lines[$i] -match $active)) { $ia = $i }
        elseif (($ip -lt 0) -and ($lines[$i] -match $parked)) { $ip = $i }
    }
    if ($Present) {
        if ($ia -ge 0) { return }
        if ($ip -ge 0) { $lines[$ip] = $Entry }
        else {
            $mark = '# --- added by WHD-ImageMenu ---'
            if (-not ($lines -contains $mark)) { $lines.Add(''); $lines.Add($mark) }
            $lines.Add($Entry)
        }
    } else {
        if ($ia -lt 0) { return }
        $lines[$ia] = "# $Entry (off - menu)"
    }
    Write-Lines $File $lines.ToArray()
}

# ===================================================================================================
# the toggle screen used by step 3
# ===================================================================================================
# Items: objects with Key, Label, Info, On. Returns the items with the new On values, or $null (back
# without saving).
function Show-Toggle([string]$Title, [string]$OnMeans, $Items) {
    $work = @()
    foreach ($it in $Items) { $work += [pscustomobject]@{ Key = $it.Key; Label = $it.Label; Info = $it.Info; On = [bool]$it.On; Was = [bool]$it.On } }
    while ($true) {
        Write-Host ''
        Write-Host ("=== {0} ===   [x] = {1}" -f $Title, $OnMeans)
        for ($i = 0; $i -lt $work.Count; $i++) {
            $mark = if ($work[$i].On) { 'x' } else { ' ' }
            $chg  = if ($work[$i].On -ne $work[$i].Was) { ' *' } else { '' }
            $info = if ($work[$i].Info) { '   ' + $work[$i].Info } else { '' }
            Write-Host ('{0,4} [{1}] {2}{3}{4}' -f ($i + 1), $mark, $work[$i].Label, $chg, $info)
        }
        Write-Host '  numbers toggle (1,3,5  2-6) | a = all on | n = all off | s = save and back | q = back without saving'
        $in = Ask 'Choice'
        if ($in -match '^(s|S)$') { return $work }
        if ($in -match '^(q|Q)$') { return $null }
        if ($in -match '^(a|A)$') { foreach ($w in $work) { $w.On = $true }; continue }
        if ($in -match '^(n|N)$') { foreach ($w in $work) { $w.On = $false }; continue }
        $nums = Get-Numbers $in $work.Count
        if ($null -eq $nums) { Write-Host '  (not understood - use numbers, ranges like 2-6, a, n, s or q)'; continue }
        foreach ($n in $nums) { $work[$n - 1].On = -not $work[$n - 1].On }
    }
}

# "1,3, 5-7" -> 1,3,5,6,7. $null when not understood or out of range.
function Get-Numbers([string]$Text, [int]$Max) {
    if (-not $Text) { return $null }
    $out = @()
    foreach ($tok in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $x = $a; $a = $b; $b = $x }
            for ($n = $a; $n -le $b; $n++) { $out += $n }
        } elseif ($tok -match '^\d+$') { $out += [int]$tok }
        else { return $null }
    }
    foreach ($n in $out) { if (($n -lt 1) -or ($n -gt $Max)) { return $null } }
    return ,@($out | Select-Object -Unique)
}

# ===================================================================================================
# start: always clean
# ===================================================================================================
function Start-Clean {
    foreach ($h in @($hiveSw, $hiveSys)) {
        if (Test-HiveLoaded $h) {
            if (Close-Hive $h) { Say "Clean start: the registry name HKLM\$h of an earlier session was closed." }
            else { Stop-Run "the registry name HKLM\$h of an earlier session cannot be closed. Close it by hand:  reg unload HKLM\$h" }
        }
    }
    foreach ($h in $buildHives) {
        if (Test-HiveLoaded $h) { Stop-Run "HKLM\$h is in use: the build script or the inventory script is running (or did not close it). Start the menu when they have ended" }
    }
    $info = Invoke-Dism @('/English', '/Get-MountedWimInfo') -AllowFail -Quiet
    $workLow = $S.Work.ToLowerInvariant()
    foreach ($l in $info.Out) {
        if (([string]$l) -match '^\s*Mount Dir\s*:\s*(.+?)\s*$') {
            $md = $Matches[1].TrimEnd('\')
            $leaf = (Split-Path -Leaf $md).ToLowerInvariant()
            $parent = (Split-Path -Parent $md).ToLowerInvariant()
            if ($parent -ne $workLow) { continue }
            if ($leaf -like 'mount-menu*') {
                Say "Clean start: an image of an earlier session is still open in $md. Closing it WITHOUT saving ..."
                $r = Invoke-Dism @('/Unmount-Image', "/MountDir:$md", '/Discard') -AllowFail
                if ($r.Code -ne 0) { Stop-Run "the image in $md could not be closed. Close it by hand:  dism /Unmount-Image /MountDir:`"$md`" /Discard   (then, if needed:  dism /Cleanup-Wim)" }
            }
            elseif (($leaf -like 'mount') -or ($leaf -like 'mount_*') -or ($leaf -like 'mount-inventory*')) {
                Stop-Run "the build script or the inventory script has an image open in $md. Start the menu when it has ended (or close it:  dism /Unmount-Image /MountDir:`"$md`" /Discard)"
            }
        }
    }
}

# ===================================================================================================
# step 1 - open the image source
# ===================================================================================================
function Step1 {
    if ($S.Mounted) {
        if (-not (Confirm-Yes 'An image is open. Close it WITHOUT saving and open a new source?')) { return }
        Close-Image -Discard
    }
    Write-Host ''
    Write-Host '  1  ISO file'
    Write-Host '  2  Windows USB stick (made by the media creation tool)'
    Write-Host '  3  install.wim kept in the work folder'
    $c = Ask 'Source'
    $setupFrom = ''; $sourceSha = ''; $sourceText = ''
    switch ($c) {
        '1' {
            $isos = @(Get-ChildItem -LiteralPath $root -Filter '*.iso' -File -ErrorAction SilentlyContinue)
            if ($S.Work -ne $root) { $isos += @(Get-ChildItem -LiteralPath $S.Work -Filter '*.iso' -File -ErrorAction SilentlyContinue) }
            for ($i = 0; $i -lt $isos.Count; $i++) { Write-Host ('  {0}  {1}  ({2})' -f ($i + 1), $isos[$i].FullName, (Fmt $isos[$i].Length)) }
            $p = Ask 'Number of an ISO above, or the full path of an ISO file'
            if (($p -match '^\d+$') -and ([int]$p -ge 1) -and ([int]$p -le $isos.Count)) { $p = $isos[[int]$p - 1].FullName }
            $p = $p.Trim('"')
            if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or ($p -notmatch '\.iso$')) { Stop-Run "not an ISO file: $p" }
            $iso = (Get-Item -LiteralPath $p).FullName
            Say "ISO file: $iso ($(Fmt (Get-Item -LiteralPath $iso).Length))"
            Say 'Working out its SHA-256 checksum (a minute or two) ...'
            $sourceSha = Get-Sha $iso
            Say "    SHA-256: $sourceSha"
            $want = Ask 'SHA-256 the download page shows (Enter = skip the compare)'
            $want = ($want -replace '[\s:-]', '').ToUpperInvariant()
            if ($want) {
                if ($want -notmatch '^[0-9A-F]{64}$') { Stop-Run 'that is not a SHA-256 value' }
                if ($want -ne $sourceSha) { Stop-Run 'the ISO file does not have that SHA-256 value. Nothing was changed' }
                Say '    same as the value you typed.'
            }
            Open-Iso $iso
            $isoSrc = "$(Get-IsoLetter $iso):\sources"
            $srcImage = Find-InstallImage $isoSrc
            $sourceText = "ISO file $(Split-Path -Leaf $iso)"
            $setupFrom = 'iso'
        }
        '2' {
            $l = (Ask 'Letter of the Windows USB stick').TrimEnd(':').ToUpperInvariant()
            if ($l -notmatch '^[A-Z]$') { Stop-Run 'that is not a drive letter' }
            $stickSrc = "${l}:\sources"
            if (-not (Test-Path -LiteralPath (Join-Path $stickSrc 'boot.wim'))) { Stop-Run "${l}:\ is not a Windows install stick (no sources\boot.wim)" }
            if (Test-Path -LiteralPath "${l}:\$stickMarkName") { Stop-Run "${l}:\ holds a CHANGED image made by these scripts ($stickMarkName is on it). Use a plain Windows stick or the ISO file" }
            $srcImage = Find-InstallImage $stickSrc
            Say ("Install image on the stick: {0} ({1})" -f $srcImage, (Fmt (Get-Item -LiteralPath $srcImage).Length))
            Say 'Working out its SHA-256 checksum ...'
            $sourceSha = Get-Sha $srcImage
            Say "    SHA-256: $sourceSha"
            # The setup files are copied now: the same stick may be the one that is erased in step 7.
            $setup = Join-Path $S.Work 'setup-files'
            if (Test-Path -LiteralPath $setup) { Move-Old $setup }
            New-Item -ItemType Directory -Path $setup | Out-Null
            $items = Get-SetupFiles "${l}:\"
            Say ("Copying the stick's {0} setup file(s) (all but the install image) to setup-files, each compared ..." -f $items.Count)
            foreach ($it in $items) { Copy-CheckedTo $it.File (Join-Path $setup $it.Rel) }
            Say '    copied, all checksums same.'
            $sourceText = "Windows USB stick ${l}:"
            $setupFrom = 'folder'
        }
        '3' {
            if (-not (Test-Path -LiteralPath $S.SrcWim -PathType Leaf)) { Stop-Run "there is no install.wim in $($S.Work)" }
            if (-not (Test-HomeOnly $S.SrcWim)) { Stop-Run "install.wim is not a single '$HomeName' image" }
            $note = Read-Lines $S.SrcNote
            if ($note.Count -ge 1) { $sourceSha = ([string]$note[0]).Trim() }
            $made = if ($note.Count -ge 2) { [string]$note[1] } else { '(not known)' }
            $sourceText = "install.wim kept (made from $made)"
            $srcImage = ''
            $iso = Join-Path $root $made
            if (($note.Count -ge 2) -and (Test-Path -LiteralPath $iso -PathType Leaf)) {
                Say "The ISO file named in install-source.txt is here: $made. Checking it is the same file (SHA-256) ..."
                if ((Get-Sha $iso) -eq $sourceSha) { Open-Iso $iso; $setupFrom = 'iso'; Say '    same - its setup files are used in step 7.' }
                else { Say '    NOT the same file: its setup files are not used.' }
            }
            if ((-not $setupFrom) -and (Test-Path -LiteralPath (Join-Path $S.Work 'setup-files\sources\boot.wim'))) { $setupFrom = 'folder'; Say 'The setup files in setup-files are used in step 7.' }
            if (-not $setupFrom) { Say 'NOTE: no setup files are known yet. Step 7 asks for an ISO file.' }
        }
        default { Write-Host '  (nothing chosen)'; return }
    }

    $vol = Get-Volume -DriveLetter $S.Work.Substring(0, 1)
    if ($vol.SizeRemaining -lt 25GB) { Stop-Run ("less than 25 GB free on drive {0}: ({1} free)" -f $S.Work.Substring(0, 1), (Fmt $vol.SizeRemaining)) }

    if ($srcImage) {
        $reuse = $false
        if ((Test-Path -LiteralPath $S.SrcWim -PathType Leaf) -and (Test-Path -LiteralPath $S.SrcNote -PathType Leaf)) {
            if (([string](Read-Lines $S.SrcNote)[0]).Trim() -eq $sourceSha) { $reuse = $true }
        }
        if ($reuse) { Say 'install.wim in the work folder was made from this same source. It is used again.' }
        else {
            if (Test-Path -LiteralPath $S.SrcWim) { Say 'install.wim in the work folder is from another source:'; Move-Old $S.SrcWim }
            $images = Get-ImageList $srcImage
            foreach ($i in $images) { Say ("    in the source: index {0} = {1}" -f $i.Index, $i.Name) }
            $homeImg = @($images | Where-Object { $_.Name -eq $HomeName })
            if ($homeImg.Count -ne 1) { Stop-Run "the source does not hold exactly one edition named '$HomeName'" }
            $partial = Join-Path $S.Work 'install-partial.wim'
            if (Test-Path -LiteralPath $partial) { Move-Old $partial }
            Say 'Exporting the Home edition with maximum compression (15 minutes or more) ...'
            $a = @('/Export-Image', "/SourceImageFile:$srcImage")
            if ($srcImage -match '\.swm$') { $a += "/SWMFile:$(Join-Path (Split-Path $srcImage) 'install*.swm')" }
            $a += @("/SourceIndex:$($homeImg[0].Index)", "/DestinationImageFile:$partial", '/Compress:max', '/CheckIntegrity')
            Invoke-Dism $a | Out-Null
            if (-not (Test-HomeOnly $partial)) { Stop-Run "the export is not a single '$HomeName' image. It is kept as $partial" }
            Rename-Item -LiteralPath $partial -NewName 'install.wim'
            $srcName = if ($setupFrom -eq 'iso') { Split-Path -Leaf $S.IsoPath } else { $sourceText }
            Set-Content -LiteralPath $S.SrcNote -Value @($sourceSha, $srcName, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding Ascii
            Say ("install.wim made: {0}" -f (Fmt (Get-Item -LiteralPath $S.SrcWim).Length))
        }
    }

    if (Test-Path -LiteralPath $S.NewWim) { Say 'install-custom.wim of an earlier run:'; Move-Old $S.NewWim }
    Say ("Copying install.wim to install-custom.wim ({0}) ..." -f (Fmt (Get-Item -LiteralPath $S.SrcWim).Length))
    Copy-Item -LiteralPath $S.SrcWim -Destination $S.NewWim
    $m = Join-Path $S.Work 'mount-menu'
    if ((Test-Path -LiteralPath $m) -and (@(Get-ChildItem -LiteralPath $m -Force).Count -gt 0)) { $m = Join-Path $S.Work "mount-menu_$stamp" }
    if (-not (Test-Path -LiteralPath $m)) { New-Item -ItemType Directory -Path $m | Out-Null }
    Say 'Opening install-custom.wim (a few minutes) ...'
    Invoke-Dism @('/Mount-Image', "/ImageFile:$($S.NewWim)", '/Index:1', "/MountDir:$m") | Out-Null
    $S.Mount = $m; $S.Mounted = $true
    if (Test-Path -LiteralPath (Join-Path $m "$imageScriptsDir\WHD-Image-applied.txt")) {
        Close-Image -Discard
        Stop-Run 'install.wim holds an image these scripts changed before (WHD-Image-applied.txt is in it). Choose the ISO file or a plain stick: install.wim is then made new'
    }
    $S.SourceKind = $c; $S.SourceText = $sourceText; $S.SourceSha = $sourceSha; $S.SetupFrom = $setupFrom
    $S.Done = @(); $S.Skipped = @(); $S.Failed = @(); $S.Families = @(); $S.Inv = $null; $S.Pieces = @()
    foreach ($k in @(2, 3, 4, 5, 6, 7)) { $S.Steps[$k] = $false }
    $S.Steps[1] = $true
    Say "RESULT: step 1 DONE - $sourceText; the Home image is open in $m."
}

function Find-InstallImage([string]$Dir) {
    foreach ($kind in @('wim', 'esd', 'swm')) {
        $f = Join-Path $Dir "install.$kind"
        if (Test-Path -LiteralPath $f -PathType Leaf) { return $f }
    }
    Stop-Run "there is no install.wim, install.esd or install.swm in $Dir"
}

function Open-Iso([string]$Iso) {
    if ($S.IsoPath -and ($S.IsoPath -ne $Iso)) { Close-Iso }
    if (-not (Get-DiskImage -ImagePath $Iso).Attached) {
        Mount-DiskImage -ImagePath $Iso -ErrorAction Stop | Out-Null
        $S.IsoOpenedByUs = $true
    }
    $S.IsoPath = $Iso
    $l = Get-IsoLetter $Iso
    if (-not $l) { Stop-Run 'Windows opened the ISO file but gave it no drive letter' }
    if (-not (Test-Path -LiteralPath "${l}:\sources\boot.wim")) { Stop-Run 'the ISO file is not a Windows install ISO (no sources\boot.wim)' }
    Say "The ISO file is open as drive ${l}:"
}

function Close-Iso {
    if ($S.IsoPath -and $S.IsoOpenedByUs) {
        try { Dismount-DiskImage -ImagePath $S.IsoPath -ErrorAction Stop | Out-Null; Say 'The ISO file was closed.' }
        catch { Say 'NOTE: the ISO file could not be closed. Eject its drive in Explorer.' }
    }
    $S.IsoPath = ''; $S.IsoOpenedByUs = $false
}

function Close-Image([switch]$Discard) {
    if (-not $S.Mounted) { return }
    $r = Invoke-Dism @('/Unmount-Image', "/MountDir:$($S.Mount)", '/Discard') -AllowFail
    if ($r.Code -eq 0) { Say 'The image was closed WITHOUT saving.'; $S.Mounted = $false }
    else { Say "WARNING: the image could not be closed. Close it by hand:  dism /Unmount-Image /MountDir:`"$($S.Mount)`" /Discard" }
}

# Every file of a setup source (ISO drive, stick, setup-files folder) except the install image.
function Get-SetupFiles([string]$Base) {
    $baseFull = (Get-Item -LiteralPath $Base).FullName
    $list = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Base -Recurse -File -Force | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($baseFull.Length).TrimStart('\', '/')
        if ($rel -match '^sources[\\/]install\d*\.(swm|wim|esd)$') { continue }
        if ($rel -match '^System Volume Information[\\/]') { continue }
        if ($rel -ieq $stickMarkName) { continue }
        $list += [pscustomobject]@{ File = $f; Rel = $rel }
    }
    return ,@($list)
}

# Copies one file to a full destination path and compares size and SHA-256; a second try on a difference.
function Copy-CheckedTo($File, [string]$Dest) {
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $h1 = Get-Sha $File.FullName
    for ($try = 1; $try -le 2; $try++) {
        Copy-Item -LiteralPath $File.FullName -Destination $Dest -Force
        $made = Get-Item -LiteralPath $Dest -Force
        if (($made.Length -eq $File.Length) -and ((Get-Sha $Dest) -eq $h1)) {
            if ($made.IsReadOnly) { $made.IsReadOnly = $false }
            return $h1
        }
        Say ("    {0}: the copy differs from its source (attempt {1})." -f $Dest, $try)
    }
    Stop-Run "$Dest does not match its source after two copies. On a stick: try a USB port directly on the PC (no hub), or another stick"
}

# ===================================================================================================
# step 2 - inventory
# ===================================================================================================
function Step2 {
    if (-not $S.Mounted) { Stop-Run 'open an image first (step 1)' }
    $inv = [ordered]@{ Apps = [ordered]@{}; Features = [ordered]@{}; Caps = [ordered]@{}; Ai = @(); Recall = @(); Cbs = @() }

    Say 'Inventory of the open image ...'
    $disp = ''
    foreach ($l in (Invoke-Dism @('/English', "/Image:$($S.Mount)", '/Get-ProvisionedAppxPackages')).Out) {
        $ln = [string]$l
        if ($ln -match '^\s*DisplayName\s*:\s*(.+?)\s*$') { $disp = $Matches[1] }
        elseif ($ln -match '^\s*PackageName\s*:\s*(.+?)\s*$') { if ($disp) { $inv.Apps[$disp] = $Matches[1] }; $disp = '' }
    }
    foreach ($l in (Invoke-Dism @('/English', "/Image:$($S.Mount)", '/Get-Features', '/Format:Table')).Out) {
        if (([string]$l) -match '^\s*(\S+)\s*\|\s*(Enabled|Disabled|Disabled with Payload Removed|Enable Pending|Disable Pending)\s*$') { $inv.Features[$Matches[1]] = $Matches[2] }
    }
    foreach ($l in (Invoke-Dism @('/English', "/Image:$($S.Mount)", '/Get-Capabilities', '/Format:Table')).Out) {
        if (([string]$l) -match '^\s*(\S+~\S*)\s*\|\s*(.+?)\s*$') { $inv.Caps[$Matches[1]] = $Matches[2] }
    }
    $win = Join-Path $S.Mount 'Windows'

    # AI system packages: folders, their app entries, the hidden servicing packages (AIX, Recall).
    foreach ($sub in @('SystemApps', 'SystemApps\SxS')) {
        $dir = Join-Path $win $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ((Get-AiWords $d.Name).Count -eq 0) { continue }
            $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
            $bytes = [double]0; foreach ($x in $files) { $bytes += $x.Length }
            $man = Join-Path $d.FullName 'AppxManifest.xml'
            $idName = ''; $idPub = ''
            if (Test-Path -LiteralPath $man) {
                try {
                    $xml = [xml](Get-Content -LiteralPath $man -Raw)
                    $idName = [string]$xml.Package.Identity.Name
                    $idPub  = [string]$xml.Package.Identity.Publisher
                } catch { }
            }
            $inv.Ai += [pscustomobject]@{
                Family = $d.Name; Rel = "$sub\$($d.Name)"; Path = $d.FullName; Files = $files.Count; Bytes = $bytes
                Name = $idName; Publisher = $idPub; Inbox = @(); Config = $false; Updated = $false
            }
        }
    }
    Use-ImageRegistry {
        param($cs)
        $store = "HKLM\$hiveSw\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
        $inbox = Get-SubKeys "$store\InboxApplications"
        $cfg   = Get-SubKeys "$store\Config"
        $upd   = Get-SubKeys "$store\UpdatedApplications"
        foreach ($a in $inv.Ai) {
            $pre = ($a.Family -split '_')[0] + '_'
            $pub = ($a.Family -split '_')[-1]
            $a.Inbox   = @($inbox | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) -and $_.EndsWith("_$pub", [StringComparison]::OrdinalIgnoreCase) })
            $a.Config  = (@($cfg | Where-Object { $_ -ieq $a.Family }).Count -gt 0)
            $a.Updated = (@($upd | Where-Object { $_ -ieq $a.Family }).Count -gt 0)
        }
        $cbsKey = "HKLM\$hiveSw\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"
        foreach ($p in (Get-SubKeys $cbsKey)) {
            if (($p -notmatch '(?i)(^|[^A-Za-z0-9])(AIX|Recall)($|[^A-Za-z0-9])')) { continue }
            $st = Get-RegValue "$cbsKey\$p" 'CurrentState'
            $vi = Get-RegValue "$cbsKey\$p" 'Visibility'
            $inv.Cbs += [pscustomobject]@{ Name = $p; State = (Get-CbsStateText $st); Visibility = $(if ($vi.Exists) { $vi.Data } else { '-' }) }
        }
    }
    foreach ($f in $inv.Features.Keys) { if ($f -match '(?i)recall') { $inv.Recall += "$f ($($inv.Features[$f]))" } }

    $txt = @()
    $txt += ('Contents of the open Home image - {0}. Source: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $S.SourceText)
    $txt += ''
    $txt += "=== BUNDLED APPS ($($inv.Apps.Count)) - display name -> package ==="
    foreach ($k in $inv.Apps.Keys) { $txt += "$k -> $($inv.Apps[$k])" }
    $txt += ''
    $en = @($inv.Features.Keys | Where-Object { $inv.Features[$_] -eq 'Enabled' })
    $txt += "=== OPTIONAL FEATURES ENABLED ($($en.Count) of $($inv.Features.Count)) ==="
    $txt += $en
    $txt += ''
    $ic = @($inv.Caps.Keys | Where-Object { $inv.Caps[$_] -eq 'Installed' })
    $txt += "=== CAPABILITIES INSTALLED ($($ic.Count)) ==="
    $txt += $ic
    $txt += ''
    $txt += "=== AI SYSTEM PACKAGES ($($inv.Ai.Count)) - folder, files, app entries ==="
    foreach ($a in $inv.Ai) {
        $txt += ('{0}  ({1} files, {2}; manifest name: {3}; app entries: inbox {4}, config {5}, updated {6})' -f $a.Rel, $a.Files, (Fmt $a.Bytes), $(if ($a.Name) { $a.Name } else { 'none' }), $a.Inbox.Count, $a.Config, $a.Updated)
    }
    $txt += ''
    $txt += '=== RECALL / AIX ==='
    $txt += ('Recall optional feature: {0}' -f $(if ($inv.Recall.Count) { $inv.Recall -join '; ' } else { 'not in the image' }))
    foreach ($c in $inv.Cbs) { $txt += ('servicing package {0}: state {1}, visibility {2}' -f $c.Name, $c.State, $c.Visibility) }
    if (Test-Path -LiteralPath $contents) { Move-Old $contents }
    Write-Lines $contents $txt
    Say ("Image: {0} bundled apps, {1} features enabled, {2} capabilities installed, {3} AI package folder(s). Written to image-contents.txt." -f $inv.Apps.Count, $en.Count, $ic.Count, $inv.Ai.Count)
    Say ('    Recall feature: {0}' -f $(if ($inv.Recall.Count) { $inv.Recall -join '; ' } else { 'not in the image' }))
    foreach ($c in $inv.Cbs) { Say ('    {0}: {1}, visibility {2}' -f $c.Name, $c.State, $c.Visibility) }

    # ai-list.txt: made when missing; a package found now that is not in it is added switched ON.
    $have = Read-AiList
    $lines = Read-Lines $aiFile
    if ($lines.Count -eq 0) {
        $lines = @(
            '# ai-list.txt - the AI system packages of the image, for WHD-ImageMenu.ps1 (step 5).',
            '# on  = BLOCK (deprovisioned mark, AppLocker deny rule, first sign-in recheck) and REMOVE (its SystemApps',
            '#       folder and its app entries in the image registry).  off = left as it is.',
            '# NOT SUPPORTED BY MICROSOFT: a health check can report the missing files, a repair or an update can bring',
            '# them back or fail. Their WinSxS component files are not touched.',
            '')
    }
    $added = 0
    foreach ($a in $inv.Ai) {
        if (@($have | Where-Object { $_.Family -ieq $a.Family }).Count -gt 0) { continue }
        $lines += "# $($a.Rel)"
        $lines += "ai:$($a.Family) on"
        $added++
    }
    if ($added -gt 0) { Write-Lines $aiFile $lines; Say "    ai-list.txt: $added package(s) added, switched on." }

    Step2Drivers
    $S.Inv = $inv
    $S.Steps[2] = $true
    Say 'RESULT: step 2 DONE - image-contents.txt and drivers-list.txt are up to date.'
}

function Get-CbsStateText($Have) {
    if (-not $Have.Exists) { return 'not set' }
    if ($Have.Data -notmatch '^0x([0-9A-Fa-f]+)$') { return $Have.Data }
    $n = [Convert]::ToInt32($Matches[1], 16)
    $names = @{ 0 = 'absent'; 5 = 'uninstall pending'; 16 = 'resolving'; 32 = 'resolved'; 48 = 'staging'; 64 = 'staged'; 80 = 'superseded'; 96 = 'install pending'; 101 = 'partially installed'; 112 = 'installed'; 128 = 'permanent' }
    if ($names.ContainsKey($n)) { return ('0x{0:x} ({1})' -f $n, $names[$n]) }
    return ('0x{0:x}' -f $n)
}

# This running Windows: its third-party driver packages, copied fresh. Choices are kept by package name.
function Step2Drivers {
    Say 'Inventory of this running Windows: its driver packages (copied fresh; a few minutes) ...'
    $old = @{}
    foreach ($d in (Read-DriverList)) { $old[$d.Name.ToLowerInvariant()] = $d.On }
    if (Test-Path -LiteralPath $drvDir) { Move-Old $drvDir }
    if (Test-Path -LiteralPath $drvList) { Move-Old $drvList }
    New-Item -ItemType Directory -Path $drvDir | Out-Null
    Invoke-Dism @('/English', '/Online', '/Export-Driver', "/Destination:$drvDir") | Out-Null
    $folders = @(Get-ChildItem -LiteralPath $drvDir -Directory | Sort-Object Name)
    if ($folders.Count -eq 0) { Stop-Run "DISM copied no driver package into $drvDir" }

    # The driver store, as DISM lists it: published name (oemNN.inf) -> original name, class, maker, version.
    $store = @{}; $cur = $null
    foreach ($l in (Invoke-Dism @('/English', '/Online', '/Get-Drivers', '/Format:List') -Quiet).Out) {
        $ln = [string]$l
        if ($ln -match '^\s*Published Name\s*:\s*(\S+)\s*$') { $cur = [pscustomobject]@{ Pub = $Matches[1].ToLowerInvariant(); Orig = ''; Class = ''; Maker = ''; Version = ''; Date = '' }; $store[$cur.Pub] = $cur }
        elseif ($null -ne $cur) {
            if ($ln -match '^\s*Original File Name\s*:\s*(.+?)\s*$') { $cur.Orig = $Matches[1].ToLowerInvariant() }
            elseif ($ln -match '^\s*Class Name\s*:\s*(.+?)\s*$') { $cur.Class = $Matches[1] }
            elseif ($ln -match '^\s*Provider Name\s*:\s*(.+?)\s*$') { $cur.Maker = $Matches[1] }
            elseif ($ln -match '^\s*Version\s*:\s*(.+?)\s*$') { $cur.Version = $Matches[1] }
            elseif ($ln -match '^\s*Date\s*:\s*(.+?)\s*$') { $cur.Date = $Matches[1] }
        }
    }
    # Which store folder belongs to which oemNN.inf: Windows' own driver database.
    $folderOf = @{}
    foreach ($pub in $store.Keys) {
        $q = Invoke-Reg @('query', "HKLM\SYSTEM\DriverDatabase\DriverInfFiles\$pub", '/ve')
        foreach ($l in $q.Out) {
            if (([string]$l) -match 'REG_MULTI_SZ\s+(.+)$') { foreach ($f in ($Matches[1] -split '\\0')) { if ($f) { $folderOf[$f.Trim().ToLowerInvariant()] = $pub } } }
        }
    }
    # The devices: which oemNN.inf each one uses now.
    $usedBy = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
        $inf = "$($p.InfName)".Trim().ToLowerInvariant()
        if ($inf -notmatch '^oem\d+\.inf$') { continue }
        $name = "$($p.DeviceName)".Trim(); if (-not $name) { $name = "$($p.DeviceID)".Trim() }
        if (-not $usedBy.ContainsKey($inf)) { $usedBy[$inf] = @() }
        if ($usedBy[$inf] -notcontains $name) { $usedBy[$inf] += $name }
    }

    $text = @(
        '# drivers-list.txt - the driver packages of this PC (WHD-ImageMenu.ps1, step 2). PRIVATE: it names this PC''s hardware.',
        ('# Written {0}. One line "driver:<folder> on|off"; the comment above it: class | maker | version | size | name | why.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        '# ON: a device uses it now, or class Extension. OFF: class SoftwareComponent (maker apps arrive through these), or no device uses it.',
        '# "kept: your choice" = the same package was in the list before; its on/off was carried over.',
        '')
    $onCount = 0; $keptCount = 0
    foreach ($f in $folders) {
        $bytes = [double]0
        $files = @(Get-ChildItem -LiteralPath $f.FullName -Recurse -File -Force)
        foreach ($x in $files) { $bytes += $x.Length }
        $hasInf = (@($files | Where-Object { $_.Name -like '*.inf' }).Count -gt 0)
        $pub = ''
        if ($folderOf.ContainsKey($f.Name.ToLowerInvariant())) { $pub = $folderOf[$f.Name.ToLowerInvariant()] }
        else {
            # Fallback: the folder name starts with the original .inf name; used when exactly one package has it.
            $origName = ($f.Name -split '_')[0].ToLowerInvariant()
            $m = @($store.Values | Where-Object { $_.Orig -eq $origName })
            if ($m.Count -eq 1) { $pub = $m[0].Pub }
        }
        $dsi = $null; if ($pub -and $store.ContainsKey($pub)) { $dsi = $store[$pub] }
        $devices = @(); if ($pub -and $usedBy.ContainsKey($pub)) { $devices = $usedBy[$pub] }
        if (-not $hasInf) { $on = $false; $why = 'OFF: no .inf file' }
        elseif ($null -eq $dsi) { $on = $true; $why = 'ON: no details from Windows, kept to be safe' }
        elseif ($dsi.Class -ieq 'SoftwareComponent') { $on = $false; $why = 'OFF: software component' }
        elseif ($devices.Count -gt 0) { $on = $true; $why = 'ON: in use' }
        elseif ($dsi.Class -ieq 'Extension') { $on = $true; $why = 'ON: extension' }
        else { $on = $false; $why = 'OFF: no device uses it now' }
        if ($hasInf -and $old.ContainsKey($f.Name.ToLowerInvariant())) {
            $was = $old[$f.Name.ToLowerInvariant()]
            if ($was -ne $on) { $why = "kept: your choice ($(if ($was) { 'on' } else { 'off' })); the rule says $why" } else { $why = "kept: your choice; $why" }
            $on = $was; $keptCount++
        }
        $cls = if ($dsi) { $dsi.Class } else { '(not known)' }; $mk = if ($dsi) { $dsi.Maker } else { '(not known)' }
        $ver = if ($dsi) { "$($dsi.Version) ($($dsi.Date))" } else { '' }
        $text += ('# {0} | {1} | {2} | {3} | {4} | {5}' -f $cls, $mk, $ver, (Fmt $bytes), $pub, $why)
        if ($devices.Count -gt 0) {
            $shown = @($devices | Select-Object -First 4) -join '; '
            if ($devices.Count -gt 4) { $shown += (' (+{0} more)' -f ($devices.Count - 4)) }
            $text += "#     used by: $shown"
        }
        $text += ('driver:{0} {1}' -f $f.Name, $(if ($on) { 'on' } else { 'off' }))
        $text += ''
        if ($on) { $onCount++ }
    }
    Write-Lines $drvList $text
    Say ("    {0} driver package(s) copied; {1} on, {2} off; {3} choice(s) carried over from the list before." -f $folders.Count, $onCount, ($folders.Count - $onCount), $keptCount)
}

# ===================================================================================================
# step 3 - choose
# ===================================================================================================
function Step3 {
    if (-not $S.Steps[2]) { Stop-Run 'run the inventory first (step 2): the choices are made from what the image holds' }
    $inv = $S.Inv
    while ($true) {
        Write-Host ''
        Write-Host '=== Step 3 - choose ==='
        Write-Host '  1  Bundled apps to remove                 (remove-list.txt)'
        Write-Host '  2  Optional features to switch off        (remove-list.txt)'
        Write-Host '  3  Capabilities to remove                 (remove-list.txt)'
        Write-Host '  4  Settings groups and parts              (image-settings.txt)'
        Write-Host '  5  Drivers of this PC                     (drivers-list.txt)'
        Write-Host '  6  First sign-in parts                    (first-signin\first-signin-list.txt)'
        Write-Host '  7  AI system packages: block + remove     (ai-list.txt)'
        Write-Host '  B  back to the main menu'
        $c = Ask 'Choice'
        switch -Regex ($c) {
            '^1$' { Choose-Presence 'Bundled apps' 'remove' 'app:' @($inv.Apps.Keys) { param($k) $inv.Apps[$k] } }
            '^2$' {
                $keys = @($inv.Features.Keys | Where-Object { $inv.Features[$_] -eq 'Enabled' })
                Choose-Presence 'Optional features (enabled in the image)' 'switch off' 'feature:' $keys { param($k) '' }
            }
            '^3$' {
                $keys = @($inv.Caps.Keys | Where-Object { $inv.Caps[$_] -eq 'Installed' })
                Choose-Presence 'Capabilities (installed in the image)' 'remove' 'capability:' $keys { param($k) '' }
            }
            '^4$' { Choose-OnOff 'Settings groups and parts' 'on' $setFile '^(part|group):([a-z0-9-]+)\s+(on|off)$' }
            '^5$' { Choose-OnOff 'Drivers of this PC' 'goes into the image' $drvList '^(driver):([A-Za-z0-9._-]+)\s+(on|off)$' }
            '^6$' { Choose-OnOff 'First sign-in parts' 'runs at the first sign-in' $fsList '^(part):([a-z-]+)\s+(on|off)$' }
            '^7$' { Choose-OnOff 'AI system packages' 'block + remove (unsupported)' $aiFile '^(ai):([A-Za-z0-9.\-]+_[a-z0-9]{13})\s+(on|off)$' }
            '^(b|B)$' { $S.Steps[3] = $true; return }
            default { Write-Host '  (not understood)' }
        }
    }
}

# Items that are "in the list or not" (remove-list.txt).
function Choose-Presence([string]$Title, [string]$OnMeans, [string]$Prefix, [string[]]$Keys, [scriptblock]$InfoOf) {
    $listed = @()
    foreach ($raw in (Read-Lines $listFile)) {
        $t = ([string]$raw).Trim()
        if ($t.StartsWith($Prefix)) { $listed += $t.Substring($Prefix.Length) }
    }
    $items = @()
    foreach ($k in $Keys) { $items += [pscustomobject]@{ Key = $k; Label = $k; Info = (& $InfoOf $k); On = ($listed -contains $k) } }
    foreach ($k in $listed) { if ($Keys -notcontains $k) { $items += [pscustomobject]@{ Key = $k; Label = $k; Info = '(listed, not in this image)'; On = $true } } }
    if ($items.Count -eq 0) { Write-Host '  (nothing to choose here)'; return }
    $res = Show-Toggle $Title $OnMeans $items
    if ($null -eq $res) { Write-Host '  back - nothing saved'; return }
    $n = 0
    foreach ($r in $res) {
        if ($r.On -eq $r.Was) { continue }
        Backup-ListOnce $listFile
        Set-PresenceLine $listFile ($Prefix + $r.Key) $r.On
        $n++
    }
    Say ("    remove-list.txt: {0} change(s) saved ({1})" -f $n, $Title)
}

# Items that are "<prefix>:<name> on|off" lines in a file.
function Choose-OnOff([string]$Title, [string]$OnMeans, [string]$File, [string]$Rx) {
    if (-not (Test-Path -LiteralPath $File)) { Write-Host "  $File is not there"; return }
    $lines = Read-Lines $File
    $items = @(); $prev = ''
    foreach ($raw in $lines) {
        $t = ([string]$raw).Trim()
        if ($t -match $Rx) { $items += [pscustomobject]@{ Key = "$($Matches[1]):$($Matches[2])"; Label = "$($Matches[1]):$($Matches[2])"; Info = $prev; On = ($Matches[3] -eq 'on') } }
        if ($t.StartsWith('#')) { $prev = $t.TrimStart('#').Trim(); if ($prev.Length -gt 70) { $prev = $prev.Substring(0, 70) + '...' } }
        elseif ($t) { $prev = '' }
    }
    if ($items.Count -eq 0) { Write-Host '  (nothing to choose here)'; return }
    $res = Show-Toggle $Title $OnMeans $items
    if ($null -eq $res) { Write-Host '  back - nothing saved'; return }
    $n = 0
    foreach ($r in $res) {
        if ($r.On -eq $r.Was) { continue }
        Backup-ListOnce $File
        $p = $r.Key.Split(':', 2)
        if (Set-OnOffLine $File ($p[0] + ':') $p[1] $r.On) { $n++ }
    }
    Say ("    {0}: {1} change(s) saved" -f (Split-Path -Leaf $File), $n)
}

# ===================================================================================================
# step 4 - apply the choices to the open image
# ===================================================================================================
function Step4 {
    if (-not $S.Mounted) { Stop-Run 'open an image first (step 1)' }
    $plan = Read-Lists
    $drivers = @((Read-DriverList) | Where-Object { $_.On })
    foreach ($d in $drivers) {
        if (-not (Test-Path -LiteralPath $d.Dir -PathType Container)) { Stop-Run "drivers-list.txt switches on '$($d.Name)', but its folder is not in 'drivers'. Run step 2 again, or switch it off" }
    }
    if ($plan.PartFirstSignIn) {
        foreach ($need in @($fsScript, $fsList, $fsAnswer)) { if (-not (Test-Path -LiteralPath $need -PathType Leaf)) { Stop-Run "part first-signin is on, but $need is missing" } }
        try { $null = [xml](Get-Content -LiteralPath $fsAnswer -Raw) } catch { Stop-Run "$fsAnswer is not readable XML" }
        Sync-AiBlockLines
        $chk = Invoke-Program 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fsScript, '-CheckList', '-ListFile', $fsList)
        foreach ($l in $chk.Out) { if (([string]$l).Trim()) { Say ('first-signin-list.txt: ' + ([string]$l).Trim()) } }
        if ($chk.Code -ne 0) { Stop-Run 'the first sign-in script did not accept first-signin-list.txt (line above). Nothing was changed' }
    }
    Say ("Applying: {0} app(s), {1} feature(s), {2} capability(ies), {3} driver package(s), {4} service(s), {5} registry value(s)" -f $plan.Apps.Count, $plan.Features.Count, $plan.Capabilities.Count, $drivers.Count, $plan.Services.Count, $plan.RegOps.Count)
    $m = $S.Mount

    # apps
    if ($plan.Apps.Count -gt 0) {
        $map = @{}; $disp = ''
        foreach ($l in (Invoke-Dism @('/English', "/Image:$m", '/Get-ProvisionedAppxPackages') -Quiet).Out) {
            $ln = [string]$l
            if ($ln -match '^\s*DisplayName\s*:\s*(.+?)\s*$') { $disp = $Matches[1] }
            elseif ($ln -match '^\s*PackageName\s*:\s*(.+?)\s*$') { if ($disp) { $map[$disp] = $Matches[1] }; $disp = '' }
        }
        foreach ($a in $plan.Apps) {
            if (-not $map.ContainsKey($a)) { Add-Skipped "app $a (not in the image)"; continue }
            $r = Invoke-Dism @("/Image:$m", '/Remove-ProvisionedAppxPackage', "/PackageName:$($map[$a])") -AllowFail -Quiet
            if ($r.Code -eq 0) {
                Add-Done "app $a removed"
                $fam = Get-FamilyName $map[$a]
                if ($fam) { $S.Families += $fam }
            } else { Add-Failed "app $a (DISM code $($r.Code))" }
        }
    }
    # features
    foreach ($f in $plan.Features) {
        $r = Invoke-Dism @('/English', "/Image:$m", '/Get-FeatureInfo', "/FeatureName:$f") -AllowFail -Quiet
        $state = ''; foreach ($l in $r.Out) { if (([string]$l) -match '^\s*State\s*:\s*(.+?)\s*$') { $state = $Matches[1] } }
        if (-not $state) { Add-Skipped "feature $f (not in the image)"; continue }
        if ($state -ne 'Enabled') { Add-Skipped "feature $f (state: $state)"; continue }
        $r = Invoke-Dism @("/Image:$m", '/Disable-Feature', "/FeatureName:$f") -AllowFail -Quiet
        if ($r.Code -eq 0) { Add-Done "feature $f switched off" } else { Add-Failed "feature $f (DISM code $($r.Code))" }
    }
    # capabilities
    foreach ($c in $plan.Capabilities) {
        $r = Invoke-Dism @('/English', "/Image:$m", '/Get-CapabilityInfo', "/CapabilityName:$c") -AllowFail -Quiet
        $state = ''; foreach ($l in $r.Out) { if (([string]$l) -match '^\s*State\s*:\s*(.+?)\s*$') { $state = $Matches[1] } }
        if (-not $state) { Add-Skipped "capability $c (not known to the image)"; continue }
        if ($state -ne 'Installed') { Add-Skipped "capability $c (state: $state)"; continue }
        $r = Invoke-Dism @("/Image:$m", '/Remove-Capability', "/CapabilityName:$c") -AllowFail -Quiet
        if ($r.Code -eq 0) { Add-Done "capability $c removed" } else { Add-Failed "capability $c (DISM code $($r.Code))" }
    }
    # drivers
    if ($drivers.Count -gt 0) {
        Say ("Adding {0} driver package(s) (one after the other) ..." -f $drivers.Count)
        $i = 0
        foreach ($d in $drivers) {
            $i++
            $r = Invoke-Dism @('/English', "/Image:$m", '/Add-Driver', "/Driver:$($d.Dir)", '/Recurse') -AllowFail -Quiet
            $added = @($r.Out | Where-Object { ([string]$_) -match 'successfully installed' }).Count
            if (($r.Code -eq 0) -and ($added -gt 0)) { Add-Done "driver $($d.Name)" }
            elseif ($r.Code -eq 0) { Add-Failed "driver $($d.Name) (DISM found nothing it could add)" }
            else { Add-Failed "driver $($d.Name) (DISM code $($r.Code))" }
            if (($i % 20) -eq 0) { Say "        $i of $($drivers.Count)" }
        }
    }
    # registry: services, values, marks
    if (($plan.Services.Count + $plan.RegOps.Count + $S.Families.Count) -gt 0) {
        Use-ImageRegistry -System {
            param($cs)
            foreach ($svc in $plan.Services) {
                $key = "HKLM\$hiveSys\$cs\Services\$($svc.Name)"
                $from = if ($svc.Group -eq 'remove-list') { '' } else { " [$($svc.Group)]" }
                $have = Get-RegValue $key 'Start'
                if ((-not $have.Exists) -or ($have.Data -notmatch '^0x([0-9A-Fa-f]+)$')) { Add-Skipped "service $($svc.Name) (not in the image)$from"; continue }
                $was = [Convert]::ToInt32($Matches[1], 16)
                if ($was -eq 4) { Add-Skipped "service $($svc.Name) (was already disabled)$from"; continue }
                $w = Invoke-Reg @('add', $key, '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
                if (($w.Code -eq 0) -and (Test-RegSame (Get-RegValue $key 'Start') 'dword' '4')) { Add-Done "service $($svc.Name) disabled (Start was $was)$from" }
                else { Add-Failed "service $($svc.Name) (registry write failed)$from" }
            }
            foreach ($op in $plan.RegOps) {
                if ($op.Hive -eq 'SYSTEM') { $key = "HKLM\$hiveSys\$cs\$($op.Key)"; $show = "SYSTEM\$($op.Key)" }
                else { $key = "HKLM\$hiveSw\$($op.Key)"; $show = "SOFTWARE\$($op.Key)" }
                $text = "value $show : $($op.Name) = $($op.Data) [$($op.Group)]"
                $have = Get-RegValue $key $op.Name
                if (Test-RegSame $have $op.Type $op.Data) { Add-Skipped "$text (was already set)"; continue }
                $rt = if ($op.Type -eq 'dword') { 'REG_DWORD' } else { 'REG_SZ' }
                $w = Invoke-Reg @('add', $key, '/v', $op.Name, '/t', $rt, '/d', $op.Data, '/f')
                if (($w.Code -eq 0) -and (Test-RegSame (Get-RegValue $key $op.Name) $op.Type $op.Data)) { Add-Done "$text (was: $(Get-RegText $have))" }
                else { Add-Failed "$text (registry write failed)" }
            }
            if ($plan.PartMarks) {
                foreach ($fam in @($S.Families | Select-Object -Unique)) { Add-DeprovisionedMark $fam }
            }
        }
    }
    # first sign-in files
    if ($plan.PartFirstSignIn) { Copy-FirstSignIn }
    $S.Steps[4] = $true
    Say ("RESULT: step 4 DONE - so far this session: {0} done, {1} skipped, {2} failed. Nothing is saved until step 6." -f $S.Done.Count, $S.Skipped.Count, $S.Failed.Count)
}

function Add-DeprovisionedMark([string]$Fam) {
    $key = "HKLM\$hiveSw\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$Fam"
    if ((Invoke-Reg @('query', $key)).Code -eq 0) { Add-Skipped "mark $Fam (was already there)"; return }
    $w = Invoke-Reg @('add', $key, '/f')
    if (($w.Code -eq 0) -and ((Invoke-Reg @('query', $key)).Code -eq 0)) { Add-Done "mark $Fam (deprovisioned: do not bring back)" }
    else { Add-Failed "mark $Fam (registry write failed)" }
}

function Copy-FirstSignIn {
    $dir = Join-Path $S.Mount $imageScriptsDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $ok = 0
    foreach ($f in @($fsScript, $fsList)) {
        $dest = Join-Path $dir (Split-Path -Leaf $f)
        Copy-Item -LiteralPath $f -Destination $dest -Force
        if ((Get-Sha $f) -eq (Get-Sha $dest)) { $ok++ } else { Add-Failed "first sign-in file $(Split-Path -Leaf $f) (the copy differs)" }
    }
    if ($ok -eq 2) { Add-Done "first sign-in script and list copied into the image ($imageScriptsDir)" }
    $ans = Join-Path $S.Mount $imageAnswer
    if (Test-Path -LiteralPath $ans -PathType Leaf) {
        if ((Get-Sha $ans) -eq (Get-Sha $fsAnswer)) { Add-Skipped "answer file (already ours)" }
        else { Add-Failed 'answer file: the image has its own Windows\Panther\unattend.xml; not replaced (start the first sign-in script by hand)' }
    } else {
        $ad = Split-Path -Parent $ans
        if (-not (Test-Path -LiteralPath $ad)) { New-Item -ItemType Directory -Path $ad | Out-Null }
        Copy-Item -LiteralPath $fsAnswer -Destination $ans -Force
        if ((Get-Sha $ans) -eq (Get-Sha $fsAnswer)) { Add-Done 'answer file put into the image: Setup starts the first sign-in script once' }
        else { Add-Failed 'answer file (the copy differs)' }
    }
}

# first-signin-list.txt gets one "ai-block:<family>" line per AI package that is on in ai-list.txt
# (the first sign-in recheck). The lines are written below a mark line; older ai-block lines are replaced.
function Sync-AiBlockLines {
    if (-not (Test-Path -LiteralPath $fsList)) { return }
    $want = @((Read-AiList) | Where-Object { $_.On } | ForEach-Object { $_.Family })
    $lines = Read-Lines $fsList
    $mark = '# --- AI system packages to recheck (written by WHD-ImageMenu from ai-list.txt) ---'
    $keep = @(); $had = @()
    foreach ($l in $lines) {
        $t = ([string]$l).Trim()
        if ($t -match '^ai-block:(.+)$') { $had += $Matches[1].Trim(); continue }
        if ($t -eq $mark) { continue }
        $keep += $l
    }
    if ((($had | Sort-Object) -join ',') -eq (($want | Sort-Object) -join ',') -and ($lines -contains $mark -or $want.Count -eq 0)) { return }
    while (($keep.Count -gt 0) -and (-not ([string]$keep[-1]).Trim())) { $keep = @($keep | Select-Object -SkipLast 1) }
    Backup-ListOnce $fsList
    if ($want.Count -gt 0) {
        $keep += ''
        $keep += $mark
        foreach ($w in $want) { $keep += "ai-block:$w" }
    }
    Write-Lines $fsList $keep
    Say ("    first-signin-list.txt: {0} ai-block line(s) written" -f $want.Count)
}

# ===================================================================================================
# step 5 - AI system packages: block and remove
# ===================================================================================================
function Step5 {
    if (-not $S.Mounted) { Stop-Run 'open an image first (step 1)' }
    if (-not $S.Steps[2]) { Stop-Run 'run the inventory first (step 2)' }
    $chosen = @((Read-AiList) | Where-Object { $_.On })
    if ($chosen.Count -eq 0) { Say 'ai-list.txt switches no AI package on. Nothing to do.'; return }
    $targets = @()
    foreach ($c in $chosen) {
        $a = @($S.Inv.Ai | Where-Object { $_.Family -ieq $c.Family })
        if ($a.Count -eq 0) { Add-Skipped "AI package $($c.Family) (not in this image)"; continue }
        $targets += $a[0]
    }
    if ($targets.Count -eq 0) { return }
    Write-Host ''
    Write-Host 'NOT SUPPORTED BY MICROSOFT. On the installed PC: a health check (DISM /ScanHealth, SFC) can report the'
    Write-Host 'missing files, a repair or a cumulative update can bring them back or fail. WinSxS is not touched.'
    Write-Host 'AppLocker on Windows 11 Home: the rules were taken in on the first test install (one PC).'
    foreach ($t in $targets) { Write-Host ("    {0}  ({1} files, {2})" -f $t.Rel, $t.Files, (Fmt $t.Bytes)) }
    if (-not (Confirm-Yes ("Block and remove these {0} package(s) in the open image?" -f $targets.Count))) { Say 'Step 5: not confirmed, nothing changed.'; return }

    $regDir = Join-Path $S.Work "ai-removed_$stamp"
    if (-not (Test-Path -LiteralPath $regDir)) { New-Item -ItemType Directory -Path $regDir | Out-Null }
    Use-ImageRegistry -System {
        param($cs)
        $store = "HKLM\$hiveSw\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"
        foreach ($t in $targets) {
            Say "AI package $($t.Family):"
            # 1. block: the deprovisioned mark
            Add-DeprovisionedMark $t.Family
            # 2. block: AppLocker deny rule (needs the publisher from the package's manifest)
            if ($t.Name -and $t.Publisher) { Add-AppxDenyRule $t.Name $t.Publisher }
            else { Add-Skipped "AppLocker rule for $($t.Family) (no AppxManifest.xml in its folder, so no publisher to name in a rule)" }
            # 3. remove: its app entries (saved to a .reg file first)
            $keys = @()
            foreach ($full in $t.Inbox) { $keys += "$store\InboxApplications\$full" }
            if ($t.Config)  { $keys += "$store\Config\$($t.Family)" }
            if ($t.Updated) { $keys += "$store\UpdatedApplications\$($t.Family)" }
            if ($keys.Count -eq 0) { Add-Skipped "app entries of $($t.Family) (none in the image)" }
            $n = 0
            foreach ($k in $keys) {
                $n++
                $file = Join-Path $regDir ('{0}_{1}.reg' -f $t.Family, $n)
                $e = Invoke-Reg @('export', $k, $file, '/y')
                if ($e.Code -ne 0) { Add-Failed "app entry $k (could not be saved first, so it was not deleted)"; continue }
                $d = Invoke-Reg @('delete', $k, '/f')
                if (($d.Code -eq 0) -and ((Invoke-Reg @('query', $k)).Code -ne 0)) { Add-Done "app entry deleted: $($k -replace [regex]::Escape("HKLM\$hiveSw"), 'SOFTWARE') (saved in $(Split-Path -Leaf $regDir))" }
                else { Add-Failed "app entry $k (delete failed)" }
            }
        }
        # AppLocker is enforced only while the Application Identity service runs.
        if (@($S.Done | Where-Object { $_ -like 'AppLocker deny rule*' }).Count -gt 0) { Set-AppLockerOn $cs }
    }
    # 4. remove: the folders
    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { Add-Skipped "folder $($t.Rel) (already gone)"; continue }
        $r1 = Invoke-Program 'takeown.exe' @('/f', $t.Path, '/r', '/d', 'Y')
        $r2 = Invoke-Program 'icacls.exe' @($t.Path, '/grant', '*S-1-5-32-544:F', '/t', '/c', '/q')
        try { Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop } catch { }
        if (-not (Test-Path -LiteralPath $t.Path)) { Add-Done "folder removed: $($t.Rel) ($($t.Files) files, $(Fmt $t.Bytes))" }
        else { Add-Failed ("folder {0} (could not be removed; takeown code {1}, icacls code {2})" -f $t.Rel, $r1.Code, $r2.Code) }
    }
    # 5. the first sign-in recheck list, also inside the image when it is already there
    Sync-AiBlockLines
    $inImage = Join-Path $S.Mount "$imageScriptsDir\first-signin-list.txt"
    if (Test-Path -LiteralPath $inImage) {
        Copy-Item -LiteralPath $fsList -Destination $inImage -Force
        if ((Get-Sha $fsList) -eq (Get-Sha $inImage)) { Add-Done 'first-signin-list.txt in the image updated (ai-block lines)' }
    } else { Say '    NOTE: the first sign-in files are not in the image yet: step 4 puts them there with the ai-block lines.' }
    $S.Steps[5] = $true
    Say ("RESULT: step 5 DONE - the app entries are saved in {0}. Nothing is saved into the image until step 6." -f $regDir)
}

# One AppLocker deny rule for a packaged app (all versions), written as a local policy into the image.
# The allow-all rule for packaged apps is added with it - without an allow rule no packaged app could run.
function Add-AppxDenyRule([string]$Name, [string]$Publisher) {
    $base = "HKLM\$hiveSw\$appxPolicyKey"
    # Rules already there: ours are recognised by their name text.
    $others = 0; $haveAllow = $false; $haveThis = $false
    foreach ($sub in (Get-SubKeys $base)) {
        $v = Get-RegValue "$base\$sub" 'Value'
        if ($sub -ieq "{$allowAllId}") { $haveAllow = $true; continue }
        if ($v.Data -match ('ProductName="' + [regex]::Escape($Name) + '"') -and ($v.Data -match 'Action="Deny"')) { $haveThis = $true; continue }
        if ($v.Data -notmatch 'Name="WHD-ImageMenu ') { $others++ }
    }
    if ($others -gt 0) { Add-Failed "AppLocker rule for $Name (the image already has $others packaged-app rule(s) of its own; not mixed)"; return }
    if (-not $haveAllow) {
        $xml = '<FilePublisherRule Id="{0}" Name="WHD-ImageMenu (all signed packaged apps)" Description="Allows every signed packaged app; the deny rules next to it win over it." UserOrGroupSid="S-1-1-0" Action="Allow"><Conditions><FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*"><BinaryVersionRange LowSection="0.0.0.0" HighSection="*" /></FilePublisherCondition></Conditions></FilePublisherRule>' -f $allowAllId
        $w = Invoke-Reg @('add', "$base\{$allowAllId}", '/v', 'Value', '/t', 'REG_SZ', '/d', $xml, '/f')
        if ($w.Code -eq 0) { Add-Done 'AppLocker allow rule: all signed packaged apps (so that only the deny rules block)' } else { Add-Failed 'AppLocker allow rule (registry write failed)'; return }
    }
    if ($haveThis) { Add-Skipped "AppLocker deny rule for $Name (was already there)"; return }
    if ($Publisher -match '["<>&]') { Add-Failed "AppLocker rule for $Name (the publisher text has a character that cannot go into the rule)"; return }
    $id = [guid]::NewGuid().ToString()
    $xml = '<FilePublisherRule Id="{0}" Name="WHD-ImageMenu deny {1}" Description="Blocks the AI system package {1} (all versions)." UserOrGroupSid="S-1-1-0" Action="Deny"><Conditions><FilePublisherCondition PublisherName="{2}" ProductName="{1}" BinaryName="*"><BinaryVersionRange LowSection="0.0.0.0" HighSection="*" /></FilePublisherCondition></Conditions></FilePublisherRule>' -f $id, $Name, $Publisher
    $w = Invoke-Reg @('add', "$base\{$id}", '/v', 'Value', '/t', 'REG_SZ', '/d', $xml, '/f')
    if ($w.Code -eq 0) { Add-Done "AppLocker deny rule for $Name" } else { Add-Failed "AppLocker deny rule for $Name (registry write failed)" }
}

function Set-AppLockerOn([string]$Cs) {
    $base = "HKLM\$hiveSw\$appxPolicyKey"
    $have = Get-RegValue $base 'EnforcementMode'
    if (Test-RegSame $have 'dword' '1') { Add-Skipped 'AppLocker packaged-app rules: enforced (was already set)' }
    else {
        $w = Invoke-Reg @('add', $base, '/v', 'EnforcementMode', '/t', 'REG_DWORD', '/d', '1', '/f')
        if ($w.Code -eq 0) { Add-Done 'AppLocker packaged-app rules: enforced (EnforcementMode 1)' } else { Add-Failed 'AppLocker EnforcementMode (registry write failed)' }
    }
    $key = "HKLM\$hiveSys\$Cs\Services\AppIDSvc"
    $st = Get-RegValue $key 'Start'
    if (-not $st.Exists) { Add-Failed 'Application Identity service (AppIDSvc) is not in the image: AppLocker rules cannot be enforced'; return }
    if (Test-RegSame $st 'dword' '2') { Add-Skipped 'Application Identity service: automatic (was already set)'; return }
    $w = Invoke-Reg @('add', $key, '/v', 'Start', '/t', 'REG_DWORD', '/d', '2', '/f')
    if ($w.Code -eq 0) { Add-Done "Application Identity service (AppIDSvc) set to start automatically (was $(Get-RegText $st)) - AppLocker needs it" }
    else { Add-Failed 'Application Identity service start (registry write failed)' }
}

# ===================================================================================================
# step 6 - save
# ===================================================================================================
function Step6 {
    if (-not $S.Mounted) { Stop-Run 'no image is open (step 1)' }
    if ((-not $S.Steps[4]) -and (-not $S.Steps[5])) {
        if (-not (Confirm-Yes 'Neither step 4 nor step 5 ran this session. Save the image unchanged?')) { return }
    }
    $dir = Join-Path $S.Mount $imageScriptsDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $rec = @(
        'WHD Imaging Helper - what was changed in this Windows image before it was installed.',
        ('Written by WHD-ImageMenu.ps1 on {0}. Source: {1} (SHA-256 {2}).' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $S.SourceText, $S.SourceSha),
        'WHD Classic and WHD Next do not know about these changes: their Undo and Verify do not cover them.',
        '')
    foreach ($x in $S.Done) { $rec += "done:    $x" }
    foreach ($x in $S.Skipped) { $rec += "skipped: $x" }
    foreach ($x in $S.Failed) { $rec += "FAILED:  $x" }
    Write-Lines (Join-Path $dir 'WHD-Image-applied.txt') $rec
    Say 'Saving the image (several minutes) ...'
    Invoke-Dism @('/Unmount-Image', "/MountDir:$($S.Mount)", '/Commit') | Out-Null
    $S.Mounted = $false
    if (-not (Test-HomeOnly $S.NewWim)) { Stop-Run "install-custom.wim does not read as a single '$HomeName' image after saving" }
    Say ("install-custom.wim saved: {0}, one image: {1}" -f (Fmt (Get-Item -LiteralPath $S.NewWim).Length), $HomeName)
    if (Test-Path -LiteralPath $S.NewDir) { Move-Old $S.NewDir }
    New-Item -ItemType Directory -Path $S.NewDir | Out-Null
    Invoke-Dism @('/Split-Image', "/ImageFile:$($S.NewWim)", "/SWMFile:$(Join-Path $S.NewDir 'install.swm')", '/FileSize:3800') | Out-Null
    $pieces = @(Get-ChildItem -LiteralPath $S.NewDir -File | Where-Object { $_.Name -match '^install\d*\.swm$' } | Sort-Object Name)
    if ($pieces.Count -eq 0) { Stop-Run 'no pieces were written to usb-custom' }
    foreach ($f in $pieces) { if ($f.Length -ge 4GB) { Stop-Run "$($f.Name) is 4 GB or larger" }; Say ("    piece {0}: {1}" -f $f.Name, (Fmt $f.Length)) }
    if (-not (Test-HomeOnly (Join-Path $S.NewDir 'install.swm'))) { Stop-Run "the pieces are not a single '$HomeName' image" }
    $S.Pieces = $pieces
    $S.Steps[6] = $true
    Say ("RESULT: step 6 DONE - saved and split ({0} piece(s) in usb-custom). Session: {1} done, {2} skipped, {3} failed." -f $pieces.Count, $S.Done.Count, $S.Skipped.Count, $S.Failed.Count)
}

# ===================================================================================================
# step 7 - make the stick
# ===================================================================================================
function Get-StickInfo([string]$Letter) {
    $part = $null
    try { $part = Get-Partition -DriveLetter $Letter -ErrorAction Stop } catch { $part = $null }
    if ($null -eq $part) { Stop-Run "drive ${Letter}: was not found" }
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    $vol  = Get-Volume -DriveLetter $Letter -ErrorAction Stop
    $letters = @()
    foreach ($p in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) { $l = Get-LetterText $p.DriveLetter; if ($l) { $letters += $l } }
    return [pscustomobject]@{
        Number = [int]$disk.Number; Name = "$($disk.FriendlyName)".Trim(); Bus = "$($disk.BusType)"; Size = [double]$disk.Size
        Serial = "$($disk.SerialNumber)".Trim(); UniqueId = "$($disk.UniqueId)".Trim(); IsBoot = [bool]$disk.IsBoot; IsSystem = [bool]$disk.IsSystem
        DriveType = "$($vol.DriveType)"; Label = "$($vol.FileSystemLabel)"; FileSystem = "$($vol.FileSystem)"; Letters = $letters
    }
}

function Test-StickRules($Stick, [string]$Letter, [string[]]$Avoid) {
    if ($Stick.Bus -ne 'USB') { Stop-Run "drive ${Letter}: is connected by $($Stick.Bus), not USB. Refused" }
    if ($Stick.DriveType -ne 'Removable') { Stop-Run "drive ${Letter}: is not a removable drive ('$($Stick.DriveType)'). External hard drives and SSDs are refused" }
    if ($Stick.IsBoot -or $Stick.IsSystem) { Stop-Run "drive ${Letter}: is on the disk Windows starts from. Refused" }
    if ($Stick.Size -gt $maxStickBytes) { Stop-Run ("drive {0}: is on a disk of {1}; larger than {2} is refused" -f $Letter, (Fmt $Stick.Size), (Fmt $maxStickBytes)) }
    if ($Stick.Size -lt 7.5GB) { Stop-Run ("drive {0}: is on a disk of {1}; an install stick needs 8 GB or more" -f $Letter, (Fmt $Stick.Size)) }
    foreach ($a in $Avoid) { if ($a -and ($Stick.Letters -contains $a.ToUpperInvariant())) { Stop-Run "drive ${a}: is on the same disk as ${Letter}:; Windows, the work folder and the setup source must be on another disk" } }
}

function Step7 {
    if (-not $S.Steps[6]) { Stop-Run 'save the image first (step 6)' }
    if ($S.Mounted) { Stop-Run 'an image is open; save it first (step 6)' }
    # the setup files
    $setupRoot = ''
    if ($S.SetupFrom -eq 'iso') {
        if (-not $S.IsoPath) { Stop-Run 'the ISO file is not open any more' }
        if (-not (Get-DiskImage -ImagePath $S.IsoPath).Attached) { Open-Iso $S.IsoPath }
        $setupRoot = "$(Get-IsoLetter $S.IsoPath):\"
    } elseif ($S.SetupFrom -eq 'folder') {
        $setupRoot = (Join-Path $S.Work 'setup-files') + '\'
    } else {
        $p = (Ask 'The setup files come from an ISO file. Full path of the Windows ISO file').Trim('"')
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-Run "not found: $p" }
        Open-Iso (Get-Item -LiteralPath $p).FullName
        $S.SetupFrom = 'iso'
        $setupRoot = "$(Get-IsoLetter $S.IsoPath):\"
    }
    $items = Get-SetupFiles $setupRoot
    $setupBytes = [double]0
    foreach ($it in $items) { $setupBytes += $it.File.Length; if ($it.File.Length -ge 4GB) { Stop-Run "$($it.Rel) is 4 GB or larger and cannot go on FAT32" } }
    Say ("Setup files: {0} file(s), {1}, from {2}" -f $items.Count, (Fmt $setupBytes), $setupRoot)

    $letter = (Ask 'Letter of the stick to ERASE and make').TrimEnd(':').ToUpperInvariant()
    if ($letter -notmatch '^[A-Z]$') { Stop-Run 'that is not a drive letter' }
    $stick = Get-StickInfo $letter
    $avoid = @($S.Work.Substring(0, 1), $root.Substring(0, 1), $setupRoot.Substring(0, 1))
    if ($env:SystemDrive) { $avoid += $env:SystemDrive.Substring(0, 1) }
    Test-StickRules $stick $letter $avoid
    $partBytes = $stick.Size; if ($partBytes -gt 32GB) { $partBytes = $fatPartBytes }
    $pieceBytes = [double]0; foreach ($f in $S.Pieces) { $pieceBytes += $f.Length }
    if (($setupBytes + $pieceBytes + 100MB) -gt ($partBytes - 200MB)) { Stop-Run ("the stick is too small: {0} needed, {1} there" -f (Fmt ($setupBytes + $pieceBytes + 100MB)), (Fmt $partBytes)) }
    Write-Host ''
    Write-Host ("EVERYTHING ON THIS STICK WILL BE DELETED: {0}: = disk {1} '{2}', {3}, label '{4}'" -f $letter, $stick.Number, $stick.Name, (Fmt $stick.Size), $stick.Label)
    try { foreach ($t in @(Get-ChildItem -LiteralPath "${letter}:\" -Force -ErrorAction Stop | Select-Object -First 30)) { Write-Host "        $($t.Name)" } } catch { }
    $typed = Ask "To go on, type  ERASE $letter"
    if ($typed.ToUpperInvariant() -ne "ERASE $letter") { Say "Step 7: the erase was not confirmed (typed '$typed'). The stick was not changed."; return }
    Say "Confirmed: ERASE $letter."

    $now = Get-StickInfo $letter
    if (($now.Number -ne $stick.Number) -or ($now.UniqueId -ne $stick.UniqueId) -or ($now.Serial -ne $stick.Serial)) { Stop-Run "drive ${letter}: is not the stick you confirmed any more. Nothing on any stick was changed" }
    Say ("Erasing disk {0} ..." -f $stick.Number)
    Clear-Disk -Number $stick.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    $S.Steps[7] = $false
    if ("$((Get-Disk -Number $stick.Number).PartitionStyle)" -eq 'RAW') { Initialize-Disk -Number $stick.Number -PartitionStyle MBR -ErrorAction Stop }
    if ("$((Get-Disk -Number $stick.Number).PartitionStyle)" -ne 'MBR') { Stop-Run 'the erased stick is not MBR. Format it once by hand (FAT32) and run step 7 again' }
    if ($stick.Size -gt 32GB) { $np = New-Partition -DiskNumber $stick.Number -Size $fatPartBytes -IsActive -ErrorAction Stop }
    else { $np = New-Partition -DiskNumber $stick.Number -UseMaximumSize -IsActive -ErrorAction Stop }
    $pn = $np.PartitionNumber
    Say "Formatting FAT32, label $stickLabel ..."
    Format-Volume -Partition (Get-Partition -DiskNumber $stick.Number -PartitionNumber $pn -ErrorAction Stop) -FileSystem FAT32 -NewFileSystemLabel $stickLabel -Confirm:$false -ErrorAction Stop | Out-Null
    $cur = Get-LetterText (Get-Partition -DiskNumber $stick.Number -PartitionNumber $pn).DriveLetter
    if ($cur -ne $letter) {
        $ok = $false
        try { Set-Partition -DiskNumber $stick.Number -PartitionNumber $pn -NewDriveLetter $letter -ErrorAction Stop; $ok = $true } catch { }
        if (-not $ok) {
            if (-not $cur) { Add-PartitionAccessPath -DiskNumber $stick.Number -PartitionNumber $pn -AssignDriveLetter -ErrorAction Stop }
            $got = Get-LetterText (Get-Partition -DiskNumber $stick.Number -PartitionNumber $pn).DriveLetter
            if (-not $got) { Stop-Run 'the new partition got no drive letter' }
            Say "NOTE: the stick is now ${got}: (not ${letter}:)"
            $letter = $got
        }
    }
    for ($i = 0; $i -lt 10; $i++) { if (Test-Path -LiteralPath "${letter}:\") { break }; Start-Sleep -Seconds 1 }
    $stickRoot = "${letter}:\"
    Say ("Copying {0} setup file(s) to the stick, each compared ..." -f $items.Count)
    $n = 0
    foreach ($it in $items) {
        $null = Copy-CheckedTo $it.File (Join-Path $stickRoot $it.Rel); $n++
        if (($n % 200) -eq 0) { Say "        $n of $($items.Count)" }
    }
    $sums = @()
    foreach ($f in $S.Pieces) {
        Say ("Copying {0} ({1}) ..." -f $f.Name, (Fmt $f.Length))
        $h = Copy-CheckedTo $f (Join-Path $stickRoot "sources\$($f.Name)")
        $sums += ('piece: {0}|{1}|{2}' -f $f.Name, $f.Length, $h)
    }
    if (-not (Test-HomeOnly (Join-Path $stickRoot 'sources\install.swm'))) { Stop-Run "the image on the stick does not read as a single '$HomeName' image" }
    $mark = @(
        'WHD Imaging Helper - this stick holds the CHANGED Windows image made by WHD-ImageMenu.ps1.',
        ('Written {0}. Edition: {1}. Source: {2}. Changes done: {3}, skipped: {4}, failed: {5}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HomeName, $S.SourceText, $S.Done.Count, $S.Skipped.Count, $S.Failed.Count),
        'The scripts read this file to know what is on the stick. Windows Setup does not use it.',
        'What was changed is written inside the image: Windows\Setup\Scripts\WHD-Image-applied.txt.',
        '', '# piece: file name|bytes|SHA-256') + $sums
    Write-Lines (Join-Path $stickRoot $stickMarkName) $mark
    $S.Steps[7] = $true
    Say ("RESULT: step 7 DONE - stick {0}: holds the changed {1} image; every file compared by checksum." -f $letter, $HomeName)
    Say 'NOTE: at the first sign-in a PowerShell window works for several minutes. Leave it alone; it closes by itself.'
}

# ===================================================================================================
# the menu
# ===================================================================================================
function Show-Menu {
    $names = @{
        1 = 'Open image source (ISO / USB stick / install.wim kept)'
        2 = 'Inventory (image + this PC''s drivers)'
        3 = 'Choose (switch items on / off)'
        4 = 'Apply the choices to the open image'
        5 = 'AI packages: block + remove (unsupported)'
        6 = 'Save the image and split it'
        7 = 'Make the USB stick (ERASES it)'
    }
    Write-Host ''
    Write-Host '=================== WHD-ImageMenu - Home install stick ==================='
    $img = if ($S.Mounted) { "open ($($S.SourceText))" } else { 'not open' }
    Write-Host ("  image: {0}   work folder: {1}" -f $img, $S.Work)
    Write-Host ("  this session: {0} done, {1} skipped, {2} failed" -f $S.Done.Count, $S.Skipped.Count, $S.Failed.Count)
    foreach ($k in 1..7) {
        $st = if ($S.Steps[$k]) { 'done' } else { '    ' }
        Write-Host ('  {0}  [{1}]  {2}' -f $k, $st, $names[$k])
    }
    Write-Host '  L  show this session''s list of changes'
    Write-Host '  X  exit'
}

function Show-Changes {
    Write-Host ''
    foreach ($x in $S.Done) { Write-Host "  done:    $x" }
    foreach ($x in $S.Skipped) { Write-Host "  skipped: $x" }
    foreach ($x in $S.Failed) { Write-Host "  FAILED:  $x" }
    if (($S.Done.Count + $S.Skipped.Count + $S.Failed.Count) -eq 0) { Write-Host '  (nothing yet)' }
}

function Exit-Menu {
    if ($S.Mounted) {
        Write-Host ''
        Write-Host 'The image is still open and NOT saved.'
        Write-Host '  K  keep it open (the next start of the menu closes it WITHOUT saving)'
        Write-Host '  D  close it now WITHOUT saving'
        Write-Host '  C  cancel - back to the menu'
        $a = Ask 'Choice'
        if ($a -match '^(c|C)$' -or (-not $a)) { return $false }
        if ($a -match '^(d|D)$') { Close-Image -Discard }
        elseif ($a -match '^(k|K)$') { Say "The image is left open in $($S.Mount) (not saved)." }
        else { return $false }
    }
    Close-Iso
    return $true
}

# ---- main -----------------------------------------------------------------------------------------
$exitCode = 0
try {
    Say '=== WHD-ImageMenu started ==='
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { Stop-Run 'this window is not running as administrator' }
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Stop-Run "the work folder $WorkDir does not exist" }
        $S.Work = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd('\')
    }
    if ($S.Work -notmatch '^[A-Za-z]:\\.+') { Stop-Run "the work folder must be a folder on a drive with a letter (it is $($S.Work))" }
    $fmt = [string](New-Object System.IO.DriveInfo($S.Work.Substring(0, 1))).DriveFormat
    if ($fmt -ne 'NTFS') { Stop-Run "the work folder is on $fmt; DISM needs NTFS. Use -WorkDir with a folder on an NTFS drive" }
    $S.SrcWim = Join-Path $S.Work 'install.wim'; $S.SrcNote = Join-Path $S.Work 'install-source.txt'
    $S.NewWim = Join-Path $S.Work 'install-custom.wim'; $S.NewDir = Join-Path $S.Work 'usb-custom'
    Say ("PowerShell {0}; work folder {1}" -f $PSVersionTable.PSVersion, $S.Work)
    Start-Clean

    while ($true) {
        Show-Menu
        $c = Ask 'Step'
        try {
            switch -Regex ($c) {
                '^1$' { Step1 }
                '^2$' { Step2 }
                '^3$' { Step3 }
                '^4$' { Step4 }
                '^5$' { Step5 }
                '^6$' { Step6 }
                '^7$' { Step7 }
                '^(l|L)$' { Show-Changes }
                '^(x|X)$' { if (Exit-Menu) { Say '=== WHD-ImageMenu ended ==='; exit $exitCode } }
                default { Write-Host '  (not understood)' }
            }
        } catch {
            $msg = $_.Exception.Message
            if ($msg -notmatch '^STOPPED') { $msg = 'STOPPED - error: {0} (script line {1})' -f $msg, $_.InvocationInfo.ScriptLineNumber }
            Say "RESULT: $msg"
            if ($S.Mounted) { Say '    The image is still open; nothing in it is saved until step 6.' }
            $exitCode = 1
        }
    }
}
catch {
    $msg = $_.Exception.Message
    if ($msg -notmatch '^STOPPED') { $msg = 'STOPPED - error: {0} (script line {1})' -f $msg, $_.InvocationInfo.ScriptLineNumber }
    Say "RESULT: $msg"
    if ($S.Mounted) { Close-Image -Discard }
    Close-Iso
    Say '=== WHD-ImageMenu ended ==='
    exit 1
}
