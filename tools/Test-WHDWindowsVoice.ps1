#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  tools\Test-WHDWindowsVoice.ps1   (development test, read-only)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Theme sounds, voice trial (owner 2026-10-16 19:26: Windows' own offline speech
 allowed). Lists the voices Windows' speech component (SAPI) has on this PC and
 records the 20 ship lines (D64) with each into
   <project>\logs\voice-test\<voice>_<line>.wav
 plus voices.txt. It changes no Windows setting and plays nothing.

   pwsh -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-WHDWindowsVoice.ps1      (in the WHD folder)
================================================================================
#>
[CmdletBinding()]
param([string]$OutDir)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { Write-Host 'Windows only.' -ForegroundColor Red; exit 2 }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs\voice-test' }
[void](New-Item -ItemType Directory -Path $OutDir -Force)

$lines = [ordered]@{
    signin          = 'Main power online. All systems standing by. Welcome aboard.'
    signout         = 'Crew member signed off. Systems holding.'
    shutdown        = 'Power-down sequence engaged. Ship going dark.'
    lock            = 'Console secured.'
    unlock          = 'Access confirmed. Console active.'
    notify          = 'Incoming notice.'
    message         = 'Incoming message.'
    mail            = 'Transmission received.'
    reminder        = 'Scheduled event approaching.'
    error           = 'Operation failed. Fault detected.'
    warning         = 'Caution.'
    info            = 'Information available.'
    beep            = 'Acknowledged.'
    connect         = 'Device linked.'
    disconnect      = 'Device released.'
    devicefail      = 'Device link failed.'
    uac             = 'Command authorization required.'
    batterylow      = 'Power reserves low.'
    batterycritical = 'Warning. Power reserves critical.'
    proximity       = 'Contact in range.'
}

$sp = New-Object -ComObject SAPI.SpVoice
$tokens = @($sp.GetVoices())
$report = [System.Collections.Generic.List[string]]::new()
$report.Add(('Voices found by Windows speech (SAPI) on {0}, {1:yyyy-MM-dd HH:mm}: {2}' -f $env:COMPUTERNAME, (Get-Date), $tokens.Count))
Write-Host ('  {0} voice(s) found.' -f $tokens.Count) -ForegroundColor Cyan

foreach ($tok in $tokens) {
    $desc = [string]$tok.GetDescription()
    $tag = ($desc -replace '^Microsoft\s+', '' -replace '\s+-.*$', '' -replace '[^A-Za-z0-9]', '')
    if (-not $tag) { $tag = 'voice' }
    $report.Add(('  {0}  ->  {1}' -f $desc, $tag))
    Write-Host ('  {0}' -f $desc)
    foreach ($k in $lines.Keys) {
        $file = Join-Path $OutDir ('{0}_{1}.wav' -f $tag, $k)
        $fs = New-Object -ComObject SAPI.SpFileStream
        try {
            try { $fmt = New-Object -ComObject SAPI.SpAudioFormat; $fmt.Type = 22; $fs.Format = $fmt } catch { $report.Add(('    (format not set, voice default used: {0})' -f $_.Exception.Message)) }
            $fs.Open($file, 3, $false)                  # 3 = create for writing
            $sp.AudioOutputStream = $fs
            $sp.Voice = $tok
            $sp.Rate = 0
            [void]$sp.Speak($lines[$k])
            $report.Add(('    made {0}' -f (Split-Path $file -Leaf)))
            Write-Host ('    made {0}' -f (Split-Path $file -Leaf)) -ForegroundColor Green
        } catch {
            $report.Add(('    FAILED {0}: {1}' -f $k, $_.Exception.Message))
            Write-Host ('    FAILED {0}: {1}' -f $k, $_.Exception.Message) -ForegroundColor Red
        } finally {
            try { $fs.Close() } catch { Write-Verbose ('close: {0}' -f $_.Exception.Message) }
            try { $sp.AudioOutputStream = $null } catch { Write-Verbose ('release: {0}' -f $_.Exception.Message) }
        }
    }
}
$report | Set-Content -LiteralPath (Join-Path $OutDir 'voices.txt') -Encoding ascii
Write-Host ('  Done. Files in {0}' -f $OutDir) -ForegroundColor Cyan
