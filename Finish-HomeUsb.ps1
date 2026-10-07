#requires -Version 5.1
<#
  Finish-HomeUsb.ps1   (WHD USB Image)

  Puts the Home-only Windows install image on the USB stick and checks the copy.

  - Uses only Windows PowerShell and DISM as built into Windows. No downloads, no web calls.
  - Works only inside this folder and <stick>:\sources.
  - On the stick it touches only files named install*.swm / install*.wim / install*.esd.
    Such a file is removed from the stick only when a copy with the same name and the same
    size is kept in this folder. Any other one is moved into this folder, not deleted.
  - Nothing in this folder is deleted. The backup in "original" is only read.
  - Everything it does is written to Finish-HomeUsb.log in this folder.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\Finish-HomeUsb.ps1
#>
param(
    [string]$UsbDrive = 'F',
    [string]$HomeName = 'Windows 11 Home'
)

$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$log     = Join-Path $root 'Finish-HomeUsb.log'
$origDir = Join-Path $root 'original'
$newDir  = Join-Path $root 'usb'
$maxDir  = Join-Path $root 'usb-max'
$maxWim  = Join-Path $root 'install-max.wim'
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

function Test-KeptCopy($File) {
    foreach ($d in @($origDir, $newDir, $maxDir)) {
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

    if (-not (Test-Path -LiteralPath (Join-Path $origDir 'install.swm'))) {
        Stop-Run "the backup $origDir\install.swm is missing"
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
            Say "No pieces found in $newDir. Making an export with maximum compression."
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
