#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/Guard.ps1   (build step 7, D6, D13, D87-D93)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The update guard - ALERT ONLY: it reads and reports, it never changes a
 setting and never installs anything.
   Main menu G (D87); in the window: Inventory / Undo > "Update guard".
   1  install / refresh  a LOCKED copy of WHD in ProgramData\WinHardenDebloatNext
                         \guard3 (Administrators + SYSTEM change, Users read; D90)
                         + scheduled task \WinHardenDebloatNext3\UpdateGuard
                         (D88): 10 min after you sign in AND daily at 16:30
                         (D91), as you, highest rights. The task starts the
                         small Windows PowerShell 5.1 front door
                         Start-WHDGuard.ps1 (D89): PowerShell 7.6 usable ->
                         it hands over to WHD.ps1 -Guard; missing / old /
                         broken -> only an alert. Also registers the event-log
                         source "WHD Next 3.0". Old guards of WHD Next 2.0 /
                         WHD Classic: asked first, then switched off (D93).
   2  check now          the same check, read-only, shown here
   3  last report        opens the newest report
   4  remove             task, locked copy, event-log source (reports kept)
 The check (D92): every recorded change still in place (Verify); after a
 Windows update an inventory scan + compare (CAME BACK = alert; the guard keeps
 its last 5 scans); refused clock jumps; update gate + IP block list (info).
 An alert writes an Application-log entry and shows a small window with
 "Open the report" (D6). Reports: restore\update-guard\guard_<time>.txt.
 Written new for 3.0 - WHD Next 2.0's guard (Maintenance.ps1) read for
 reference, not copied.
================================================================================
#>

$script:WHDGuardTaskPath = '\WinHardenDebloatNext3\'
$script:WHDGuardTaskName = 'UpdateGuard'
$script:WHDGuardCopyName = 'guard3'
$script:WHDGuardDelay    = 'PT10M'
$script:WHDGuardDaily    = '16:30'
$script:WHDGuardKeep     = 5
$script:WHDGuardMarker   = '.whd-guard'
$script:WHDGuardSource   = 'WHD Next 3.0'
$script:WHDGuardLogName  = 'Application'
$script:WHDGuardFrontDoor = 'Start-WHDGuard.ps1'
$script:WHDGuardOld = @(
    @{ Name = 'WHD Next 2.0'; TaskPath = '\WinHardenDebloatNext\'; TaskName = 'UpdateGuard' }
    @{ Name = 'WHD Classic'; TaskPath = '\WinHardenDebloat\'; TaskName = 'UpdateGuard' }
)
$script:WHDGuardBaseOverride = $null      # tests

# ---- places ----------------------------------------------------------------------------------------------------------
function Get-WHDGuardBase {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:WHDGuardBaseOverride) { return $script:WHDGuardBaseOverride }
    if (-not $env:ProgramData) { return '' }
    return [System.IO.Path]::Combine($env:ProgramData, 'WinHardenDebloatNext')
}
function Get-WHDGuardCopyDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $b = Get-WHDGuardBase; if (-not $b) { return '' }
    return [System.IO.Path]::Combine($b, $script:WHDGuardCopyName)
}
function Get-WHDGuardDataDir {
    # the guard's reports, its status and its scans: in the WHD folder, next to the update gate's file
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::Combine($script:WHDState.DataRoot, 'restore', 'update-guard')
}
function Get-WHDGuardInvRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [System.IO.Path]::Combine((Get-WHDGuardDataDir), 'inventory')
}
function Test-WHDGuardRunningFromCopy {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $c = Get-WHDGuardCopyDir
    if (-not $c) { return $false }
    return [string]::Equals(([string]$script:WHDState.Root).TrimEnd('\', '/'), $c.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
}

# ---- Windows reads and writes (one place each; tests swap them) -------------------------------------------------------
function Get-WHDGuardTask {
    [CmdletBinding()]
    param([string]$TaskPath = $script:WHDGuardTaskPath, [string]$TaskName = $script:WHDGuardTaskName)
    try { Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $TaskName } | Select-Object -First 1 }
    catch { return $null }      # no Task Scheduler (not Windows)
}
function Test-WHDGuardTaskOn {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Task)
    if (-not $Task) { return $false }
    $on = ([string]$Task.State -ne 'Disabled')
    try { if ($null -ne $Task.Settings -and $null -ne $Task.Settings.Enabled) { $on = [bool]$Task.Settings.Enabled } } catch { Write-Verbose $_.Exception.Message }
    return $on
}
function Register-WHDGuardTask {
    # The task: Windows PowerShell 5.1 (on every PC) starts the front door in the locked copy (D89).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$CopyDir, [Parameter(Mandatory)][string]$DataRoot)
    if (-not $PSCmdlet.ShouldProcess(('{0}{1}' -f $script:WHDGuardTaskPath, $script:WHDGuardTaskName), 'register')) { return }
    $user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $ps51 = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe')
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DataRoot "{1}"' -f ([System.IO.Path]::Combine($CopyDir, $script:WHDGuardFrontDoor)), $DataRoot
    $act = New-ScheduledTaskAction -Execute $ps51 -Argument $arg -WorkingDirectory $CopyDir
    $t1 = New-ScheduledTaskTrigger -AtLogOn -User $user
    $t1.Delay = $script:WHDGuardDelay
    $t2 = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($script:WHDGuardDaily, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture))
    $prin = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    $desc = 'WHD Next 3.0 update guard (alert only): 10 min after sign-in and daily at {0} it checks that WHD''s changes are still in place. It never changes anything.' -f $script:WHDGuardDaily
    [void](Register-ScheduledTask -TaskPath $script:WHDGuardTaskPath -TaskName $script:WHDGuardTaskName -Action $act -Trigger @($t1, $t2) -Principal $prin -Settings $set -Description $desc -Force -ErrorAction Stop)
}
function Unregister-WHDGuardTask {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskPath = $script:WHDGuardTaskPath, [string]$TaskName = $script:WHDGuardTaskName)
    if (-not $PSCmdlet.ShouldProcess(('{0}{1}' -f $TaskPath, $TaskName), 'unregister')) { return }
    if (Get-WHDGuardTask -TaskPath $TaskPath -TaskName $TaskName) { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false -ErrorAction Stop }
}
function Invoke-WHDGuardIcacls {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$IcArgs)
    $r = Invoke-WHDNative -Exe 'icacls.exe' -ArgList $IcArgs
    if ($r.Code -ne 0) { throw ('icacls {0} failed ({1}): {2}' -f ($IcArgs -join ' '), $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
}
function Test-WHDGuardEventSource {
    # the registration itself (EventLog.SourceExists also searches the Security log and throws when not elevated)
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Source = $script:WHDGuardSource)
    return [bool](Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\{0}\{1}' -f $script:WHDGuardLogName, $Source))
}
function Register-WHDGuardEventSource {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:WHDGuardSource, 'register event-log source')) { return }
    if (-not (Test-WHDGuardEventSource)) { [System.Diagnostics.EventLog]::CreateEventSource($script:WHDGuardSource, $script:WHDGuardLogName) }
}
function Unregister-WHDGuardEventSource {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Source = $script:WHDGuardSource)
    if (-not $PSCmdlet.ShouldProcess($Source, 'remove event-log source')) { return }
    if (Test-WHDGuardEventSource -Source $Source) { [System.Diagnostics.EventLog]::DeleteEventSource($Source) }
}
function Write-WHDGuardEvent {
    # $true when written (the source must be registered - the check never registers it)
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Message, [ValidateSet('Warning', 'Information', 'Error')][string]$Type = 'Warning', [int]$EventId = 3001)
    if (-not (Test-WHDGuardEventSource)) { return $false }
    try { [System.Diagnostics.EventLog]::WriteEntry($script:WHDGuardSource, $Message, [System.Diagnostics.EventLogEntryType]::$Type, $EventId); return $true }
    catch { Write-WHDLog -Message ('The event-log entry could not be written: {0}' -f $_.Exception.Message) -Level 'WARN'; return $false }
}
function Get-WHDGuardFingerprint {
    # build.UBR + the installed updates: a cumulative / feature update changes it (Defender signatures do not)
    [CmdletBinding()]
    param()
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = if ($cv) { '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR } else { '?' }
    $hf = @()
    try { $hf = @(Get-HotFix -ErrorAction Stop | ForEach-Object { [string]$_.HotFixID } | Where-Object { $_ } | Sort-Object -Unique) } catch { Write-Verbose $_.Exception.Message }
    [pscustomobject]@{ Build = $build; HotFixes = $hf; Text = ('{0}|{1}' -f $build, ($hf -join ',')) }
}
function Get-WHDGuardBusy {
    # reasons NOT to check now: Windows servicing unfinished. Empty = fine.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $why = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $why.Add('a Windows component update is waiting for a restart') }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $why.Add('Windows Update is waiting for a restart') }
    if (@(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue).Count) { $why.Add('Windows is still installing updates (TiWorker running)') }
    return $why.ToArray()
}
function Wait-WHDGuardMinute {
    [CmdletBinding()]
    param([int]$Minutes = 5)
    Start-Sleep -Seconds (60 * $Minutes)
}
function Show-WHDGuardAlert {
    # The small window (D6). $false = it could not be shown (the caller then opens the report).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Lines, [string]$ReportPath)
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $w = [System.Windows.Window]::new()
        $w.Title = 'WHD Next 3.0 - update guard'; $w.SizeToContent = 'WidthAndHeight'; $w.WindowStartupLocation = 'CenterScreen'; $w.Topmost = $true; $w.ResizeMode = 'NoResize'
        $p = [System.Windows.Controls.StackPanel]::new(); $p.Margin = [System.Windows.Thickness]::new(16, 14, 16, 14); $w.Content = $p
        $h = [System.Windows.Controls.TextBlock]::new(); $h.Text = 'The update guard found something to look at'; $h.FontSize = 16; $h.FontWeight = [System.Windows.FontWeights]::Bold; $h.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        [void]$p.Children.Add($h)
        $t = [System.Windows.Controls.TextBlock]::new(); $t.Text = ($Lines -join [Environment]::NewLine); $t.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas'); $t.MaxWidth = 900; $t.TextWrapping = 'Wrap'
        [void]$p.Children.Add($t)
        $row = [System.Windows.Controls.StackPanel]::new(); $row.Orientation = 'Horizontal'; $row.HorizontalAlignment = 'Right'; $row.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
        [void]$p.Children.Add($row)
        if ($ReportPath) {
            $o = [System.Windows.Controls.Button]::new(); $o.Content = 'Open the report'; $o.Padding = [System.Windows.Thickness]::new(12, 3, 12, 3); $o.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0); $o.Tag = $ReportPath
            $o.add_Click({ param($sender, $e) [void]$e; try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f [string]$sender.Tag) } catch { Write-Verbose $_.Exception.Message } })
            [void]$row.Children.Add($o)
        }
        $c = [System.Windows.Controls.Button]::new(); $c.Content = 'Close'; $c.IsCancel = $true; $c.IsDefault = $true; $c.Padding = [System.Windows.Thickness]::new(12, 3, 12, 3)
        $c.add_Click({ param($sender, $e) [void]$e; [System.Windows.Window]::GetWindow($sender).Close() })
        [void]$row.Children.Add($c)
        [void]$w.ShowDialog()
        return $true
    } catch {
        Write-WHDLog -Message ('The alert window could not be shown: {0}' -f $_.Exception.Message) -Level 'WARN'
        return $false
    }
}
function Open-WHDGuardFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $Path)
}

# ---- the locked copy (D90) ------------------------------------------------------------------------------------------------
function Get-WHDGuardSourceFile {
    # what the copy holds, relative to the WHD folder: the entry, the 5.1 front door and the whole module
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Source)
    $rel = [System.Collections.Generic.List[string]]::new()
    foreach ($f in 'WHD.ps1', $script:WHDGuardFrontDoor) { if (Test-Path -LiteralPath (Join-Path $Source $f)) { $rel.Add($f) } }
    $mod = Join-Path $Source 'WHDNext'
    if (Test-Path -LiteralPath $mod) {
        $base = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\', '/')
        foreach ($x in Get-ChildItem -LiteralPath $mod -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName) { $rel.Add($x.FullName.Substring($base.Length + 1)) }
    }
    return $rel.ToArray()
}
function Get-WHDGuardStaleFile {
    # files of the copy that differ from the WHD folder (or are missing); all of them when there is no copy
    [CmdletBinding()]
    [OutputType([string[]])]
    param([string]$Source = $script:WHDState.Root, [string]$CopyDir = (Get-WHDGuardCopyDir))
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($r in (Get-WHDGuardSourceFile -Source $Source)) {
        $a = Join-Path $Source $r; $b = Join-Path $CopyDir $r
        if (-not (Test-Path -LiteralPath $b)) { $out.Add($r); continue }
        if ((Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash) { $out.Add($r) }
    }
    return $out.ToArray()
}
function Copy-WHDGuardFile {
    # Fresh copy into the guard folder, then locked: owner Administrators; Administrators + SYSTEM full, Users read
    # and run (well-known SIDs, so any Windows language). The rest of ProgramData\WinHardenDebloatNext is not touched.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$CopyDir)
    if (-not $PSCmdlet.ShouldProcess($CopyDir, 'copy WHD and lock the folder')) { return }
    if (-not (Test-Path -LiteralPath $CopyDir)) { [void](New-Item -ItemType Directory -Path $CopyDir -Force -ErrorAction Stop) }
    Invoke-WHDGuardIcacls -IcArgs @($CopyDir, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q')
    Invoke-WHDGuardIcacls -IcArgs @($CopyDir, '/inheritance:r', '/grant:r', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX', '/Q')
    Get-ChildItem -LiteralPath $CopyDir -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction Stop
    foreach ($r in (Get-WHDGuardSourceFile -Source $Source)) {
        $to = Join-Path $CopyDir $r
        $d = Split-Path $to -Parent
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
        Copy-Item -LiteralPath (Join-Path $Source $r) -Destination $to -Force -ErrorAction Stop
    }
    Invoke-WHDGuardIcacls -IcArgs @((Join-Path $CopyDir '*'), '/reset', '/T', '/C', '/Q')
}

# ---- old guards (D93) -------------------------------------------------------------------------------------------------------
function Get-WHDGuardOldState {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(foreach ($o in $script:WHDGuardOld) {
        $t = Get-WHDGuardTask -TaskPath $o['TaskPath'] -TaskName $o['TaskName']
        [pscustomobject]@{ Name = $o['Name']; TaskPath = $o['TaskPath']; TaskName = $o['TaskName']; Found = [bool]$t; On = (Test-WHDGuardTaskOn -Task $t) }
    })
}
function Invoke-WHDGuardOldOff {
    # Asked first, one by one; only switched off (the task and its files stay), recorded - the Undo center switches it on again.
    [CmdletBinding()]
    param()
    foreach ($o in @(Get-WHDGuardOldState | Where-Object { $_.Found -and $_.On })) {
        Write-WHDLog -Message ('{0}''s update guard task ({1}{2}) is switched on - with both, two guards check after every sign-in.' -f $o.Name, $o.TaskPath, $o.TaskName) -Level 'WARN'
        Write-WHDRisk -Tier 'reversible' -Text ('Switches off the scheduled task {0}{1} ({2}''s update guard). Nothing of {2} is removed - its files, reports and the task stay; the task is only disabled. Recorded: the Undo center switches it on again, and Verify reports it if it comes back on.' -f $o.TaskPath, $o.TaskName, $o.Name)
        if (-not (Confirm-WHDProceed -What ('switch off {0}''s update guard task' -f $o.Name))) { Write-WHDLog -Message 'left on.' -Level 'WARN'; continue }
        Set-WHDScheduledTaskEnabled -TaskPath $o.TaskPath -TaskName $o.TaskName -Enabled $false -WasEnabled $true -Confirm:$false
    }
}

# ---- install / refresh, remove -------------------------------------------------------------------------------------------
function Remove-WHDGuardInstall {
    # task + locked copy + event-log source; the reports and scans in the WHD folder are kept
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskPath = $script:WHDGuardTaskPath, [string]$TaskName = $script:WHDGuardTaskName, [string]$CopyDir = (Get-WHDGuardCopyDir), [string]$EventSource = $script:WHDGuardSource)
    if (-not $PSCmdlet.ShouldProcess(('{0}{1}' -f $TaskPath, $TaskName), 'remove the update guard')) { return }
    Unregister-WHDGuardTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
    if ($CopyDir -and (Test-Path -LiteralPath $CopyDir)) { Remove-Item -LiteralPath $CopyDir -Recurse -Force -ErrorAction Stop }
    if ($EventSource) { try { Unregister-WHDGuardEventSource -Source $EventSource -Confirm:$false } catch { Write-WHDLog -Message ('The event-log source could not be removed: {0}' -f $_.Exception.Message) -Level 'WARN' } }
}
function Install-WHDGuard {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'UPDATE GUARD: install / refresh (alert only)' -Level 'ACT'
    if (Test-WHDGuardRunningFromCopy) { Write-WHDLog -Message 'This is the guard''s locked copy - install from the WHD folder instead.' -Level 'ERR'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window (the task runs with highest rights and the copy goes into ProgramData).' -Level 'WARN'; return }
    $copy = Get-WHDGuardCopyDir
    if (-not $copy) { Write-WHDLog -Message 'No ProgramData folder on this PC - the guard has no place.' -Level 'ERR'; return }
    if (-not (Test-Path -LiteralPath (Join-Path $script:WHDState.Root $script:WHDGuardFrontDoor))) { Write-WHDLog -Message ('{0} is missing in the WHD folder - the guard cannot be installed.' -f $script:WHDGuardFrontDoor) -Level 'ERR'; return }
    Invoke-WHDGuardOldOff
    $had = [bool](Get-WHDGuardTask)
    $src = $script:WHDState.Root; $data = $script:WHDState.DataRoot
    Write-WHDRisk -Tier 'reversible' -Text ('Copies WHD to {0} and locks that folder (Administrators and SYSTEM can change it, users only read). Adds the scheduled task {1}{2}: 10 min after you sign in and daily at {3}, as you, with highest rights. It only reads and reports - it never changes anything. If PowerShell 7.6 is missing or broken it only alerts. Registers the event-log source "{4}" (Application log) for its alerts. Reports: {5}. WHD refreshes the copy by itself when its files change. Undo removes the task, the copy and the source.' -f $copy, $script:WHDGuardTaskPath, $script:WHDGuardTaskName, $script:WHDGuardDaily, $script:WHDGuardSource, (Get-WHDGuardDataDir))
    if (-not (Confirm-WHDProceed -What $(if ($had) { 'refresh the update guard (copy + task)' } else { 'install the update guard' }))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $jr = @{ Kind = 'schtask'; TaskPath = $script:WHDGuardTaskPath; TaskName = $script:WHDGuardTaskName; GuardDir = $copy; Existed = $had; EventSource = $script:WHDGuardSource }
    Invoke-WHDChange -Description ('update guard: locked copy in {0} + task {1}{2} (sign-in +10 min, daily {3})' -f $copy, $script:WHDGuardTaskPath, $script:WHDGuardTaskName, $script:WHDGuardDaily) -Journal $jr -Action {
        Copy-WHDGuardFile -Source $src -CopyDir $copy -Confirm:$false
        Register-WHDGuardTask -CopyDir $copy -DataRoot $data -Confirm:$false
        try { Register-WHDGuardEventSource -Confirm:$false } catch { Write-WHDLog -Message ('The event-log source could not be registered (alerts still show the window): {0}' -f $_.Exception.Message) -Level 'WARN' }
        if (-not (Get-WHDGuardTask)) { throw 'read-back: the scheduled task is not there after registering' }
        $left = @(Get-WHDGuardStaleFile -Source $src -CopyDir $copy)
        if ($left.Count) { throw ('read-back: the locked copy differs from the WHD folder ({0} file(s))' -f $left.Count) }
    } | Out-Null
}
function Uninstall-WHDGuard {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'UPDATE GUARD: remove' -Level 'ACT'
    $copy = Get-WHDGuardCopyDir
    if (-not (Get-WHDGuardTask) -and -not ($copy -and (Test-Path -LiteralPath $copy)) -and -not (Test-WHDGuardEventSource)) { Write-WHDLog -Message 'Not installed - nothing to remove.' -Level 'OK'; return }
    if (-not $script:WHDState.IsAdmin) { Write-WHDLog -Message 'Needs an administrator window.' -Level 'WARN'; return }
    Write-WHDRisk -Tier 'reversible' -Text 'Removes the guard''s scheduled task, its locked copy and its event-log source. Its reports and scans in restore\update-guard are kept. Install it again with 1.'
    if (-not (Confirm-WHDProceed -What 'remove the update guard')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $done0 = $script:WHDState.Counts.done
    Invoke-WHDChange -Description 'remove the update guard (task, locked copy, event-log source)' -Journal @{ Kind = 'action'; Hint = 'main menu G > 1 installs the update guard again' } -Action { Remove-WHDGuardInstall -Confirm:$false } | Out-Null
    if ($script:WHDState.Counts.done -gt $done0) {
        # the install entries no longer have to verify
        foreach ($s in @(Get-WHDHistorySession)) {
            foreach ($e in @(Get-WHDHistoryEntry -SessionPath $s.Path -Source $s.Source | Where-Object { [string]$_['Kind'] -eq 'schtask' -and [string]$_['TaskPath'] -eq $script:WHDGuardTaskPath -and -not $_['Undone'] })) { Add-WHDUndoMark -Entry $e }
        }
    }
}
function Update-WHDGuardIfStale {
    # When WHD starts: refresh the locked copy by itself if WHD's files changed (not recorded - the install was).
    [CmdletBinding()]
    param()
    try {
        if (Test-WHDGuardRunningFromCopy) { return }
        if (-not $script:WHDState.IsAdmin -or -not (Get-WHDGuardTask)) { return }
        $copy = Get-WHDGuardCopyDir
        $stale = @(Get-WHDGuardStaleFile -CopyDir $copy)
        if (-not $stale.Count) { return }
        if ($script:WHDState.SafeMode) { Write-WHDLog -Message ('Update guard: its locked copy is out of date ({0} file(s)); it is refreshed when WHD runs without safe mode.' -f $stale.Count); return }
        Copy-WHDGuardFile -Source $script:WHDState.Root -CopyDir $copy -Confirm:$false
        Write-WHDLog -Message ('Update guard: locked copy refreshed ({0} changed file(s)).' -f $stale.Count) -Level 'OK'
    } catch { Write-WHDLog -Message ('Update guard: the locked copy could not be refreshed: {0} - main menu G > 1 refreshes it.' -f $_.Exception.Message) -Level 'WARN' }
}

# ---- status ----------------------------------------------------------------------------------------------------------------
function Get-WHDGuardState {
    # this PC's last check (state.json); another PC's file counts as none
    [CmdletBinding()]
    param()
    $p = Join-Path (Get-WHDGuardDataDir) 'state.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $s = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable } catch { return $null }
    if ([string]$s['MachineId'] -and ([string]$s['MachineId']).ToLowerInvariant() -ne (Get-WHDMachineId)) { return $null }
    return $s
}
function Save-WHDGuardState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    $State['MachineId'] = Get-WHDMachineId; $State['Computer'] = [string]$env:COMPUTERNAME
    try {
        $d = Get-WHDGuardDataDir
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Join-Path $d 'state.json') -Encoding utf8 -ErrorAction Stop
    } catch { Write-WHDLog -Message ('UPDATE GUARD: its status could not be saved: {0}' -f $_.Exception.Message) -Level 'ERR' }
}
function Get-WHDGuardStatus {
    [CmdletBinding()]
    param()
    $t = Get-WHDGuardTask
    $copy = Get-WHDGuardCopyDir
    $hasCopy = [bool]($copy -and (Test-Path -LiteralPath (Join-Path $copy 'WHD.ps1')))
    $stale = if ($hasCopy -and -not (Test-WHDGuardRunningFromCopy)) { @(Get-WHDGuardStaleFile -CopyDir $copy).Count } else { 0 }
    $st = Get-WHDGuardState
    $txt = if (-not $t) { 'not installed' } elseif (Test-WHDGuardTaskOn -Task $t) { 'installed, on ({0})' -f $t.State } else { 'installed but SWITCHED OFF' }
    if ($t -and -not $hasCopy) { $txt += ' - locked copy MISSING (1 refreshes it)' }
    elseif ($stale) { $txt += (' - locked copy out of date ({0} file(s); refreshed when WHD starts as administrator)' -f $stale) }
    $last = if ($st -and $st['LastCheck']) { 'last check {0}: {1}' -f $st['LastCheck'], $st['LastResult'] } elseif ($t) { 'no check yet' } else { '' }
    [pscustomobject]@{ Installed = [bool]$t; On = (Test-WHDGuardTaskOn -Task $t); Copy = $hasCopy; Stale = $stale; Source = (Test-WHDGuardEventSource); Last = $st; LastText = $last; Text = $txt }
}

# ---- the check (read-only) -------------------------------------------------------------------------------------------------
function Save-WHDGuardReport {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path, [string[]]$Lines)
    try {
        $d = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop) }
        $Lines | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
        return $true
    } catch {
        Write-WHDLog -Message ('UPDATE GUARD: the report could not be saved to {0}: {1}' -f $Path, $_.Exception.Message) -Level 'ERR'
        foreach ($l in @($Lines)) { Write-WHDLog -Message ('  | {0}' -f $l) }
        return $false
    }
}
function Remove-WHDGuardOldScan {
    # keeps the newest $Keep scans the guard made (marked folders); returns the names removed
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$InvRoot, [int]$Keep = $script:WHDGuardKeep)
    $g = @(Get-ChildItem -LiteralPath $InvRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName $script:WHDGuardMarker) } | Sort-Object Name)
    $gone = [System.Collections.Generic.List[string]]::new()
    if ($g.Count -gt $Keep -and $PSCmdlet.ShouldProcess($InvRoot, 'remove older guard scans')) {
        foreach ($d in $g[0..($g.Count - $Keep - 1)]) { try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop; $gone.Add($d.Name) } catch { Write-Verbose $_.Exception.Message } }
    }
    return $gone.ToArray()
}
function Invoke-WHDGuardCheck {
    # -Now = from the menu / window: never waits for Windows servicing, shows no alert window.
    [CmdletBinding()]
    param([switch]$Now, [switch]$NoPopup)
    $dataDir = Get-WHDGuardDataDir
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $report = Join-Path $dataDir ('guard_{0}.txt' -f $stamp)
    $rep = [System.Collections.Generic.List[string]]::new()
    $alert = $false
    $state = Get-WHDGuardState
    $rep.Add('WHD Next 3.0 - UPDATE GUARD (alert only - nothing was changed)')
    $rep.Add(('Checked : {0}   on {1} as {2}\{3}   ({4})' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME, $env:USERDOMAIN, $env:USERNAME, $(if ($Now) { 'check now' } else { 'scheduled' })))
    $rep.Add(('Engine  : PowerShell {0}' -f $PSVersionTable.PSVersion))
    $rep.Add('')
    Write-WHDLog -Message 'UPDATE GUARD: checking (read-only) ...' -Level 'ACT'

    # 1. never in the middle of Windows servicing
    $busy = @(Get-WHDGuardBusy)
    if ($Now -and $busy.Count) {
        Write-WHDLog -Message ('UPDATE GUARD: not checking now - {0}. Try again when Windows has finished (the scheduled check waits by itself).' -f ($busy -join '; ')) -Level 'WARN'
        return [pscustomobject]@{ Result = 'BUSY'; Alert = $false; Report = '' }
    }
    $waited = 0
    while ($busy.Count -and -not ($busy -match 'restart') -and $waited -lt 30) {
        Write-WHDLog -Message ('waiting 5 min: {0}' -f ($busy -join '; '))
        Wait-WHDGuardMinute -Minutes 5; $waited += 5
        $busy = @(Get-WHDGuardBusy)
    }
    if ($busy.Count) {
        $rep.Insert(2, ('RESULT  : SKIPPED - {0}. The guard checks again at the next sign-in or at {1}.' -f ($busy -join '; '), $script:WHDGuardDaily))
        if (-not (Save-WHDGuardReport -Path $report -Lines $rep.ToArray())) { $report = '' }
        Save-WHDGuardState -State (@{ Fingerprint = $(if ($state) { [string]$state['Fingerprint'] } else { '' }); LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = 'skipped (Windows servicing)'; LastReport = $report })
        Write-WHDLog -Message ('UPDATE GUARD: skipped - {0}' -f ($busy -join '; ')) -Level 'WARN'
        return [pscustomobject]@{ Result = 'SKIPPED'; Alert = $false; Report = $report }
    }

    # 2. every recorded change still in place?
    $rep.Add('-- 1. WHD CHANGES STILL IN PLACE? (Verify, latest state per item) --------')
    $res = @()
    try { $res = @(Invoke-WHDVerify -All) } catch { $rep.Add(('  !! Verify could not run: {0}' -f $_.Exception.Message)); $alert = $true }
    $bad = @($res | Where-Object { $_.Result -in 'CHANGED', 'RETURNED' })
    $rep.Add(('  {0} checked: {1} pass, {2} changed / returned' -f $res.Count, @($res | Where-Object Result -eq 'PASS').Count, $bad.Count))
    foreach ($b in $bad) { $rep.Add(('  !! {0,-8} {1}   now: {2}' -f $b.Result, $b.Target, $b.Now)) }
    if ($bad.Count) { $alert = $true; $rep.Add('  -> Main menu V shows the same list and re-applies / re-removes them (window: Inventory / Undo > Verify).') }
    $rep.Add('')

    # 3. refused clock jumps since the last check
    $rep.Add('-- 2. TIME: REFUSED CLOCK JUMPS ------------------------------------------')
    $since = (Get-Date).AddDays(-7)
    if ($state -and $state['LastCheck']) { try { $since = [datetime]::ParseExact([string]$state['LastCheck'], 'yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) } catch { Write-Verbose $_.Exception.Message } }
    $tev = @()
    try { $tev = @(Get-WHDTimeJumpEvent -Since $since) } catch { $rep.Add(('  (the System log could not be read: {0})' -f $_.Exception.Message)) }
    if ($tev.Count) {
        $alert = $true
        $rep.Add(('  !! Windows refused {0} time correction(s) bigger than the limit since {1:yyyy-MM-dd HH:mm}:' -f $tev.Count, $since))
        foreach ($e in $tev) { $rep.Add(('     {0:yyyy-MM-dd HH:mm}  {1}' -f $e.Time, $e.Message)) }
        $rep.Add('  -> Check the clock. If it really is wrong: Settings > Time & language > Date & time - set it, then Sync now. If it is right, something sent a wrong time and the limit stopped it.')
    } else { $rep.Add(('  none since {0:yyyy-MM-dd HH:mm}' -f $since)) }
    $rep.Add('')

    # 4. update gate and IP block list (info only, never an alert)
    $rep.Add('-- 3. UPDATE GATE AND IP BLOCK LIST (info only) --------------------------')
    try { $gs = Get-WHDGateState; $rep.Add(('  update gate: {0}   (outbound {1})' -f $gs.Text, $gs.Outbound)) } catch { $rep.Add(('  update gate: not readable ({0})' -f $_.Exception.Message)) }
    try { $bl = Get-WHDBlocklistNeed; $rep.Add(('  IP block list: {0}' -f $bl.Text)) } catch { $rep.Add(('  IP block list: not readable ({0})' -f $_.Exception.Message)) }
    $rep.Add('')

    # 5. apps after Windows updates: scan + compare only when Windows changed
    $rep.Add('-- 4. APPS AFTER WINDOWS UPDATES (inventory compare) --------------------')
    $fp = Get-WHDGuardFingerprint
    $prev = if ($state) { [string]$state['Fingerprint'] } else { '' }
    $newFp = $prev
    if ($prev -and $prev -eq $fp.Text) {
        $rep.Add(('  No Windows update since the last check (build {0}) - no scan needed.' -f $fp.Build))
    } else {
        if (-not $prev) { $rep.Add(('  First guard check - a baseline scan (build {0}).' -f $fp.Build)) }
        else {
            $oldHf = @(($prev.Split('|') + @('', ''))[1] -split ',' | Where-Object { $_ })
            $added = @($fp.HotFixes | Where-Object { $oldHf -notcontains $_ })
            $rep.Add(('  Windows changed: build {0} -> {1}{2}' -f $prev.Split('|')[0], $fp.Build, $(if ($added.Count) { '; new updates: ' + ($added -join ', ') } else { '' })))
        }
        $invRoot = Get-WHDGuardInvRoot
        $keepOv = $script:WHDInvOverride
        $script:WHDInvOverride = $invRoot
        try {
            [object[]]$before = Get-WHDInvScan      # an array already (no @(): it would nest it)
            $scan = $null
            try { $scan = Invoke-WHDInventory } catch { $rep.Add(('  !! the inventory scan stopped: {0}' -f $_.Exception.Message)) }
            if (-not $scan -or -not (Test-Path -LiteralPath (Join-Path $scan 'REPORT.txt'))) {
                $rep.Add('  !! the inventory scan did not finish - tried again at the next check.')
            } else {
                Set-Content -LiteralPath (Join-Path $scan $script:WHDGuardMarker) -Value ('made by the update guard {0}' -f $stamp) -Encoding ascii -ErrorAction SilentlyContinue
                $newFp = $fp.Text
                $rep.Add(('  Scan: {0}' -f $scan))
                if ($before.Count) {
                    $d = Get-WHDInvDiff -OldDir $before[-1].FullName -NewDir $scan
                    if ($d.CameBack) {
                        $alert = $true
                        $rep.Add(('  !! {0} app(s) that WHD removed CAME BACK:' -f $d.CameBack))
                        foreach ($r in @($d.Rows | Where-Object { $_.Note -like 'CAME BACK*' })) { $rep.Add(('     {0}   ({1})' -f $r.Item, $r.Note)) }
                        $rep.Add('  -> Main menu V re-removes them.')
                    }
                    $rep.Add('')
                    foreach ($l in @($d.Lines | Select-Object -First 400)) { $rep.Add($l) }
                } else { $rep.Add('  (no earlier guard scan to compare with - this one is the baseline)') }
                $gone = @(Remove-WHDGuardOldScan -InvRoot $invRoot -Confirm:$false)
                if ($gone.Count) { $rep.Add(''); $rep.Add(('  Removed {0} older guard scan(s) (keeping the last {1}).' -f $gone.Count, $script:WHDGuardKeep)) }
            }
        } finally { $script:WHDInvOverride = $keepOv }
    }
    $rep.Add('')
    $result = if ($alert) { 'ALERT' } else { 'OK' }
    $rep.Insert(2, ('RESULT  : ' + $(if ($alert) { 'ALERT - see the !! lines below' } else { 'OK - nothing WHD set or removed has changed' })))
    if (-not (Save-WHDGuardReport -Path $report -Lines $rep.ToArray())) { $alert = $true; $result = 'ALERT'; $report = '' }
    Save-WHDGuardState -State (@{ Fingerprint = $newFp; LastCheck = (Get-Date -Format 'yyyy-MM-dd HH:mm'); LastResult = $result; LastReport = $report })
    Write-WHDLog -Message ('UPDATE GUARD: {0} - report: {1}' -f $result, $(if ($report) { $report } else { '(not saved)' })) -Level $(if ($alert) { 'WARN' } else { 'OK' })
    if ($alert) {
        $lines = @($rep | Where-Object { $_ -like 'RESULT*' -or $_ -match '^\s*!!' })
        [void](Write-WHDGuardEvent -Message ("WHD Next 3.0 update guard: ALERT`r`n{0}`r`nReport: {1}" -f ($lines -join "`r`n"), $report))
        if (-not $NoPopup) {
            $shown = Show-WHDGuardAlert -Lines (@($lines) + @('', 'Nothing was changed. "Open the report" shows the details and what to do.')) -ReportPath $report
            if (-not $shown -and $report) { try { Open-WHDGuardFile -Path $report } catch { Write-Verbose $_.Exception.Message } }
        }
    }
    [pscustomobject]@{ Result = $result; Alert = $alert; Report = $report }
}

# ---- the menu (main menu G) --------------------------------------------------------------------------------------------------
function Show-WHDGuardMenu {
    [CmdletBinding()]
    param()
    $g = Get-WHDGuardStatus
    Write-Host ''
    Write-Host '  ======= UPDATE GUARD (alert only - it never changes anything) =======' -ForegroundColor White
    Write-Host ('  Guard now: {0}' -f $g.Text) -ForegroundColor $(if ($g.Installed -and $g.On -and $g.Copy) { 'Green' } else { 'Yellow' })
    if ($g.LastText) { Write-Host ('  {0}' -f $g.LastText) -ForegroundColor Gray }
    Write-Host ('  Event-log source "{0}": {1}' -f $script:WHDGuardSource, $(if ($g.Source) { 'registered' } else { 'not registered' })) -ForegroundColor Gray
    foreach ($o in @(Get-WHDGuardOldState | Where-Object Found)) { Write-Host ('  {0}''s guard task: {1}' -f $o.Name, $(if ($o.On) { 'ON (offered to switch off at 1)' } else { 'off' })) -ForegroundColor $(if ($o.On) { 'Yellow' } else { 'Gray' }) }
    Write-Host '  Guard' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key '1' -Label 'Install / refresh the guard' -Hint ('[locked copy + task: 10 min after sign-in and daily {0}]' -f $script:WHDGuardDaily)
    Write-WHDMenuItem -Key '2' -Label 'Check now (read-only)' -Hint '[the same check; the report is shown here]'
    Write-WHDMenuItem -Key '3' -Label 'Open the last report'
    Write-WHDMenuItem -Key '4' -Label 'Remove the guard' -Hint '[task, locked copy, event-log source; reports kept]'
    Write-WHDMenuCommonKey
}
function Invoke-WHDGuardChoice {
    # One menu choice. Returns $false for B (back).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Bb]$' { return $false }
        '^$' { return $true }
        '^1$' { Install-WHDGuard }
        '^2$' {
            $r = Invoke-WHDGuardCheck -Now -NoPopup
            if ($r.Report -and (Test-Path -LiteralPath $r.Report)) { foreach ($l in @(Get-Content -LiteralPath $r.Report -Encoding utf8)) { Write-Host ('  {0}' -f $l) } }
        }
        '^3$' {
            $st = Get-WHDGuardState
            $p = if ($st -and $st['LastReport'] -and (Test-Path -LiteralPath ([string]$st['LastReport']))) { [string]$st['LastReport'] } else { '' }
            if (-not $p) { $p = @(Get-ChildItem -LiteralPath (Get-WHDGuardDataDir) -Filter 'guard_*.txt' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1 | ForEach-Object FullName) -join '' }
            if ($p) { Write-WHDLog -Message ('Opening {0}' -f $p); Open-WHDGuardFile -Path $p } else { Write-WHDLog -Message 'No guard report yet - 2 checks now.' -Level 'WARN' }
        }
        '^4$' { Uninstall-WHDGuard }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}
