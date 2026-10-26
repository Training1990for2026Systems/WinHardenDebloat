#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  tools/Invoke-WHDThemeEvent.ps1   (theme part c, D74)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Plays one theme sound. Started by the three scheduled tasks in
 \WinHardenDebloatNext3\ (Theme menu > 9) as the signed-in user, WITHOUT
 administrator rights. WHD copies it next to the sounds:
   C:\ProgramData\WinHardenDebloatNext\app\theme\Invoke-WHDThemeEvent.ps1
 It changes nothing. What it did is written to
   %LOCALAPPDATA%\WinHardenDebloatNext\app\theme\events.log  (last 200 lines)
 Sign-in, lock and unlock only: Windows does not start tasks while it signs
 out or shuts down (D76).
================================================================================
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('signin', 'lock', 'unlock')][string]$What)

function Write-WHDEventLine {
    param([string]$Text)
    try {
        if (-not $env:LOCALAPPDATA) { return }
        $d = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'WinHardenDebloatNext', 'app', 'theme')
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        $f = [System.IO.Path]::Combine($d, 'events.log')
        $lines = @(if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Tail 199 })
        $lines += ('{0:yyyy-MM-dd HH:mm:ss}  {1,-8}  {2}' -f (Get-Date), $What, $Text)
        Set-Content -LiteralPath $f -Value $lines -Encoding utf8
    } catch { Write-Verbose $_.Exception.Message }
}

$wav = [System.IO.Path]::Combine($PSScriptRoot, 'sounds', ('whd-{0}.wav' -f $What))
if (-not (Test-Path -LiteralPath $wav)) { Write-WHDEventLine ('sound file not found: {0}' -f $wav); exit 2 }
$p = $null
try {
    $p = [System.Media.SoundPlayer]::new($wav)
    $p.Load()
    $p.PlaySync()
    Write-WHDEventLine 'played'
    exit 0
} catch {
    Write-WHDEventLine ('could not be played: {0}' -f $_.Exception.Message)
    exit 1
} finally { if ($p) { $p.Dispose() } }
