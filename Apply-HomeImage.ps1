#requires -Version 5.1
<#
  Apply-HomeImage.ps1   (WHD USB Image)

  Takes the items named in remove-list.txt out of the Home-only install image and puts the
  result on the USB stick.

  What it does, in this order:
    1. Copies install.wim to install-custom.wim. install.wim itself is never changed.
    2. Opens the copy, removes the listed bundled apps, switches the listed features off,
       sets the listed services to "disabled" in the image's registry, and saves the copy.
    3. Splits the saved copy into pieces under 4 GB in the folder usb-custom.
    4. Replaces the install image files on the stick with those pieces and compares checksums.

  Rules it keeps:
    - Uses only Windows PowerShell, DISM and reg.exe as built into Windows. No downloads, no web calls.
    - Works only inside this folder and <stick>:\sources.
    - On the stick it touches only files named install*.swm / install*.wim / install*.esd.
      Such a file is removed from the stick only when a copy with the same name and the same
      size is kept in this folder. Any other one is moved into this folder, not deleted.
    - Nothing in this folder is deleted. Older work files are renamed, not removed.
    - Everything is written to Apply-HomeImage.log in this folder.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1

  Only compare the stick with the pieces in usb-custom (changes nothing):
    powershell -ExecutionPolicy Bypass -File .\Apply-HomeImage.ps1 -CheckOnly
#>
param(
    [string]$UsbDrive = 'F',
    [string]$HomeName = 'Windows 11 Home',
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

$root     = $PSScriptRoot
$log      = Join-Path $root 'Apply-HomeImage.log'
$listFile = Join-Path $root 'remove-list.txt'
$srcWim   = Join-Path $root 'install.wim'
$newWim   = Join-Path $root 'install-custom.wim'
$origDir  = Join-Path $root 'original'
$plainDir = Join-Path $root 'usb'
$newDir   = Join-Path $root 'usb-custom'
$stamp    = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$hiveName = 'WHDIMG'
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

function Invoke-Reg([string[]]$RegArgs) {
    $out  = & reg.exe @RegArgs
    $code = $LASTEXITCODE
    return (New-Object PSObject -Property @{ Code = $code; Out = @($out) })
}

function Close-Hive {
    for ($i = 0; $i -lt 5; $i++) {
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $r = Invoke-Reg @('unload', "HKLM\$hiveName")
        if ($r.Code -eq 0) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Get-ImageNames([string]$File) {
    $r     = Invoke-Dism @('/English', '/Get-WimInfo', "/WimFile:$File")
    $names = @()
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*Name\s*:\s*(.+?)\s*$') { $names += $Matches[1] }
    }
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
    foreach ($d in @($origDir, $plainDir, $newDir)) {
        $p = Join-Path $d $File.Name
        if (Test-Path -LiteralPath $p) {
            if ((Get-Item -LiteralPath $p).Length -eq $File.Length) { return $true }
        }
    }
    return $false
}

function Copy-Checked($File, [string]$DestDir) {
    $dest = Join-Path $DestDir $File.Name
    $h1   = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash
    for ($try = 1; $try -le 2; $try++) {
        Say ("Copying {0} ({1}) to the stick, attempt {2} ..." -f $File.Name, (Fmt $File.Length), $try)
        Copy-Item -LiteralPath $File.FullName -Destination $DestDir -Force
        if ((Get-Item -LiteralPath $dest).Length -eq $File.Length) {
            $h2 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
            if ($h2 -eq $h1) {
                Say "    checksum same: $h1"
                return
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
        $h1 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
        $h2 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        if ($h1 -ne $h2) { Stop-Run "$dest does not match its source (checksum differs)" }
        Say "    same: $h1"
    }
    if (-not (Test-HomeOnly (Join-Path $SourcesDir 'install.swm'))) {
        Stop-Run "the image on the stick does not read as a single '$HomeName' image"
    }
}

$mounted    = $false
$hiveLoaded = $false
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

    $src = "${UsbDrive}:\sources"
    if (-not (Test-Path -LiteralPath (Join-Path $src 'boot.wim'))) {
        Stop-Run "$src\boot.wim not found - is the install stick in drive ${UsbDrive}: ?"
    }
    $vol = Get-Volume -DriveLetter $UsbDrive
    Say ("Stick {0}: label '{1}', {2}, size {3}, free {4}" -f $UsbDrive, $vol.FileSystemLabel, $vol.DriveType, (Fmt $vol.Size), (Fmt $vol.SizeRemaining))
    if ($vol.DriveType -ne 'Removable') { Stop-Run "drive ${UsbDrive}: is not a removable drive" }

    # ------------------------------------------------------------------------------------------
    # -CheckOnly: compare the stick with usb-custom and end
    # ------------------------------------------------------------------------------------------
    if ($CheckOnly) {
        $pieces = Get-Pieces $newDir
        if ($pieces.Count -eq 0) { Stop-Run "no pieces found in $newDir" }
        Compare-Stick $src $pieces
        Say "RESULT: DONE - check only. The stick matches the pieces in usb-custom and reads as one image: $HomeName."
    }
    else {
        # --- read the list --------------------------------------------------------------------
        if (-not (Test-Path -LiteralPath $listFile)) { Stop-Run "$listFile not found" }
        $apps = @(); $features = @(); $services = @()
        foreach ($raw in (Get-Content -LiteralPath $listFile)) {
            $t = ([string]$raw).Trim()
            if ((-not $t) -or $t.StartsWith('#')) { continue }
            if ($t -match '^app:([A-Za-z0-9._-]+)$') { $apps += $Matches[1] }
            elseif ($t -match '^feature:([A-Za-z0-9._-]+)$') { $features += $Matches[1] }
            elseif ($t -match '^service-off:([A-Za-z0-9._-]+)$') { $services += $Matches[1] }
            else { Stop-Run "remove-list.txt has a line that is not understood: $t" }
        }
        Say ("List: {0} app(s), {1} feature(s), {2} service(s)" -f $apps.Count, $features.Count, $services.Count)
        if (($apps.Count + $features.Count + $services.Count) -eq 0) { Stop-Run 'remove-list.txt names nothing' }

        # --- checks before anything is changed ------------------------------------------------
        if (-not (Test-Path -LiteralPath $srcWim)) { Stop-Run "$srcWim not found" }
        if (-not (Test-HomeOnly $srcWim)) { Stop-Run "install.wim is not a single '$HomeName' image" }
        if (-not (Test-Path -LiteralPath (Join-Path $origDir 'install.swm'))) {
            Stop-Run "the backup $origDir\install.swm is missing"
        }
        $pcLetter = $root.Substring(0, 1)
        $pcVol    = Get-Volume -DriveLetter $pcLetter
        Say ("This PC, drive {0}: free {1}" -f $pcLetter, (Fmt $pcVol.SizeRemaining))
        if ($pcVol.SizeRemaining -lt 20GB) { Stop-Run 'less than 20 GB free on this PC' }

        $probe = Invoke-Reg @('query', "HKLM\$hiveName", '/ve')
        if ($probe.Code -eq 0) { Stop-Run "the registry name HKLM\$hiveName is already in use - an earlier run did not close the image's registry" }

        # --- work copy ------------------------------------------------------------------------
        if (Test-Path -LiteralPath $newWim) {
            $old = "install-custom_old_$stamp.wim"
            Say "install-custom.wim exists from an earlier run. Renaming it to $old (nothing deleted)."
            Rename-Item -LiteralPath $newWim -NewName $old
        }
        Say ("Copying install.wim ({0}) to install-custom.wim ..." -f (Fmt (Get-Item -LiteralPath $srcWim).Length))
        Copy-Item -LiteralPath $srcWim -Destination $newWim

        $mount = Join-Path $root 'mount'
        if (Test-Path -LiteralPath $mount) {
            if (@(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
                $mount = Join-Path $root "mount_$stamp"
                New-Item -ItemType Directory -Path $mount | Out-Null
            }
        } else {
            New-Item -ItemType Directory -Path $mount | Out-Null
        }

        Say 'Opening install-custom.wim (a few minutes) ...'
        Invoke-Dism @('/Mount-Image', "/ImageFile:$newWim", '/Index:1', "/MountDir:$mount") | Out-Null
        $mounted = $true

        # --- apps -----------------------------------------------------------------------------
        if ($apps.Count -gt 0) {
            $map = Get-AppMap $mount
            Say ("Bundled apps in the image before: {0}" -f $map.Count)
            foreach ($a in $apps) {
                if (-not $map.ContainsKey($a)) { $skipped += "app $a (not in the image)"; continue }
                $r = Invoke-Dism @("/Image:$mount", '/Remove-ProvisionedAppxPackage', "/PackageName:$($map[$a])") -AllowFail
                if ($r.Code -eq 0) { $done += "app $a" } else { $failed += "app $a (DISM code $($r.Code))" }
            }
            $mapAfter = Get-AppMap $mount
            Say ("Bundled apps in the image after: {0}" -f $mapAfter.Count)
        }

        # --- features -------------------------------------------------------------------------
        foreach ($f in $features) {
            $state = Get-FeatureState $mount $f
            if (-not $state) { $skipped += "feature $f (not in the image)"; continue }
            if ($state -ne 'Enabled') { $skipped += "feature $f (state was: $state)"; continue }
            $r = Invoke-Dism @("/Image:$mount", '/Disable-Feature', "/FeatureName:$f") -AllowFail
            if ($r.Code -eq 0) { $done += "feature $f switched off" } else { $failed += "feature $f (DISM code $($r.Code))" }
        }

        # --- services -------------------------------------------------------------------------
        if ($services.Count -gt 0) {
            $hive = Join-Path $mount 'Windows\System32\config\SYSTEM'
            $r    = Invoke-Reg @('load', "HKLM\$hiveName", $hive)
            if ($r.Code -ne 0) {
                foreach ($s in $services) { $failed += "service $s (the image's registry could not be opened)" }
            } else {
                $hiveLoaded = $true
                $setNumber  = 1
                $q = Invoke-Reg @('query', "HKLM\$hiveName\Select", '/v', 'Current')
                foreach ($l in $q.Out) {
                    if (([string]$l) -match 'Current\s+REG_DWORD\s+0x([0-9A-Fa-f]+)') { $setNumber = [Convert]::ToInt32($Matches[1], 16) }
                }
                $controlSet = 'ControlSet{0:D3}' -f $setNumber
                Say "Image registry opened. Control set in use: $controlSet"
                foreach ($s in $services) {
                    $key = "HKLM\$hiveName\$controlSet\Services\$s"
                    $q   = Invoke-Reg @('query', $key, '/v', 'Start')
                    $was = -1
                    foreach ($l in $q.Out) {
                        if (([string]$l) -match 'Start\s+REG_DWORD\s+0x([0-9A-Fa-f]+)') { $was = [Convert]::ToInt32($Matches[1], 16) }
                    }
                    if (($q.Code -ne 0) -or ($was -lt 0)) { $skipped += "service $s (not in the image)"; continue }
                    if ($was -eq 4) { $skipped += "service $s (was already disabled)"; continue }
                    $w = Invoke-Reg @('add', $key, '/v', 'Start', '/t', 'REG_DWORD', '/d', '4', '/f')
                    if ($w.Code -eq 0) { $done += "service $s set to disabled (Start was $was, now 4)" } else { $failed += "service $s (registry write failed)" }
                }
                if (-not (Close-Hive)) { Stop-Run "the image's registry could not be closed (HKLM\$hiveName)" }
                $hiveLoaded = $false
            }
        }

        # --- what happened --------------------------------------------------------------------
        Say ("Changes made: {0}   skipped: {1}   failed: {2}" -f $done.Count, $skipped.Count, $failed.Count)
        foreach ($x in $done)    { Say "    done:    $x" }
        foreach ($x in $skipped) { Say "    skipped: $x" }
        foreach ($x in $failed)  { Say "    FAILED:  $x" }
        if ($done.Count -eq 0) { Stop-Run 'none of the listed changes could be made. The image copy is closed without saving and the stick is left as it was' }

        # --- save -----------------------------------------------------------------------------
        Say 'Saving the changed image (several minutes) ...'
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
                Say "Removing $($f.Name) ($($f.Length) bytes) from the stick (a copy with the same name and size is kept in this folder)."
                Remove-Item -LiteralPath $f.FullName -Force
            } else {
                $keep = Join-Path $root "from-usb_$stamp"
                if (-not (Test-Path -LiteralPath $keep)) { New-Item -ItemType Directory -Path $keep | Out-Null }
                Say "Moving $($f.Name) from the stick to $keep (no kept copy with that name and size)."
                Move-Item -LiteralPath $f.FullName -Destination $keep
            }
        }
        foreach ($f in $pieces) { Copy-Checked $f $src }

        $after = Get-UsbImageFiles $src
        if ((Get-SetKey $after) -ne (Get-SetKey $pieces)) { Stop-Run 'the install image files on the stick are not exactly the ones that were copied' }
        if (-not (Test-HomeOnly (Join-Path $src 'install.swm'))) { Stop-Run "the image on the stick does not read as a single '$HomeName' image" }
        foreach ($f in $after) { Say ("On the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }
        Say ("Stick free space at the end: {0}" -f (Fmt (Get-Volume -DriveLetter $UsbDrive).SizeRemaining))

        if ($failed.Count -gt 0) {
            Say ("RESULT: DONE WITH {0} FAILED ITEM(S) - the stick holds the changed '{1}' image; see the FAILED lines above." -f $failed.Count, $HomeName)
        } else {
            Say ("RESULT: DONE - the stick holds the changed '{0}' image: {1} change(s) made, {2} skipped." -f $HomeName, $done.Count, $skipped.Count)
        }
        Say 'NOTE: Windows may have answered part of the checksum check from memory. To be sure, eject the stick,'
        Say '      plug it in again and run this script with -CheckOnly: it then only reads and compares.'
        Say 'NOTE: to go back to the plain Home image, run Finish-HomeUsb.ps1: it puts the pieces from "usb" back.'
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
        if ($hiveLoaded) {
            if (Close-Hive) { Say "The image's registry was closed." } else { Say "WARNING: the image's registry is still open. Close it by hand:  reg unload HKLM\$hiveName" }
        }
        if ($mounted) {
            $u = Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Discard') -AllowFail
            if ($u.Code -eq 0) {
                Say 'The image copy was closed without saving.'
            } else {
                Say 'WARNING: the image copy is still open. Close it by hand:'
                Say ('  dism /Unmount-Image /MountDir:"{0}" /Discard' -f $mount)
            }
        }
        if (Test-Path -LiteralPath "${UsbDrive}:\sources") {
            $left = Get-UsbImageFiles "${UsbDrive}:\sources"
            if ($left.Count -eq 0) { Say 'State of the stick: no install image file in \sources. Run Finish-HomeUsb.ps1 to put the plain Home pieces back.' }
            foreach ($f in $left) { Say ("State of the stick: {0}  {1} bytes" -f $f.Name, $f.Length) }
        }
    } catch {
        Write-Host "RESULT: $msg"
    }
}
Say '=== Apply-HomeImage ended ==='
exit $exitCode
