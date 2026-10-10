#requires -Version 5.1
<#
  Build-HomeUsbFromIso.ps1   (WHD USB Image - ISO build)

  Makes a Windows 11 install stick from ONE Windows ISO file: Home edition only, with the items named
  in remove-list.txt taken out and the settings named in image-settings.txt written in.

  THIS SCRIPT ERASES THE WHOLE USB STICK. It shows the stick, lists what is on it and asks you to
  type  ERASE <letter>  before it does anything. With -NoStick it builds the image and leaves every
  stick alone.

  What it does, in this order:
    1. Checks: administrator window, the lists, the work folder, the stick (a removable USB drive,
       not larger than 256 GB, not the drive Windows or the work files are on).
    2. Asks you to confirm the erase (not with -NoStick). Nothing has been changed up to here.
    3. Works out the SHA-256 checksum of the ISO file and writes it down. With -IsoSha256 <value> it
       compares it and stops on a difference.
    4. Opens the ISO file (Windows mounts it read-only as a drive), finds the edition "Windows 11 Home"
       in sources\install.wim or install.esd and exports it to install.wim in the work folder.
       An install.wim that an earlier run made from the same ISO file is used again.
    5. Copies install.wim to install-custom.wim, opens the copy and
         - removes the listed bundled apps, switches the listed features off, removes the listed
           capabilities (remove-list.txt),
         - sets the listed services to "disabled" and writes the listed machine-wide registry values
           (remove-list.txt and image-settings.txt),
         - writes Windows' "deprovisioned" mark for every app it removed (part removed-app-marks),
         - copies the first sign-in script and its list into the image, and the answer file that
           starts the script once (Windows\Panther\unattend.xml) (part first-signin),
         - writes WHD-Image-applied.txt, the record of this run, into the image,
       and saves the copy.
    6. Splits the saved copy into pieces under 4 GB in the folder usb-custom.
    7. The stick: erases it, makes one FAT32 partition (at most 30 GB), copies every file of the ISO
       except the install image, copies the pieces, and compares the checksum of every file with its
       source. Writes the note WHD-USB-Image.txt on the stick.
    8. Closes the ISO file again (when this script opened it).

  Rules it keeps:
    - Uses only Windows PowerShell, DISM, reg.exe and the disk commands built into Windows.
      No downloads, no web calls. You download the ISO file yourself.
    - The ISO file is only read. It is never changed, moved or deleted.
    - It writes only into its work folder and onto the stick you confirmed.
    - The stick is not touched before the changed image is saved and split: when the build fails,
      the stick is as it was.
    - Nothing in the work folder is deleted. Older work files are renamed, not removed.
    - Everything is written to Build-HomeUsbFromIso.log in the folder of this script.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -UsbDrive F

  Build the image only, touch no stick (a safe first try):
    powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -NoStick

  Only compare a finished stick with the ISO file and the pieces in usb-custom (changes nothing):
    powershell -ExecutionPolicy Bypass -File .\Build-HomeUsbFromIso.ps1 -IsoFile C:\Downloads\Win11.iso -UsbDrive F -CheckOnly

  Switches:
    -IsoFile <file>      the Windows 11 ISO file (needed)
    -UsbDrive F          the letter of the stick. There is no default: the stick is erased.
    -NoStick             build the image and the pieces only; no stick is needed or touched
    -CheckOnly           only read and compare a finished stick
    -IsoSha256 <value>   the SHA-256 value the ISO file should have; the script stops when it differs
    -WorkDir <folder>    where the work files go (install.wim, install-custom.wim, mount, usb-custom).
                         It must be on an NTFS drive: DISM cannot open an image on FAT32 or exFAT.
#>
param(
    [string]$IsoFile = '',
    [string]$UsbDrive = '',
    [string]$HomeName = 'Windows 11 Home',
    [string]$IsoSha256 = '',
    [string]$WorkDir = '',
    [switch]$NoStick,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$log      = Join-Path $root 'Build-HomeUsbFromIso.log'
$listFile = Join-Path $root 'remove-list.txt'
$setFile  = Join-Path $root 'image-settings.txt'
$fsDir    = Join-Path $root 'first-signin'
$fsScript = Join-Path $fsDir 'WHD-FirstSignIn.ps1'
$fsList   = Join-Path $fsDir 'first-signin-list.txt'
$fsAnswer = Join-Path $fsDir 'Autounattend.xml'
# Where the answer file goes inside the image. Microsoft Learn, "Replace the answer file in an offline
# image": Windows Setup finds and uses the file at this place.
$imageAnswer = 'Windows\Panther\unattend.xml'
# The note this script leaves on the root of the stick.
$stickMarkName = 'WHD-USB-Image.txt'
$stickLabel    = 'WHD-USB'
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$hiveSys  = 'WHDIMG'
$hiveSw   = 'WHDIMGSW'
$imagePattern = '^install\d*\.(swm|wim|esd)$'
# Where the first sign-in files and the record of this run go inside the image.
$imageScriptsDir = 'Windows\Setup\Scripts'
# Services this script refuses to switch off. With the WinHTTP proxy service disabled, Wi-Fi stayed
# "dormant" after a restart in WHD's own tests.
$neverOff = @('WinHttpAutoProxySvc')
# A stick larger than this is refused: it is more likely an external drive with data on it.
$maxStickBytes = 256GB
# Windows formats FAT32 up to 32 GB. A larger stick gets one partition of this size.
$fatPartBytes  = 30GB

# The work folder. Set for real in the main part, after the checks.
$work     = $root
$srcWim   = ''
$newWim   = ''
$newDir   = ''

# Writes a line to the screen and to the log. It never stops the run: when the log cannot be written
# (a moment's lock on the file), it tries twice more and then goes on with the screen only.
function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -LiteralPath $log -Value $line -Encoding Ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Host '    (that line could not be written to the log file)'
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

function Fmt([double]$Bytes) {
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Invoke-Dism([string[]]$DismArgs, [switch]$AllowFail) {
    Say ('dism ' + ($DismArgs -join ' '))
    $out  = & dism.exe @DismArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($l in $out) {
            $s = ([string]$l).Trim()
            if ($s -and ($s -notmatch '^\[[=\s]*\d')) { Say ('    ' + $s) }
        }
        if (-not $AllowFail) { Stop-Run "DISM ended with code $code" }
    }
    return (New-Object PSObject -Property @{ Code = $code; Out = @($out) })
}

# Runs a program and returns its exit code and all its text, error output included.
# 'Continue' is set for this function only: with 'Stop', Windows PowerShell 5.1 would end the whole run
# at the first line a program writes to its error output.
function Invoke-Program([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $out  = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($o in @($out)) { $text += [string]$o }
    return (New-Object PSObject -Property @{ Code = $code; Out = $text })
}

# reg.exe writes "value not found" to its error output. That is an ordinary answer here.
function Invoke-Reg([string[]]$RegArgs) {
    return (Invoke-Program 'reg.exe' $RegArgs)
}

# Opens one registry file of the image under HKLM\<Name>. Three tries, two seconds apart.
function Open-Hive([string]$Name, [string]$File) {
    $r = $null
    for ($i = 0; $i -lt 3; $i++) {
        $r = Invoke-Reg @('load', "HKLM\$Name", $File)
        if ($r.Code -eq 0) { break }
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

function Get-DriveFormat([string]$Letter) {
    return [string](New-Object System.IO.DriveInfo($Letter)).DriveFormat
}

# The images in a .wim / .swm file: one object per image, with Index and Name.
function Get-ImageList([string]$File) {
    $r    = Invoke-Dism @('/English', '/Get-WimInfo', "/WimFile:$File")
    $list = @()
    $idx  = 0
    foreach ($l in $r.Out) {
        $s = [string]$l
        if ($s -match '^\s*Index\s*:\s*(\d+)\s*$') { $idx = [int]$Matches[1] }
        elseif ($s -match '^\s*Name\s*:\s*(.+?)\s*$') {
            $list += (New-Object PSObject -Property @{ Index = $idx; Name = $Matches[1] })
            $idx = 0
        }
    }
    return ,@($list)
}

function Get-ImageNames([string]$File) {
    $names = @()
    foreach ($i in (Get-ImageList $File)) { $names += $i.Name }
    return ,@($names)
}

function Test-HomeOnly([string]$File) {
    $names = Get-ImageNames $File
    return (($names.Count -eq 1) -and ($names[0] -eq $HomeName))
}

function Get-AppMap([string]$MountDir) {
    $r    = Invoke-Dism @('/English', "/Image:$MountDir", '/Get-ProvisionedAppxPackages')
    $map  = @{}
    $disp = ''
    foreach ($l in $r.Out) {
        $s = [string]$l
        if ($s -match '^\s*DisplayName\s*:\s*(.+?)\s*$') { $disp = $Matches[1] }
        elseif ($s -match '^\s*PackageName\s*:\s*(.+?)\s*$') {
            if ($disp) { $map[$disp] = $Matches[1] }
            $disp = ''
        }
    }
    return $map
}

function Get-FeatureState([string]$MountDir, [string]$Feature) {
    $r = Invoke-Dism @('/English', "/Image:$MountDir", '/Get-FeatureInfo', "/FeatureName:$Feature") -AllowFail
    if ($r.Code -ne 0) { return '' }
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*State\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

function Get-CapabilityState([string]$MountDir, [string]$Capability) {
    $r = Invoke-Dism @('/English', "/Image:$MountDir", '/Get-CapabilityInfo', "/CapabilityName:$Capability") -AllowFail
    if ($r.Code -ne 0) { return '' }
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*State\s*:\s*(.+?)\s*$') { return $Matches[1] }
    }
    return ''
}

# "Microsoft.Copilot_0.25061.2.0_neutral_~_8wekyb3d8bbwe" -> "Microsoft.Copilot_8wekyb3d8bbwe"
# (the package family name: the name and the publisher id). Empty when the name does not have that form.
function Get-FamilyName([string]$PackageName) {
    $parts = @($PackageName -split '_')
    if ($parts.Count -lt 5) { return '' }
    $fam = '{0}_{1}' -f $parts[0], $parts[$parts.Count - 1]
    if ($fam -notmatch '^[A-Za-z0-9.\-]+_[a-z0-9]{13}$') { return '' }
    return $fam
}

# Reads one value from the opened image registry. Returns Exists, Type (REG_...) and Data (text).
function Get-RegValue([string]$Key, [string]$Name) {
    $q = Invoke-Reg @('query', $Key, '/v', $Name)
    if ($q.Code -eq 0) {
        $rx = '^\s+' + [regex]::Escape($Name) + '\s+(REG_[A-Z_]+)\s*(.*)$'
        foreach ($l in $q.Out) {
            if (([string]$l) -match $rx) {
                return (New-Object PSObject -Property @{ Exists = $true; Type = $Matches[1]; Data = ([string]$Matches[2]).Trim() })
            }
        }
    }
    return (New-Object PSObject -Property @{ Exists = $false; Type = ''; Data = '' })
}

# Is the value already what the list asks for?
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

# Short text of a value for the log: "not set", "0x1", "Allow".
function Get-RegText($Have) {
    if (-not $Have.Exists) { return 'not set' }
    return $Have.Data
}

function Get-Pieces([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return ,@() }
    return ,@(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -match '^install\d*\.swm$' } | Sort-Object Name)
}

function Get-UsbImageFiles([string]$Dir) {
    return ,@(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -match $imagePattern } | Sort-Object Name)
}

# Does this answer file name our first sign-in script?
function Test-OurStickAnswer([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    try { return [bool](Select-String -LiteralPath $File -Pattern 'WHD-FirstSignIn.ps1' -SimpleMatch -Quiet -ErrorAction Stop) }
    catch { return $false }
}

function Get-SetKey($Files) {
    $keys = @()
    foreach ($f in $Files) { $keys += ('{0}|{1}' -f $f.Name.ToLowerInvariant(), $f.Length) }
    return (($keys | Sort-Object) -join ';')
}

function Get-TotalSize($Files) {
    $sum = [double]0
    foreach ($f in $Files) { $sum += $f.Length }
    return $sum
}

function Get-Sha([string]$File) {
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
}

# Copies one file and compares checksums; a second try when the copy differs. Returns the checksum.
function Copy-Checked($File, [string]$DestDir, [string]$Where = 'to the stick') {
    $dest = Join-Path $DestDir $File.Name
    $h1   = Get-Sha $File.FullName
    for ($try = 1; $try -le 2; $try++) {
        Say ("Copying {0} ({1}) {2}, attempt {3} ..." -f $File.Name, (Fmt $File.Length), $Where, $try)
        Copy-Item -LiteralPath $File.FullName -Destination $DestDir -Force
        if ((Get-Item -LiteralPath $dest).Length -eq $File.Length) {
            $h2 = Get-Sha $dest
            if ($h2 -eq $h1) {
                Say "    checksum same: $h1"
                return $h1
            }
            Say '    checksum DIFFERENT after the copy.'
        } else {
            Say '    size DIFFERENT after the copy.'
        }
    }
    Stop-Run "$dest does not match its source after two copies. The stick or the USB port is unreliable: try a USB port directly on the PC (no hub), or another stick"
}

# Reads remove-list.txt and image-settings.txt. Stops on any line it does not understand, before
# anything is changed. Returns one object with everything the run has to do.
function Read-Lists {
    $plan = New-Object PSObject -Property @{
        Apps = @(); Features = @(); Capabilities = @(); Services = @(); RegOps = @()
        PartSettings = $false; PartMarks = $false; PartFirstSignIn = $false
        GroupsOn = @(); GroupsOff = @()
    }

    if (-not (Test-Path -LiteralPath $listFile)) { Stop-Run "$listFile not found" }
    foreach ($raw in (Get-Content -LiteralPath $listFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^app:([A-Za-z0-9._-]+)$') { $plan.Apps += $Matches[1] }
        elseif ($t -match '^feature:([A-Za-z0-9._-]+)$') { $plan.Features += $Matches[1] }
        elseif ($t -match '^capability:([A-Za-z0-9._~-]+)$') { $plan.Capabilities += $Matches[1] }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') {
            if ($neverOff -contains $Matches[1]) { Stop-Run "remove-list.txt asks to switch off $($Matches[1]). This script refuses that service: with it disabled, Wi-Fi did not come up in WHD's tests" }
            $plan.Services += (New-Object PSObject -Property @{ Name = $Matches[1]; Group = 'remove-list' })
        }
        else { Stop-Run "remove-list.txt has a line that is not understood: $t" }
    }

    if (-not (Test-Path -LiteralPath $setFile)) {
        Say 'image-settings.txt not found: no settings are written, no marks, no first sign-in script.'
        return $plan
    }
    $group   = ''
    $groupOn = $false
    foreach ($raw in (Get-Content -LiteralPath $setFile)) {
        $t = ([string]$raw).Trim()
        if ((-not $t) -or $t.StartsWith('#')) { continue }
        if ($t -match '^part:(machine-settings|removed-app-marks|first-signin)\s+(on|off)$') {
            $on = ($Matches[2] -eq 'on')
            switch ($Matches[1]) {
                'machine-settings'  { $plan.PartSettings    = $on }
                'removed-app-marks' { $plan.PartMarks       = $on }
                'first-signin'      { $plan.PartFirstSignIn = $on }
            }
        }
        elseif ($t -match '^group:([a-z0-9-]+)\s+(on|off)$') {
            $group   = $Matches[1]
            $groupOn = ($Matches[2] -eq 'on')
            if (($plan.GroupsOn -contains $group) -or ($plan.GroupsOff -contains $group)) { Stop-Run "image-settings.txt names the group '$group' twice" }
            if ($groupOn) { $plan.GroupsOn += $group } else { $plan.GroupsOff += $group }
        }
        elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') {
            if (-not $group) { Stop-Run "image-settings.txt: this line stands before the first group: line: $t" }
            if ($neverOff -contains $Matches[1]) { Stop-Run "image-settings.txt asks to switch off $($Matches[1]). This script refuses that service: with it disabled, Wi-Fi did not come up in WHD's tests" }
            if ($groupOn) { $plan.Services += (New-Object PSObject -Property @{ Name = $Matches[1]; Group = $group }) }
        }
        elseif ($t.StartsWith('reg:')) {
            if (-not $group) { Stop-Run "image-settings.txt: this line stands before the first group: line: $t" }
            $f = @($t.Substring(4) -split '\|')
            if ($f.Count -ne 5) { Stop-Run "image-settings.txt: a reg: line needs 5 fields (hive|key|value name|type|data): $t" }
            $hive = $f[0]; $key = $f[1]; $name = $f[2]; $type = $f[3]; $data = $f[4]
            if ($t -match '["%&<>^]') { Stop-Run "image-settings.txt: a reg: line must not contain any of these characters: `" % & < > ^ : $t" }
            if (@('SOFTWARE', 'SYSTEM') -cnotcontains $hive) { Stop-Run "image-settings.txt: the hive must be SOFTWARE or SYSTEM: $t" }
            if (@('dword', 'string') -cnotcontains $type) { Stop-Run "image-settings.txt: the type must be dword or string: $t" }
            if ((-not $key) -or $key.StartsWith('\') -or $key.EndsWith('\') -or ($key -match '\\\\') -or ($key -match '[/*?]')) { Stop-Run "image-settings.txt: the key is not usable: $t" }
            if (($hive -eq 'SYSTEM') -and ($key -notmatch '^(Services|Control)\\')) { Stop-Run "image-settings.txt: a SYSTEM key must start with Services\ or Control\ : $t" }
            if (($hive -eq 'SYSTEM') -and ($key -match '^Services\\([^\\]+)')) {
                if (($neverOff -contains $Matches[1]) -and ($name -eq 'Start')) { Stop-Run "image-settings.txt changes the start of $($Matches[1]). This script refuses that service" }
            }
            if ((-not $name) -or ($name -match '\s')) { Stop-Run "image-settings.txt: the value name is empty or has a space in it: $t" }
            if ($type -eq 'dword') {
                if (($data -notmatch '^\d{1,10}$') -or ([double]$data -gt 4294967295)) { Stop-Run "image-settings.txt: dword data must be a whole number from 0 to 4294967295: $t" }
            } elseif ((-not $data) -or ($data -ne $data.Trim()) -or $data.EndsWith('\')) { Stop-Run "image-settings.txt: string data is empty or ends with a backslash: $t" }
            if ($groupOn) {
                $plan.RegOps += (New-Object PSObject -Property @{ Group = $group; Hive = $hive; Key = $key; Name = $name; Type = $type; Data = $data })
            }
        }
        else { Stop-Run "image-settings.txt has a line that is not understood: $t" }
    }
    if (-not $plan.PartSettings) {
        # The part is off: nothing from image-settings.txt is written (the service-off lines of
        # remove-list.txt stay).
        $plan.RegOps   = @()
        $plan.Services = @($plan.Services | Where-Object { $_.Group -eq 'remove-list' })
    }
    return $plan
}

# ---- the ISO file ---------------------------------------------------------------------------------

# The path of a file below a folder, without the folder: "X:\sources\boot.wim" below "X:\" gives
# "sources\boot.wim".
function Get-RelativeName([string]$Full, [string]$BaseFull) {
    return $Full.Substring($BaseFull.Length).TrimStart('\', '/')
}

# Every file of the opened ISO except the install image in \sources. Returns objects with File and Rel.
function Get-IsoFiles([string]$IsoRoot) {
    $baseFull = (Get-Item -LiteralPath $IsoRoot).FullName
    $list = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $IsoRoot -Recurse -File -Force | Sort-Object FullName)) {
        $rel = Get-RelativeName $f.FullName $baseFull
        if ($rel -match '^sources[\\/]install\d*\.(swm|wim|esd)$') { continue }
        $list += (New-Object PSObject -Property @{ File = $f; Rel = $rel })
    }
    return ,@($list)
}

# The drive letter Windows gave the opened ISO file. Windows can need a moment after opening it:
# up to ten tries, one second apart. Empty when there is none.
function Get-IsoLetter([string]$IsoPath) {
    for ($i = 0; $i -lt 10; $i++) {
        $l = ''
        try { $l = Get-LetterText (Get-Volume -DiskImage (Get-DiskImage -ImagePath $IsoPath) -ErrorAction Stop).DriveLetter } catch { $l = '' }
        if ($l) { return $l }
        Start-Sleep -Seconds 1
    }
    return ''
}

# ---- the stick ------------------------------------------------------------------------------------

# A drive letter as Windows gives it (a character, empty for "none") as text: "F", or "" when there is none.
function Get-LetterText($Letter) {
    $t = "$Letter"
    if ($t -match '^[A-Za-z]$') { return $t.ToUpperInvariant() }
    return ''
}

# What Windows knows about the disk behind a drive letter. Stops when there is no such drive.
function Get-StickInfo([string]$Letter) {
    $part = $null
    try { $part = Get-Partition -DriveLetter $Letter -ErrorAction Stop } catch { $part = $null }
    if ($null -eq $part) { Stop-Run "drive ${Letter}: was not found - is the stick plugged in, and does it show with that letter in Explorer?" }
    $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
    $vol  = Get-Volume -DriveLetter $Letter -ErrorAction Stop
    $letters = @()
    foreach ($p in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop)) {
        $l = Get-LetterText $p.DriveLetter
        if ($l) { $letters += $l }
    }
    return (New-Object PSObject -Property @{
        Number = [int]$disk.Number; Name = "$($disk.FriendlyName)".Trim(); Bus = "$($disk.BusType)"
        Size = [double]$disk.Size; Serial = "$($disk.SerialNumber)".Trim(); UniqueId = "$($disk.UniqueId)".Trim()
        IsBoot = [bool]$disk.IsBoot; IsSystem = [bool]$disk.IsSystem
        DriveType = "$($vol.DriveType)"; Label = "$($vol.FileSystemLabel)"; FileSystem = "$($vol.FileSystem)"
        Letters = $letters
    })
}

# The rules a drive has to pass before this script will erase it. $Avoid = drive letters that must not be
# on that disk (Windows, the work folder, the script, the ISO file).
function Test-StickRules($Stick, [string]$Letter, [string[]]$Avoid) {
    if ($Stick.Bus -ne 'USB') { Stop-Run "drive ${Letter}: is on a disk that is connected by $($Stick.Bus), not by USB. It is refused. Nothing was changed" }
    if ($Stick.DriveType -ne 'Removable') { Stop-Run "drive ${Letter}: is not a removable drive (Windows calls it '$($Stick.DriveType)'). External hard drives and SSDs are refused on purpose. Nothing was changed" }
    if ($Stick.IsBoot -or $Stick.IsSystem) { Stop-Run "drive ${Letter}: is on the disk this Windows starts from. It is refused. Nothing was changed" }
    if ($Stick.Size -gt $maxStickBytes) { Stop-Run ("drive {0}: is on a disk of {1}. Disks larger than {2} are refused: that is more likely an external drive with data than an install stick. Nothing was changed" -f $Letter, (Fmt $Stick.Size), (Fmt $maxStickBytes)) }
    if ($Stick.Size -lt 7.5GB) { Stop-Run ("drive {0}: is on a disk of {1}. An install stick needs 8 GB or more. Nothing was changed" -f $Letter, (Fmt $Stick.Size)) }
    foreach ($a in $Avoid) {
        if ($a -and ($Stick.Letters -contains $a.ToUpperInvariant())) { Stop-Run "drive ${a}: is on the same disk as the stick ${Letter}:. Windows, this script, the work folder and the ISO file must be on another disk: the stick is erased. Nothing was changed" }
    }
}

# Copies one file of the ISO to the stick and compares size and checksum; one more try when it differs.
function Copy-IsoFile($Item, [string]$StickRoot) {
    $dest    = Join-Path $StickRoot $Item.Rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $h1 = Get-Sha $Item.File.FullName
    for ($try = 1; $try -le 2; $try++) {
        Copy-Item -LiteralPath $Item.File.FullName -Destination $dest -Force
        $made = Get-Item -LiteralPath $dest -Force
        if ($made.Length -eq $Item.File.Length) {
            if ((Get-Sha $dest) -eq $h1) {
                # Files in an ISO are read-only; the copy on the stick should not be.
                if ($made.IsReadOnly) { $made.IsReadOnly = $false }
                return
            }
        }
        Say ("    {0}: the copy on the stick differs from the ISO (attempt {1})." -f $Item.Rel, $try)
    }
    Stop-Run "$dest does not match its source after two copies. The stick or the USB port is unreliable: try a USB port directly on the PC (no hub), or another stick"
}

# Compares the stick with the ISO files and the pieces. Changes nothing. Returns the number of files compared.
function Compare-StickWithIso($IsoItems, [string]$StickRoot, $Pieces) {
    $n = 0
    foreach ($it in $IsoItems) {
        $dest = Join-Path $StickRoot $it.Rel
        if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) { Stop-Run "$dest is missing on the stick" }
        if ((Get-Item -LiteralPath $dest -Force).Length -ne $it.File.Length) { Stop-Run "$dest has another size than the file in the ISO" }
        if ((Get-Sha $dest) -ne (Get-Sha $it.File.FullName)) { Stop-Run "$dest does not match the file in the ISO (checksum differs)" }
        $n++
    }
    $stickSources = Join-Path $StickRoot 'sources'
    $onStick = Get-UsbImageFiles $stickSources
    if ((Get-SetKey $onStick) -ne (Get-SetKey $Pieces)) { Stop-Run 'the install image files on the stick are not the pieces from usb-custom (names or sizes differ)' }
    foreach ($f in $Pieces) {
        $dest = Join-Path $stickSources $f.Name
        if ((Get-Sha $f.FullName) -ne (Get-Sha $dest)) { Stop-Run "$dest does not match its source (checksum differs)" }
        $n++
    }
    if (-not (Test-HomeOnly (Join-Path $stickSources 'install.swm'))) { Stop-Run "the image on the stick does not read as a single '$HomeName' image" }
    return $n
}

$mounted    = $false
$sysLoaded  = $false
$swLoaded   = $false
$mount      = ''
$exitCode   = 0
$done       = @()
$skipped    = @()
$failed     = @()
$iso            = ''
$isoSha         = ''
$isoOpenedByUs  = $false
$stickErased    = $false
$stickFinished  = $false

try {
    Say '=== Build-HomeUsbFromIso started ==='

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator'
    }

    # --- the switches -------------------------------------------------------------------------
    if (-not $IsoFile) { Stop-Run 'give the Windows ISO file with -IsoFile <file>' }
    if (-not (Test-Path -LiteralPath $IsoFile -PathType Leaf)) { Stop-Run "the ISO file was not found: $IsoFile" }
    $iso = (Get-Item -LiteralPath $IsoFile).FullName
    if ($iso -notmatch '^[A-Za-z]:\\.+\.iso$') { Stop-Run "-IsoFile must be a file that ends with .iso, on a drive with a letter (it is $iso)" }
    if ($NoStick -and $CheckOnly) { Stop-Run '-NoStick and -CheckOnly cannot be used together: -CheckOnly compares a stick' }
    $useStick = (-not $NoStick)
    if ($useStick) {
        if ($UsbDrive -notmatch '^[A-Za-z]$') { Stop-Run "give the letter of the stick with -UsbDrive (one letter, for example F). There is no default, because the stick is erased. To build the image only, use -NoStick (it is '$UsbDrive')" }
        $UsbDrive = $UsbDrive.ToUpperInvariant()
    } elseif ($UsbDrive) {
        Say 'NOTE: -NoStick was given: -UsbDrive is not used and no stick is touched.'
    }
    $wantSha = ''
    if ($IsoSha256) {
        $wantSha = ($IsoSha256 -replace '[\s:-]', '').ToUpperInvariant()
        if ($wantSha -notmatch '^[0-9A-F]{64}$') { Stop-Run "-IsoSha256 is not a SHA-256 value (64 characters, 0-9 and A-F): $IsoSha256" }
    }

    # --- the work folder ----------------------------------------------------------------------
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Stop-Run "the work folder $WorkDir does not exist. Make it first, or leave -WorkDir out" }
        $work = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd('\')
    }
    if ($work -notmatch '^[A-Za-z]:\\.+') { Stop-Run "the work folder must be a folder on a drive with a letter, not the top of a drive and not a network path (it is $work)" }
    $srcWim  = Join-Path $work 'install.wim'
    $srcNote = Join-Path $work 'install-source.txt'
    $newWim  = Join-Path $work 'install-custom.wim'
    $newDir  = Join-Path $work 'usb-custom'
    Say "Work folder: $work"
    Say ("ISO file: {0} ({1})" -f $iso, (Fmt (Get-Item -LiteralPath $iso).Length))
    # The same switches again, for the command lines this run prints at its end.
    $extra = " -IsoFile `"$iso`""
    if ($useStick) { $extra += " -UsbDrive $UsbDrive" }
    if ($work -ne $root) { $extra += " -WorkDir `"$work`"" }

    # --- the stick: which disk it is, and whether this script may erase it ------------------
    $stick = $null
    if ($useStick) {
        $stick = Get-StickInfo $UsbDrive
        Say ("Stick {0}: disk {1} '{2}', connected by {3}, {4}, size {5}, label '{6}', file system {7}" -f $UsbDrive, $stick.Number, $stick.Name, $stick.Bus, $stick.DriveType, (Fmt $stick.Size), $stick.Label, $stick.FileSystem)
        $avoid = @($work.Substring(0, 1), $root.Substring(0, 1), $iso.Substring(0, 1))
        if ($env:SystemDrive) { $avoid += $env:SystemDrive.Substring(0, 1) }
        Test-StickRules $stick $UsbDrive $avoid
    }

    # ------------------------------------------------------------------------------------------
    # -CheckOnly: compare the stick with the ISO file and usb-custom, and end
    # ------------------------------------------------------------------------------------------
    if ($CheckOnly) {
        $pieces = Get-Pieces $newDir
        if ($pieces.Count -eq 0) { Stop-Run "no pieces found in $newDir" }
        if (-not (Get-DiskImage -ImagePath $iso).Attached) { Mount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null; $isoOpenedByUs = $true }
        $isoLetter = Get-IsoLetter $iso
        if (-not $isoLetter) { Stop-Run 'Windows opened the ISO file but gave it no drive letter' }
        $isoItems = Get-IsoFiles "${isoLetter}:\"
        Say ("Comparing {0} file(s) of the ISO and {1} piece(s) with the stick (this reads everything once) ..." -f $isoItems.Count, $pieces.Count)
        $n = Compare-StickWithIso $isoItems "${UsbDrive}:\" $pieces
        if (Test-Path -LiteralPath "${UsbDrive}:\$stickMarkName" -PathType Leaf) { Say "    the note $stickMarkName is on the stick." }
        else { Say "NOTE: the note $stickMarkName is not on the stick." }
        Say "RESULT: DONE - check only. $n file(s) on the stick match the ISO file and the pieces in usb-custom; the image reads as one edition: $HomeName."
    }
    else {
        # --- read the lists (stops on a line that is not understood) --------------------------
        $plan = Read-Lists
        Say ("remove-list.txt: {0} app(s), {1} feature(s), {2} capability(ies), {3} service(s)" -f $plan.Apps.Count, $plan.Features.Count, $plan.Capabilities.Count, @($plan.Services | Where-Object { $_.Group -eq 'remove-list' }).Count)
        $onOff = @{ $true = 'on'; $false = 'off' }
        Say ("image-settings.txt: part machine-settings {0}, part removed-app-marks {1}, part first-signin {2}" -f $onOff[$plan.PartSettings], $onOff[$plan.PartMarks], $onOff[$plan.PartFirstSignIn])
        if ($plan.PartSettings) {
            Say ("    groups on ({0}): {1}" -f $plan.GroupsOn.Count, ($plan.GroupsOn -join ', '))
            Say ("    groups off ({0}): {1}" -f $plan.GroupsOff.Count, ($plan.GroupsOff -join ', '))
            Say ("    {0} registry value(s), {1} service(s) from the groups that are on" -f $plan.RegOps.Count, @($plan.Services | Where-Object { $_.Group -ne 'remove-list' }).Count)
        }
        if (($plan.Apps.Count + $plan.Features.Count + $plan.Capabilities.Count + $plan.Services.Count + $plan.RegOps.Count) -eq 0) {
            Stop-Run 'the lists name nothing to do'
        }

        # --- checks before anything is changed ------------------------------------------------
        if ($plan.PartFirstSignIn) {
            foreach ($need in @($fsScript, $fsList, $fsAnswer)) {
                if (-not (Test-Path -LiteralPath $need -PathType Leaf)) { Stop-Run "part first-signin is on, but $need is missing" }
            }
            # The answer file goes into the image: it has to be readable XML and name our script.
            $answerOk = $false
            try { $null = [xml](Get-Content -LiteralPath $fsAnswer -Raw); $answerOk = $true } catch { }
            if (-not $answerOk) { Stop-Run "$fsAnswer is not readable as XML. Nothing was changed" }
            if (-not (Test-OurStickAnswer $fsAnswer)) { Stop-Run "$fsAnswer does not name WHD-FirstSignIn.ps1. Nothing was changed" }
            # Let the first sign-in script read its own list now: a line it does not understand would
            # otherwise only show on the freshly installed PC. This reads the list and changes nothing.
            $chk = Invoke-Program 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fsScript, '-CheckList', '-ListFile', $fsList)
            foreach ($l in $chk.Out) { if (([string]$l).Trim()) { Say ('first-signin-list.txt: ' + ([string]$l).Trim()) } }
            if ($chk.Code -ne 0) { Stop-Run "the first sign-in script did not accept first-signin-list.txt (it ended with code $($chk.Code); see the line above). Nothing was changed" }
        }
        $pcLetter = $work.Substring(0, 1)
        $pcFormat = Get-DriveFormat $pcLetter
        $pcVol    = Get-Volume -DriveLetter $pcLetter
        Say ("Work drive {0}: {1}, free {2}" -f $pcLetter, $pcFormat, (Fmt $pcVol.SizeRemaining))
        if ($pcFormat -ne 'NTFS') {
            Stop-Run "the work folder is on a drive with the $pcFormat file system. DISM can only open an image in a folder on an NTFS drive. Run again with -WorkDir and a folder on an NTFS drive, for example: -WorkDir C:\WHD-Image-work (make the folder first)"
        }
        $needFree = 20GB + (2.5 * (Get-Item -LiteralPath $iso).Length)
        if ($pcVol.SizeRemaining -lt $needFree) {
            Stop-Run ("less than {0} free on drive {1}: (free: {2}). Run again with -WorkDir and a folder on a drive with more room" -f (Fmt $needFree), $pcLetter, (Fmt $pcVol.SizeRemaining))
        }
        foreach ($h in @($hiveSys, $hiveSw)) {
            $probe = Invoke-Reg @('query', "HKLM\$h", '/ve')
            if ($probe.Code -eq 0) { Stop-Run "the registry name HKLM\$h is already in use - an earlier run did not close the image's registry. Close it by hand:  reg unload HKLM\$h" }
        }

        # --- the stick: show it and ask ---------------------------------------------------------
        # Asked now, at the start, so that the long part can run without you. The erase itself comes
        # at the end, after the changed image is saved and split.
        if ($useStick) {
            Say ''
            Say ("EVERYTHING ON THIS STICK WILL BE DELETED: drive {0}: = disk {1} '{2}', {3}, label '{4}'." -f $UsbDrive, $stick.Number, $stick.Name, (Fmt $stick.Size), $stick.Label)
            if ($stick.Letters.Count -gt 1) { Say ("    The disk has more than one drive letter: {0}. All of them are deleted." -f ($stick.Letters -join ', ')) }
            $top = @()
            try { $top = @(Get-ChildItem -LiteralPath "${UsbDrive}:\" -Force -ErrorAction Stop | Sort-Object Name) } catch { Say '    (what is on it could not be listed)' }
            Say ("    On it now, at the top: {0} item(s)" -f $top.Count)
            foreach ($t in @($top | Select-Object -First 40)) { Say ('        ' + $t.Name) }
            if ($top.Count -gt 40) { Say ('        ... and {0} more' -f ($top.Count - 40)) }
            Say "    To go on, type these two words and press Enter:   ERASE $UsbDrive"
            $typed = [string](Read-Host '    Type them here (anything else stops the run; nothing is changed)')
            if ($typed.Trim().ToUpperInvariant() -ne "ERASE $UsbDrive") { Stop-Run "the erase was not confirmed (typed: '$typed'). Nothing was changed" }
            Say "Confirmed: ERASE $UsbDrive. The stick is erased after the image is built, not before."
            Say ''
        }

        # --- the ISO file: checksum, open, look inside ------------------------------------------
        Say 'Reading the ISO file to work out its SHA-256 checksum (a minute or two) ...'
        $isoSha = Get-Sha $iso
        Say "    SHA-256 of the ISO file: $isoSha"
        if ($wantSha) {
            if ($isoSha -ne $wantSha) { Stop-Run "the ISO file does not have the SHA-256 value given with -IsoSha256 ($wantSha). The download is damaged, or it is not the file you think. Nothing was changed" }
            Say '    same as the value given with -IsoSha256.'
        } else {
            Say 'NOTE: when the place you downloaded from shows a SHA-256 value for this file, compare it with the line above.'
            Say '      With -IsoSha256 <value> this script compares it for you and stops on a difference.'
        }
        if (-not (Get-DiskImage -ImagePath $iso).Attached) {
            Say 'Opening the ISO file (Windows shows it as a read-only drive) ...'
            Mount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null
            $isoOpenedByUs = $true
        } else {
            Say 'The ISO file is already open as a drive. It is left open at the end.'
        }
        $isoLetter = Get-IsoLetter $iso
        if (-not $isoLetter) { Stop-Run 'Windows opened the ISO file but gave it no drive letter' }
        $isoRoot = "${isoLetter}:\"
        $isoSrc  = "${isoLetter}:\sources"
        Say "The ISO file is open as drive ${isoLetter}:"
        if (-not (Test-Path -LiteralPath (Join-Path $isoSrc 'boot.wim') -PathType Leaf)) { Stop-Run "there is no sources\boot.wim in the ISO file: it is not a Windows install ISO. Nothing was changed" }
        $isoImage = ''
        foreach ($kind in @('wim', 'esd', 'swm')) {
            if ((-not $isoImage) -and (Test-Path -LiteralPath (Join-Path $isoSrc "install.$kind") -PathType Leaf)) { $isoImage = Join-Path $isoSrc "install.$kind" }
        }
        if (-not $isoImage) { Stop-Run "there is no sources\install.wim, install.esd or install.swm in the ISO file. Nothing was changed" }
        $isoItems = Get-IsoFiles $isoRoot
        $isoBytes = [double]0
        foreach ($it in $isoItems) {
            $isoBytes += $it.File.Length
            if ($it.File.Length -ge 4GB) { Stop-Run "$($it.Rel) in the ISO file is 4 GB or larger and cannot go on a FAT32 stick. Nothing was changed" }
        }
        Say ("In the ISO file: {0}, and {1} other file(s), {2}" -f (Split-Path -Leaf $isoImage), $isoItems.Count, (Fmt $isoBytes))

        # --- install.wim: the Home edition out of the ISO file ----------------------------------
        $reuse = $false
        if ((Test-Path -LiteralPath $srcWim -PathType Leaf) -and (Test-Path -LiteralPath $srcNote -PathType Leaf)) {
            $noteSha = "$(@(Get-Content -LiteralPath $srcNote)[0])".Trim()
            if ($noteSha -eq $isoSha) { $reuse = $true }
        }
        if ($reuse) {
            Say 'install.wim in the work folder was made from this same ISO file by an earlier run. It is used again.'
        } else {
            if (Test-Path -LiteralPath $srcWim -PathType Leaf) {
                Say "install.wim in the work folder is not from this ISO file. Renaming it to install_old_$stamp.wim (nothing deleted)."
                Rename-Item -LiteralPath $srcWim -NewName "install_old_$stamp.wim"
            }
            $images = Get-ImageList $isoImage
            foreach ($i in $images) { Say ("    in the ISO file: index {0} = {1}" -f $i.Index, $i.Name) }
            $homeImg = @($images | Where-Object { $_.Name -eq $HomeName })
            if ($homeImg.Count -ne 1) { Stop-Run "the ISO file does not hold exactly one edition named '$HomeName'. Nothing was changed" }
            if ($homeImg[0].Index -lt 1) { Stop-Run "the index of '$HomeName' could not be read from DISM's answer" }
            $partial = Join-Path $work 'install-partial.wim'
            if (Test-Path -LiteralPath $partial) {
                Say "A half-made export from an earlier run is renamed to install-partial_old_$stamp.wim (nothing deleted)."
                Rename-Item -LiteralPath $partial -NewName "install-partial_old_$stamp.wim"
            }
            Say 'Exporting the Home edition with maximum compression (this can take 15 minutes or more) ...'
            $exportArgs = @('/Export-Image', "/SourceImageFile:$isoImage")
            if ($isoImage -match '\.swm$') { $exportArgs += "/SWMFile:$(Join-Path $isoSrc 'install*.swm')" }
            $exportArgs += @("/SourceIndex:$($homeImg[0].Index)", "/DestinationImageFile:$partial", '/Compress:max', '/CheckIntegrity')
            Invoke-Dism $exportArgs | Out-Null
            if (-not (Test-HomeOnly $partial)) { Stop-Run "the export does not read as a single '$HomeName' image. It is kept as $partial" }
            Rename-Item -LiteralPath $partial -NewName 'install.wim'
            Set-Content -LiteralPath $srcNote -Value @($isoSha, (Split-Path -Leaf $iso), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding Ascii
            Say ("install.wim made: {0}" -f (Fmt (Get-Item -LiteralPath $srcWim).Length))
        }
        if (-not (Test-HomeOnly $srcWim)) { Stop-Run "install.wim is not a single '$HomeName' image" }

        # --- work copy ------------------------------------------------------------------------
        if (Test-Path -LiteralPath $newWim) {
            $old = "install-custom_old_$stamp.wim"
            Say "install-custom.wim exists from an earlier run. Renaming it to $old (nothing deleted)."
            Rename-Item -LiteralPath $newWim -NewName $old
        }
        Say ("Copying install.wim ({0}) to install-custom.wim ..." -f (Fmt (Get-Item -LiteralPath $srcWim).Length))
        Copy-Item -LiteralPath $srcWim -Destination $newWim

        $mount = Join-Path $work 'mount'
        if (Test-Path -LiteralPath $mount) {
            if (@(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
                $mount = Join-Path $work "mount_$stamp"
                New-Item -ItemType Directory -Path $mount | Out-Null
            }
        } else {
            New-Item -ItemType Directory -Path $mount | Out-Null
        }

        Say 'Opening install-custom.wim (a few minutes; much longer on a USB drive) ...'
        Invoke-Dism @('/Mount-Image', "/ImageFile:$newWim", '/Index:1', "/MountDir:$mount") | Out-Null
        $mounted = $true

        # An image that this script changed before is refused: the changes would be made a second time.
        if (Test-Path -LiteralPath (Join-Path $mount "$imageScriptsDir\WHD-Image-applied.txt") -PathType Leaf) {
            Stop-Run "install.wim holds an image that this script changed before (the record $imageScriptsDir\WHD-Image-applied.txt is in it). Rename install.wim in the work folder away and run again: it is then made new from the ISO file. The image copy is closed without saving and the stick is left as it was"
        }

        # --- apps -----------------------------------------------------------------------------
        $families = @()
        if ($plan.Apps.Count -gt 0) {
            $map = Get-AppMap $mount
            Say ("Bundled apps in the image before: {0}" -f $map.Count)
            foreach ($a in $plan.Apps) {
                if (-not $map.ContainsKey($a)) { $skipped += "app $a (not in the image)"; continue }
                $r = Invoke-Dism @("/Image:$mount", '/Remove-ProvisionedAppxPackage', "/PackageName:$($map[$a])") -AllowFail
                if ($r.Code -eq 0) {
                    $done += "app $a"
                    $fam = Get-FamilyName $map[$a]
                    if ($fam) { $families += $fam } elseif ($plan.PartMarks) { $skipped += "mark for $a (the package name $($map[$a]) has an unexpected form)" }
                } else { $failed += "app $a (DISM code $($r.Code))" }
            }
            $mapAfter = Get-AppMap $mount
            Say ("Bundled apps in the image after: {0}" -f $mapAfter.Count)
        }

        # --- features -------------------------------------------------------------------------
        foreach ($f in $plan.Features) {
            $state = Get-FeatureState $mount $f
            if (-not $state) { $skipped += "feature $f (not in the image)"; continue }
            if ($state -ne 'Enabled') { $skipped += "feature $f (state was: $state)"; continue }
            $r = Invoke-Dism @("/Image:$mount", '/Disable-Feature', "/FeatureName:$f") -AllowFail
            if ($r.Code -eq 0) { $done += "feature $f switched off" } else { $failed += "feature $f (DISM code $($r.Code))" }
        }

        # --- capabilities ---------------------------------------------------------------------
        foreach ($c in $plan.Capabilities) {
            $state = Get-CapabilityState $mount $c
            if (-not $state) { $skipped += "capability $c (not known to the image)"; continue }
            if ($state -ne 'Installed') { $skipped += "capability $c (state was: $state)"; continue }
            $r = Invoke-Dism @("/Image:$mount", '/Remove-Capability', "/CapabilityName:$c") -AllowFail
            if ($r.Code -eq 0) { $done += "capability $c removed" } else { $failed += "capability $c (DISM code $($r.Code))" }
        }

        # --- the image's registry: services, values, marks -----------------------------------
        $needSys = (($plan.Services.Count -gt 0) -or (@($plan.RegOps | Where-Object { $_.Hive -eq 'SYSTEM' }).Count -gt 0))
        $needSw  = ((@($plan.RegOps | Where-Object { $_.Hive -eq 'SOFTWARE' }).Count -gt 0) -or ($plan.PartMarks -and ($families.Count -gt 0)))
        $controlSet = ''
        if ($needSys) {
            $r = Open-Hive $hiveSys (Join-Path $mount 'Windows\System32\config\SYSTEM')
            if ($r.Code -ne 0) {
                Stop-Run ("the SYSTEM part of the image's registry could not be opened ({0}). The image copy is closed without saving and the stick is left as it was" -f (($r.Out | Where-Object { $_ }) -join ' '))
            }
            $sysLoaded = $true
            $setNumber = 1
            $q = Invoke-Reg @('query', "HKLM\$hiveSys\Select", '/v', 'Current')
            foreach ($l in $q.Out) {
                if (([string]$l) -match 'Current\s+REG_DWORD\s+0x([0-9A-Fa-f]+)') { $setNumber = [Convert]::ToInt32($Matches[1], 16) }
            }
            $controlSet = 'ControlSet{0:D3}' -f $setNumber
            Say "Image registry (SYSTEM) opened. Control set in use: $controlSet"
        }
        if ($needSw) {
            $r = Open-Hive $hiveSw (Join-Path $mount 'Windows\System32\config\SOFTWARE')
            if ($r.Code -ne 0) {
                Stop-Run ("the SOFTWARE part of the image's registry could not be opened ({0}). The image copy is closed without saving and the stick is left as it was" -f (($r.Out | Where-Object { $_ }) -join ' '))
            }
            $swLoaded = $true
            Say 'Image registry (SOFTWARE) opened.'
        }

        if ($sysLoaded) {
            foreach ($svc in $plan.Services) {
                $s    = $svc.Name
                $from = if ($svc.Group -eq 'remove-list') { '' } else { " [$($svc.Group)]" }
                $key  = "HKLM\$hiveSys\$controlSet\Services\$s"
                $have = Get-RegValue $key 'Start'
                if ((-not $have.Exists) -or ($have.Type -ne 'REG_DWORD') -or ($have.Data -notmatch '^0x([0-9A-Fa-f]+)$')) { $skipped += "service $s (not in the image)$from"; continue }
                $was = [Convert]::ToInt32($Matches[1], 16)
                if ($was -eq 4) { $skipped += "service $s (was already disabled)$from"; continue }
                $w = Invoke-Reg @('add', $key, '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
                if (($w.Code -eq 0) -and (Test-RegSame (Get-RegValue $key 'Start') 'dword' '4')) { $done += "service $s set to disabled (Start was $was, now 4)$from" }
                else { $failed += "service $s (registry write failed)$from" }
            }
        }

        foreach ($op in $plan.RegOps) {
            if ($op.Hive -eq 'SYSTEM') {
                if (-not $sysLoaded) { continue }
                $key  = "HKLM\$hiveSys\$controlSet\$($op.Key)"
                $show = "SYSTEM\$($op.Key)"
            } else {
                if (-not $swLoaded) { continue }
                $key  = "HKLM\$hiveSw\$($op.Key)"
                $show = "SOFTWARE\$($op.Key)"
            }
            $text = "value $show : $($op.Name) = $($op.Data) [$($op.Group)]"
            $have = Get-RegValue $key $op.Name
            if (Test-RegSame $have $op.Type $op.Data) { $skipped += "$text (was already set)"; continue }
            $regType = if ($op.Type -eq 'dword') { 'REG_DWORD' } else { 'REG_SZ' }
            $w = Invoke-Reg @('add', $key, '/v', $op.Name, '/t', $regType, '/d', $op.Data, '/f')
            if (($w.Code -eq 0) -and (Test-RegSame (Get-RegValue $key $op.Name) $op.Type $op.Data)) { $done += "$text (was: $(Get-RegText $have))" }
            else { $failed += "$text (registry write failed)" }
        }

        if ($plan.PartMarks -and $swLoaded) {
            foreach ($fam in $families) {
                $key = "HKLM\$hiveSw\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\$fam"
                $q   = Invoke-Reg @('query', $key)
                if ($q.Code -eq 0) { $skipped += "mark $fam (was already there)"; continue }
                $w = Invoke-Reg @('add', $key, '/f')
                $q = Invoke-Reg @('query', $key)
                if (($w.Code -eq 0) -and ($q.Code -eq 0)) { $done += "mark $fam (do not bring back)" } else { $failed += "mark $fam (registry write failed)" }
            }
        }

        if ($swLoaded) {
            if (-not (Close-Hive $hiveSw)) { Stop-Run "the image's registry could not be closed (HKLM\$hiveSw)" }
            $swLoaded = $false
        }
        if ($sysLoaded) {
            if (-not (Close-Hive $hiveSys)) { Stop-Run "the image's registry could not be closed (HKLM\$hiveSys)" }
            $sysLoaded = $false
        }

        # --- first sign-in files into the image -----------------------------------------------
        $scriptsDir = Join-Path $mount $imageScriptsDir
        if ($plan.PartFirstSignIn) {
            if (-not (Test-Path -LiteralPath $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir | Out-Null }
            $copied = 0
            foreach ($f in @($fsScript, $fsList)) {
                $dest = Join-Path $scriptsDir (Split-Path -Leaf $f)
                Copy-Item -LiteralPath $f -Destination $dest -Force
                if ((Get-Sha $f) -eq (Get-Sha $dest)) { $copied++ } else { $failed += "first sign-in file $(Split-Path -Leaf $f) (the copy in the image differs)" }
            }
            if ($copied -eq 2) { $done += "first sign-in script and its list copied into the image ($imageScriptsDir)" }

            # The answer file that starts the script once goes into the image, not on the stick.
            $answerDest = Join-Path $mount $imageAnswer
            if (Test-Path -LiteralPath $answerDest -PathType Leaf) {
                if ((Get-Sha $answerDest) -eq (Get-Sha $fsAnswer)) { $skipped += "answer file in the image ($imageAnswer was already ours)" }
                else { $failed += "answer file: the image has its own $imageAnswer. It is not replaced, so Windows Setup will not start the first sign-in script by itself (start it by hand after the first sign-in)" }
            } else {
                $answerDir = Split-Path -Parent $answerDest
                if (-not (Test-Path -LiteralPath $answerDir)) { New-Item -ItemType Directory -Path $answerDir | Out-Null }
                Copy-Item -LiteralPath $fsAnswer -Destination $answerDest -Force
                if ((Get-Sha $answerDest) -eq (Get-Sha $fsAnswer)) { $done += "answer file put into the image ($imageAnswer): Windows Setup starts the first sign-in script once" }
                else { $failed += "answer file (the copy in the image differs)" }
            }
        }

        # --- what happened --------------------------------------------------------------------
        Say ("Changes made: {0}   skipped: {1}   failed: {2}" -f $done.Count, $skipped.Count, $failed.Count)
        foreach ($x in $done)    { Say "    done:    $x" }
        foreach ($x in $skipped) { Say "    skipped: $x" }
        foreach ($x in $failed)  { Say "    FAILED:  $x" }
        if ($done.Count -eq 0) { Stop-Run 'none of the listed changes could be made. The image copy is closed without saving and the stick is left as it was' }

        # --- the record of this run, inside the image -----------------------------------------
        if (-not (Test-Path -LiteralPath $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir | Out-Null }
        $record = @()
        $record += 'WHD USB Image - what was changed in this Windows image before it was installed.'
        $record += ('Written by Build-HomeUsbFromIso.ps1 on {0}, from the ISO file {1} (SHA-256 {2}).' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Split-Path -Leaf $iso), $isoSha)
        $record += 'WHD Classic and WHD Next do not know about these changes: their Undo and Verify do not cover them.'
        $record += ''
        foreach ($x in $done)    { $record += "done:    $x" }
        foreach ($x in $skipped) { $record += "skipped: $x" }
        foreach ($x in $failed)  { $record += "FAILED:  $x" }
        Set-Content -LiteralPath (Join-Path $scriptsDir 'WHD-Image-applied.txt') -Value $record -Encoding Ascii

        # --- save -----------------------------------------------------------------------------
        Say 'Saving the changed image (several minutes; much longer on a USB drive) ...'
        Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Commit') | Out-Null
        $mounted = $false
        if (-not (Test-HomeOnly $newWim)) { Stop-Run "install-custom.wim does not read as a single '$HomeName' image after saving" }
        Say ("install-custom.wim: {0}" -f (Fmt (Get-Item -LiteralPath $newWim).Length))

        # --- split ----------------------------------------------------------------------------
        if (Test-Path -LiteralPath $newDir) {
            $old = "usb-custom_old_$stamp"
            Say "Folder usb-custom exists from an earlier run. Renaming it to $old (nothing deleted)."
            Rename-Item -LiteralPath $newDir -NewName $old
        }
        New-Item -ItemType Directory -Path $newDir | Out-Null
        Invoke-Dism @('/Split-Image', "/ImageFile:$newWim", "/SWMFile:$(Join-Path $newDir 'install.swm')", '/FileSize:3800') | Out-Null
        $pieces = Get-Pieces $newDir
        if ($pieces.Count -eq 0) { Stop-Run "no pieces were written to $newDir" }
        foreach ($f in $pieces) {
            Say ("Piece: {0}  {1} bytes" -f $f.Name, $f.Length)
            if ($f.Length -ge 4GB) { Stop-Run "$($f.Name) is 4 GB or larger and cannot go on a FAT32 stick" }
        }
        if (-not (Test-HomeOnly (Join-Path $newDir 'install.swm'))) { Stop-Run "the pieces in $newDir are not a single '$HomeName' image" }

        if (-not $useStick) {
            if ($failed.Count -gt 0) {
                Say ("RESULT: DONE WITH {0} FAILED ITEM(S) - the changed '{1}' image is built ({2}); no stick was touched (-NoStick). See the FAILED lines above." -f $failed.Count, $HomeName, $newDir)
            } else {
                Say ("RESULT: DONE - the changed '{0}' image is built: {1} change(s) made, {2} skipped. The pieces are in {3}. No stick was touched (-NoStick)." -f $HomeName, $done.Count, $skipped.Count, $newDir)
            }
            Say 'NOTE: to put it on a stick, run again with -UsbDrive <letter> instead of -NoStick. install.wim is used again; the image is changed anew.'
        }
        else {
            # --- the stick: still the same one? does everything fit? ----------------------------
            $now = Get-StickInfo $UsbDrive
            if (($now.Number -ne $stick.Number) -or ($now.Size -ne $stick.Size) -or ($now.UniqueId -ne $stick.UniqueId) -or ($now.Serial -ne $stick.Serial)) {
                Stop-Run "drive ${UsbDrive}: is not the stick you confirmed at the start any more (another disk has that letter now). Nothing on any stick was changed. The image is built; run again"
            }
            Test-StickRules $now $UsbDrive $avoid
            $partBytes = $stick.Size
            if ($partBytes -gt 32GB) { $partBytes = $fatPartBytes }
            $needStick = $isoBytes + (Get-TotalSize $pieces) + 100MB
            if ($needStick -gt ($partBytes - 200MB)) {
                Stop-Run ("the stick is too small: the files need {0}, the stick gives {1}. The stick was not changed" -f (Fmt $needStick), (Fmt $partBytes))
            }

            # --- the stick: erase, one FAT32 partition ------------------------------------------
            Say ("Erasing disk {0} ('{1}') ..." -f $stick.Number, $stick.Name)
            Clear-Disk -Number $stick.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            $stickErased = $true
            if ("$((Get-Disk -Number $stick.Number).PartitionStyle)" -eq 'RAW') {
                Initialize-Disk -Number $stick.Number -PartitionStyle MBR -ErrorAction Stop
            }
            $style = "$((Get-Disk -Number $stick.Number).PartitionStyle)"
            if ($style -ne 'MBR') { Stop-Run "the erased stick has the partition style $style, not MBR. Format the stick once by hand (FAT32) and run again" }
            $newPart = $null
            if ($stick.Size -gt 32GB) {
                Say ("The stick is larger than 32 GB: one partition of {0} is made (Windows formats FAT32 only up to 32 GB); the rest stays unused." -f (Fmt $fatPartBytes))
                $newPart = New-Partition -DiskNumber $stick.Number -Size $fatPartBytes -IsActive -ErrorAction Stop
            } else {
                $newPart = New-Partition -DiskNumber $stick.Number -UseMaximumSize -IsActive -ErrorAction Stop
            }
            # Format first, then the letter: a partition that has a letter and no file system makes Windows
            # show its "You need to format the disk" window.
            $partNo = $newPart.PartitionNumber
            Say "Formatting the new partition as FAT32, label $stickLabel ..."
            Format-Volume -Partition (Get-Partition -DiskNumber $stick.Number -PartitionNumber $partNo -ErrorAction Stop) -FileSystem FAT32 -NewFileSystemLabel $stickLabel -Confirm:$false -ErrorAction Stop | Out-Null
            # Windows may have given the new partition a letter by itself. It should be the one from before.
            $cur = Get-LetterText (Get-Partition -DiskNumber $stick.Number -PartitionNumber $partNo -ErrorAction Stop).DriveLetter
            if ($cur -ne $UsbDrive) {
                $letterOk = $false
                try { Set-Partition -DiskNumber $stick.Number -PartitionNumber $partNo -NewDriveLetter $UsbDrive -ErrorAction Stop; $letterOk = $true } catch { }
                if (-not $letterOk) {
                    if (-not $cur) { Add-PartitionAccessPath -DiskNumber $stick.Number -PartitionNumber $partNo -AssignDriveLetter -ErrorAction Stop }
                    $got = Get-LetterText (Get-Partition -DiskNumber $stick.Number -PartitionNumber $partNo -ErrorAction Stop).DriveLetter
                    if (-not $got) { Stop-Run 'the new partition on the stick got no drive letter' }
                    Say "NOTE: the letter ${UsbDrive}: could not be given back to the stick. It is now ${got}:"
                    $UsbDrive = $got
                }
            }
            # The volume can need a moment before Windows shows it under its letter.
            for ($i = 0; $i -lt 10; $i++) { if (Test-Path -LiteralPath "${UsbDrive}:\") { break }; Start-Sleep -Seconds 1 }
            $stickRoot = "${UsbDrive}:\"
            $stickSrc  = "${UsbDrive}:\sources"
            $fmtVol = Get-Volume -DriveLetter $UsbDrive
            Say ("Stick {0}: {1}, size {2}, free {3}" -f $UsbDrive, $fmtVol.FileSystem, (Fmt $fmtVol.Size), (Fmt $fmtVol.SizeRemaining))
            if ("$($fmtVol.FileSystem)" -ne 'FAT32') { Stop-Run "the stick is not FAT32 after formatting (it is $($fmtVol.FileSystem))" }

            # --- the stick: the files of the ISO, then the pieces -------------------------------
            Say ("Copying {0} file(s) from the ISO to the stick, each one compared by checksum ..." -f $isoItems.Count)
            $count = 0
            foreach ($it in $isoItems) {
                Copy-IsoFile $it $stickRoot
                $count++
                if (($count % 200) -eq 0) { Say ("        {0} of {1}" -f $count, $isoItems.Count) }
            }
            Say ("    {0} file(s) copied, {1}, all checksums same." -f $count, (Fmt $isoBytes))
            if (-not (Test-Path -LiteralPath $stickSrc -PathType Container)) { Stop-Run "$stickSrc is missing after the copy" }
            $pieceSums = @()
            foreach ($f in $pieces) {
                $sum = Copy-Checked $f $stickSrc
                $pieceSums += ('piece: {0}|{1}|{2}' -f $f.Name, $f.Length, $sum)
            }
            $after = Get-UsbImageFiles $stickSrc
            if ((Get-SetKey $after) -ne (Get-SetKey $pieces)) { Stop-Run 'the install image files on the stick are not exactly the ones that were copied' }
            if (-not (Test-HomeOnly (Join-Path $stickSrc 'install.swm'))) { Stop-Run "the image on the stick does not read as a single '$HomeName' image" }
            foreach ($f in $after) { Say ("On the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }

            # --- the stick: the note that says what is on it ------------------------------------
            $mark = @()
            $mark += 'WHD USB Image - this stick holds the CHANGED Windows image made by Build-HomeUsbFromIso.ps1.'
            $mark += ('Written {0}. Edition: {1}. Changes made: {2}, skipped: {3}, failed: {4}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HomeName, $done.Count, $skipped.Count, $failed.Count)
            $mark += ('Made from the ISO file {0}, SHA-256 {1}.' -f (Split-Path -Leaf $iso), $isoSha)
            $mark += 'The scripts read this file to know what is on the stick. Windows Setup does not use it.'
            $mark += 'What was changed is written inside the image: Windows\Setup\Scripts\WHD-Image-applied.txt.'
            $mark += ''
            $mark += '# piece: file name|bytes|SHA-256'
            $mark += $pieceSums
            Set-Content -LiteralPath (Join-Path $stickRoot $stickMarkName) -Value $mark -Encoding Ascii
            Say "On the stick: the note $stickMarkName written on the root."
            $stickFinished = $true
            Say ("Stick free space at the end: {0}" -f (Fmt (Get-Volume -DriveLetter $UsbDrive).SizeRemaining))

            if ($failed.Count -gt 0) {
                Say ("RESULT: DONE WITH {0} FAILED ITEM(S) - the stick holds the changed '{1}' image; see the FAILED lines above." -f $failed.Count, $HomeName)
            } else {
                Say ("RESULT: DONE - the stick was made new from the ISO file and holds the changed '{0}' image: {1} change(s) made, {2} skipped." -f $HomeName, $done.Count, $skipped.Count)
            }
            Say 'NOTE: Windows may have answered part of the checksum check from memory. To be sure, eject the stick,'
            Say '      plug it in again and run this, which only reads and compares:'
            $extraNow = ($extra -replace ' -UsbDrive [A-Za-z]', " -UsbDrive $UsbDrive")
            Say "      powershell -ExecutionPolicy Bypass -File `"$(Join-Path $root 'Build-HomeUsbFromIso.ps1')`"$extraNow -CheckOnly"
        }
        if ($plan.PartFirstSignIn) {
            Say 'NOTE: at the first sign-in a PowerShell window opens and works for several minutes (the firewall part is slow).'
            Say '      Leave that window alone: do not close it and do not click in it. It closes by itself.'
            Say '      It writes C:\ProgramData\WHD-Image\FirstSignIn.log. If that file is not there after the install,'
            Say '      Setup did not start the script. Start it by hand then - after you have signed in with your own'
            Say '      account, not from a command window during setup - in an administrator PowerShell:'
            Say '      powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1'
        }
        $oldOnes = @(Get-ChildItem -LiteralPath $work | Where-Object { $_.Name -match '^(usb-custom_old_|install-custom_old_|install-partial_old_|install_old_)' })
        if ($oldOnes.Count -gt 0) {
            Say ("NOTE: the work folder holds {0} older work item(s) (names with _old_). This script never deletes them;" -f $oldOnes.Count)
            Say '      once the stick has installed Windows correctly you can delete them by hand to get the space back.'
        }
    }
}
catch {
    $exitCode = 1
    $err   = $_
    $msg   = $err.Exception.Message
    $isOwn = ($msg -match '^STOPPED')
    if (-not $isOwn) { $msg = "STOPPED - error: $msg" }
    # First put things back (close the image's registry, close the image copy without saving), then report.
    $swClosed = $true; $sysClosed = $true; $discardCode = -1
    if ($swLoaded)  { try { $swClosed  = Close-Hive $hiveSw }  catch { $swClosed  = $false } }
    if ($sysLoaded) { try { $sysClosed = Close-Hive $hiveSys } catch { $sysClosed = $false } }
    if ($mounted) {
        try { $discardCode = (Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Discard') -AllowFail).Code } catch { $discardCode = 1 }
    }
    try {
        Say "RESULT: $msg"
        if ((-not $isOwn) -and $err.InvocationInfo) { Say ("    at script line {0}" -f $err.InvocationInfo.ScriptLineNumber) }
        if ($swLoaded) {
            if ($swClosed) { Say "The image's registry (SOFTWARE) was closed." } else { Say "WARNING: the image's registry is still open. Close it by hand:  reg unload HKLM\$hiveSw" }
        }
        if ($sysLoaded) {
            if ($sysClosed) { Say "The image's registry (SYSTEM) was closed." } else { Say "WARNING: the image's registry is still open. Close it by hand:  reg unload HKLM\$hiveSys" }
        }
        if ($mounted) {
            if ($discardCode -eq 0) {
                Say 'The image copy was closed without saving.'
            } else {
                Say 'WARNING: the image copy is still open. Close it by hand:'
                Say ('  dism /Unmount-Image /MountDir:"{0}" /Discard' -f $mount)
            }
        }
        if ($stickErased -and (-not $stickFinished)) {
            Say 'State of the stick: it WAS ERASED and is not complete. It cannot install Windows until this script has run to its end again.'
        } elseif ((-not $NoStick) -and (-not $CheckOnly) -and (-not $stickErased)) {
            Say 'State of the stick: it was not changed.'
        }
    } catch {
        Write-Host "RESULT: $msg"
    }
}
# The ISO file is closed again when this run opened it.
if ($isoOpenedByUs) {
    try { Dismount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null; Say 'The ISO file was closed again.' }
    catch { Say "NOTE: the ISO file could not be closed. Close it by hand: right-click its drive in Explorer, Eject." }
}
Say '=== Build-HomeUsbFromIso ended ==='
exit $exitCode
