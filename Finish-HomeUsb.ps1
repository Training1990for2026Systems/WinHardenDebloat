#requires -Version 5.1
<#
  Finish-HomeUsb.ps1   (WHD USB Image)

  Puts the PLAIN Home-only Windows install image on the USB stick and checks the copy.
  "Plain" means: one edition, nothing taken out, nothing set. The changed image is made by
  Apply-HomeImage.ps1.

  - Uses only Windows PowerShell and DISM as built into Windows. No downloads, no web calls.
  - Works only inside this folder, <stick>:\sources, <stick>:\WHD-USB-Image.txt and
    <stick>:\Autounattend.xml.
  - On the stick it touches only files named install*.swm / install*.wim / install*.esd, the note
    WHD-USB-Image.txt that Apply-HomeImage.ps1 writes, and an Autounattend.xml that an earlier version
    of Apply-HomeImage.ps1 put on the root.
    An image file is removed from the stick only when a copy with the same name and the same
    size is kept in this folder. Any other one is moved into this folder, not deleted.
  - When the stick holds the CHANGED image from Apply-HomeImage.ps1, this script stops and says so.
    It knows that image by the note WHD-USB-Image.txt on the stick, by the pieces kept in usb-custom,
    or by an answer file of an earlier version. It replaces that image only when you add
    -ReplaceCustom. It then also takes the note and such an answer file off the stick (moved into
    this folder, not deleted): the plain image does not hold the first sign-in script.
  - The kept originals must be split pieces (original\install.swm, install2.swm, ...).
  - Nothing in this folder is deleted. The original pieces are only read.
  - Everything it does is written to Finish-HomeUsb.log in this folder.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\Finish-HomeUsb.ps1

  Switches:
    -UsbDrive F            the letter of the install stick
    -OriginalDir <folder>  where the kept original pieces are (install.swm, install2.swm, ...), when
                           they are not in "original" next to this script
    -ReplaceCustom         replace the changed image on the stick with the plain Home image
#>
param(
    [string]$UsbDrive = 'F',
    [string]$HomeName = 'Windows 11 Home',
    [string]$OriginalDir = '',
    [switch]$ReplaceCustom
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$log     = Join-Path $root 'Finish-HomeUsb.log'
$origDir = Join-Path $root 'original'
$newDir  = Join-Path $root 'usb'
$maxDir  = Join-Path $root 'usb-max'
$maxWim  = Join-Path $root 'install-max.wim'
$customDir  = Join-Path $root 'usb-custom'
$answerName = 'Autounattend.xml'
$stickMarkName = 'WHD-USB-Image.txt'
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$imagePattern = '^install\d*\.(swm|wim|esd)$'

function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    Add-Content -LiteralPath $log -Value $line -Encoding Ascii
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

function Fmt([double]$Bytes) {
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

function Invoke-Dism([string[]]$DismArgs) {
    Say ('dism ' + ($DismArgs -join ' '))
    $out  = & dism.exe @DismArgs
    $code = $LASTEXITCODE
    foreach ($l in $out) {
        $s = ([string]$l).Trim()
        # leave the progress bar lines out of the log
        if ($s -and ($s -notmatch '^\[[=\s]*\d')) { Say ('    ' + $s) }
    }
    if ($code -ne 0) { Stop-Run "DISM ended with code $code" }
    return ,@($out)
}

function Get-ImageNames([string]$File) {
    $out   = Invoke-Dism @('/English', '/Get-WimInfo', "/WimFile:$File")
    $names = @()
    foreach ($l in $out) {
        if (([string]$l) -match '^\s*Name\s*:\s*(.+?)\s*$') { $names += $Matches[1] }
    }
    return ,@($names)
}

function Get-Pieces([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return ,@() }
    return ,@(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -match '^install\d*\.swm$' } | Sort-Object Name)
}

function Get-UsbImageFiles([string]$Dir) {
    return ,@(Get-ChildItem -LiteralPath $Dir -File | Where-Object { $_.Name -match $imagePattern } | Sort-Object Name)
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

# The folders that can hold pieces of the changed image: usb-custom and the ones earlier runs renamed.
function Get-CustomDirs {
    $dirs = @($customDir)
    foreach ($o in @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $_.Name -like 'usb-custom_old_*' })) { $dirs += $o.FullName }
    return ,@($dirs)
}

# Is this file an answer file that a version of Apply-HomeImage.ps1 put on the stick? (it names the
# first sign-in script, or it has the same content as the one in the folder first-signin or as a copy
# kept with the pieces of the changed image)
function Test-OurAnswer([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
    try { if (Select-String -LiteralPath $File -Pattern 'WHD-FirstSignIn.ps1' -SimpleMatch -Quiet -ErrorAction Stop) { return $true } } catch { }
    $have = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
    $cands = @((Join-Path (Join-Path $root 'first-signin') $answerName))
    foreach ($d in (Get-CustomDirs)) { $cands += (Join-Path $d $answerName) }
    foreach ($c in $cands) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $c -Algorithm SHA256).Hash -eq $have) { return $true }
        }
    }
    return $false
}

function Test-KeptCopy($File) {
    $dirs = @($origDir, $newDir, $maxDir)
    $dirs += (Get-CustomDirs)
    foreach ($d in $dirs) {
        # A folder on the stick itself is never a kept copy.
        if ($d.Substring(0, 1) -ieq $UsbDrive) { continue }
        $p = Join-Path $d $File.Name
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p).Length -eq $File.Length) { return $true }
        }
    }
    return $false
}

function Test-HomeOnly([string]$FirstPiece) {
    $names = Get-ImageNames $FirstPiece
    return (($names.Count -eq 1) -and ($names[0] -eq $HomeName))
}

$exitCode = 0
$recopied = $false
try {
    Say '=== Finish-HomeUsb started ==='

    # --- checks before anything is changed -----------------------------------------------
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator'
    }

    $src = "${UsbDrive}:\sources"
    if (-not (Test-Path -LiteralPath (Join-Path $src 'boot.wim'))) {
        Stop-Run "$src\boot.wim not found - is the install stick in drive ${UsbDrive}: ?"
    }
    $vol = Get-Volume -DriveLetter $UsbDrive
    Say ("Stick {0}: label '{1}', {2}, {3}, size {4}, free {5}" -f $UsbDrive, $vol.FileSystemLabel, $vol.FileSystem, $vol.DriveType, (Fmt $vol.Size), (Fmt $vol.SizeRemaining))
    if ($vol.DriveType -ne 'Removable') { Stop-Run "drive ${UsbDrive}: is not a removable drive" }

    if ($OriginalDir) {
        if (-not (Test-Path -LiteralPath $OriginalDir -PathType Container)) { Stop-Run "the folder given with -OriginalDir does not exist: $OriginalDir" }
        $origDir = (Get-Item -LiteralPath $OriginalDir).FullName.TrimEnd('\')
    }
    foreach ($d in @($root, $origDir)) {
        if ($d.Substring(0, 1) -ieq $UsbDrive) { Stop-Run "$d is on the install stick itself. This folder and the kept original pieces must be on another drive: files on the stick are replaced by this script" }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $origDir 'install.swm'))) {
        Stop-Run "the kept original $origDir\install.swm is missing. Give its folder with -OriginalDir"
    }
    $pcLetter = $root.Substring(0, 1)
    $pcVol    = Get-Volume -DriveLetter $pcLetter
    Say ("This PC, drive {0}: free {1}" -f $pcLetter, (Fmt $pcVol.SizeRemaining))

    # --- what is on the stick now ---------------------------------------------------------
    $onUsb = Get-UsbImageFiles $src
    if ($onUsb.Count -eq 0) {
        Say 'Stick: no install image file in \sources.'
    } else {
        foreach ($f in $onUsb) { Say ("Stick has: {0}  {1} bytes" -f $f.Name, $f.Length) }
    }

    # --- is the changed image from Apply-HomeImage.ps1 on the stick? ----------------------
    # This script puts the PLAIN Home image on the stick. It must never do that in place of the
    # changed image without being told to.
    $stickAnswer  = "${UsbDrive}:\$answerName"
    $stickMark    = "${UsbDrive}:\$stickMarkName"
    $hasMark      = Test-Path -LiteralPath $stickMark -PathType Leaf
    $answerIsOurs = Test-OurAnswer $stickAnswer
    $holdsCustom  = $false
    $customFrom   = ''
    foreach ($d in (Get-CustomDirs)) {
        $set = Get-Pieces $d
        if (($set.Count -gt 0) -and ($onUsb.Count -gt 0) -and ((Get-SetKey $set) -eq (Get-SetKey $onUsb))) { $holdsCustom = $true; $customFrom = $d; break }
    }
    if ($hasMark) { Say "The stick has the note ${stickMarkName}: it holds the CHANGED image made by Apply-HomeImage.ps1." }
    if ($holdsCustom) { Say "The stick holds the CHANGED image made by Apply-HomeImage.ps1 (same names and sizes as the pieces in $customFrom)." }
    if ($answerIsOurs) { Say "The stick has the answer file of the first sign-in script ($stickAnswer)." }
    $isCustom = ($hasMark -or $holdsCustom -or $answerIsOurs)
    if ($isCustom -and (-not $ReplaceCustom)) {
        Stop-Run 'the stick is set up with the changed image from Apply-HomeImage.ps1. This script would put the PLAIN Home image in its place: no settings, no removals, no first sign-in script. Nothing was changed. If that is what you want, run this script again with -ReplaceCustom'
    }
    if ($isCustom) { Say 'Asked with -ReplaceCustom: the changed image on the stick is replaced with the plain Home image.' }

    $chosen      = $null
    $alreadyDone = $false
    foreach ($d in @($maxDir, $newDir)) {
        $set = Get-Pieces $d
        if (($set.Count -gt 0) -and ($onUsb.Count -gt 0) -and ((Get-SetKey $set) -eq (Get-SetKey $onUsb))) {
            $chosen      = $set
            $alreadyDone = $true
            Say "The stick already holds the pieces from $d (same names and sizes). No copy needed."
            break
        }
    }

    if (-not $alreadyDone) {
        # --- clear old image files off the stick (never without a kept copy) -------------
        foreach ($f in $onUsb) {
            if (Test-KeptCopy $f) {
                Say "Removing $($f.Name) from the stick (a copy with the same name and size is kept in this folder)."
                Remove-Item -LiteralPath $f.FullName -Force
            } else {
                $keep = Join-Path $root "from-usb_$stamp"
                if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
                Say "Moving $($f.Name) from the stick to $keep (no kept copy with that name and size)."
                Move-Item -LiteralPath $f.FullName -Destination $keep
            }
        }

        $free = (Get-Volume -DriveLetter $UsbDrive).SizeRemaining
        Say ("Stick free space now: {0}" -f (Fmt $free))
        $margin = 20MB

        # --- first choice: the Home-only pieces that already exist -----------------------
        $pieces = Get-Pieces $newDir
        if ($pieces.Count -gt 0) {
            $needNow = (Get-TotalSize $pieces) + $margin
            Say ("Existing Home-only pieces in 'usb': {0} file(s), {1}" -f $pieces.Count, (Fmt (Get-TotalSize $pieces)))
            if ($needNow -le $free) {
                if (-not (Test-HomeOnly (Join-Path $newDir 'install.swm'))) {
                    Stop-Run "the pieces in $newDir are not a single '$HomeName' image"
                }
                $chosen = $pieces
                Say 'They fit on the stick. Using them.'
            } else {
                Say 'They do NOT fit on the stick. Making a smaller export with maximum compression.'
            }
        } else {
            Say "No plain Home pieces are kept in $newDir. A new plain Home image is made from the original pieces now (maximum compression; this takes 15 minutes or more)."
        }

        # --- second choice: a new export with maximum compression ------------------------
        if ($null -eq $chosen) {
            $ready = Get-Pieces $maxDir
            $reuse = $false
            if (($ready.Count -gt 0) -and (Test-Path -LiteralPath $maxWim)) {
                $diff = [math]::Abs((Get-TotalSize $ready) - (Get-Item -LiteralPath $maxWim).Length)
                if (($diff -lt 50MB) -and (Test-HomeOnly (Join-Path $maxDir 'install.swm'))) { $reuse = $true }
            }

            if ($reuse) {
                Say "Pieces from an earlier run found in $maxDir. Using them."
            } else {
                if ($pcVol.SizeRemaining -lt 14GB) {
                    Stop-Run ("not enough free space on this PC for a new export (free {0}, wanted 14 GB)" -f (Fmt $pcVol.SizeRemaining))
                }

                if (Test-Path -LiteralPath $maxWim) {
                    $n = Get-ImageNames $maxWim
                    if (-not (($n.Count -eq 1) -and ($n[0] -eq $HomeName))) {
                        Stop-Run "$maxWim exists and is not a single '$HomeName' image - left untouched"
                    }
                    Say "$maxWim from an earlier run found (single '$HomeName' image). Using it."
                } else {
                    $origNames = Get-ImageNames (Join-Path $origDir 'install.swm')
                    $index = 0
                    for ($i = 0; $i -lt $origNames.Count; $i++) {
                        if ($origNames[$i] -eq $HomeName) { $index = $i + 1; break }
                    }
                    if ($index -eq 0) { Stop-Run "'$HomeName' not found in the original image" }
                    Say "'$HomeName' is index $index in the original image. Exporting (this takes a while)."
                    Invoke-Dism @(
                        '/Export-Image',
                        "/SourceImageFile:$(Join-Path $origDir 'install.swm')",
                        "/SWMFile:$(Join-Path $origDir 'install*.swm')",
                        "/SourceIndex:$index",
                        "/DestinationImageFile:$maxWim",
                        '/Compress:max', '/CheckIntegrity'
                    ) | Out-Null
                }
                Say ("install-max.wim: {0}" -f (Fmt (Get-Item -LiteralPath $maxWim).Length))

                if (Test-Path -LiteralPath $maxDir) {
                    $old = "usb-max_old_$stamp"
                    Say "Folder usb-max exists from an earlier run. Renaming it to $old (nothing deleted)."
                    Rename-Item -LiteralPath $maxDir -NewName $old
                }
                New-Item -ItemType Directory -Path $maxDir | Out-Null
                Invoke-Dism @(
                    '/Split-Image',
                    "/ImageFile:$maxWim",
                    "/SWMFile:$(Join-Path $maxDir 'install.swm')",
                    '/FileSize:3800'
                ) | Out-Null

                if (-not (Test-HomeOnly (Join-Path $maxDir 'install.swm'))) {
                    Stop-Run "the new pieces in $maxDir are not a single '$HomeName' image"
                }
            }

            $pieces  = Get-Pieces $maxDir
            $needNow = (Get-TotalSize $pieces) + $margin
            Say ("Maximum-compression pieces: {0} file(s), {1}" -f $pieces.Count, (Fmt (Get-TotalSize $pieces)))
            if ($needNow -gt $free) {
                Stop-Run ("the stick is too small: the Home-only image needs {0}, the stick has {1} free. The stick has no install image on it now; the original pieces are safe in $origDir" -f (Fmt $needNow), (Fmt $free))
            }
            $chosen = $pieces
        }

        # --- copy to the stick ------------------------------------------------------------
        foreach ($f in $chosen) {
            if ($f.Length -ge 4GB) {
                Stop-Run "$($f.Name) is 4 GB or larger and cannot go on a FAT32 stick"
            }
        }
        foreach ($f in $chosen) {
            Say ("Copying {0} ({1}) to {2} ..." -f $f.Name, (Fmt $f.Length), $src)
            Copy-Item -LiteralPath $f.FullName -Destination $src
        }
    }

    # --- check the copy ---------------------------------------------------------------------
    foreach ($f in $chosen) {
        $dest = Join-Path $src $f.Name
        if (-not (Test-Path -LiteralPath $dest)) { Stop-Run "$dest is missing after the copy" }
        if ((Get-Item -LiteralPath $dest).Length -ne $f.Length) { Stop-Run "$dest has a different size than the source" }
        Say "Comparing checksums for $($f.Name) ..."
        $h1 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($h1 -ne $h2) {
            Say "    DIFFERENT. folder:    $h1"
            Say "               stick:     $h2"
            Say '    Reading both files a second time to see which side is wrong ...'
            $h1b = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            if ($h1b -ne $h1) {
                Stop-Run "the source file $($f.FullName) reads differently each time - the problem is on this PC's drive, not on the stick. Nothing was changed on the stick"
            }
            $h2b = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            if ($h2b -ne $h2) {
                Say '    The stick gave different data on the second read: the stick or the USB port is unreliable.'
            } else {
                Say '    The stick gives the same wrong data each time: the copy on it is bad.'
            }
            Say "    Copying $($f.Name) to the stick again (the source in this folder is kept) ..."
            Copy-Item -LiteralPath $f.FullName -Destination $src -Force
            if ((Get-Item -LiteralPath $dest).Length -ne $f.Length) { Stop-Run "$dest has a different size than the source after the second copy" }
            $h3 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            if ($h3 -ne $h1) {
                Stop-Run "$dest still does not match its source after a second copy. The stick or the USB port is unreliable: try a USB port directly on the PC (no hub), or another stick"
            }
            Say '    The second copy matches.'
            $recopied = $true
        }
        Say "    same: $h1"
    }

    $after = Get-UsbImageFiles $src
    if ((Get-SetKey $after) -ne (Get-SetKey $chosen)) {
        Stop-Run 'the install image files on the stick are not exactly the ones that were copied'
    }
    $final = Get-ImageNames (Join-Path $src 'install.swm')
    if (-not (($final.Count -eq 1) -and ($final[0] -eq $HomeName))) {
        Stop-Run "the image on the stick does not read as a single '$HomeName' image"
    }

    foreach ($f in $after) { Say ("On the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }

    # --- the note of the changed image ----------------------------------------------------------
    # The stick holds the plain image now: the note would say something that is no longer true.
    if (Test-Path -LiteralPath $stickMark -PathType Leaf) {
        $keep = Join-Path $root "from-usb_$stamp"
        if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
        Say "Moving the note $stickMarkName from the stick to $keep (nothing deleted): the stick holds the plain image now."
        Move-Item -LiteralPath $stickMark -Destination $keep
    }

    # --- the answer file of the first sign-in script ------------------------------------------
    # The plain image does not hold that script. Left on the stick, the answer file would make the
    # first sign-in show an error about a script that is not there.
    if (Test-Path -LiteralPath $stickAnswer -PathType Leaf) {
        if ($answerIsOurs) {
            $keep = Join-Path $root "from-usb_$stamp"
            if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
            Say "Moving $answerName from the stick to $keep (nothing deleted): the plain image does not hold the first sign-in script."
            Move-Item -LiteralPath $stickAnswer -Destination $keep
        } else {
            Say "NOTE: the stick has an $answerName that is not from these scripts. It is left as it is; Windows Setup will use it."
        }
    }
    $cfg = Join-Path $src 'ei.cfg'
    if (Test-Path -LiteralPath $cfg) { Say 'ei.cfg is on the stick (left as it is).' } else { Say 'No ei.cfg on the stick.' }
    Say ("Stick free space at the end: {0}" -f (Fmt (Get-Volume -DriveLetter $UsbDrive).SizeRemaining))
    Say "RESULT: DONE - the stick holds one edition only: $HomeName. Copy checked by checksum."
    if ($recopied) {
        Say 'NOTE: a file was copied again in this run. Windows may have answered part of the last check from memory.'
        Say '      To be sure, eject the stick, plug it in again and run this script once more: it then only reads and compares.'
    }
}
catch {
    $exitCode = 1
    $err   = $_
    $msg   = $err.Exception.Message
    $isOwn = ($msg -match '^STOPPED')
    if (-not $isOwn) { $msg = "STOPPED - error: $msg" }
    try {
        Say "RESULT: $msg"
        if ((-not $isOwn) -and $err.InvocationInfo) { Say ("    at script line {0}" -f $err.InvocationInfo.ScriptLineNumber) }
        if (Test-Path -LiteralPath "${UsbDrive}:\sources") {
            $left = Get-UsbImageFiles "${UsbDrive}:\sources"
            if ($left.Count -eq 0) { Say 'State of the stick: no install image file in \sources.' }
            foreach ($f in $left) { Say ("State of the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }
        }
    } catch {
        Write-Host "RESULT: $msg"
    }
}
Say '=== Finish-HomeUsb ended ==='
exit $exitCode
