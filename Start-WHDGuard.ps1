#requires -Version 5.1
<#
================================================================================
 WHD Next 3.0  -  Start-WHDGuard.ps1   (the update guard's front door - Windows PowerShell 5.1)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Started ONLY by the scheduled task \WinHardenDebloatNext3\UpdateGuard, from
 the guard's locked copy (D89, D90). The second of the two 5.1 files (D13).

   PowerShell 7.6 or newer (stable, machine-wide) usable
        -> hands over to WHD.ps1 -Guard on PowerShell 7 (the real check)
   missing, too old, a preview, or the check could not run
        -> ALERT ONLY: an Application-log entry (source "WHD Next 3.0") and a
           small window. It changes nothing and installs nothing (D6).

 Its own lines go to <WHD folder>\restore\update-guard\front-door.log.
 Testing without changing the PC:  -Simulate missing | old | preview | broken
   (pretends that situation and shows the alert; nothing is started).
================================================================================
#>
[CmdletBinding()]
param(
    [string]$DataRoot,      # the WHD folder (change history, reports)
    [ValidateSet('', 'missing', 'old', 'preview', 'broken')][string]$Simulate = ''
)
Set-StrictMode -Version 2.0

$script:Here     = $PSScriptRoot
$script:Minimum  = [version]'7.6.0'
$script:PwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
$script:Source   = 'WHD Next 3.0'
if (-not $DataRoot) { $DataRoot = $script:Here }
$script:GuardDir = Join-Path (Join-Path $DataRoot 'restore') 'update-guard'

function Write-DoorLog {
    param([string]$Text)
    try {
        if (-not (Test-Path -LiteralPath $script:GuardDir)) { [void](New-Item -ItemType Directory -Path $script:GuardDir -Force -ErrorAction Stop) }
        Add-Content -LiteralPath (Join-Path $script:GuardDir 'front-door.log') -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding ASCII -ErrorAction Stop
    } catch { $null = $_ }     # a log that cannot be written must never stop the alert
}

function Get-DoorPwshState {
    # ok | missing | old | preview | unreadable  (+ the version text)
    $o = New-Object psobject -Property @{ State = 'missing'; Text = '' }
    if (-not (Test-Path -LiteralPath $script:PwshPath)) { return $o }
    $pv = ''
    try {
        $vi = (Get-Item -LiteralPath $script:PwshPath -ErrorAction Stop).VersionInfo
        $pv = [string]$vi.ProductVersion
        if (-not $pv) { $pv = [string]$vi.FileVersion }
    } catch { $pv = '' }
    $o.Text = $pv
    if ($pv -notmatch '^\s*(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z\.]+)?') { $o.State = 'unreadable'; return $o }
    $v = [version]('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3])
    if ($Matches[4]) { $o.State = 'preview'; return $o }
    if ($v -lt $script:Minimum) { $o.State = 'old'; return $o }
    $o.State = 'ok'
    return $o
}

function Show-DoorAlert {
    param([string[]]$Lines)
    # 1. the Application log (only when the guard registered its source at install)
    $msg = ("WHD Next 3.0 update guard: ALERT`r`n{0}" -f ($Lines -join "`r`n"))
    try {
        if (Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\{0}' -f $script:Source)) {
            [System.Diagnostics.EventLog]::WriteEntry($script:Source, $msg, [System.Diagnostics.EventLogEntryType]::Warning, 3002)
            Write-DoorLog 'event-log entry written'
        } else { Write-DoorLog 'event-log source not registered - no entry' }
    } catch { Write-DoorLog ('event-log entry failed: {0}' -f $_.Exception.Message) }
    # 2. the small window
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $w = New-Object System.Windows.Window
        $w.Title = 'WHD Next 3.0 - update guard'; $w.SizeToContent = 'WidthAndHeight'; $w.WindowStartupLocation = 'CenterScreen'; $w.Topmost = $true; $w.ResizeMode = 'NoResize'
        $p = New-Object System.Windows.Controls.StackPanel; $p.Margin = New-Object System.Windows.Thickness(16, 14, 16, 14); $w.Content = $p
        $h = New-Object System.Windows.Controls.TextBlock; $h.Text = 'The update guard could not check this PC'; $h.FontSize = 16; $h.FontWeight = [System.Windows.FontWeights]::Bold; $h.Margin = New-Object System.Windows.Thickness(0, 0, 0, 8)
        [void]$p.Children.Add($h)
        $t = New-Object System.Windows.Controls.TextBlock; $t.Text = ($Lines -join [Environment]::NewLine); $t.MaxWidth = 760; $t.TextWrapping = 'Wrap'
        [void]$p.Children.Add($t)
        $c = New-Object System.Windows.Controls.Button; $c.Content = 'Close'; $c.IsCancel = $true; $c.IsDefault = $true; $c.Padding = New-Object System.Windows.Thickness(14, 3, 14, 3); $c.Margin = New-Object System.Windows.Thickness(0, 12, 0, 0); $c.HorizontalAlignment = 'Right'
        $c.add_Click({ param($sender, $e) $null = $e; [System.Windows.Window]::GetWindow($sender).Close() })
        [void]$p.Children.Add($c)
        [void]$w.ShowDialog()
        Write-DoorLog 'alert window shown'
    } catch { Write-DoorLog ('alert window failed: {0}' -f $_.Exception.Message) }
}

# ---------------------------------------------------------------------------- main --
Write-DoorLog ('front door started on Windows PowerShell {0}; WHD folder {1}{2}' -f $PSVersionTable.PSVersion, $DataRoot, $(if ($Simulate) { '; SIMULATE ' + $Simulate } else { '' }))
$ps = Get-DoorPwshState
if ($Simulate -in 'missing', 'old', 'preview') { $ps.State = $Simulate; $ps.Text = '(simulated)' }
$why = ''
switch ($ps.State) {
    'missing'    { $why = 'PowerShell 7 is not installed (machine-wide).' }
    'old'        { $why = ('PowerShell 7 is too old ({0}); WHD Next 3.0 needs 7.6 or newer.' -f $ps.Text) }
    'preview'    { $why = ('PowerShell 7 is a preview ({0}); WHD Next 3.0 needs a stable 7.6 or newer.' -f $ps.Text) }
    'unreadable' { $why = 'The version of PowerShell 7 cannot be read.' }
}
if (-not $why) {
    if ($Simulate -eq 'broken') { $code = 1; Write-DoorLog 'simulated: the check on PowerShell 7 ended with exit code 1' }
    else {
        $whd = Join-Path $script:Here 'WHD.ps1'
        Write-DoorLog ('PowerShell {0} - handing over to {1} -Guard' -f $ps.Text, $whd)
        $code = -1
        try {
            & $script:PwshPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $whd -Guard -DataRoot $DataRoot
            $code = $LASTEXITCODE
        } catch { Write-DoorLog ('PowerShell 7 could not be started: {0}' -f $_.Exception.Message) }
        Write-DoorLog ('the check on PowerShell 7 ended, exit code {0}' -f $code)
    }
    if ($code -eq 0) { exit 0 }
    $why = ('The check on PowerShell 7 did not finish (exit code {0}).' -f $code)
}
Write-DoorLog ('ALERT: {0}' -f $why)
Show-DoorAlert -Lines @(
    $why,
    '',
    'So this time the update guard could not check that WHD''s changes are still in place.',
    'Nothing was changed and nothing was installed.',
    '',
    'What to do: start WHD with Start-WHD.cmd - it shows what is missing and offers to install',
    'PowerShell 7 (machine-wide). Details: restore\update-guard\front-door.log in the WHD folder.'
)
exit 2
