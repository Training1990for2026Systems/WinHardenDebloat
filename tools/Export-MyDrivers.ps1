#requires -Version 5.1
<#
  Export-MyDrivers.ps1   (WHD Imaging Helper 1.5 preview 1 - tools)

  Copies the driver packages of THIS PC out of Windows' driver store into the folder "drivers" next to
  this script, and writes drivers-list.txt: one line per package, switched on or off.
  tools\Build-HomeUsbFromIso.ps1 puts the packages that are switched on into the install image.

  What "driver package" means here: the .inf file and the files it names (.sys, .cat, .dll ...), as
  Windows keeps them in its driver store. Nothing else is taken: no setup program, no maker app, no
  control panel from the Store. A package can carry a service or a helper program of its own; that
  part belongs to the driver and comes along.

  What it does:
    1. Lets DISM copy every third-party driver package of this Windows into "drivers"
       (dism /Online /Export-Driver). Windows' own drivers are not copied: they are in every image.
    2. Asks Windows which of these packages a device of this PC uses right now.
    3. Writes drivers-list.txt. Switched ON:  packages a device uses now, and "Extension" packages
       (the maker's settings for a device; they only take effect on matching hardware).
       Switched OFF: "SoftwareComponent" packages (the hooks through which maker apps and control
       panels arrive) and packages no device uses now (old versions, printers that are not connected).
       Change any line from on to off, or off to on, before you build.

  Rules it keeps:
    - Uses only Windows PowerShell, DISM and what is built into Windows. No downloads, no web calls.
    - It only READS this Windows. It writes only into the folder of this script.
    - Nothing is deleted: with -Again an older "drivers" folder and list are renamed.
    - Everything is written to Export-MyDrivers.log.

  Run from an administrator Windows PowerShell, in the helper's main folder (the one that holds WHD-ImageMenu.ps1):
    powershell -ExecutionPolicy Bypass -File .\tools\Export-MyDrivers.ps1

  Switches:
    -Again    export anew although "drivers" already holds an export (the old one is renamed)
#>
param(
    [switch]$Again
)

$ErrorActionPreference = 'Stop'

# This script lies in tools\ ; lists, logs and work files are in the helper's main folder above it.
$root    = Split-Path -Parent $PSScriptRoot
$log     = Join-Path $root 'Export-MyDrivers.log'
$drvDir  = Join-Path $root 'drivers'
$drvList = Join-Path $root 'drivers-list.txt'
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'

function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    try { Add-Content -LiteralPath $log -Value $line -Encoding Ascii -ErrorAction Stop } catch { }
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

function Fmt([double]$Bytes) {
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

# The name of the folder a file lies in: "C:\a\b\c.inf" gives "b".
function Get-ParentName([string]$Path) {
    $parent = Split-Path -Parent $Path
    if (-not $parent) { return '' }
    return (Split-Path -Leaf $parent)
}

$exitCode = 0
try {
    Say '=== Export-MyDrivers started ==='

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator'
    }

    # --- an export that is already there ------------------------------------------------------
    $haveOld = ((Test-Path -LiteralPath $drvDir -PathType Container) -and (@(Get-ChildItem -LiteralPath $drvDir -Force).Count -gt 0))
    if ($haveOld -and (-not $Again)) {
        Stop-Run "the folder $drvDir already holds an export. Nothing was changed. To export anew, run again with -Again: the old folder and the old list are renamed, not deleted"
    }
    if ($haveOld) {
        Say "Renaming the older export to drivers_old_$stamp (nothing deleted)."
        Rename-Item -LiteralPath $drvDir -NewName "drivers_old_$stamp"
    }
    if (Test-Path -LiteralPath $drvList -PathType Leaf) {
        Say "Renaming the older list to drivers-list_old_$stamp.txt (nothing deleted)."
        Rename-Item -LiteralPath $drvList -NewName "drivers-list_old_$stamp.txt"
    }
    if (-not (Test-Path -LiteralPath $drvDir)) { New-Item -ItemType Directory -Path $drvDir | Out-Null }

    # --- 1. copy the packages out of the driver store -----------------------------------------
    Say 'Copying the third-party driver packages of this Windows (a few minutes) ...'
    Say ("dism /English /Online /Export-Driver /Destination:{0}" -f $drvDir)
    $out  = & dism.exe '/English' '/Online' '/Export-Driver' "/Destination:$drvDir"
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($l in $out) {
            $s = ([string]$l).Trim()
            if ($s -and ($s -notmatch '^\[[=\s]*\d')) { Say ('    ' + $s) }
        }
        Stop-Run "DISM ended with code $code"
    }
    $folders = @(Get-ChildItem -LiteralPath $drvDir -Directory | Sort-Object Name)
    if ($folders.Count -eq 0) { Stop-Run "DISM copied no driver package into $drvDir" }
    Say ("    {0} package(s) copied." -f $folders.Count)

    # --- 2. what Windows knows about them ------------------------------------------------------
    # The driver store: class, maker, version, and the name Windows gave the package (oemNN.inf).
    $byFolder = @{}
    $byInf    = @{}
    foreach ($s in @(Get-WindowsDriver -Online -ErrorAction Stop)) {
        $orig = "$($s.OriginalFileName)"
        if (-not $orig) { continue }
        $folderKey = (Get-ParentName $orig).ToLowerInvariant()
        $infKey    = (Split-Path -Leaf $orig).ToLowerInvariant()
        if ($folderKey) { $byFolder[$folderKey] = $s }
        if (-not $byInf.ContainsKey($infKey)) { $byInf[$infKey] = @() }
        $byInf[$infKey] += $s
    }
    # The devices: which package (oemNN.inf) each device uses now.
    $usedBy = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop)) {
        $inf = "$($p.InfName)".Trim().ToLowerInvariant()
        if ($inf -notmatch '^oem\d+\.inf$') { continue }
        $name = "$($p.DeviceName)".Trim()
        if (-not $name) { $name = "$($p.DeviceID)".Trim() }
        if (-not $usedBy.ContainsKey($inf)) { $usedBy[$inf] = @() }
        if ($usedBy[$inf] -notcontains $name) { $usedBy[$inf] += $name }
    }

    # --- 3. one row per copied package --------------------------------------------------------
    $rows = @()
    foreach ($f in $folders) {
        $bytes = [double]0
        $files = @(Get-ChildItem -LiteralPath $f.FullName -Recurse -File -Force)
        foreach ($x in $files) { $bytes += $x.Length }
        $infs = @($files | Where-Object { $_.Name -like '*.inf' } | Sort-Object Name)
        $s = $null
        if ($byFolder.ContainsKey($f.Name.ToLowerInvariant())) { $s = $byFolder[$f.Name.ToLowerInvariant()] }
        elseif ($infs.Count -gt 0) {
            $k = $infs[0].Name.ToLowerInvariant()
            if ($byInf.ContainsKey($k) -and (@($byInf[$k]).Count -eq 1)) { $s = @($byInf[$k])[0] }
        }
        $class = '(not known)'; $maker = '(not known)'; $version = ''; $date = ''; $published = ''; $devices = @()
        if ($null -ne $s) {
            $class = "$($s.ClassName)".Trim(); $maker = "$($s.ProviderName)".Trim(); $version = "$($s.Version)".Trim()
            try { $date = ([datetime]$s.Date).ToString('yyyy-MM-dd') } catch { $date = '' }
            # Windows gives the name as "oem12.inf"; should it come with a folder in front, only the name counts.
            $published = "$($s.Driver)".Trim().ToLowerInvariant()
            if ($published -match '[\\/]') { $published = (Split-Path -Leaf $published) }
            if ($published -and $usedBy.ContainsKey($published)) { $devices = @($usedBy[$published]) }
        }
        $on = $false; $why = ''
        if ($infs.Count -eq 0) { $on = $false; $why = 'OFF: no .inf file in this folder' }
        elseif ($null -eq $s) { $on = $true; $why = 'ON: Windows gave no details for it, so it is kept to be safe' }
        elseif ($class -ieq 'SoftwareComponent') { $on = $false; $why = 'OFF: software component (maker apps and control panels arrive through these)' }
        elseif ($devices.Count -gt 0) { $on = $true; $why = 'ON: in use' }
        elseif ($class -ieq 'Extension') { $on = $true; $why = 'ON: extension (takes effect only on matching hardware)' }
        else { $on = $false; $why = 'OFF: no device uses it now' }
        $rows += (New-Object PSObject -Property @{
            Folder = $f.Name; Class = $class; Maker = $maker; Version = $version; Date = $date; Published = $published
            Devices = $devices; Bytes = $bytes; On = $on; Why = $why
        })
    }

    # --- 4. the list ---------------------------------------------------------------------------
    $text = @()
    $text += '# drivers-list.txt - the driver packages of this PC, for tools\Build-HomeUsbFromIso.ps1 (WHD-ImageMenu.ps1 writes its own, step 2).'
    $text += ('# Written by Export-MyDrivers.ps1 on {0}. PRIVATE: it names the hardware of this PC. Never upload it.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $text += '#'
    $text += '# One package = one line "driver:<folder name> on" or "... off". The folder is in "drivers".'
    $text += '# The comment line above each one says: class | maker | version (date) | size | name in Windows | why.'
    $text += '# Change on to off (or off to on) as you like, then run the build script. A line that starts with # is a comment.'
    $text += '#'
    $text += '# How the script chose:'
    $text += '#   ON   a device of this PC uses the package now'
    $text += '#   ON   class Extension: the maker''s settings for a device; takes effect only on matching hardware'
    $text += '#   OFF  class SoftwareComponent: the hooks for maker apps and control panels. With these off, Device Manager'
    $text += '#        can show a "software component" without a driver, and an extra such as audio effects or a'
    $text += '#        graphics control panel can be missing. The devices themselves work. Switch a line on to have it.'
    $text += '#   OFF  no device uses the package now (an older version, a printer or a device that is not connected)'
    $text += ''
    $onCount = 0; $onBytes = [double]0; $swc = 0; $unused = 0
    foreach ($r in @($rows | Sort-Object @{ Expression = { -not $_.On } }, Class, Maker, Folder)) {
        $ver = $r.Version; if ($r.Date) { $ver = ('{0} ({1})' -f $r.Version, $r.Date) }
        $text += ('# {0} | {1} | {2} | {3} | {4} | {5}' -f $r.Class, $r.Maker, $ver, (Fmt $r.Bytes), $r.Published, $r.Why)
        if ($r.Devices.Count -gt 0) {
            $shown = @($r.Devices | Select-Object -First 4) -join '; '
            if ($r.Devices.Count -gt 4) { $shown += (' (+{0} more)' -f ($r.Devices.Count - 4)) }
            $text += ('#     used by: {0}' -f ($shown -replace '[^\x20-\x7E]', '?'))
        }
        if ($r.On) { $text += ('driver:{0} on' -f $r.Folder); $onCount++; $onBytes += $r.Bytes }
        else {
            $text += ('driver:{0} off' -f $r.Folder)
            if ($r.Class -ieq 'SoftwareComponent') { $swc++ } else { $unused++ }
        }
        $text += ''
    }
    $clean = @()
    foreach ($t in $text) { $clean += ([string]$t -replace '[^\x20-\x7E]', '?') }
    Set-Content -LiteralPath $drvList -Value $clean -Encoding Ascii

    $allBytes = [double]0
    foreach ($r in $rows) { $allBytes += $r.Bytes }
    Say ("drivers-list.txt written: {0} package(s), {1} copied in all." -f $rows.Count, (Fmt $allBytes))
    Say ("    switched ON : {0} package(s), {1}" -f $onCount, (Fmt $onBytes))
    Say ("    switched OFF: {0} software component(s), {1} package(s) that are not in use or have no .inf" -f $swc, $unused)
    Say 'RESULT: DONE - read drivers-list.txt, change what you want, then run tools\Build-HomeUsbFromIso.ps1.'
    Say 'NOTE: the folder "drivers" and the list name the hardware of this PC. They are private: never upload them.'
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    if ($msg -notmatch '^STOPPED') { $msg = 'STOPPED - error: {0} (script line {1})' -f $msg, $_.InvocationInfo.ScriptLineNumber }
    try { Say "RESULT: $msg" } catch { Write-Host "RESULT: $msg" }
}
Say '=== Export-MyDrivers ended ==='
exit $exitCode
