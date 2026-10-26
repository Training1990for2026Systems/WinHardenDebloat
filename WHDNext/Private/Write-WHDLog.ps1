#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Write-WHDLog.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 One log line: on screen (coloured), in logs\run_<session>.log, and to the
 optional sink (-FileOnly: log file only). A log file that cannot be written
 never stops WHD.
#>
function Write-WHDLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [ValidateSet('INFO', 'WARN', 'ERR', 'OK', 'DRY', 'ACT')][string]$Level = 'INFO', [switch]$FileOnly)
    $line = '[{0}] {1,-4} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERR' { 'Red' } 'OK' { 'Green' } 'DRY' { 'Cyan' } 'ACT' { 'Magenta' } default { 'Gray' } }
    if (-not $FileOnly) { Write-Host $line -ForegroundColor $color }
    $s = $script:WHDState
    if ($s.LogFile) {
        try { Add-Content -LiteralPath $s.LogFile -Value $line -Encoding utf8 -ErrorAction Stop }
        catch { $s.LogFile = $null; Write-Host ('  (log file could not be written - logging to screen only: {0})' -f $_.Exception.Message) -ForegroundColor Yellow }
    }
    if ($s.LogSink) { try { & $s.LogSink $line $Level } catch { $s.LogSink = $null } }
}
