#requires -Version 5.1
<#
  Inventory-AiPackages.ps1   (WHD Imaging Helper 1.5 preview 1 - tools)

  Lists where Windows' built-in AI "System" packages sit inside the Home install image, so the way to
  take them out offline can be chosen. IT CHANGES NOTHING IN ANY IMAGE.

  The packages it looks for (whole-word match on these names, -Words to change them):
    CoreAI, AIX, AIFabric, AugLoop, Voiess, Livtop, Speion
  (MicrosoftWindows.Client.CoreAI, MicrosoftWindows.Client.AIX, Microsoft.AIFabric.CBS,
   Microsoft.Windows.AugLoop.CBS, MicrosoftWindows.61869720.Voiess / .61869721.Livtop / .61869722.Speion)

  It works together with tools\Build-HomeUsbFromIso.ps1:
    - Same switches: -IsoFile, -IsoSha256, -WorkDir, -HomeName.
    - Same work file: install.wim in the work folder, with its note install-source.txt.
      When install.wim was made from this same ISO file, it is used as it is.
      When it is missing, this script makes it exactly as the build does (Home edition exported from the
      ISO file, maximum compression, install-source.txt written). The build then finds it and uses it
      again, so the 15-minute export is done only once.
      An install.wim from another ISO file is renamed install_old_<date_time>.wim, as the build does.
    - -After looks at install-custom.wim instead: the image the build changed. Run it after a build to
      see what is still in it. Needs no ISO file.
    - Its own folder "mount-inventory" and registry name HKLM\WHDINVSW: never the build's "mount",
      WHDIMG or WHDIMGSW, so it cannot get in the build's way.
    - It refuses to start while an image is open in the build's folder "mount".

  What it reads, inside the image opened READ-ONLY:
    1. Provisioned apps                    dism /Get-ProvisionedAppxPackages
    2. Servicing packages                  dism /Get-Packages, then /Get-PackageInfo for each match
    3. Capabilities and optional features  dism /Get-Capabilities, /Get-Features
    4. Package manifests (.mum) in Windows\servicing\Packages: names that match, and manifests whose
       text names a match - with each manifest's "permanence" and "visibility"
    5. Component manifests in Windows\WinSxS\Manifests whose names match
    6. Folders in Windows\SystemApps and Windows\SystemApps\SxS whose names match (size, file count)
    7. The image's registry (a COPY of its SOFTWARE file, loaded under HKLM\WHDINVSW): the Appx store
       (AppxAllUserStore) and the servicing package list, searched for the names
  Then a summary, one block per name: where it was found.

  Writes: ai-inventory.txt and Inventory-AiPackages.log in the helper's main folder (an older
  ai-inventory.txt is renamed ai-inventory_old_<date_time>.txt). In the work folder only what the
  build itself would write: install.wim, install-source.txt, the folder mount-inventory.
  The registry copy goes to a folder of its own under %TEMP% and is removed again at the end.
  The image is always closed with /Discard. The ISO file is only read.

  Uses only Windows PowerShell, DISM and reg.exe as built into Windows. No downloads, no web calls.

  Run from an administrator Windows PowerShell, in the helper's main folder (the one that holds WHD-ImageMenu.ps1):
    powershell -ExecutionPolicy Bypass -File .\tools\Inventory-AiPackages.ps1 -IsoFile C:\Downloads\Win11.iso
  After a build, look at the changed image:
    powershell -ExecutionPolicy Bypass -File .\tools\Inventory-AiPackages.ps1 -After

  Switches:
    -IsoFile <file>      the Windows 11 ISO file (needed, except with -After)
    -IsoSha256 <value>   the SHA-256 value the ISO file should have; stops when it differs
    -WorkDir <folder>    the build's work folder, when the build was given one (NTFS drive)
    -After               look at install-custom.wim (made by the build) instead of install.wim
    -Words <list>        other names to look for, for example -Words CoreAI,AIFabric
#>
param(
    [string]$IsoFile = '',
    [string]$IsoSha256 = '',
    [string]$WorkDir = '',
    [string]$HomeName = 'Windows 11 Home',
    [switch]$After,
    [string[]]$Words = @('CoreAI', 'AIX', 'AIFabric', 'AugLoop', 'Voiess', 'Livtop', 'Speion')
)

$ErrorActionPreference = 'Stop'

# This script lies in tools\ ; lists, logs and work files are in the helper's main folder above it.
$root   = Split-Path -Parent $PSScriptRoot
$log    = Join-Path $root 'Inventory-AiPackages.log'
$out    = Join-Path $root 'ai-inventory.txt'
$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$hive   = 'WHDINVSW'
# The build's own names: this script never uses them, and stops while the build's image is open.
$buildHives = @('WHDIMG', 'WHDIMGSW')
# The most lines one registry search may add to the report.
$maxRegLines = 300

$work  = $root
$lines = New-Object System.Collections.ArrayList

function Say([string]$Text) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    for ($i = 0; $i -lt 3; $i++) {
        try { Add-Content -LiteralPath $log -Value $line -Encoding Ascii -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 300 }
    }
    Write-Host '    (that line could not be written to the log file)'
}

# One line for the report ai-inventory.txt. Characters outside ASCII are written as '?'.
function Put([string]$Text) {
    [void]$lines.Add(($Text -replace '[^\x09\x20-\x7E]', '?'))
}

function Stop-Run([string]$Why) {
    throw "STOPPED - $Why"
}

function Fmt([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    return ('{0:N1} MB' -f ($Bytes / 1MB))
}

function Invoke-Dism([string[]]$DismArgs, [switch]$AllowFail) {
    Say ('dism ' + ($DismArgs -join ' '))
    $o    = & dism.exe @DismArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($l in $o) {
            $s = ([string]$l).Trim()
            if ($s -and ($s -notmatch '^\[[=\s]*\d')) { Say ('    ' + $s) }
        }
        if (-not $AllowFail) { Stop-Run "DISM ended with code $code" }
    }
    return (New-Object PSObject -Property @{ Code = $code; Out = @($o) })
}

# Runs a program and returns its exit code and all its text, error output included.
function Invoke-Program([string]$Exe, [string[]]$ArgList) {
    $ErrorActionPreference = 'Continue'
    $o    = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
    $text = @()
    foreach ($x in @($o)) { $text += [string]$x }
    return (New-Object PSObject -Property @{ Code = $code; Out = $text })
}

function Invoke-Reg([string[]]$RegArgs) {
    return (Invoke-Program 'reg.exe' $RegArgs)
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

# CurrentState and Visibility of one servicing package key in the loaded copy of the image's registry.
# The state numbers are the servicing stack's own; the names are given next to the number.
$cbsStates = @{ 0 = 'absent'; 5 = 'uninstall pending'; 16 = 'resolving'; 32 = 'resolved'; 48 = 'staging'; 64 = 'staged'; 80 = 'superseded'; 96 = 'install pending'; 101 = 'partially installed'; 112 = 'installed'; 128 = 'permanent' }
function Get-CbsValues([string]$Key) {
    $state = '-'; $vis = '-'
    $r = Invoke-Reg @('query', $Key)
    foreach ($l in $r.Out) {
        $s = [string]$l
        if ($s -match '^\s*CurrentState\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
            $n = [Convert]::ToInt64($Matches[1], 16)
            $state = '0x{0:x}' -f $n
            if ($cbsStates.ContainsKey([int]$n)) { $state += ' (' + $cbsStates[[int]$n] + ')' }
        }
        elseif ($s -match '^\s*Visibility\s+REG_DWORD\s+0x([0-9a-fA-F]+)') {
            $n = [Convert]::ToInt64($Matches[1], 16)
            $vis = '{0}' -f $n
            if ($n -eq 1) { $vis += ' (shown)' } elseif ($n -eq 2) { $vis += ' (hidden)' }
        }
    }
    return (New-Object PSObject -Property @{ State = $state; Visibility = $vis })
}

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

function Test-HomeOnly([string]$File) {
    $l = Get-ImageList $File
    return (($l.Count -eq 1) -and ($l[0].Name -eq $HomeName))
}

function Get-LetterText($Letter) {
    $s = [string]$Letter
    if ($s -match '^[A-Za-z]$') { return $s.ToUpperInvariant() }
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

# True when the text names one of the words as a whole word (letters and digits around it do not count
# as a boundary: "AIX" matches "Client.AIX" but not "AIXP"). Case does not matter.
# $wordRx and $found are filled in the main part, after the words are checked.
$wordRx = @{}
$found  = @{}
function Get-WordsIn([string]$Text) {
    $hit = @()
    foreach ($w in $Words) { if ($Text -match $wordRx[$w]) { $hit += $w } }
    return ,@($hit)
}

# Where each word was found: word -> list of short notes, for the summary.
function Note([string[]]$Hit, [string]$Where) {
    foreach ($w in $Hit) { [void]$found[$w].Add($Where) }
}

# --------------------------------------------------------------------------------------------------
$exitCode      = 0
$iso           = ''
$isoOpenedByUs = $false
$mount         = ''
$mounted       = $false
$hiveLoaded    = $false
$hiveDir       = ''

try {
    Say '=== Inventory-AiPackages started (changes nothing in any image) ==='

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Stop-Run 'this window is not running as administrator'
    }

    # --- the words ------------------------------------------------------------------------------
    $Words = @($Words | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($Words.Count -eq 0) { Stop-Run '-Words names nothing' }
    foreach ($w in $Words) {
        if ($w -notmatch '^[A-Za-z0-9.\-]{2,64}$') { Stop-Run "-Words: '$w' is not a name this script can look for (letters, digits, dot and dash, 2 to 64 characters)" }
    }
    foreach ($w in $Words) {
        $wordRx[$w] = '(?i)(^|[^A-Za-z0-9])' + [regex]::Escape($w) + '($|[^A-Za-z0-9])'
        $found[$w]  = New-Object System.Collections.ArrayList
    }
    Say ('Looking for: ' + ($Words -join ', '))

    # --- the work folder (the build's) ----------------------------------------------------------
    if ($WorkDir) {
        if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { Stop-Run "the work folder $WorkDir does not exist" }
        $work = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd('\')
    }
    if ($work -notmatch '^[A-Za-z]:\\.+') { Stop-Run "the work folder must be a folder on a drive with a letter, not the top of a drive and not a network path (it is $work)" }
    $srcWim  = Join-Path $work 'install.wim'
    $srcNote = Join-Path $work 'install-source.txt'
    $newWim  = Join-Path $work 'install-custom.wim'
    Say "Work folder: $work"

    $fmt = [string](New-Object System.IO.DriveInfo($work.Substring(0, 1))).DriveFormat
    if ($fmt -ne 'NTFS') { Stop-Run "the work folder is on a drive with the $fmt file system. DISM can only open an image in a folder on an NTFS drive. Use -WorkDir with a folder on an NTFS drive" }

    # --- the build must not be running ----------------------------------------------------------
    foreach ($h in ($buildHives + $hive)) {
        $probe = Invoke-Reg @('query', "HKLM\$h", '/ve')
        if ($probe.Code -eq 0) {
            if ($h -eq $hive) { Stop-Run "the registry name HKLM\$h is already in use - an earlier run of this script did not close it. Close it by hand:  reg unload HKLM\$h" }
            Stop-Run "the build's registry name HKLM\$h is in use - the build is running, or an earlier build did not close it. Run this script when the build has ended"
        }
    }
    $info = Invoke-Dism @('/English', '/Get-MountedWimInfo') -AllowFail
    $buildMount = (Join-Path $work 'mount').ToLowerInvariant()
    $invMount   = (Join-Path $work 'mount-inventory').ToLowerInvariant()
    foreach ($l in $info.Out) {
        if (([string]$l) -match '^\s*Mount Dir\s*:\s*(.+?)\s*$') {
            $md = $Matches[1].TrimEnd('\').ToLowerInvariant()
            if ($md -eq $invMount) { Stop-Run "an image is still open in $md from an earlier run of this script. Close it by hand:  dism /Unmount-Image /MountDir:`"$md`" /Discard" }
            if ($md.StartsWith($buildMount)) { Stop-Run "the build has an image open in $md. Run this script when the build has ended (or close that image:  dism /Unmount-Image /MountDir:`"$md`" /Discard)" }
        }
    }

    # --- which image ----------------------------------------------------------------------------
    $image = ''
    $what  = ''
    if ($After) {
        if ($IsoFile) { Say 'NOTE: -After was given: -IsoFile is not used.' }
        if (-not (Test-Path -LiteralPath $newWim -PathType Leaf)) { Stop-Run "$newWim not found - -After looks at the image the build made; build first" }
        if (-not (Test-HomeOnly $newWim)) { Stop-Run "install-custom.wim is not a single '$HomeName' image" }
        $image = $newWim
        $what  = 'install-custom.wim (the image the build changed)'
    } else {
        if (-not $IsoFile) { Stop-Run 'give the Windows ISO file with -IsoFile <file> (or use -After to look at the image the build made)' }
        if (-not (Test-Path -LiteralPath $IsoFile -PathType Leaf)) { Stop-Run "the ISO file was not found: $IsoFile" }
        $iso = (Get-Item -LiteralPath $IsoFile).FullName
        if ($iso -notmatch '^[A-Za-z]:\\.+\.iso$') { Stop-Run "-IsoFile must be a file that ends with .iso, on a drive with a letter (it is $iso)" }
        $wantSha = ''
        if ($IsoSha256) {
            $wantSha = ($IsoSha256 -replace '[\s:-]', '').ToUpperInvariant()
            if ($wantSha -notmatch '^[0-9A-F]{64}$') { Stop-Run "-IsoSha256 is not a SHA-256 value (64 characters, 0-9 and A-F): $IsoSha256" }
        }
        Say ("ISO file: {0} ({1})" -f $iso, (Fmt (Get-Item -LiteralPath $iso).Length))
        Say 'Reading the ISO file to work out its SHA-256 checksum (a minute or two) ...'
        $isoSha = (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash
        Say "    SHA-256 of the ISO file: $isoSha"
        if ($wantSha -and ($isoSha -ne $wantSha)) { Stop-Run "the ISO file does not have the SHA-256 value given with -IsoSha256 ($wantSha). Nothing was changed" }

        $reuse = $false
        if ((Test-Path -LiteralPath $srcWim -PathType Leaf) -and (Test-Path -LiteralPath $srcNote -PathType Leaf)) {
            $noteSha = "$(@(Get-Content -LiteralPath $srcNote)[0])".Trim()
            if ($noteSha -eq $isoSha) { $reuse = $true }
        }
        if ($reuse) {
            Say 'install.wim in the work folder was made from this same ISO file. It is used as it is.'
        } else {
            # Made exactly as tools\Build-HomeUsbFromIso.ps1 makes it, so the build uses it again.
            $vol = Get-Volume -DriveLetter $work.Substring(0, 1)
            $needFree = 10GB + (1.2 * (Get-Item -LiteralPath $iso).Length)
            if ($vol.SizeRemaining -lt $needFree) { Stop-Run ("less than {0} free on the work drive (free: {1})" -f (Fmt $needFree), (Fmt $vol.SizeRemaining)) }
            if (Test-Path -LiteralPath $srcWim -PathType Leaf) {
                Say "install.wim in the work folder is not from this ISO file. Renaming it to install_old_$stamp.wim (nothing deleted)."
                Rename-Item -LiteralPath $srcWim -NewName "install_old_$stamp.wim"
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
            $isoSrc   = "${isoLetter}:\sources"
            $isoImage = ''
            foreach ($kind in @('wim', 'esd', 'swm')) {
                if ((-not $isoImage) -and (Test-Path -LiteralPath (Join-Path $isoSrc "install.$kind") -PathType Leaf)) { $isoImage = Join-Path $isoSrc "install.$kind" }
            }
            if (-not $isoImage) { Stop-Run 'there is no sources\install.wim, install.esd or install.swm in the ISO file' }
            $images = Get-ImageList $isoImage
            foreach ($i in $images) { Say ("    in the ISO file: index {0} = {1}" -f $i.Index, $i.Name) }
            $homeImg = @($images | Where-Object { $_.Name -eq $HomeName })
            if ($homeImg.Count -ne 1) { Stop-Run "the ISO file does not hold exactly one edition named '$HomeName'" }
            $partial = Join-Path $work 'install-partial.wim'
            if (Test-Path -LiteralPath $partial) {
                Say "A half-made export from an earlier run is renamed to install-partial_old_$stamp.wim (nothing deleted)."
                Rename-Item -LiteralPath $partial -NewName "install-partial_old_$stamp.wim"
            }
            Say 'Exporting the Home edition with maximum compression, as the build does (15 minutes or more) ...'
            $exportArgs = @('/Export-Image', "/SourceImageFile:$isoImage")
            if ($isoImage -match '\.swm$') { $exportArgs += "/SWMFile:$(Join-Path $isoSrc 'install*.swm')" }
            $exportArgs += @("/SourceIndex:$($homeImg[0].Index)", "/DestinationImageFile:$partial", '/Compress:max', '/CheckIntegrity')
            Invoke-Dism $exportArgs | Out-Null
            if (-not (Test-HomeOnly $partial)) { Stop-Run "the export does not read as a single '$HomeName' image. It is kept as $partial" }
            Rename-Item -LiteralPath $partial -NewName 'install.wim'
            Set-Content -LiteralPath $srcNote -Value @($isoSha, (Split-Path -Leaf $iso), (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding Ascii
            Say ("install.wim made: {0}. The build will find it and use it again." -f (Fmt (Get-Item -LiteralPath $srcWim).Length))
        }
        if (-not (Test-HomeOnly $srcWim)) { Stop-Run "install.wim is not a single '$HomeName' image" }
        $image = $srcWim
        $what  = 'install.wim (the plain Home edition, before the build changes it)'
    }

    # --- open the image read-only ---------------------------------------------------------------
    $mount = Join-Path $work 'mount-inventory'
    if (Test-Path -LiteralPath $mount) {
        if (@(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
            $mount = Join-Path $work "mount-inventory_$stamp"
            New-Item -ItemType Directory -Path $mount | Out-Null
        }
    } else {
        New-Item -ItemType Directory -Path $mount | Out-Null
    }
    Say "Opening $what read-only (a few minutes) ..."
    Invoke-Dism @('/Mount-Image', "/ImageFile:$image", '/Index:1', "/MountDir:$mount", '/ReadOnly') | Out-Null
    $mounted = $true
    $win = Join-Path $mount 'Windows'

    Put ('AI package inventory - {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    Put ('Image: {0}' -f $what)
    Put ('File:  {0}' -f $image)
    if ($iso) { Put ('ISO:   {0}  SHA-256 {1}' -f (Split-Path -Leaf $iso), $isoSha) }
    $vi  = Invoke-Dism @('/English', '/Get-WimInfo', "/WimFile:$image", '/Index:1') -AllowFail
    # Only the lines after "Index :" describe the image. The "Version:" line above them is DISM's own version.
    $inImage = $false
    foreach ($l in $vi.Out) {
        $s = [string]$l
        if ($s -match '^\s*Index\s*:') { $inImage = $true; continue }
        if ($inImage -and ($s -match '^\s*(Version|ServicePack Build|Edition|Architecture)\s*:\s*(.+?)\s*$')) { Put ('       {0}: {1}' -f $Matches[1], $Matches[2]) }
    }
    Put ('Looking for (whole word, any case): ' + ($Words -join ', '))
    Put 'Nothing in the image was changed: it was opened read-only and closed with /Discard.'
    Put ''

    # --- 1. provisioned apps --------------------------------------------------------------------
    Put '=== 1. PROVISIONED APPS (dism /Get-ProvisionedAppxPackages) ==='
    $r = Invoke-Dism @('/English', "/Image:$mount", '/Get-ProvisionedAppxPackages') -AllowFail
    $n = 0; $disp = ''
    foreach ($l in $r.Out) {
        $s = [string]$l
        if ($s -match '^\s*DisplayName\s*:\s*(.+?)\s*$') { $disp = $Matches[1] }
        elseif ($s -match '^\s*PackageName\s*:\s*(.+?)\s*$') {
            $pkg = $Matches[1]
            $hit = Get-WordsIn "$disp $pkg"
            if ($hit.Count -gt 0) { Put ('{0} -> {1}' -f $disp, $pkg); Note $hit "provisioned app $pkg"; $n++ }
            $disp = ''
        }
    }
    if ($r.Code -ne 0) { Put "(DISM ended with code $($r.Code) - this part is not complete)" }
    Put ("{0} match(es)" -f $n)
    Put ''

    # --- 2. servicing packages ------------------------------------------------------------------
    Put '=== 2. SERVICING PACKAGES (dism /Get-Packages, details by /Get-PackageInfo) ==='
    $r = Invoke-Dism @('/English', "/Image:$mount", '/Get-Packages', '/Format:Table') -AllowFail
    $pkgs = @()
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*(\S+~\S*)\s*\|') { $pkgs += $Matches[1] }
    }
    Put ("{0} package(s) in the image" -f $pkgs.Count)
    $n = 0
    foreach ($p in $pkgs) {
        $hit = Get-WordsIn $p
        if ($hit.Count -eq 0) { continue }
        $n++
        Put ("package: {0}" -f $p)
        $d = Invoke-Dism @('/English', "/Image:$mount", '/Get-PackageInfo', "/PackageName:$p") -AllowFail
        foreach ($l in $d.Out) {
            if (([string]$l) -match '^\s*(Release Type|State|Applicable|Install Time|Capability Identity|Restart Required|Completely offline capable)\s*:\s*(.*?)\s*$') { Put ('    {0}: {1}' -f $Matches[1], $Matches[2]) }
        }
        Note $hit "servicing package $p"
    }
    if ($r.Code -ne 0) { Put "(DISM ended with code $($r.Code) - this part is not complete)" }
    Put ("{0} match(es) by package name (see part 4 for packages that name them inside)" -f $n)
    Put ''

    # --- 3. capabilities and features -----------------------------------------------------------
    Put '=== 3. CAPABILITIES AND OPTIONAL FEATURES ==='
    $n = 0
    $r = Invoke-Dism @('/English', "/Image:$mount", '/Get-Capabilities', '/Format:Table') -AllowFail
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*(\S+)\s*\|\s*(.+?)\s*$') {
            $hit = Get-WordsIn $Matches[1]
            if ($hit.Count -gt 0) { Put ('capability: {0}  ({1})' -f $Matches[1], $Matches[2]); Note $hit "capability $($Matches[1]) ($($Matches[2]))"; $n++ }
        }
    }
    $r = Invoke-Dism @('/English', "/Image:$mount", '/Get-Features', '/Format:Table') -AllowFail
    foreach ($l in $r.Out) {
        if (([string]$l) -match '^\s*(\S+)\s*\|\s*(.+?)\s*$') {
            $hit = Get-WordsIn $Matches[1]
            if ($hit.Count -gt 0) { Put ('feature: {0}  ({1})' -f $Matches[1], $Matches[2]); Note $hit "optional feature $($Matches[1]) ($($Matches[2]))"; $n++ }
        }
    }
    Put ("{0} match(es)" -f $n)
    Put ''

    # --- 4. package manifests (.mum) ------------------------------------------------------------
    Put '=== 4. PACKAGE MANIFESTS (Windows\servicing\Packages\*.mum) ==='
    Put 'permanence="permanent" = DISM /Remove-Package refuses it; visibility="2" = hidden from /Get-Packages.'
    $mumDir = Join-Path $win 'servicing\Packages'
    $mums = @()
    if (Test-Path -LiteralPath $mumDir) { $mums = @(Get-ChildItem -LiteralPath $mumDir -Filter '*.mum' -File -ErrorAction SilentlyContinue) }
    Say ("Reading {0} package manifest(s) ..." -f $mums.Count)
    $n = 0
    foreach ($m in $mums) {
        $text = ''
        try { $text = [IO.File]::ReadAllText($m.FullName) } catch { continue }
        $byName = Get-WordsIn $m.BaseName
        $inside = Get-WordsIn $text
        if (($byName.Count + $inside.Count) -eq 0) { continue }
        $n++
        $perm = ''; $vis = ''
        if ($text -match 'permanence\s*=\s*"([^"]*)"') { $perm = $Matches[1] }
        if ($text -match '<package\b[^>]*\bvisibility\s*=\s*"([^"]*)"') { $vis = $Matches[1] } elseif ($text -match 'visibility\s*=\s*"([^"]*)"') { $vis = $Matches[1] }
        $how = @()
        if ($byName.Count -gt 0) { $how += ('name: ' + ($byName -join ',')) }
        if ($inside.Count -gt 0) { $how += ('text: ' + ($inside -join ',')) }
        Put ('{0}  [permanence={1}; visibility={2}; {3}]' -f $m.Name, $(if ($perm) { $perm } else { '-' }), $(if ($vis) { $vis } else { '-' }), ($how -join '; '))
        # The component names inside that hold a word.
        $comps = @()
        foreach ($cm in [regex]::Matches($text, 'name\s*=\s*"([^"]+)"')) {
            $cn = $cm.Groups[1].Value
            if (((Get-WordsIn $cn).Count -gt 0) -and ($comps -notcontains $cn)) { $comps += $cn }
        }
        foreach ($cn in @($comps | Select-Object -First 20)) { Put ('    names: ' + $cn) }
        Note @(@($byName) + @($inside) | Select-Object -Unique) ("package manifest {0} (permanence={1})" -f $m.BaseName, $(if ($perm) { $perm } else { '-' }))
    }
    Put ("{0} manifest(s) match" -f $n)
    Put ''

    # --- 5. component manifests -----------------------------------------------------------------
    Put '=== 5. COMPONENT MANIFESTS (Windows\WinSxS\Manifests, by file name) ==='
    $manDir = Join-Path $win 'WinSxS\Manifests'
    $n = 0
    if (Test-Path -LiteralPath $manDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $manDir -File -ErrorAction SilentlyContinue)) {
            $hit = Get-WordsIn $f.Name
            if ($hit.Count -gt 0) { Put $f.Name; Note $hit 'component manifest in WinSxS'; $n++ }
        }
    }
    Put ("{0} match(es)" -f $n)
    Put ''

    # --- 6. SystemApps folders ------------------------------------------------------------------
    Put '=== 6. FOLDERS IN Windows\SystemApps AND Windows\SystemApps\SxS ==='
    $n = 0
    foreach ($sub in @('SystemApps', 'SystemApps\SxS')) {
        $dir = Join-Path $win $sub
        if (-not (Test-Path -LiteralPath $dir)) { Put "($sub not in the image)"; continue }
        foreach ($d in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            $hit = Get-WordsIn $d.Name
            if ($hit.Count -eq 0) { continue }
            $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -Force -ErrorAction SilentlyContinue)
            $bytes = [double]0
            foreach ($x in $files) { $bytes += $x.Length }
            $hasMan = Test-Path -LiteralPath (Join-Path $d.FullName 'AppxManifest.xml')
            Put ('{0}\{1}  ({2} file(s), {3}; AppxManifest.xml: {4})' -f $sub, $d.Name, $files.Count, (Fmt $bytes), $(if ($hasMan) { 'yes' } else { 'no' }))
            Note $hit "folder $sub\$($d.Name)"
            $n++
        }
    }
    Put ("{0} match(es)" -f $n)
    Put ''

    # --- 7. the image's registry (a copy of its SOFTWARE file) ----------------------------------
    Put '=== 7. THE IMAGE''S REGISTRY (a copy of Windows\System32\config\SOFTWARE) ==='
    $swFile  = Join-Path $win 'System32\config\SOFTWARE'
    $hiveDir = Join-Path $env:TEMP "WHD-Inventory_$stamp"
    New-Item -ItemType Directory -Path $hiveDir | Out-Null
    foreach ($x in @(Get-ChildItem -LiteralPath (Split-Path $swFile) -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'SOFTWARE*' })) {
        Copy-Item -LiteralPath $x.FullName -Destination $hiveDir
    }
    $swCopy = Join-Path $hiveDir 'SOFTWARE'
    if (-not (Test-Path -LiteralPath $swCopy -PathType Leaf)) {
        Put '(the SOFTWARE file was not found in the image - this part is skipped)'
    } else {
        $r = Invoke-Reg @('load', "HKLM\$hive", $swCopy)
        if ($r.Code -ne 0) {
            Put ('(the copy could not be loaded: ' + (($r.Out | Where-Object { $_ }) -join ' ') + ')')
        } else {
            $hiveLoaded = $true
            $keys = @(
                @{ Key = "HKLM\$hive\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore"; Label = 'Appx store (AppxAllUserStore)' },
                @{ Key = "HKLM\$hive\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"; Label = 'servicing package list (Component Based Servicing\Packages, key names only)'; KeysOnly = $true }
            )
            foreach ($k in $keys) {
                Put ('--- ' + $k.Label + ' ---')
                $q = Invoke-Reg @('query', $k.Key, '/ve')
                if ($q.Code -ne 0) { Put '    (key not in the image)'; continue }
                foreach ($w in $Words) {
                    $qa = @('query', $k.Key, '/s', '/f', $w)
                    if ($k.KeysOnly) { $qa += '/k' }
                    $q = Invoke-Reg $qa
                    $hitLines = @()
                    $curKey = ''
                    foreach ($l in $q.Out) {
                        $s = ([string]$l).TrimEnd()
                        if (-not $s) { continue }
                        if ($s -match '^HKEY_') { $curKey = $s }
                        if ($s -match '^End of search') { continue }
                        if ((Get-WordsIn $s).Count -eq 0) { continue }
                        $hitLines += ($s -replace [regex]::Escape("HKEY_LOCAL_MACHINE\$hive"), 'IMAGE-SOFTWARE')
                    }
                    if ($hitLines.Count -eq 0) { continue }
                    Put ("  {0}: {1} line(s)" -f $w, $hitLines.Count)
                    foreach ($h in @($hitLines | Select-Object -First $maxRegLines)) { Put ('    ' + $h) }
                    if ($hitLines.Count -gt $maxRegLines) { Put ("    ... and {0} more" -f ($hitLines.Count - $maxRegLines)) }
                    Note @($w) ("registry: {0} ({1} line(s))" -f $k.Label, $hitLines.Count)
                    # A servicing package that /Get-Packages does not show (hidden): its state from the
                    # image's registry, and what DISM says about it when asked by name.
                    if ($k.KeysOnly) {
                        foreach ($h in @($hitLines | Where-Object { $_ -match '\\Packages\\([^\\]+~[^\\]*)$' })) {
                            $pn = ([regex]::Match($h, '\\Packages\\([^\\]+~[^\\]*)$')).Groups[1].Value
                            $st = Get-CbsValues "$($k.Key)\$pn"
                            Put ('    {0}: CurrentState {1}; Visibility {2}' -f $pn, $st.State, $st.Visibility)
                            $d = Invoke-Dism @('/English', "/Image:$mount", '/Get-PackageInfo', "/PackageName:$pn") -AllowFail
                            if ($d.Code -ne 0) { Put ("        dism /Get-PackageInfo: refused (code {0})" -f $d.Code) }
                            foreach ($dl in $d.Out) {
                                if (([string]$dl) -match '^\s*(Release Type|State|Applicable|Capability Identity|Restart Required|Completely offline capable)\s*:\s*(.*?)\s*$') { Put ('        {0}: {1}' -f $Matches[1], $Matches[2]) }
                            }
                        }
                    }
                }
            }
        }
    }
    Put ''

    # --- summary --------------------------------------------------------------------------------
    Put '=== SUMMARY - where each name was found ==='
    foreach ($w in $Words) {
        $u = @($found[$w] | Select-Object -Unique)
        if ($u.Count -eq 0) { Put ("{0}: not found in this image" -f $w); continue }
        Put ("{0}:" -f $w)
        foreach ($x in $u) { Put ('    ' + $x) }
    }
    Put ''
    Put 'How to read it: a provisioned app, a capability, an optional feature or a servicing package that is'
    Put 'not permanent can be taken out with DISM (Microsoft supports that). A name found only in folders,'
    Put 'component manifests or permanent packages belongs to Windows itself: DISM has no supported way to'
    Put 'take it out.'

    if (Test-Path -LiteralPath $out) {
        Rename-Item -LiteralPath $out -NewName "ai-inventory_old_$stamp.txt"
        Say "The older ai-inventory.txt was renamed to ai-inventory_old_$stamp.txt (nothing deleted)."
    }
    Set-Content -LiteralPath $out -Value $lines.ToArray() -Encoding Ascii
    Say ('{0} line(s) written to {1}' -f $lines.Count, $out)
    foreach ($w in $Words) { Say ('    {0}: found in {1} place(s)' -f $w, @($found[$w] | Select-Object -Unique).Count) }
}
catch {
    $exitCode = 1
    $msg = $_.Exception.Message
    if ($msg -notmatch '^STOPPED') { $msg = "STOPPED - $msg" }
    Say ('RESULT: ' + $msg)
}
finally {
    if ($hiveLoaded) {
        if (Close-Hive $hive) { Say 'The registry copy was closed again.' }
        else { $exitCode = 1; Say "WARNING: the registry copy could not be closed. Close it by hand:  reg unload HKLM\$hive" }
    }
    if ($hiveDir -and (Test-Path -LiteralPath $hiveDir)) {
        if (-not $hiveLoaded -or ((Invoke-Reg @('query', "HKLM\$hive", '/ve')).Code -ne 0)) {
            try { Remove-Item -LiteralPath $hiveDir -Recurse -Force -ErrorAction Stop } catch { Say "NOTE: the temporary folder $hiveDir could not be removed; it holds only a copy of the image's registry." }
        }
    }
    if ($mounted) {
        $u = Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Discard') -AllowFail
        if ($u.Code -eq 0) { Say 'The image was closed again. Nothing was saved into it.' }
        else { $exitCode = 1; Say "WARNING: the image could not be closed. Close it by hand:  dism /Unmount-Image /MountDir:`"$mount`" /Discard" }
    }
    if ($isoOpenedByUs) {
        try { Dismount-DiskImage -ImagePath $iso -ErrorAction Stop | Out-Null; Say 'The ISO file was closed again.' }
        catch { Say 'NOTE: the ISO file could not be closed. Close it in Explorer (right-click the drive, Eject).' }
    }
}
if ($exitCode -eq 0) { Say 'RESULT: DONE - the inventory is in ai-inventory.txt. Nothing in any image was changed.' }
exit $exitCode
