#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Engine.State.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 The one session state of the engine. Everything else reads and writes it
 through the functions in this module - no loose script variables.
#>
function Initialize-WHDState {
    [CmdletBinding()]
    param([string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent))
    $script:WHDState = [pscustomobject]@{
        Root          = $Root
        DataRoot      = $Root                       # logs\ and restore\ live here
        Stamp         = (Get-Date -Format 'yyyy-MM-dd_HHmmss')
        Execute       = $false                      # the user's EXECUTE switch (dry-run when off)
        SafeMode      = $false                      # D14: safe mode on 7.6
        SafeAllow     = 0                           # >0 while an allowed safe-mode operation runs
        IsAdmin       = (Test-WHDAdmin)
        Undoing       = $false                      # entries written by an undo get ByUndo (Verify ignores them)
        FwBackupDone  = $false                      # firewall exported to restore\ this session?
        RestoreDone   = $false                      # restore point made this session?
        RestorePoint  = $null                       # scriptblock that makes the restore point (tests replace it)
        JournalStop   = $null                       # facts of the first failed journal write
        ChangeNote    = $null                       # set by a change Action that finished but needs a check
        Confirm       = { param($What) Write-Host ('  Proceed with: {0}? [y/N] ' -f $What) -ForegroundColor Magenta -NoNewline; (Read-Host) -match '^[Yy]' }
        LogSink       = $null                       # optional scriptblock param($line, $level) (the window uses it)
        LogFile       = $null
        Results       = [System.Collections.Generic.List[object]]::new()
        Counts        = @{ planned = 0; done = 0; failed = 0; skipped = 0 }
        Initialized   = $false
    }
}

function Test-WHDAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }   # not Windows
}

function Get-WHDRestoreFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Join-Path $script:WHDState.DataRoot 'restore') $script:WHDState.Stamp
}

function Test-WHDRealChange {
    # Would a change made NOW be real? EXECUTE on, no journal stop, and in safe mode only inside an allowed operation.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $s = $script:WHDState
    if (-not $s.Execute -or $s.JournalStop) { return $false }
    if ($s.SafeMode -and $s.SafeAllow -le 0) { return $false }
    return $true
}

function Add-WHDResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][ValidateSet('planned', 'done', 'failed', 'skipped')][string]$Status, [string]$Detail = '')
    $r = [pscustomobject]@{ Time = (Get-Date); Action = $Action; Status = $Status; Detail = $Detail }
    $script:WHDState.Results.Add($r)
    $script:WHDState.Counts[$Status]++
    return $r
}
