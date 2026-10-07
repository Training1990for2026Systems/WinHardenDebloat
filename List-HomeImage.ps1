#requires -Version 5.1
<#
  List-HomeImage.ps1   (WHD USB Image)

  Lists what is inside the Home-only install image. It changes nothing.

  - Opens install.wim read-only in the folder "mount", reads three lists
    and closes it again without saving.
  - Writes the lists to image-contents.txt.
  - Does not touch the USB stick. Uses only Windows PowerShell and DISM as built into Windows.

  Run from an administrator Windows PowerShell, in the folder that holds this script:
    powershell -ExecutionPolicy Bypass -File .\List-HomeImage.ps1
#>
param(
    [string]$HomeName = 'Windows 11 Home'
)

$ErrorActionPreference = 'Stop'

$root  = $PSScriptRoot
$wim   = Join-Path $root 'install.wim'
$mount = Join-Path $root 'mount'
$out   = Join-Path $root 'image-contents.txt'

function Say([string]$Text) {
    Write-Host ('{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text)
}

function Invoke-Dism([string[]]$DismArgs) {
    Say ('dism ' + ($DismArgs -join ' '))
    $o    = & dism.exe @DismArgs
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        foreach ($l in $o) {
            $s = ([string]$l).Trim()
            if ($s -and ($s -notmatch '^\[[=\s]*\d')) { Write-Host "    $s" }
        }
        throw "DISM ended with code $code"
    }
    return ,@($o)
}

$mounted  = $false
$exitCode = 0
try {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'this window is not running as administrator'
    }
    if (-not (Test-Path -LiteralPath $wim)) { throw "$wim not found" }

    $info  = Invoke-Dism @('/English', '/Get-WimInfo', "/WimFile:$wim")
    $names = @()
    foreach ($l in $info) {
        if (([string]$l) -match '^\s*Name\s*:\s*(.+?)\s*$') { $names += $Matches[1] }
    }
    if (-not (($names.Count -eq 1) -and ($names[0] -eq $HomeName))) {
        throw "install.wim is not a single '$HomeName' image"
    }

    if (Test-Path -LiteralPath $mount) {
        if (@(Get-ChildItem -LiteralPath $mount -Force).Count -gt 0) {
            throw "the folder $mount is not empty - an earlier run may have left the image open"
        }
    } else {
        New-Item -ItemType Directory -Path $mount | Out-Null
    }

    Say 'Opening the image read-only (this can take a few minutes) ...'
    Invoke-Dism @('/Mount-Image', "/ImageFile:$wim", '/Index:1', "/MountDir:$mount", '/ReadOnly') | Out-Null
    $mounted = $true

    $lines = @()
    $lines += ('Contents of the Home-only image (install.wim) - listed {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'))
    $lines += ''

    $lines += '=== OPTIONAL FEATURES THAT ARE ENABLED ==='
    $f = Invoke-Dism @('/English', "/Image:$mount", '/Get-Features', '/Format:Table')
    foreach ($l in $f) {
        if (([string]$l) -match '^\s*(\S+)\s*\|\s*Enabled\s*$') { $lines += $Matches[1] }
    }
    $lines += ''

    $lines += '=== CAPABILITIES THAT ARE INSTALLED ==='
    $c = Invoke-Dism @('/English', "/Image:$mount", '/Get-Capabilities', '/Format:Table')
    foreach ($l in $c) {
        if (([string]$l) -match '^\s*(\S+)\s*\|\s*Installed\s*$') { $lines += $Matches[1] }
    }
    $lines += ''

    $lines += '=== APPS PROVISIONED FOR EVERY NEW USER (display name -> package name) ==='
    $a    = Invoke-Dism @('/English', "/Image:$mount", '/Get-ProvisionedAppxPackages')
    $disp = ''
    foreach ($l in $a) {
        $s = [string]$l
        if ($s -match '^\s*DisplayName\s*:\s*(.+?)\s*$') { $disp = $Matches[1] }
        elseif ($s -match '^\s*PackageName\s*:\s*(.+?)\s*$') {
            $lines += ('{0} -> {1}' -f $disp, $Matches[1])
            $disp = ''
        }
    }

    Set-Content -LiteralPath $out -Value $lines -Encoding Ascii
    Say ('{0} lines written to {1}' -f $lines.Count, $out)
}
catch {
    $exitCode = 1
    Write-Host ('RESULT: STOPPED - {0}' -f $_.Exception.Message)
}
finally {
    if ($mounted) {
        try {
            Invoke-Dism @('/Unmount-Image', "/MountDir:$mount", '/Discard') | Out-Null
            Say 'Image closed again. Nothing was saved into it.'
        } catch {
            $exitCode = 1
            Write-Host 'WARNING: the image could not be closed. Close it by hand with:'
            Write-Host ('  dism /Unmount-Image /MountDir:"{0}" /Discard' -f $mount)
        }
    }
}
if ($exitCode -eq 0) { Say 'RESULT: DONE - the list is in image-contents.txt' }
exit $exitCode
