#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Get-WHDModeText.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The mode line shown in the title and menus.
#>
function Get-WHDModeText {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $s = $script:WHDState
    $m = if ($s.Execute) { 'EXECUTE' } else { 'DRY-RUN' }
    if ($s.SafeMode) { $m = 'SAFE MODE (Undo, re-apply, re-remove, restore points) - ' + $m }
    if ($s.JournalStop) { $m = 'STOPPED (change history not writable) - ' + $m }
    return $m
}
