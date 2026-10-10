#requires -Version 5.1
<#
  Apply-HomeImage.ps1   (WHD USB Image)

  Takes the items named in remove-list.txt out of the Home-only install image, writes the settings
  named in image-settings.txt into it, and puts the result on the USB stick.

  What it does, in this order:
    0. When there is no original image yet (folder "original") and no install.wim, takes the image
       files from the stick into the folder "original" and compares checksums. The stick must be a
       fresh one from Microsoft's media creation tool: an image with more than one edition.
       -FromStick does the same when older originals are there (they are renamed, not deleted).
       When install.wim is missing, makes it from the original image. The originals are only read.
    1. Copies install.wim to install-custom.wim. install.wim itself is never changed.
    2. Opens the copy and
         - removes the listed bundled apps, switches the listed features off, removes the listed
           capabilities (remove-list.txt),
         - sets the listed services to "disabled" and writes the listed machine-wide registry values
           (remove-list.txt and image-settings.txt),
         - writes Windows' "deprovisioned" mark for every app it removed (part removed-app-marks),
         - copies the first sign-in script and its list into the image, and the answer file that
           starts the script once (Windows\Panther\unattend.xml) (part first-signin),
         - writes WHD-Image-applied.txt, the record of this run, into the image,
       and saves the copy.
    3. Splits the saved copy into pieces under 4 GB in the folder usb-custom.
    4. Replaces the install image files on the stick with those pieces and compares checksums.
    5. Writes WHD-USB-Image.txt on the root of the stick: the note that says the stick holds the changed
       image. Finish-HomeUsb.ps1 reads it. An Autounattend.xml of an earlier version of this script is
       moved off the stick: Windows Setup passed it over, the answer file is inside the image now.

  Rules it keeps:
    - Uses only Windows PowerShell, DISM and reg.exe as built into Windows. No downloads, no web calls.
    - Works only inside its work folder, <stick>:\sources, <stick>:\WHD-USB-Image.txt and
      <stick>:\Autounattend.xml.
      The work folder is the folder of this script, or the folder given with -WorkDir.
    - On the stick it touches only files named install*.swm / install*.wim / install*.esd in \sources,
      its own note WHD-USB-Image.txt, and an Autounattend.xml that an earlier version of this script
      put on the root. An image file is removed from the stick only when a copy with the same name and
      the same size is kept in the work folder; any other one is moved into the work folder, not
      deleted. An Autounattend.xml that is not from this script is left where it is.
    - Nothing in the work folder is deleted. Older work files are renamed, not removed.
    - The folder "original" is only read.
    - Everything is written to Apply-HomeImage.log in the folder of this script.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F

  Only compare the stick with the pieces in usb-custom (changes nothing):
    powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -UsbDrive F -CheckOnly

  Switches:
    -UsbDrive F          the letter of the install stick. It must be given: there is no default,
                         because the image files on that stick are replaced.
    -FromStick           take the image files that are on the stick as the new originals, also when
                         older ones are kept (those are renamed, not deleted). For a fresh stick from
                         the media creation tool.
    -KeepOriginal        build from the kept original although the stick holds a fresh image that is
                         not that original (the stick's image files are moved into the work folder).
                         Without -FromStick or -KeepOriginal the script stops in that case and asks.
    -WorkDir <folder>    where the work files go (install.wim, install-custom.wim, mount, usb-custom).
                         It must be on an NTFS drive: DISM cannot open an image on FAT32 or exFAT.
    -OriginalDir <folder> where the kept original pieces are (install.swm, install2.swm, ...), when
                         they are not in "original" in the work folder or next to this script.
#>
param(
    [string]$UsbDrive = '',
    [string]$HomeName = 'Windows 11 Home',
    [switch]$CheckOnly,
    [switch]$FromStick,
    [switch]$KeepOriginal,
    [string]$WorkDir = '',
    [string]$OriginalDir = ''
)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$log      = Join-Path $root 'Apply-HomeImage.log'
$listFile = Join-Path $root 'remove-list.txt'
$setFile  = Join-Path $root 'image-settings.txt'
$fsDir    = Join-Path $root 'first-signin'
$fsScript = Join-Path $fsDir 'WHD-FirstSignIn.ps1'
$fsList   = Join-Path $fsDir 'first-signin-list.txt'
$fsAnswer = Join-Path $fsDir 'Autounattend.xml'
# The name an earlier version of this script used for the answer file on the root of the stick.
$answerName = 'Autounattend.xml'
# Where the answer file goes inside the image. Microsoft Learn, "Replace the answer file in an offline
# image": Windows Setup finds and uses the file at this place.
$imageAnswer = 'Windows\Panther\unattend.xml'
# The note this script leaves on the root of the stick.
$stickMarkName = 'WHD-USB-Image.txt'
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$hiveSys  = 'WHDIMG'
$hiveSw   = 'WHDIMGSW'
$imagePattern = '^install\d*\.(swm|wim|esd)$'
# Where the first sign-in files and the record of this run go inside the image.
$imageScriptsDir = 'Windows\Setup\Scripts'
# Services this script refuses to switch off. With the WinHTTP proxy service disabled, Wi-Fi stayed
# "dormant" after a restart in WHD's own tests.
$neverOff = @('WinHttpAutoProxySvc')

# The work folder. Set for real in the main part, after the checks.
$work     = $root
$srcWim   = ''
$newWim   = ''
$origDir  = ''
$plainDir = ''
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

# The original image in a folder: split pieces (install.swm, install2.swm, ...), or one install.wim,
# or one install.esd. Returns First (the file DISM is pointed at), Kind and Files; $null when none is there.
function Get-OriginalSet([string]$Dir) {
    if ((-not $Dir) -or (-not (Test-Path -LiteralPath $Dir -PathType Container))) { return $null }
    foreach ($kind in @('swm', 'wim', 'esd')) {
        $first = Join-Path $Dir "install.$kind"
        if (Test-Path -LiteralPath $first -PathType Leaf) {
            $files = @()
            if ($kind -eq 'swm') { $files = Get-Pieces $Dir } else { $files = @(Get-Item -LiteralPath $first) }
            return (New-Object PSObject -Property @{ First = $first; Kind = $kind; Files = $files })
        }
    }
    return $null
}

# Is this an answer file that a version of this script put on the stick? (it names our script)
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

# Is a copy of this stick file (same name, same size) kept in the work folder? Looked for in the original
# pieces, in usb, in usb-custom and in the usb-custom folders that earlier runs renamed.
function Test-KeptCopy($File) {
    $dirs = @($origDir, $plainDir, $newDir)
    foreach ($o in @(Get-ChildItem -LiteralPath $work -Directory | Where-Object { $_.Name -like 'usb-custom_old_*' })) { $dirs += $o.FullName }
    foreach ($d in $dirs) {
        if (-not $d) { continue }
        # A folder on the stick itself is never a kept copy.
        if ($d.Substring(0, 1) -ieq $UsbDrive) { continue }
        $p = Join-Path $d $File.Name
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p).Length -eq $File.Length) { return $true }
        }
    }
    return $false
}

function Get-Sha([string]$File) {
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
}

# Copies one file and compares checksums; a second try when the copy differs. Returns the checksum.
# $Where is the text for the log: 'to the stick' or 'from the stick to the work folder'.
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

function Compare-Stick([string]$SourcesDir, $Pieces) {
    $onStick = Get-UsbImageFiles $SourcesDir
    if ((Get-SetKey $onStick) -ne (Get-SetKey $Pieces)) {
        Stop-Run 'the install image files on the stick are not the pieces from usb-custom (names or sizes differ)'
    }
    foreach ($f in $Pieces) {
        $dest = Join-Path $SourcesDir $f.Name
        Say "Comparing checksums for $($f.Name) ..."
        $h1 = Get-Sha $f.FullName
        $h2 = Get-Sha $dest
        if ($h1 -ne $h2) { Stop-Run "$dest does not match its source (checksum differs)" }
        Say "    same: $h1"
    }
    if (-not (Test-HomeOnly (Join-Path $SourcesDir 'install.swm'))) {
        Stop-Run "the image on the stick does not read as a single '$HomeName' image"
    }
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

$mounted    = $false
$sysLoaded  = $false
$swLoaded   = $false
$mount      = ''
$exitCode   = 0
$done       = @()
$skipped    = @()
$failed     = @()

try {
    Say '=== Apply-HomeImage started ==='

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator'
    }

    if ($UsbDrive -notmatch '^[A-Za-z]$') { Stop-Run "give the letter of the install stick with -UsbDrive (one letter, for example: -UsbDrive F). There is no default, because the image files on that stick are replaced (it is '$UsbDrive'). Nothing was changed" }
    $UsbDrive = $UsbDrive.ToUpperInvariant()
    $src = "${UsbDrive}:\sources"
    if (-not (Test-Path -LiteralPath (Join-Path $src 'boot.wim'))) {
        Stop-Run "$src\boot.wim not found - is the install stick in drive ${UsbDrive}: ?"
    }
    $vol = Get-Volume -DriveLetter $UsbDrive
    Say ("Stick {0}: label '{1}', {2}, size {3}, free {4}" -f $UsbDrive, $vol.FileSystemLabel, $vol.DriveType, (Fmt $vol.Size), (Fmt $vol.SizeRemaining))
    if ($vol.DriveType -ne 'Removable') { Stop-Run "drive ${UsbDrive}: is not a removable drive" }
    $stickAnswer = "${UsbDrive}:\$answerName"
    $stickMark   = "${UsbDrive}:\$stickMarkName"

    # --- the work folder ----------------------------------------------------------------------
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Stop-Run "the work folder $WorkDir does not exist. Make it first, or leave -WorkDir out" }
        $work = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd('\')
    }
    if ($work -notmatch '^[A-Za-z]:\\.+') { Stop-Run "the work folder must be a folder on a drive with a letter, not the top of a drive and not a network path (it is $work)" }
    $srcWim   = Join-Path $work 'install.wim'
    $newWim   = Join-Path $work 'install-custom.wim'
    $plainDir = Join-Path $work 'usb'
    $newDir   = Join-Path $work 'usb-custom'
    if ($OriginalDir) {
        if (-not (Test-Path -LiteralPath $OriginalDir -PathType Container)) { Stop-Run "the folder given with -OriginalDir does not exist: $OriginalDir" }
        $origDir = (Get-Item -LiteralPath $OriginalDir).FullName.TrimEnd('\')
    }
    elseif ($FromStick -or ($null -ne (Get-OriginalSet (Join-Path $work 'original'))) -or ($null -eq (Get-OriginalSet (Join-Path $root 'original')))) { $origDir = Join-Path $work 'original' }
    else { $origDir = Join-Path $root 'original' }
    Say "Work folder: $work"
    Say "Original image: $origDir"
    if ($origDir -notmatch '^[A-Za-z]:\\.+') { Stop-Run "the folder of the original image must be a folder on a drive with a letter (it is $origDir)" }
    if ($FromStick -and $OriginalDir) { Stop-Run '-FromStick and -OriginalDir cannot be used together: -FromStick takes the originals from the stick into the folder "original" of the work folder' }
    if ($FromStick -and $CheckOnly) { Stop-Run '-FromStick and -CheckOnly cannot be used together: -CheckOnly changes nothing' }
    if ($FromStick -and $KeepOriginal) { Stop-Run '-FromStick and -KeepOriginal cannot be used together: one builds from the stick, the other from the kept original' }
    foreach ($d in @($work, $origDir)) {
        if ($d.Substring(0, 1) -ieq $UsbDrive) { Stop-Run "$d is on the install stick itself. The work folder and the kept original pieces must be on another drive: files on the stick are replaced by this script" }
    }
    # The same switches again, for the command lines this run prints at its end.
    $extra = " -UsbDrive $UsbDrive"
    if ($work -ne $root) { $extra += " -WorkDir `"$work`"" }
    if ($OriginalDir) { $extra += " -OriginalDir `"$origDir`"" }

    # ------------------------------------------------------------------------------------------
    # -CheckOnly: compare the stick with usb-custom and end
    # ------------------------------------------------------------------------------------------
    if ($CheckOnly) {
        $pieces = Get-Pieces $newDir
        if ($pieces.Count -eq 0) { Stop-Run "no pieces found in $newDir" }
        Compare-Stick $src $pieces
        if (Test-Path -LiteralPath $stickMark -PathType Leaf) { Say "    the note $stickMarkName is on the stick." }
        else { Say "NOTE: the note $stickMarkName is not on the stick (the pieces were put there by an earlier version of this script, or the note was deleted). Finish-HomeUsb.ps1 knows the changed image by that note; the next full run writes it." }
        if (Test-Path -LiteralPath $stickAnswer -PathType Leaf) {
            if (Test-OurStickAnswer $stickAnswer) { Say "NOTE: the stick has an $answerName of an earlier version of this script. Windows Setup passed that file over in WHD's test. The next full run moves it off the stick; the answer file is inside the image now." }
            else { Say "NOTE: the stick has an $answerName that is not from this script. It is left as it is." }
        }
        Say "RESULT: DONE - check only. The stick matches the pieces in usb-custom and reads as one image: $HomeName."
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
        # --- where the original image comes from ----------------------------------------------
        $haveWim    = Test-Path -LiteralPath $srcWim
        $orig       = Get-OriginalSet $origDir
        $stickFiles = Get-UsbImageFiles $src
        $take       = $false
        if ($FromStick) {
            $take = $true
            Say 'Asked with -FromStick: the image files on the stick are taken as the new originals.'
        } elseif (($null -eq $orig) -and (-not $haveWim)) {
            $take = $true
            Say "No original image in $origDir and no install.wim in the work folder: the image files on the stick are taken as the originals."
        }
        if ($take) {
            $stickFirst = ''
            foreach ($kind in @('swm', 'wim', 'esd')) {
                if ((-not $stickFirst) -and (Test-Path -LiteralPath (Join-Path $src "install.$kind") -PathType Leaf)) { $stickFirst = Join-Path $src "install.$kind" }
            }
            if (-not $stickFirst) { Stop-Run "there is no install.swm, install.wim or install.esd in $src to take as the original. Nothing was changed" }
            # Never take our own result as an original: the changes would be made a second time on top.
            $ownPieces = Get-Pieces $newDir
            if (Test-Path -LiteralPath $stickMark -PathType Leaf) {
                Stop-Run "the stick holds the CHANGED image this script made (the note $stickMarkName is on it). It cannot serve as the original. Make a fresh stick with Microsoft's media creation tool, or give kept originals with -OriginalDir. Nothing was changed"
            }
            if (($ownPieces.Count -gt 0) -and ((Get-SetKey $ownPieces) -eq (Get-SetKey $stickFiles))) {
                Stop-Run "the stick holds the pieces from $newDir - the CHANGED image this script made. It cannot serve as the original. Make a fresh stick with Microsoft's media creation tool, or give kept originals with -OriginalDir. Nothing was changed"
            }
            $stickNames = Get-ImageNames $stickFirst
            foreach ($n in $stickNames) { Say "    on the stick: $n" }
            if ($stickNames -notcontains $HomeName) { Stop-Run "the image on the stick has no edition named '$HomeName'. Nothing was changed" }
            if ($stickNames.Count -lt 2) {
                Stop-Run "the image on the stick holds one edition only. A fresh stick from the media creation tool holds several; a single one is what this script's own results look like, so it is not taken. If it is a plain image that you want to use, copy the image files from $src into the folder $(Join-Path $work 'original') by hand and run again. Nothing was changed"
            }
        } elseif ((-not $KeepOriginal) -and ($stickFiles.Count -gt 0) -and (-not (Test-Path -LiteralPath $stickMark -PathType Leaf))) {
            # A stick with image files that are neither our pieces nor the kept original may be a fresh one.
            # Building from the older original without a word is not what its owner expects: stop and ask.
            $unknown = @($stickFiles | Where-Object { -not (Test-KeptCopy $_) })
            $stickFirst = ''
            foreach ($kind in @('swm', 'wim', 'esd')) {
                if ((-not $stickFirst) -and (Test-Path -LiteralPath (Join-Path $src "install.$kind") -PathType Leaf)) { $stickFirst = Join-Path $src "install.$kind" }
            }
            if (($unknown.Count -gt 0) -and $stickFirst) {
                $stickNames = Get-ImageNames $stickFirst
                if ($stickNames.Count -ge 2) {
                    Stop-Run ("the stick holds an image with {0} editions that is not the kept original - it looks like a fresh stick. Nothing was changed. Run again with -FromStick to build from the stick's image (the older original is renamed, not deleted), or with -KeepOriginal to build from the kept original (the stick's image files are then moved into the work folder)" -f $stickNames.Count)
                }
            }
        }
        $pcLetter = $work.Substring(0, 1)
        $pcFormat = Get-DriveFormat $pcLetter
        $pcVol    = Get-Volume -DriveLetter $pcLetter
        Say ("Work drive {0}: {1}, free {2}" -f $pcLetter, $pcFormat, (Fmt $pcVol.SizeRemaining))
        if ($pcFormat -ne 'NTFS') {
            Stop-Run "the work folder is on a drive with the $pcFormat file system. DISM can only open an image in a folder on an NTFS drive. Run again with -WorkDir and a folder on an NTFS drive, for example: -WorkDir C:\WHD-Image-work (make the folder first)"
        }
        $needFree = 20GB
        if ($take) { $needFree += 2.3 * (Get-TotalSize $stickFiles) }
        elseif (-not $haveWim) { $needFree += 1.3 * (Get-TotalSize $orig.Files) }
        # Image files on the stick that have no kept copy are moved into the work folder, not deleted.
        if (-not $take) { foreach ($f in $stickFiles) { if (-not (Test-KeptCopy $f)) { $needFree += $f.Length } } }
        if ($pcVol.SizeRemaining -lt $needFree) {
            Stop-Run ("less than {0} free on drive {1}: (free: {2}). Run again with -WorkDir and a folder on a drive with more room" -f (Fmt $needFree), $pcLetter, (Fmt $pcVol.SizeRemaining))
        }
        if ($pcVol.SizeRemaining -lt ($needFree + 20GB)) {
            Say 'NOTE: free space is tight. If DISM stops for lack of space, nothing is saved and the stick is left as it was; run again with -WorkDir on a drive with more room.'
        }

        foreach ($h in @($hiveSys, $hiveSw)) {
            $probe = Invoke-Reg @('query', "HKLM\$h", '/ve')
            if ($probe.Code -eq 0) { Stop-Run "the registry name HKLM\$h is already in use - an earlier run did not close the image's registry. Close it by hand:  reg unload HKLM\$h" }
        }

        # --- step 0a: take the original image from the stick ----------------------------------
        if ($take) {
            $takeDir = Join-Path $work 'original'
            # What was made from older originals is renamed, so that nothing old is mixed with the new.
            foreach ($oldName in @('original', 'usb', 'usb-max')) {
                $oldPath = Join-Path $work $oldName
                if ((Test-Path -LiteralPath $oldPath -PathType Container) -and (@(Get-ChildItem -LiteralPath $oldPath -Force).Count -gt 0)) {
                    Say "Folder $oldName holds files from an earlier original. Renaming it to ${oldName}_old_$stamp (nothing deleted)."
                    Rename-Item -LiteralPath $oldPath -NewName "${oldName}_old_$stamp"
                }
            }
            foreach ($oldName in @('install', 'install-max')) {
                $oldPath = Join-Path $work "$oldName.wim"
                if (Test-Path -LiteralPath $oldPath -PathType Leaf) {
                    Say "$oldName.wim was made from an earlier original. Renaming it to ${oldName}_old_$stamp.wim (nothing deleted)."
                    Rename-Item -LiteralPath $oldPath -NewName "${oldName}_old_$stamp.wim"
                }
            }
            $haveWim = $false
            if (-not (Test-Path -LiteralPath $takeDir)) { New-Item -ItemType Directory -Path $takeDir | Out-Null }
            foreach ($f in $stickFiles) { Copy-Checked $f $takeDir 'from the stick to the work folder' | Out-Null }
            $origDir = $takeDir
            $orig    = Get-OriginalSet $origDir
            if ($null -eq $orig) { Stop-Run "the original image is not in $origDir after the copy from the stick" }
            Say ("Original image taken from the stick: {0} file(s), {1}, checksums same. The stick's files are unchanged so far." -f $orig.Files.Count, (Fmt (Get-TotalSize $orig.Files)))
        }

        # --- step 0: install.wim from the original image, when it is missing ------------------
        if (-not $haveWim) {
            Say 'install.wim is not in the work folder. Making it from the original image (it is only read).'
            $firstPiece = $orig.First
            $images     = Get-ImageList $firstPiece
            foreach ($i in $images) { Say ("    in the original: index {0} = {1}" -f $i.Index, $i.Name) }
            $homeImg = @($images | Where-Object { $_.Name -eq $HomeName })
            if ($homeImg.Count -ne 1) { Stop-Run "the original image does not hold exactly one edition named '$HomeName'" }
            if ($homeImg[0].Index -lt 1) { Stop-Run "the index of '$HomeName' could not be read from DISM's answer" }
            $partial = Join-Path $work 'install-partial.wim'
            if (Test-Path -LiteralPath $partial) {
                Say "A half-made export from an earlier run is renamed to install-partial_old_$stamp.wim (nothing deleted)."
                Rename-Item -LiteralPath $partial -NewName "install-partial_old_$stamp.wim"
            }
            Say 'Exporting the Home image with maximum compression (this can take 15 minutes or more) ...'
            $exportArgs = @('/Export-Image', "/SourceImageFile:$firstPiece")
            if ($orig.Kind -eq 'swm') { $exportArgs += "/SWMFile:$(Join-Path $origDir 'install*.swm')" }
            $exportArgs += @("/SourceIndex:$($homeImg[0].Index)", "/DestinationImageFile:$partial", '/Compress:max', '/CheckIntegrity')
            Invoke-Dism $exportArgs | Out-Null
            if (-not (Test-HomeOnly $partial)) { Stop-Run "the export does not read as a single '$HomeName' image. It is kept as $partial" }
            Rename-Item -LiteralPath $partial -NewName 'install.wim'
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
            Stop-Run "install.wim holds an image that this script changed before (the record $imageScriptsDir\WHD-Image-applied.txt is in it). A fresh image is needed: rename install.wim away and give fresh originals (-OriginalDir, or a fresh stick with -FromStick). The image copy is closed without saving and the stick is left as it was"
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
        $record += ('Written by Apply-HomeImage.ps1 on {0}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
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

        # --- stick: room, clear, copy, check --------------------------------------------------
        $onUsb = Get-UsbImageFiles $src
        $free  = (Get-Volume -DriveLetter $UsbDrive).SizeRemaining
        $need  = (Get-TotalSize $pieces) + 20MB
        if ($need -gt ($free + (Get-TotalSize $onUsb))) {
            Stop-Run ("the stick is too small for the new image (needs {0}). The stick is left as it was" -f (Fmt $need))
        }
        foreach ($f in $onUsb) {
            if (Test-KeptCopy $f) {
                Say "Removing $($f.Name) ($($f.Length) bytes) from the stick (a copy with the same name and size is kept on this PC)."
                Remove-Item -LiteralPath $f.FullName -Force
            } else {
                $keep = Join-Path $work "from-usb_$stamp"
                if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
                Say "Moving $($f.Name) from the stick to $keep (no kept copy with that name and size)."
                Move-Item -LiteralPath $f.FullName -Destination $keep
            }
        }
        # The note of an earlier run describes pieces that are gone now.
        if (Test-Path -LiteralPath $stickMark -PathType Leaf) { Remove-Item -LiteralPath $stickMark -Force }
        $pieceSums = @()
        foreach ($f in $pieces) {
            $sum = Copy-Checked $f $src
            $pieceSums += ('piece: {0}|{1}|{2}' -f $f.Name, $f.Length, $sum)
        }

        $after = Get-UsbImageFiles $src
        if ((Get-SetKey $after) -ne (Get-SetKey $pieces)) { Stop-Run 'the install image files on the stick are not exactly the ones that were copied' }
        if (-not (Test-HomeOnly (Join-Path $src 'install.swm'))) { Stop-Run "the image on the stick does not read as a single '$HomeName' image" }
        foreach ($f in $after) { Say ("On the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }

        # --- stick: the note that says what is on it ------------------------------------------
        $mark = @()
        $mark += 'WHD USB Image - this stick holds the CHANGED Windows image made by Apply-HomeImage.ps1.'
        $mark += ('Written {0}. Edition: {1}. Changes made: {2}, skipped: {3}, failed: {4}.' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HomeName, $done.Count, $skipped.Count, $failed.Count)
        $mark += 'The scripts read this file to know what is on the stick. Windows Setup does not use it.'
        $mark += 'What was changed is written inside the image: Windows\Setup\Scripts\WHD-Image-applied.txt.'
        $mark += ''
        $mark += '# piece: file name|bytes|SHA-256'
        $mark += $pieceSums
        Set-Content -LiteralPath $stickMark -Value $mark -Encoding Ascii
        Say "On the stick: the note $stickMarkName written on the root."

        # --- stick: an answer file on the root ------------------------------------------------
        # This script no longer puts one there: Windows Setup passed it over in WHD's test of 2026-10-08.
        if (Test-Path -LiteralPath $stickAnswer -PathType Leaf) {
            if (Test-OurStickAnswer $stickAnswer) {
                $keep = Join-Path $work "from-usb_$stamp"
                if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
                Say "Moving the $answerName of an earlier version of this script from the stick to $keep (nothing deleted). The answer file is inside the image now."
                Move-Item -LiteralPath $stickAnswer -Destination $keep
            } else {
                Say "NOTE: the stick has an $answerName that is not from this script. It is left as it is; Windows Setup may use it."
            }
        }
        Say ("Stick free space at the end: {0}" -f (Fmt (Get-Volume -DriveLetter $UsbDrive).SizeRemaining))

        if ($failed.Count -gt 0) {
            Say ("RESULT: DONE WITH {0} FAILED ITEM(S) - the stick holds the changed '{1}' image; see the FAILED lines above." -f $failed.Count, $HomeName)
        } else {
            Say ("RESULT: DONE - the stick holds the changed '{0}' image: {1} change(s) made, {2} skipped." -f $HomeName, $done.Count, $skipped.Count)
        }
        Say 'NOTE: Windows may have answered part of the checksum check from memory. To be sure, eject the stick,'
        Say '      plug it in again and run this, which only reads and compares:'
        Say "      powershell -ExecutionPolicy Bypass -File `"$(Join-Path $root 'Apply-HomeImage.ps1')`"$extra -CheckOnly"
        if ($plan.PartFirstSignIn) {
            Say 'NOTE: at the first sign-in a PowerShell window opens and works for several minutes (the firewall part is slow).'
            Say '      Leave that window alone: do not close it and do not click in it. It closes by itself.'
            Say '      It writes C:\ProgramData\WHD-Image\FirstSignIn.log. If that file is not there after the install,'
            Say '      Setup did not start the script. Start it by hand then - after you have signed in with your own'
            Say '      account, not from a command window during setup - in an administrator PowerShell:'
            Say '      powershell -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\WHD-FirstSignIn.ps1'
        }
        $oldOnes = @(Get-ChildItem -LiteralPath $work | Where-Object { $_.Name -match '^(usb-custom_old_|install-custom_old_|from-usb_|install-partial_old_|original_old_|usb_old_|usb-max_old_|install_old_|install-max_old_)' })
        if ($oldOnes.Count -gt 0) {
            Say ("NOTE: the work folder holds {0} older work item(s) (names with _old_, and from-usb_*). This script never deletes them;" -f $oldOnes.Count)
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
        if (($UsbDrive -match '^[A-Za-z]$') -and (Test-Path -LiteralPath "${UsbDrive}:\sources")) {
            $left = Get-UsbImageFiles "${UsbDrive}:\sources"
            if ($left.Count -eq 0) { Say 'State of the stick: no install image file in \sources. Until this script has run to its end again, the stick cannot install Windows.' }
            foreach ($f in $left) { Say ("State of the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }
        }
    } catch {
        Write-Host "RESULT: $msg"
    }
}
Say '=== Apply-HomeImage ended ==='
exit $exitCode
