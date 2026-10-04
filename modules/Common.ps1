<#
================================================================================
 WinHardenDebloat  -  modules\Common.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Shared safety engine. Dot-sourced by WHD.ps1 and every action module.

 Core contract:
   * NOTHING changes unless $script:WHDExecute is $true (set by -Execute or the
     launcher toggle). Otherwise every mutating call is a printed DRY-RUN line.
   * Before the FIRST real change in a session, a System Restore point is made
     and affected registry keys are exported to restore\ .
   * Every run is transcript-logged to logs\ .

 No StrictMode (single-object .Count trap). Collections wrapped in @().
================================================================================
#>

# ---- session-wide state (set by launcher / entry script) --------------------
if (-not (Get-Variable -Name WHDExecute -Scope Script -EA SilentlyContinue)) {
    $script:WHDExecute      = $false   # dry-run by default
}
if (-not (Get-Variable -Name WHDRoot -Scope Script -EA SilentlyContinue)) {
    if ($PSScriptRoot) { $script:WHDRoot = Split-Path -Parent $PSScriptRoot }  # modules\ -> project root
    else               { $script:WHDRoot = (Get-Location).Path }
}
$script:WHDRestoreDone   = $false      # restore point made this session?
$script:WHDStamp         = Get-Date -Format 'yyyy-MM-dd_HHmmss'

# ---- engine/UI contract (Phase 2) -------------------------------------------
# The confirmation STRATEGY is injected by the caller (dependency injection),
# so the engine never owns a blocking prompt:
#   * interactive menu  -> a Read-Host y/N strategy (the default below)
#   * profile runner/GUI -> an auto-approve strategy (set after one upfront gate)
if (-not (Get-Variable -Name WHDConfirm -Scope Script -EA SilentlyContinue)) {
    $script:WHDConfirm = {
        param($Msg)
        Write-Host ("  Proceed with: {0}? [y/N] " -f $Msg) -ForegroundColor Magenta -NoNewline
        return ((Read-Host) -match '^[Yy]')
    }
}
# Structured results every action records, for any caller (runner/GUI) to read.
if (-not (Get-Variable -Name WHDResults -Scope Script -EA SilentlyContinue)) {
    $script:WHDResults = New-Object System.Collections.Generic.List[object]
}
if (-not (Get-Variable -Name WHDCounts -Scope Script -EA SilentlyContinue)) {
    $script:WHDCounts = @{ planned = 0; done = 0; failed = 0; skipped = 0 }
}
function New-WHDResult {
    param([string]$Action, [ValidateSet('planned','done','failed','skipped')]$Status, [string]$Detail = '')
    $r = [pscustomobject]@{ Time = (Get-Date); Action = $Action; Status = $Status; Detail = $Detail }
    $script:WHDResults.Add($r) | Out-Null
    if ($script:WHDCounts.ContainsKey($Status)) { $script:WHDCounts[$Status] = [int]$script:WHDCounts[$Status] + 1 }
    return $r
}
function Reset-WHDResults {
    $script:WHDResults = New-Object System.Collections.Generic.List[object]
    $script:WHDCounts  = @{ planned = 0; done = 0; failed = 0; skipped = 0 }
}
function Get-WHDResults { $script:WHDResults.ToArray() }
function Get-WHDCounts  { $script:WHDCounts }

# Uses the injected strategy. Dry-run always "proceeds" (to preview). Callers
# replace $script:WHDConfirm to change how approval is obtained.
function Confirm-WHDProceed {
    param([string]$What)
    if (-not $script:WHDExecute) { return $true }
    return [bool](& $script:WHDConfirm $What)
}

# ---- folders ----------------------------------------------------------------
function Initialize-WHDPaths {
    $script:WHDLogs     = Join-Path $script:WHDRoot 'logs'
    $script:WHDRestore  = Join-Path $script:WHDRoot ('restore\' + $script:WHDStamp)
    foreach ($d in @($script:WHDLogs, $script:WHDRestore)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
}

# ---- logging ----------------------------------------------------------------
# A caller (e.g. the GUI) may set $script:WHDLogSink = { param($line,$level) ... }
# to also receive every log line. Console output is unchanged.
if (-not (Get-Variable -Name WHDLogSink -Scope Script -EA SilentlyContinue)) { $script:WHDLogSink = $null }
function Write-WHDLog {
    param([string]$Message, [ValidateSet('INFO','WARN','ERR','OK','DRY','ACT')]$Level = 'INFO')
    $line = "[{0}] {1,-4} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'OK'   { Write-Host $line -ForegroundColor Green }
        'DRY'  { Write-Host $line -ForegroundColor Cyan }
        'ACT'  { Write-Host $line -ForegroundColor Magenta }
        default { Write-Host $line }
    }
    if ($script:WHDLogSink) { try { & $script:WHDLogSink $line $Level } catch {} }
}

function Start-WHDTranscript {
    Initialize-WHDPaths
    $log = Join-Path $script:WHDLogs ("run_{0}.log" -f $script:WHDStamp)
    try { Start-Transcript -Path $log -Append | Out-Null } catch {}
    Write-WHDLog ("Session start | Execute={0} | Root={1}" -f $script:WHDExecute, $script:WHDRoot)
}
function Stop-WHDTranscript { try { Stop-Transcript | Out-Null } catch {} }

# ---- elevation --------------------------------------------------------------
function Test-WHDAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# Warns when the elevated process runs as a different account than the user who is signed in
# (the UAC prompt was answered with another administrator's name and password): per-user
# settings then go to the elevated account. Read-only, never throws, silent when they match.
function Write-WHDAccountWarning {
    try {
        $awRun  = "{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME
        $awUser = "$((Get-CimInstance Win32_ComputerSystem -EA Stop).UserName)"
        if ($awUser -and ($awUser -ne $awRun)) {
            Write-WHDLog ("WHD is running as {0} but the signed-in user is {1}." -f $awRun, $awUser) 'WARN'
            Write-WHDLog ("Per-user settings (app permissions, Copilot, suggestions, privacy switches, proxy auto-detect) and the update guard task will apply to {0}, not to the signed-in user. Sign in with the administrator account itself, or make the daily account an administrator for the run." -f $awRun) 'WARN'
        }
    } catch {}
}

# ---- risk labelling ---------------------------------------------------------
function Write-WHDRisk {
    param([ValidateSet('reversible','caution','hard')]$Tier, [string]$Text)
    $map = @{ reversible = 'Green'; caution = 'Yellow'; hard = 'Red' }
    Write-Host ("    [{0}] " -f $Tier.ToUpper()) -ForegroundColor $map[$Tier] -NoNewline
    Write-Host $Text
    if ($script:WHDLogSink) { try { & $script:WHDLogSink ("    [{0}] {1}" -f $Tier.ToUpper(), $Text) 'INFO' } catch {} }
}

# ---- restore point + registry backup (before first real change) ------------
function New-WHDRestorePoint {
    # Idempotent per session. Enables System Protection on C: if needed, lifts
    # the 24h throttle, then checkpoints. Best-effort: warns, never blocks.
    if ($script:WHDRestoreDone) { return }
    if (-not $script:WHDExecute) { return }
    Write-WHDLog 'Creating System Restore point before first change...' 'ACT'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -EA Stop
    } catch { Write-WHDLog "Enable-ComputerRestore: $($_.Exception.Message)" 'WARN' }
    # lift the once-per-24h throttle so our checkpoint isn't silently skipped
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    try {
        if (-not (Test-Path $srKey)) { New-Item -Path $srKey -Force | Out-Null }
        New-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
    } catch {}
    try {
        Checkpoint-Computer -Description ("WinHardenDebloat {0}" -f $script:WHDStamp) -RestorePointType 'MODIFY_SETTINGS' -EA Stop
        Write-WHDLog 'System Restore point created.' 'OK'
    } catch {
        Write-WHDLog "Checkpoint-Computer failed: $($_.Exception.Message)" 'WARN'
        Write-WHDLog 'Continuing; registry/package exports in restore\ are still captured.' 'WARN'
    }
    $script:WHDRestoreDone = $true
}

function New-WHDCheckpointNow {
    # On-demand restore point (ignores the once-per-session guard).
    if (-not $script:WHDExecute) { Write-WHDLog 'would: create a System Restore point now' 'DRY'; return }
    Write-WHDLog 'Creating a System Restore point on demand...' 'ACT'
    $script:WHDRestoreDone = $false
    New-WHDRestorePoint
}

function Backup-WHDRegistryKey {
    param([string]$PsPath)   # PowerShell form: HKLM:\...  or  HKCU:\...
    if (-not $script:WHDExecute) { return }
    Initialize-WHDPaths
    # Each key is handled only ONCE per session (first write): a later export would already contain WHD's own values.
    if (-not $script:WHDRegBackupSeen) { $script:WHDRegBackupSeen = @{} }
    if ($script:WHDRegBackupSeen.ContainsKey($PsPath)) { return }
    $script:WHDRegBackupSeen[$PsPath] = $true
    # Only export keys that already exist. A key we are about to CREATE has
    # nothing to back up (rollback = delete it), and running reg.exe on a
    # missing key just throws a noisy (caught) error into the transcript.
    if (-not (Test-Path -LiteralPath $PsPath)) { return }
    $regPath = $PsPath -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
    $safe = ($PsPath -replace '[:\\]', '_')
    $out  = Join-Path $script:WHDRestore ("$safe.reg")
    if (Test-Path -LiteralPath $out -EA SilentlyContinue) { return }   # never overwrite an export already in this session folder
    $ErrorActionPreference = 'Continue'
    try { & reg.exe export "$regPath" "$out" /y 2>$null 1>$null } catch {}
}

# ---- the central mutation chokepoint (engine) -------------------------------
# Never prompts (approval is the caller's job, via Confirm-WHDProceed). Dry-run
# records/prints intent; execute makes the restore point, runs the action, and
# records the outcome. Returns a structured result and appends it to WHDResults.
# -Force is retained for call-site compatibility and is a no-op.
function Invoke-WHDChange {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [switch]$Force,
        # Phase 5: what to record in the change journal (restore\<stamp>\journal.jsonl).
        # Omit -> recorded as Kind 'action' (listed in the Undo center, manual undo).
        [hashtable]$Journal
    )
    if (-not $script:WHDExecute) {
        Write-WHDLog ("would: {0}" -f $Description) 'DRY'
        return (New-WHDResult -Action $Description -Status 'planned')
    }
    New-WHDRestorePoint
    try {
        & $Action
        Write-WHDLog ("done: {0}" -f $Description) 'OK'
        Add-WHDJournal -Description $Description -Data $Journal
        return (New-WHDResult -Action $Description -Status 'done')
    } catch {
        $msg = $_.Exception.Message
        # A locked key (policy/ACL) is the environment blocking us, not a bug -
        # report it softly as skipped rather than an alarming failure.
        if (($_.Exception -is [System.UnauthorizedAccessException]) -or ($msg -match 'unauthorized')) {
            Write-WHDLog ("blocked (permissions/policy), skipped: {0}" -f $Description) 'WARN'
            return (New-WHDResult -Action $Description -Status 'skipped' -Detail $msg)
        }
        Write-WHDLog ("FAILED: {0} :: {1}" -f $Description, $msg) 'ERR'
        return (New-WHDResult -Action $Description -Status 'failed' -Detail $msg)
    }
}

# ---- registry helper (backs up, then sets) ----------------------------------
# Reads one registry value's current state WITHOUT changing anything.
# Used for the journal (what was there before) and for read-back verification.
function Get-WHDRegValueState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $st = [ordered]@{ KeyExists = $false; Exists = $false; Value = $null; Type = $null }
    # Test-Path first: a missing key is normal here and must not leave a
    # TerminatingError line in the transcript.
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$st }
    $k = Get-Item -LiteralPath $Path -EA SilentlyContinue
    if (-not $k) { return [pscustomobject]$st }
    $st.KeyExists = $true
    if (@($k.GetValueNames()) -contains $Name) {
        $st.Exists = $true
        $st.Value  = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $st.Type   = "$($k.GetValueKind($Name))"
    }
    return [pscustomobject]$st
}

# Compares two registry values the way Windows stores them.
function Test-WHDRegValueEqual {
    param($A, $B, [string]$Type)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    switch ($Type) {
        'DWord'       { return (([int64]$A -band 0xFFFFFFFFL) -eq ([int64]$B -band 0xFFFFFFFFL)) }
        'QWord'       { return ([int64]$A -eq [int64]$B) }
        'MultiString' { return ((@($A) -join "`n") -eq (@($B) -join "`n")) }
        'Binary'      { return ((@($A) -join ',') -eq (@($B) -join ',')) }
        default       { return ("$A" -eq "$B") }
    }
}

function Set-WHDRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Path,      # PowerShell form: HKLM:\...
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord','String','ExpandString','QWord','MultiString','Binary')]$Type = 'DWord'
    )
    $desc = "reg set $Path\$Name = $Value ($Type)"
    # Capture what is there now so the Undo center can put it back exactly.
    $before = Get-WHDRegValueState -Path $Path -Name $Name
    $jr = @{
        Kind = 'reg'; Path = $Path; Name = $Name
        OldKeyExists = [bool]$before.KeyExists; OldExists = [bool]$before.Exists
        OldValue = $before.Value; OldType = $before.Type
        NewExists = $true; NewValue = $Value; NewType = $Type
    }
    # Result goes to WHDResults only (Out-Null), so callers that don't pipe it
    # never spill a result table onto the console.
    Invoke-WHDChange -Description $desc -Force -Journal $jr -Action {
        Backup-WHDRegistryKey -PsPath $Path
        # -LiteralPath: a path is never treated as a wildcard pattern (one key only).
        if (-not (Test-Path -LiteralPath $Path)) {
            # New-Item has no -LiteralPath for the registry, so a key that has to be created must not hold wildcard characters.
            if ($Path -match '[*?\[\]]') { throw 'registry path contains wildcard characters' }
            New-Item -Path $Path -Force | Out-Null
        }
        # Set-ItemProperty creates-or-updates; New-ItemProperty -Force throws
        # "unauthorized operation" when the value already exists.
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force
        # F21: read it back - a silently ignored write (policy lock) is a failure.
        $after = Get-WHDRegValueState -Path $Path -Name $Name
        if (-not $after.Exists -or -not (Test-WHDRegValueEqual $after.Value $Value $Type)) {
            throw ("read-back mismatch: wanted '{0}', found '{1}'" -f $Value, $(if($after.Exists){$after.Value}else{'(missing)'}))
        }
    } | Out-Null
}

# Deletes one registry value (journaled + verified, so it can be undone).
function Remove-WHDRegistryValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $before = Get-WHDRegValueState -Path $Path -Name $Name
    if (-not $before.Exists) { Write-WHDLog ("reg value already absent: {0}\{1}" -f $Path, $Name) 'INFO'; return }
    $jr = @{
        Kind = 'reg'; Path = $Path; Name = $Name
        OldKeyExists = $true; OldExists = $true; OldValue = $before.Value; OldType = $before.Type
        NewExists = $false; NewValue = $null; NewType = $null
    }
    Invoke-WHDChange -Description ("reg delete {0}\{1}" -f $Path, $Name) -Force -Journal $jr -Action {
        Backup-WHDRegistryKey -PsPath $Path
        Remove-ItemProperty -LiteralPath $Path -Name $Name -EA Stop
        if ((Get-WHDRegValueState -Path $Path -Name $Name).Exists) { throw 'read-back mismatch: value still present' }
    } | Out-Null
}

# Phase 7: is a set of registry ops (@{P;N;V;T}) currently in effect?
# Returns 'set' (all match), 'partly' or 'not set'. Read-only.
function Get-WHDRegOpsState {
    param([object[]]$Ops)
    $ops = @($Ops | Where-Object { $_ })
    if (-not $ops.Count) { return 'n/a' }
    $hit = 0
    foreach ($op in $ops) {
        $t = if ($op.T) { $op.T } else { 'DWord' }
        $st = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($st.Exists -and (Test-WHDRegValueEqual $st.Value $op.V $t)) { $hit++ }
    }
    if ($hit -eq $ops.Count) { return 'set' }
    if ($hit -gt 0) { return 'partly' }
    return 'not set'
}

# ---- Appx removal helpers (correct order: remove-all-users THEN deprovision) -
function Remove-WHDAppxAllUsers {
    param([Parameter(Mandatory)][string]$NameLike)
    $pkgs = @(Get-AppxPackage -AllUsers -Name $NameLike -EA SilentlyContinue)
    if (-not $pkgs) { Write-WHDLog ("no installed package matches '{0}'" -f $NameLike) 'INFO'; return }
    foreach ($p in $pkgs) {
        $jr = @{ Kind = 'appx'; Package = "$($p.Name)"; FullName = "$($p.PackageFullName)" }
        # The result is the last object returned; mark only when the removal did not fail (dry-run: 'planned').
        $rmRes = @(Invoke-WHDChange -Description ("remove Appx (all users): {0}" -f $p.PackageFullName) -Force -Journal $jr -Action {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -EA Stop
        })[-1]
        if (("$($rmRes.Status)" -in @('done', 'planned')) -and "$($p.PackageFamilyName)") { Add-WHDDeprovisionMark -Pfn "$($p.PackageFamilyName)" }
    }
}
# Microsoft's "keep removed apps from returning during an update" mark (Microsoft Learn:
# remove-provisioned-apps-during-update): HKLM\...\Appx\AppxAllUserStore\Deprovisioned\<PackageFamilyName>.
# Windows only writes it itself when the PC is online during removal - WHD writes it always.
$script:WHDDeprovKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
function Add-WHDDeprovisionMark {
    param([Parameter(Mandatory)][string]$Pfn)
    $dpPath = Join-Path $script:WHDDeprovKey $Pfn
    if (Test-Path -LiteralPath $dpPath) { return }
    Invoke-WHDChange -Description ("mark as deprovisioned (Windows updates must not bring it back): {0}" -f $Pfn) -Force -Journal @{ Kind = 'deprov'; Pfn = $Pfn } -Action {
        New-Item -Path $dpPath -Force -EA Stop | Out-Null
    } | Out-Null
}
# Re-apply settings that Verify reports as CHANGED (user decision 2026-09-28: one-key re-apply
# instead of extra locks). Puts back the value WHD recorded as its own change. One confirm for the batch.
function Invoke-WHDReApplyChanged {
    param([object[]]$Results)
    if (-not $Results) { $Results = @(Invoke-WHDVerify -All -Quiet) }
    $auto = @('reg', 'service', 'task', 'pnpdev', 'deprov', 'fwlog', 'mppref', 'asr', 'tz')
    $bad  = @($Results | Where-Object { $_.Result -eq 'CHANGED' })
    $todo = @($bad | Where-Object { $auto -contains "$($_.Entry.Kind)" })
    $hand = @($bad | Where-Object { $auto -notcontains "$($_.Entry.Kind)" })
    foreach ($h in $hand) { Write-WHDLog ("re-apply by hand (menu): {0}" -f $h.Target) 'WARN' }
    if (-not $todo.Count) { if (-not $hand.Count) { Write-WHDLog 'No changed settings - nothing to re-apply.' 'OK' }; return }
    Write-WHDLog ("RE-APPLY {0} setting(s) that changed back:" -f $todo.Count) 'ACT'
    foreach ($t in $todo) { Write-WHDLog ("  {0}   now: {1}" -f $t.Target, $t.Now) 'INFO' }
    Write-WHDRisk 'reversible' 'Puts back exactly what WHD set before (the recorded new value). Journaled again, so the Undo center can reverse it.'
    if (-not (Confirm-WHDProceed ("re-apply {0} changed setting(s)" -f $todo.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $prevC = $script:WHDConfirm; $script:WHDConfirm = { param($m) $true }
    try {
        foreach ($t in $todo) {
            $e = $t.Entry
            switch ("$($e.Kind)") {
                'reg' {
                    if ($e.NewExists) { Set-WHDRegistryValue -Path $e.Path -Name $e.Name -Value (_WHDConvertRegValue $e.NewValue $e.NewType) -Type $e.NewType | Out-Null }
                    else { Remove-WHDRegistryValue -Path $e.Path -Name $e.Name | Out-Null }
                }
                'service' {
                    $raSvc = "$($e.Service)"; $raSt = "$($e.NewStartType)"; $raOld = "$((Get-Service -Name $raSvc -EA SilentlyContinue).StartType)"
                    $jr = @{ Kind = 'service'; Service = $raSvc; OldStartType = $raOld; NewStartType = $raSt }
                    Invoke-WHDChange -Description ("service {0}: start type -> {1}" -f $raSvc, $raSt) -Force -Journal $jr -Action {
                        if ($raSt -eq 'Disabled') { Stop-Service -Name $raSvc -Force -EA SilentlyContinue }
                        Set-Service -Name $raSvc -StartupType $raSt -EA Stop
                    } | Out-Null
                }
                'task' {
                    $raP = "$($e.TaskPath)"; $raN = "$($e.TaskName)"; $raOn = [bool]$e.NewEnabled
                    $jr = @{ Kind = 'task'; TaskPath = $raP; TaskName = $raN; OldEnabled = (-not $raOn); NewEnabled = $raOn }
                    Invoke-WHDChange -Description ("scheduled task {0}{1} -> {2}" -f $raP, $raN, $(if ($raOn) { 'enabled' } else { 'disabled' })) -Force -Journal $jr -Action {
                        if ($raOn) { Enable-ScheduledTask -TaskPath $raP -TaskName $raN -EA Stop | Out-Null } else { Stop-ScheduledTask -TaskPath $raP -TaskName $raN -EA SilentlyContinue; Disable-ScheduledTask -TaskPath $raP -TaskName $raN -EA Stop | Out-Null }
                    } | Out-Null
                }
                'pnpdev' {
                    $raId = "$($e.InstanceId)"; $raOn = [bool]$e.NewEnabled
                    $jr = @{ Kind = 'pnpdev'; InstanceId = $raId; Name = $e.Name; OldEnabled = (-not $raOn); NewEnabled = $raOn }
                    Invoke-WHDChange -Description ("device {0} -> {1}" -f $e.Name, $(if ($raOn) { 'enabled' } else { 'disabled' })) -Force -Journal $jr -Action {
                        if ($raOn) { Enable-PnpDevice -InstanceId $raId -Confirm:$false -EA Stop } else { Disable-PnpDevice -InstanceId $raId -Confirm:$false -EA Stop }
                    } | Out-Null
                }
                'deprov' { Add-WHDDeprovisionMark -Pfn "$($e.Pfn)" }
                'tz'     { Set-WHDTimeZoneId -Id "$($e.NewId)" }
                'fwlog' {
                    $flP = "$($e.Profile)"; $flA = "$($e.NewAllowed)"; $flB = "$($e.NewBlocked)"; $flS = [int64]$e.NewSizeKB
                    $cur = @(Get-NetFirewallProfile -Name $flP -EA SilentlyContinue)[0]
                    $jr = @{ Kind = 'fwlog'; Profile = $flP; OldAllowed = "$($cur.LogAllowed)"; OldBlocked = "$($cur.LogBlocked)"; OldSizeKB = [int64]$cur.LogMaxSizeKilobytes
                             NewAllowed = $flA; NewBlocked = $flB; NewSizeKB = $flS }
                    Invoke-WHDChange -Description ("firewall log ({0}): allowed={1} dropped={2} size={3} KB" -f $flP, $flA, $flB, $flS) -Force -Journal $jr -Action {
                        Set-NetFirewallProfile -Name $flP -LogAllowed $flA -LogBlocked $flB -LogMaxSizeKilobytes $flS -EA Stop
                    } | Out-Null
                }
                'mppref' { if (Get-Command Set-WHDMpPreference -EA SilentlyContinue) { Set-WHDMpPreference -Setting $e.Setting -Value ([int]$e.NewValue) | Out-Null } }
                'asr'    { if (Get-Command Set-WHDAsrRule -EA SilentlyContinue) { Set-WHDAsrRule -Id $e.RuleId -Action ([int]$e.NewAction) -Name $e.RuleName | Out-Null } }
            }
        }
    } finally { $script:WHDConfirm = $prevC }
}
# Re-remove apps that Verify reports as RETURNED (appx / provisioned). One confirm for the batch.
function Invoke-WHDReRemoveReturned {
    param([object[]]$Results)
    if (-not $Results) { $Results = @(Invoke-WHDVerify -All -Quiet) }
    $pk = @($Results | Where-Object { $_.Result -eq 'RETURNED' -and "$($_.Entry.Kind)" -in @('appx', 'provisioned') } |
            ForEach-Object { "$($_.Entry.Package)" } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $pk.Count) { Write-WHDLog 'No removed apps have come back - nothing to re-remove.' 'OK'; return }
    Write-WHDLog ("RE-REMOVE {0} app(s) that came back: {1}" -f $pk.Count, ($pk -join ', ')) 'ACT'
    Write-WHDRisk 'reversible' 'Removes them again for all users, removes the provisioned copy, and writes the Deprovisioned mark so Windows updates leave them out. Journaled.'
    if (-not (Confirm-WHDProceed ("re-remove {0} returned app(s)" -f $pk.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $prevC = $script:WHDConfirm; $script:WHDConfirm = { param($m) $true }
    try { foreach ($n in $pk) { Remove-WHDAppxAllUsers -NameLike $n; Remove-WHDProvisioned -NameLike $n } }
    finally { $script:WHDConfirm = $prevC }
}
function Remove-WHDProvisioned {
    param([Parameter(Mandatory)][string]$NameLike)
    $prov = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -like $NameLike })
    if (-not $prov) { Write-WHDLog ("no provisioned package matches '{0}'" -f $NameLike) 'INFO'; return }
    foreach ($p in $prov) {
        $jr = @{ Kind = 'provisioned'; Package = "$($p.DisplayName)"; FullName = "$($p.PackageName)" }
        # The result is the last object returned; mark only when the removal did not fail (dry-run: 'planned').
        $rmRes = @(Invoke-WHDChange -Description ("deprovision (new users won't get): {0}" -f $p.PackageName) -Force -Journal $jr -Action {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -EA Stop
        })[-1]
        if (("$($rmRes.Status)" -in @('done', 'planned')) -and "$($p.DisplayName)" -and "$($p.PublisherId)") { Add-WHDDeprovisionMark -Pfn ("{0}_{1}" -f $p.DisplayName, $p.PublisherId) }
    }
}

# =============================================================================
#  PHASE 5 - CHANGE JOURNAL, UNDO CENTER (F20) AND VERIFY-AFTER-APPLY (F21)
# -----------------------------------------------------------------------------
#  Every successful change in EXECUTE mode appends one JSON line to
#  restore\<session>\journal.jsonl. Kinds:
#    reg          old + new value captured  -> automatic undo, exact
#    service      old + new start type      -> automatic undo
#    feature      optional feature disabled -> automatic undo (re-enable;
#                 may need Windows Update if the payload was removed)
#    appx /       package removed           -> MANUAL undo (reinstall from the
#    provisioned                               Store); verify checks it stays gone
#    action       anything else (firewall, DISM, uninstallers...) -> MANUAL;
#                 use the session-level backups (firewall .wfw, hosts.bak)
#  Undone entries are recorded in restore\<session>\undo.jsonl (never deleted).
# =============================================================================
function Get-WHDRestoreRoot { Join-Path $script:WHDRoot 'restore' }

# ---- v1.1: per-PC history --------------------------------------------------
# Every change is tagged with this PC's MachineGuid (HKLM\SOFTWARE\Microsoft\
# Cryptography - survives a rename, new on every Windows install). Verify, the
# update guard, the Undo center and CAME BACK flags only use THIS PC's history.
# Untagged sessions (made before v1.1) are sorted by date: older than this
# Windows install = another PC / previous install. Undo center H archives them.
function Get-WHDMachineId {
    if ($script:WHDMachineIdCache) { return $script:WHDMachineIdCache }
    $g = $null
    try { $g = "$((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -EA Stop).MachineGuid)" } catch {}
    if (-not $g) { $g = "name:$env:COMPUTERNAME" }
    $script:WHDMachineIdCache = $g.ToLower()
    return $script:WHDMachineIdCache
}
function Get-WHDWindowsInstallDate {
    try {
        $v = [int64](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallDate -EA Stop).InstallDate
        return ([datetime]'1970-01-01').AddSeconds($v).ToLocalTime()
    } catch { return $null }
}
# Append one line; a file briefly held by OneDrive / antivirus is retried.
function _WHDAppendLine {
    param([string]$File, [string]$Line)
    $last = $null
    for ($i = 1; $i -le 8; $i++) {
        try { Add-Content -LiteralPath $File -Value $Line -Encoding UTF8 -EA Stop; return }
        catch { $last = $_; Start-Sleep -Milliseconds (150 * $i) }
    }
    throw $last
}
function _WHDSessionMachineFile { param([string]$SessionPath) Join-Path $SessionPath 'machine.json' }
function _WHDWriteSessionMachine {
    param([string]$SessionPath)
    $f = _WHDSessionMachineFile $SessionPath
    if (Test-Path -LiteralPath $f) { return }
    $o = [ordered]@{ MachineId = (Get-WHDMachineId); Computer = $env:COMPUTERNAME; Claimed = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    ([pscustomobject]$o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $f -Encoding UTF8
}
# 'this' | 'other' | 'legacy-this' | 'legacy-other'
function Get-WHDSessionOwner {
    param([string]$SessionPath)
    $f = _WHDSessionMachineFile $SessionPath
    if (Test-Path -LiteralPath $f) {
        try { $m = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $m = $null }
        if ($m -and "$($m.MachineId)") { if ("$($m.MachineId)".ToLower() -eq (Get-WHDMachineId)) { return 'this' } else { return 'other' } }
    }
    $first = @(_WHDReadJsonl (Join-Path $SessionPath 'journal.jsonl') | Where-Object { $_.MachineId } | Select-Object -First 1)
    if ($first.Count) { if ("$($first[0].MachineId)".ToLower() -eq (Get-WHDMachineId)) { return 'this' } else { return 'other' } }
    $inst = Get-WHDWindowsInstallDate
    $stamp = $null
    try { $stamp = [datetime]::ParseExact((Split-Path $SessionPath -Leaf), 'yyyy-MM-dd_HHmmss', $null) } catch {}
    if ($inst -and $stamp -and $stamp -lt $inst) { return 'legacy-other' }
    return 'legacy-this'
}

function Add-WHDJournal {
    param([string]$Description, [hashtable]$Data)
    try {
        if (-not $script:WHDRestore) { Initialize-WHDPaths }
        if (-not (Test-Path $script:WHDRestore)) { New-Item -ItemType Directory -Path $script:WHDRestore -Force | Out-Null }
        $rec = [ordered]@{
            Id          = ([guid]::NewGuid().ToString('N').Substring(0, 10))
            Time        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Session     = $script:WHDStamp
            Kind        = 'action'
            Description = $Description
        }
        $rec['MachineId'] = Get-WHDMachineId
        $rec['Computer']  = $env:COMPUTERNAME
        if ($Data) { foreach ($k in $Data.Keys) { $rec[$k] = $Data[$k] } }
        if ($script:WHDUndoing) { $rec['ByUndo'] = $true }
        if ($rec.OldValue -is [byte[]]) { $rec.OldValue = @($rec.OldValue | ForEach-Object { [int]$_ }) }
        if ($rec.NewValue -is [byte[]]) { $rec.NewValue = @($rec.NewValue | ForEach-Object { [int]$_ }) }
        $line = ([pscustomobject]$rec | ConvertTo-Json -Compress -Depth 4)
        _WHDWriteSessionMachine -SessionPath $script:WHDRestore
        _WHDAppendLine -File (Join-Path $script:WHDRestore 'journal.jsonl') -Line $line
    } catch {
        Write-WHDLog ("journal write failed (change itself is done): {0}" -f $_.Exception.Message) 'WARN'
    }
}

function _WHDReadJsonl {
    param([string]$File)
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    @(Get-Content -LiteralPath $File -Encoding UTF8 -EA SilentlyContinue | Where-Object { $_.Trim() } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch {}
    })
}

function Get-WHDUndoMode {
    param($Entry)
    switch ("$($Entry.Kind)") {
        'reg'     { if ($Entry.OldExists -and -not $Entry.OldType) { 'manual' } else { 'auto' } }
        'service' { 'auto' }
        'feature' { 'auto' }
        'regkey'  { 'auto' }
        'auditpol'{ 'auto' }
        'eventlog'{ 'auto' }
        'fwrule'  { 'auto' }
        'file'    { 'auto' }
        'mppref'  { 'auto' }
        'asr'     { 'auto' }
        'netacct' { 'auto' }
        'schtask' { if ($Entry.Existed) { 'manual' } else { 'auto' } }
        'task'    { 'auto' }
        'pnpdev'  { 'auto' }
        'tz'      { 'auto' }
        'deprov'  { 'auto' }
        'fwlog'   { 'auto' }
        default   { 'manual' }
    }
}

# Sessions that have something to show (journal, legacy .reg exports, firewall
# or hosts backups). Newest first.
function Get-WHDUndoSessions {
    # -IncludeOtherPCs lists history made on another PC / a previous Windows
    # install too (normally hidden so it can't cause false alerts here).
    param([switch]$IncludeOtherPCs)
    $root = Get-WHDRestoreRoot
    if (-not (Test-Path $root)) { return @() }
    $out = foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue | Sort-Object Name -Descending)) {
        $j     = Join-Path $d.FullName 'journal.jsonl'
        $jn    = @(_WHDReadJsonl $j).Count
        $undone= @(_WHDReadJsonl (Join-Path $d.FullName 'undo.jsonl')).Count
        $regs  = @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.reg' -File -EA SilentlyContinue).Count
        $wfw   = Test-Path -LiteralPath (Join-Path $d.FullName 'firewall-before.wfw')
        $hosts = Test-Path -LiteralPath (Join-Path $d.FullName 'hosts.bak')
        if (($jn + $regs) -eq 0 -and -not $wfw -and -not $hosts) { continue }
        $owner = Get-WHDSessionOwner -SessionPath $d.FullName
        if (-not $IncludeOtherPCs -and $owner -in @('other','legacy-other')) { continue }
        $bits = @()
        if ($jn)    { $bits += ("{0} change(s){1}" -f $jn, $(if($undone){", $undone undone"}else{''})) }
        if ($regs)  { $bits += ("{0} .reg backup(s)" -f $regs) }
        if ($wfw)   { $bits += 'firewall backup' }
        if ($hosts) { $bits += 'hosts backup' }
        [pscustomobject]@{
            Stamp = $d.Name; Path = $d.FullName; Entries = $jn; Undone = $undone; Owner = $owner
            RegFiles = $regs; HasWfw = $wfw; HasHosts = $hosts
            Label = ("{0}   {1}{2}" -f $d.Name, ($bits -join ', '), $(if ($owner -in @('other','legacy-other')) { '   [other PC / previous install]' } else { '' }))
        }
    }
    @($out)
}

# Journal entries of one session, with UndoMode + Undone flags added.
function Get-WHDJournal {
    param([Parameter(Mandatory)][string]$SessionPath)
    $undoneIds = @(_WHDReadJsonl (Join-Path $SessionPath 'undo.jsonl') | ForEach-Object { "$($_.Id)" })
    $seq = 0
    @(_WHDReadJsonl (Join-Path $SessionPath 'journal.jsonl') | ForEach-Object {
        $seq++
        $_ | Add-Member -NotePropertyName Seq      -NotePropertyValue $seq -Force
        $_ | Add-Member -NotePropertyName UndoMode -NotePropertyValue (Get-WHDUndoMode $_) -Force
        $_ | Add-Member -NotePropertyName Undone   -NotePropertyValue ($undoneIds -contains "$($_.Id)") -Force
        $_ | Add-Member -NotePropertyName SessionPath -NotePropertyValue $SessionPath -Force
        $_
    })
}

function _WHDConvertRegValue {
    param($Value, [string]$Type)
    switch ($Type) {
        'DWord'       { $v = [int64]$Value -band 0xFFFFFFFFL; if ($v -gt 2147483647L) { $v -= 4294967296L }; return [int32]$v }
        'QWord'       { return [int64]$Value }
        'MultiString' { return ,([string[]]@($Value)) }
        'Binary'      { return ,([byte[]]@($Value | ForEach-Object { [byte]$_ })) }
        default       { return "$Value" }
    }
}

function _WHDMarkUndone {
    param($Entry)
    try {
        $rec = [pscustomobject]@{ Id = "$($Entry.Id)"; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); BySession = $script:WHDStamp }
        _WHDAppendLine -File (Join-Path $Entry.SessionPath 'undo.jsonl') -Line ($rec | ConvertTo-Json -Compress)
    } catch { Write-WHDLog ("could not record undo mark: {0}" -f $_.Exception.Message) 'WARN' }
}

function _WHDUndoOne {
    param($Entry)
    $countBefore = [int]$script:WHDCounts['done']
    switch ("$($Entry.Kind)") {
        'reg' {
            if ($Entry.OldExists) {
                # DWORDs above 0x7FFFFFFF come back from the registry as negative
                # Int32 - convert so Set-ItemProperty writes the same bits.
                $v = _WHDConvertRegValue $Entry.OldValue $Entry.OldType
                Set-WHDRegistryValue -Path $Entry.Path -Name $Entry.Name -Value $v -Type $Entry.OldType | Out-Null
            } else {
                Remove-WHDRegistryValue -Path $Entry.Path -Name $Entry.Name | Out-Null
                if (-not $Entry.OldKeyExists -and $script:WHDExecute -and (Test-Path -LiteralPath $Entry.Path)) {
                    $k = Get-Item -LiteralPath $Entry.Path -EA SilentlyContinue
                    if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) {
                        Invoke-WHDChange -Description ("remove empty key created by WHD: {0}" -f $Entry.Path) -Force -Journal @{ Kind = 'regkey'; Path = $Entry.Path } -Action {
                            Remove-Item -LiteralPath $Entry.Path -EA Stop
                        } | Out-Null
                    }
                }
            }
        }
        'service' {
            $jr = @{ Kind = 'service'; Service = $Entry.Service; OldStartType = $Entry.NewStartType; NewStartType = $Entry.OldStartType }
            Invoke-WHDChange -Description ("service {0}: start type -> {1}" -f $Entry.Service, $Entry.OldStartType) -Force -Journal $jr -Action {
                Set-Service -Name $Entry.Service -StartupType $Entry.OldStartType -EA Stop
            } | Out-Null
        }
        'regkey' {
            # an empty key WHD removed during an undo - recreate it (empty)
            Invoke-WHDChange -Description ("recreate empty key: {0}" -f $Entry.Path) -Force -Action {
                if (-not (Test-Path -LiteralPath $Entry.Path)) { New-Item -Path $Entry.Path -Force | Out-Null }
            } | Out-Null
        }
        'auditpol' {
            Set-WHDAuditSetting -Guid $Entry.Guid -Name $Entry.Subcategory -Success ([bool]$Entry.OldSuccess) -Failure ([bool]$Entry.OldFailure) | Out-Null
        }
        'eventlog' {
            Set-WHDEventLogConfig -LogName $Entry.LogName -MaxBytes ([int64]$Entry.OldMaxBytes) -Mode $Entry.OldMode | Out-Null
        }
        'fwrule' {
            Invoke-WHDChange -Description ("remove firewall rule {0}" -f $Entry.RuleName) -Force -Action {
                $r = @(Get-NetFirewallRule -Name $Entry.RuleName -EA SilentlyContinue)
                if ($r) { $r | Remove-NetFirewallRule -EA Stop }
            } | Out-Null
        }
        'mppref' {
            $ov = if ($null -eq $Entry.OldValue) { 0 } else { [int]$Entry.OldValue }
            Set-WHDMpPreference -Setting $Entry.Setting -Value $ov | Out-Null
        }
        'asr' {
            Set-WHDAsrRule -Id $Entry.RuleId -Action ([int]$Entry.OldAction) -Name $Entry.RuleName | Out-Null
        }
        'deprov' {
            $dpUndo = Join-Path $script:WHDDeprovKey "$($Entry.Pfn)"
            Invoke-WHDChange -Description ("remove Deprovisioned mark: {0}" -f $Entry.Pfn) -Force -Action {
                if (Test-Path -LiteralPath $dpUndo) { Remove-Item -LiteralPath $dpUndo -Recurse -Force -EA Stop }
            } | Out-Null
        }
        'fwlog' {
            $flP = "$($Entry.Profile)"; $flA = "$($Entry.OldAllowed)"; $flB = "$($Entry.OldBlocked)"; $flS = [int64]$Entry.OldSizeKB
            $jr = @{ Kind = 'fwlog'; Profile = $flP; OldAllowed = "$($Entry.NewAllowed)"; OldBlocked = "$($Entry.NewBlocked)"; OldSizeKB = [int64]$Entry.NewSizeKB
                     NewAllowed = $flA; NewBlocked = $flB; NewSizeKB = $flS }
            Invoke-WHDChange -Description ("firewall log ({0}): allowed={1} blocked={2} size={3} KB" -f $flP, $flA, $flB, $flS) -Force -Journal $jr -Action {
                Set-NetFirewallProfile -Name $flP -LogAllowed $flA -LogBlocked $flB -LogMaxSizeKilobytes $flS -EA Stop
            } | Out-Null
        }
        'tz' {
            if (-not "$($Entry.OldId)") { Write-WHDLog 'old time zone unknown, cannot undo' 'ERR'; return }
            Set-WHDTimeZoneId -Id "$($Entry.OldId)"
        }
        'pnpdev' {
            $pdId = "$($Entry.InstanceId)"; $pdOn = [bool]$Entry.OldEnabled
            $jr = @{ Kind = 'pnpdev'; InstanceId = $pdId; Name = $Entry.Name; OldEnabled = [bool]$Entry.NewEnabled; NewEnabled = $pdOn }
            Invoke-WHDChange -Description ("device {0} -> {1}" -f $Entry.Name, $(if ($pdOn) { 'enabled' } else { 'disabled' })) -Force -Journal $jr -Action {
                if ($pdOn) { Enable-PnpDevice -InstanceId $pdId -Confirm:$false -EA Stop } else { Disable-PnpDevice -InstanceId $pdId -Confirm:$false -EA Stop }
            } | Out-Null
        }
        'task' {
            $tkP = "$($Entry.TaskPath)"; $tkN = "$($Entry.TaskName)"; $tkOn = [bool]$Entry.OldEnabled
            $jr = @{ Kind = 'task'; TaskPath = $tkP; TaskName = $tkN; OldEnabled = [bool]$Entry.NewEnabled; NewEnabled = $tkOn }
            Invoke-WHDChange -Description ("scheduled task {0}{1} -> {2}" -f $tkP, $tkN, $(if ($tkOn) { 'enabled' } else { 'disabled' })) -Force -Journal $jr -Action {
                if ($tkOn) { Enable-ScheduledTask -TaskPath $tkP -TaskName $tkN -EA Stop | Out-Null } else { Disable-ScheduledTask -TaskPath $tkP -TaskName $tkN -EA Stop | Out-Null }
            } | Out-Null
        }
        'schtask' {
            if ($Entry.Existed) { Write-WHDLog 'The guard existed before this change (it was a refresh) - remove it with Security+ GX instead.' 'WARN'; return }
            Invoke-WHDChange -Description ("remove update guard task {0}{1} + protected copy" -f $Entry.TaskPath, $Entry.TaskName) -Force -Action { _WHDGuardRemove } | Out-Null
        }
        'netacct' {
            if ($null -eq $Entry.OldValue) { Write-WHDLog ("old value unknown, cannot undo: {0}" -f $Entry.Description) 'ERR'; return }
            Set-WHDPasswordSetting -Setting $Entry.Setting -Value ([int]$Entry.OldValue) | Out-Null
        }
        'file' {
            if (-not (Test-Path -LiteralPath $Entry.Backup)) { Write-WHDLog ("backup file missing, cannot undo: {0}" -f $Entry.Backup) 'ERR'; return }
            Restore-WHDFileFromBackup -Path $Entry.Path -Backup $Entry.Backup | Out-Null
        }
        'feature' {
            $jr = @{ Kind = 'action'; Feature = $Entry.Feature }
            Invoke-WHDChange -Description ("re-enable optional feature: {0}" -f $Entry.Feature) -Force -Journal $jr -Action {
                Enable-WindowsOptionalFeature -Online -FeatureName $Entry.Feature -NoRestart -EA Stop | Out-Null
            } | Out-Null
        }
        default {
            Write-WHDLog ("manual undo only: {0}  ({1})" -f $Entry.Description, (Get-WHDUndoHint $Entry)) 'WARN'
            return
        }
    }
    if ($script:WHDExecute -and ([int]$script:WHDCounts['done'] -gt $countBefore)) { _WHDMarkUndone $Entry }
}

function Get-WHDUndoHint {
    param($Entry)
    switch ("$($Entry.Kind)") {
        'appx'        { 'reinstall it from the Microsoft Store if you want it back' }
        'provisioned' { 'new user accounts will not get it; reinstall from the Store per user if needed' }
        'action'      { if ("$($Entry.Hint)") { "$($Entry.Hint)" } else { 'use this session''s firewall/hosts backup, a restore point, or redo it by hand' } }
        default       { 'automatic' }
    }
}

# Undo specific journal entries (newest first). ONE confirm for the batch.
function Invoke-WHDUndo {
    param([Parameter(Mandatory)][object[]]$Entries)
    $todo = @($Entries | Where-Object { -not $_.Undone } | Sort-Object @{e={"$($_.Session)"};Descending=$true}, @{e={[int]$_.Seq};Descending=$true})
    if (-not $todo.Count) { Write-WHDLog 'Nothing to undo (already undone or empty selection).' 'INFO'; return }
    $auto = @($todo | Where-Object { $_.UndoMode -eq 'auto' }).Count
    Write-WHDLog ("UNDO: {0} selected change(s), {1} can be undone automatically" -f $todo.Count, $auto) 'ACT'
    Write-WHDRisk 'caution' 'Puts the previous values back. Each undo is recorded in the journal; registry undos can be undone again.'
    if (-not (Confirm-WHDProceed ("undo {0} change(s)" -f $todo.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    # Entries written while undoing are marked ByUndo: they put Windows' own value back, so Verify and
    # re-apply must not treat them as a WHD setting to protect (bug seen 2026-09-29: re-apply wrote the
    # round-4 undo value back and turned proxy auto-detect on again).
    $script:WHDUndoing = $true
    try { foreach ($e in $todo) { _WHDUndoOne $e } }
    finally { $script:WHDUndoing = $false }
}

# Undo every automatic entry of one session (newest first).
function Invoke-WHDUndoSession {
    param([Parameter(Mandatory)][string]$SessionPath)
    Invoke-WHDUndo -Entries @(Get-WHDJournal -SessionPath $SessionPath)
}

function Restore-WHDSessionFirewall {
    param([Parameter(Mandatory)][string]$SessionPath)
    $f = Join-Path $SessionPath 'firewall-before.wfw'
    if (-not (Test-Path -LiteralPath $f)) { Write-WHDLog 'This session has no firewall backup.' 'WARN'; return }
    Write-WHDLog ("RESTORE FIREWALL from {0}" -f $f) 'ACT'
    Write-WHDRisk 'hard' 'Replaces the ENTIRE current firewall policy with the one saved before that session. Later firewall changes are lost.'
    if (-not (Confirm-WHDProceed 'replace the whole firewall policy with this backup')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Invoke-WHDChange -Description ("netsh advfirewall import {0}" -f $f) -Force -Action {
        $ni = Invoke-WHDNative -Exe 'netsh.exe' -ArgList @('advfirewall', 'import', "$f")
        if ($ni.Code -ne 0) { throw ("netsh exit {0}: {1}" -f $ni.Code, ($ni.Out -join ' ')) }
    } | Out-Null
}

function Restore-WHDSessionHosts {
    param([Parameter(Mandatory)][string]$SessionPath)
    $f = Join-Path $SessionPath 'hosts.bak'
    if (-not (Test-Path -LiteralPath $f)) { Write-WHDLog 'This session has no hosts backup.' 'WARN'; return }
    $len = (Get-Item -LiteralPath $f).Length
    Write-WHDLog ("RESTORE HOSTS FILE from {0} ({1:N0} bytes)" -f $f, $len) 'ACT'
    if ($len -eq 0) { Write-WHDRisk 'caution' 'This backup is EMPTY - restoring it leaves an empty hosts file (Windows works fine without entries).' }
    else            { Write-WHDRisk 'caution' 'Replaces the current hosts file with the saved copy.' }
    if (-not (Confirm-WHDProceed 'replace the hosts file with this backup')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Invoke-WHDChange -Description ("restore hosts file from {0}" -f $f) -Force -Action {
        Copy-Item -LiteralPath $hosts -Destination (Join-Path $script:WHDRestore ("hosts.before-restore_{0}.bak" -f (Get-Date -Format 'HHmmss'))) -Force -EA SilentlyContinue
        Copy-Item -LiteralPath $f -Destination $hosts -Force -EA Stop
        & ipconfig.exe /flushdns | Out-Null
    } | Out-Null
}

# Older sessions (before the journal existed) only have .reg exports.
function Import-WHDLegacyRegBackups {
    param([Parameter(Mandatory)][string]$SessionPath)
    $files = @(Get-ChildItem -LiteralPath $SessionPath -Filter '*.reg' -File -EA SilentlyContinue)
    if (-not $files.Count) { Write-WHDLog 'This session has no .reg backups.' 'WARN'; return }
    Write-WHDLog ("IMPORT {0} legacy .reg backup(s) from {1}" -f $files.Count, $SessionPath) 'ACT'
    Write-WHDRisk 'caution' 'reg import puts the saved values back but does NOT delete values that were added later. Journaled sessions undo more precisely.'
    foreach ($f in $files) { Write-Host ("     - {0}" -f $f.Name) }
    if (-not (Confirm-WHDProceed ("import {0} .reg file(s)" -f $files.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($f in $files) {
        Invoke-WHDChange -Description ("reg import {0}" -f $f.Name) -Force -Action {
            # reg.exe writes "The operation completed successfully." to STDERR; with $ErrorActionPreference=Stop a plain
            # 2>&1 turned that success text into a failure (seen 2026-09-29). Invoke-WHDNative reads the exit code only.
            $ri = Invoke-WHDNative -Exe 'reg.exe' -ArgList @('import', "$($f.FullName)")
            if ($ri.Code -ne 0) { throw ("reg import exit {0}: {1}" -f $ri.Code, ($ri.Out -join ' ')) }
        } | Out-Null
    }
}

# ---- F21: verification (read-only, safe in any mode) -------------------------
function Test-WHDJournalEntry {
    param($Entry)
    $r = [ordered]@{ Result = 'n/a'; Now = ''; Target = ''; Entry = $Entry }
    switch ("$($Entry.Kind)") {
        'reg' {
            $r.Target = "{0}\{1}" -f $Entry.Path, $Entry.Name
            $s = Get-WHDRegValueState -Path $Entry.Path -Name $Entry.Name
            $r.Now = if ($s.Exists) { "$($s.Value)" } else { '(missing)' }
            if (-not $Entry.NewExists) { $r.Result = if ($s.Exists) { 'CHANGED' } else { 'PASS' } }
            elseif (-not $s.Exists)    { $r.Result = 'CHANGED' }
            else { $r.Result = if (Test-WHDRegValueEqual $s.Value $Entry.NewValue $Entry.NewType) { 'PASS' } else { 'CHANGED' } }
        }
        'service' {
            $r.Target = "service $($Entry.Service)"
            $svc = Get-Service -Name $Entry.Service -EA SilentlyContinue
            if (-not $svc) { $r.Now = '(not found)'; $r.Result = 'PASS' }
            else {
                $st = "$($svc.StartType)"; $r.Now = $st
                $r.Result = if ($st -eq "$($Entry.NewStartType)") { 'PASS' } else { 'CHANGED' }
            }
        }
        'feature' {
            $r.Target = "feature $($Entry.Feature)"
            try {
                $f = Get-WindowsOptionalFeature -Online -FeatureName $Entry.Feature -EA Stop
                $r.Now = "$($f.State)"
                $r.Result = if ("$($f.State)" -eq 'Enabled') { 'CHANGED' } else { 'PASS' }
            } catch { $r.Now = '(not present)'; $r.Result = 'PASS' }
        }
        'appx' {
            $r.Target = "app $($Entry.Package)"
            $n = @(Get-AppxPackage -AllUsers -Name $Entry.Package -EA SilentlyContinue).Count
            $r.Now = if ($n) { 'installed' } else { 'absent' }
            $r.Result = if ($n) { 'RETURNED' } else { 'PASS' }
        }
        'provisioned' {
            $r.Target = "provisioned $($Entry.Package)"
            $n = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -eq $Entry.Package }).Count
            $r.Now = if ($n) { 'provisioned' } else { 'absent' }
            $r.Result = if ($n) { 'RETURNED' } else { 'PASS' }
        }
        'auditpol' {
            $r.Target = "audit $($Entry.Subcategory)"
            $a = Get-WHDAuditSetting -Guid $Entry.Guid
            if (-not $a) { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
            else {
                $r.Now = "success=$($a.Success) failure=$($a.Failure)"
                $r.Result = if ($a.Success -eq [bool]$Entry.NewSuccess -and $a.Failure -eq [bool]$Entry.NewFailure) { 'PASS' } else { 'CHANGED' }
            }
        }
        'eventlog' {
            $r.Target = "event log $($Entry.LogName)"
            $c = Get-WHDEventLogConfig -LogName $Entry.LogName
            if (-not $c) { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
            else {
                $r.Now = ("{0:N0} MB, {1}" -f ($c.MaxBytes / 1MB), $c.Mode)
                $r.Result = if ([int64]$c.MaxBytes -eq [int64]$Entry.NewMaxBytes -and "$($c.Mode)" -eq "$($Entry.NewMode)") { 'PASS' } else { 'CHANGED' }
            }
        }
        'mppref' {
            $r.Target = "Defender $($Entry.Setting)"
            try { $v = [int](Get-MpPreference -EA Stop).($Entry.Setting); $r.Now = "$v"; $r.Result = if ($v -eq [int]$Entry.NewValue) { 'PASS' } else { 'CHANGED' } }
            catch { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
        }
        'asr' {
            $r.Target = "ASR $($Entry.RuleName)"
            $st = @(Get-WHDAsrState | Where-Object { $_.Id -eq $Entry.RuleId })
            if ($st.Count) { $r.Now = $st[0].Action; $r.Result = if ([int]$st[0].Code -eq [int]$Entry.NewAction) { 'PASS' } else { 'CHANGED' } }
            else { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
        }
        'deprov' {
            $r.Target = "deprovisioned mark $($Entry.Pfn)"
            $has = Test-Path -LiteralPath (Join-Path $script:WHDDeprovKey "$($Entry.Pfn)")
            $r.Now = if ($has) { 'present' } else { '(missing)' }
            $r.Result = if ($has) { 'PASS' } else { 'CHANGED' }
        }
        'fwlog' {
            $r.Target = "firewall log $($Entry.Profile)"
            $fp = @(Get-NetFirewallProfile -Name $Entry.Profile -EA SilentlyContinue)[0]
            if (-not $fp) { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
            else {
                $r.Now = ("allowed={0} blocked={1} size={2} KB" -f $fp.LogAllowed, $fp.LogBlocked, $fp.LogMaxSizeKilobytes)
                $ok = ("$($fp.LogAllowed)" -eq "$($Entry.NewAllowed)") -and ("$($fp.LogBlocked)" -eq "$($Entry.NewBlocked)") -and ([int64]$fp.LogMaxSizeKilobytes -eq [int64]$Entry.NewSizeKB)
                $r.Result = if ($ok) { 'PASS' } else { 'CHANGED' }
            }
        }
        'tz' {
            $r.Target = 'time zone'
            $cur = "$((Get-TimeZone -EA SilentlyContinue).Id)"
            $r.Now = $cur
            $r.Result = if ($cur -eq "$($Entry.NewId)") { 'PASS' } else { 'CHANGED' }
        }
        'pnpdev' {
            $r.Target = "device $($Entry.Name)"
            $d = @(Get-PnpDevice -InstanceId $Entry.InstanceId -EA SilentlyContinue)[0]
            if (-not $d) { $r.Now = '(gone)'; $r.Result = if ([bool]$Entry.NewEnabled) { 'CHANGED' } else { 'PASS' } }
            elseif (-not $d.Present -and -not [bool]$Entry.NewEnabled) {
                # Not present right now (e.g. the Bluetooth PAN device while Bluetooth is off; seen 2026-09-29 as
                # "enabled (Unknown)"): a missing device cannot be active, and its disabled flag is checked when it returns.
                $r.Now = 'not present (checked again when it comes back)'; $r.Result = 'PASS'
            }
            else {
                $isOn = -not ("$($d.ConfigManagerErrorCode)" -match 'DISABLED|^22$')
                $r.Now = if ($isOn) { "enabled ($($d.Status))" } else { 'disabled' }
                $r.Result = if ($isOn -eq [bool]$Entry.NewEnabled) { 'PASS' } else { 'CHANGED' }
            }
        }
        'task' {
            $r.Target = "task $($Entry.TaskPath)$($Entry.TaskName)"
            $t = @(Get-ScheduledTask -TaskPath $Entry.TaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $Entry.TaskName })[0]
            if (-not $t) { $r.Now = '(gone)'; $r.Result = 'PASS' }
            else {
                $isOn = ("$($t.State)" -ne 'Disabled')
                try { if ($null -ne $t.Settings -and $null -ne $t.Settings.Enabled) { $isOn = [bool]$t.Settings.Enabled } } catch { }
                $r.Now = if ($isOn) { "$($t.State)" } elseif ("$($t.State)" -eq 'Running') { 'Disabled (last run finishing)' } else { 'Disabled' }
                $r.Result = if ($isOn -eq [bool]$Entry.NewEnabled) { 'PASS' } else { 'CHANGED' }
            }
        }
        'schtask' {
            $r.Target = "scheduled task $($Entry.TaskPath)$($Entry.TaskName)"
            $t = @(Get-ScheduledTask -TaskPath $Entry.TaskPath -EA SilentlyContinue | Where-Object { $_.TaskName -eq $Entry.TaskName })[0]
            $copy = Test-Path -LiteralPath (Join-Path "$($Entry.GuardDir)" 'WHD.ps1')
            if (-not $t) { $r.Now = 'missing'; $r.Result = 'CHANGED' }
            else { $r.Now = "$($t.State)" + $(if ($copy) { '' } else { ', protected copy missing' }); $r.Result = if ("$($t.State)" -ne 'Disabled' -and $copy) { 'PASS' } else { 'CHANGED' } }
        }
        'netacct' {
            $r.Target = "password policy $($Entry.Setting)"
            $pp = Get-WHDPasswordPolicy
            if (-not $pp) { $r.Now = '(unreadable)'; $r.Result = 'n/a' }
            else { $v = [int]$pp.($Entry.Setting); $r.Now = "$v"; $r.Result = if ($v -eq [int]$Entry.NewValue) { 'PASS' } else { 'CHANGED' } }
        }
        'fwrule' {
            $r.Target = "firewall rule $($Entry.RuleName)"
            $n = @(Get-NetFirewallRule -Name $Entry.RuleName -EA SilentlyContinue).Count
            $r.Now = if ($n) { 'present' } else { 'missing' }
            $r.Result = if ($n) { 'PASS' } else { 'CHANGED' }
        }
        'file' {
            $r.Target = "file $($Entry.Path)"
            if (-not (Test-Path -LiteralPath $Entry.Path)) { $r.Now = '(missing)'; $r.Result = 'CHANGED' }
            else {
                $h = (Get-FileHash -LiteralPath $Entry.Path -Algorithm SHA256).Hash
                $r.Now = $h.Substring(0, 12)
                $r.Result = if ($h -eq "$($Entry.NewHash)") { 'PASS' } else { 'CHANGED' }
            }
        }
        default { $r.Target = "$($Entry.Description)"; $r.Now = '-'; $r.Result = 'n/a' }
    }
    [pscustomobject]$r
}

# Verify one session (default: this one) or -All sessions. For -All, only the
# LATEST journaled state of each target is checked (later changes win).
# Undo center H: move history from other PCs / previous Windows installs out of
# restore\ into archive\other-pcs\<date>\ (kept, never deleted), and tag this
# PC's untagged sessions so later checks never need the date rule again.
function Invoke-WHDArchiveOtherHistory {
    $root = Get-WHDRestoreRoot
    if (-not (Test-Path $root)) { Write-WHDLog 'No history yet.' 'INFO'; return }
    $all = @(Get-WHDUndoSessions -IncludeOtherPCs)
    $other = @($all | Where-Object { $_.Owner -in @('other','legacy-other') })
    $claim = @($all | Where-Object { $_.Owner -eq 'legacy-this' })
    $inst = Get-WHDWindowsInstallDate
    Write-WHDLog 'HISTORY FROM OTHER PCs / PREVIOUS WINDOWS INSTALLS' 'ACT'
    Write-WHDLog ("Current PC: {0}   (Windows installed {1})" -f $env:COMPUTERNAME, $(if ($inst) { $inst.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' })) 'INFO'
    Write-WHDLog ("  {0} session(s) belong to another PC or an earlier install -> move to archive\other-pcs\" -f $other.Count) 'INFO'
    foreach ($o in $other) { Write-WHDLog ("     {0}" -f $o.Label) 'INFO' }
    Write-WHDLog ("  {0} untagged session(s) from the current Windows install -> tag as the current PC" -f $claim.Count) 'INFO'
    if (-not $other.Count -and -not $claim.Count) { Write-WHDLog 'Nothing to do - all history belongs to the current PC and is tagged.' 'OK'; return }
    Write-WHDRisk 'reversible' 'Nothing is deleted: folders are moved to archive\other-pcs\ (move them back to restore\ to restore them). Verify, the update guard and CAME BACK flags then only use the current PC''s history.'
    if (-not (Confirm-WHDProceed 'archive other-PC history and tag the current PC''s sessions')) { Write-WHDLog 'skipped.' 'WARN'; return }
    if (-not $script:WHDExecute) {
        foreach ($o in $other) { Write-WHDLog ("would: move {0} -> archive\other-pcs\" -f $o.Stamp) 'DRY' }
        foreach ($c in $claim) { Write-WHDLog ("would: tag {0} as the current PC" -f $c.Stamp) 'DRY' }
        return
    }
    $dest = Join-Path $script:WHDRoot ('archive\other-pcs\' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    if ($other.Count) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $moved = 0
    foreach ($o in $other) {
        try { Move-Item -LiteralPath $o.Path -Destination (Join-Path $dest $o.Stamp) -EA Stop; $moved++ }
        catch { Write-WHDLog ("could not move {0}: {1}" -f $o.Stamp, $_.Exception.Message) 'ERR' }
    }
    foreach ($c in $claim) { try { _WHDWriteSessionMachine -SessionPath $c.Path } catch { Write-WHDLog ("could not tag {0}: {1}" -f $c.Stamp, $_.Exception.Message) 'ERR' } }
    Write-WHDLog ("Done: {0} session(s) archived to {1}; {2} tagged as the current PC." -f $moved, $dest, $claim.Count) 'OK'
}

function Invoke-WHDVerify {
    param([string]$SessionPath, [switch]$All, [switch]$Quiet)
    if ($All) {
        $entries = @(foreach ($s in @(Get-WHDUndoSessions | Sort-Object Stamp)) { Get-WHDJournal -SessionPath $s.Path })
        $label = 'ALL sessions (latest state per item)'
        $hidden = @(Get-WHDUndoSessions -IncludeOtherPCs | Where-Object { $_.Owner -in @('other','legacy-other') }).Count
        if ($hidden) { Write-WHDLog ("{0} session(s) from another PC / a previous Windows install are not checked (Undo center H archives them)." -f $hidden) 'INFO' }
    } else {
        if (-not $SessionPath) { if (-not $script:WHDRestore) { Initialize-WHDPaths }; $SessionPath = $script:WHDRestore }
        $entries = @(Get-WHDJournal -SessionPath $SessionPath)
        $label = Split-Path $SessionPath -Leaf
    }
    # Older journals (before the ByUndo flag, 2026-09-29): an entry counts as written by an undo when it
    # sits in the session that did the undo (undo.jsonl BySession) and targets the same item.
    $undoWrites = @{}
    foreach ($sp in @($entries | ForEach-Object { "$($_.SessionPath)" } | Where-Object { $_ } | Select-Object -Unique)) {
        $marks = @(_WHDReadJsonl (Join-Path $sp 'undo.jsonl'))
        if (-not $marks.Count) { continue }
        $byId = @{}; foreach ($m in $marks) { $byId["$($m.Id)"] = $m }
        foreach ($u in @($entries | Where-Object { "$($_.SessionPath)" -eq $sp -and $byId.ContainsKey("$($_.Id)") })) {
            $k = _WHDVerifyKey $u
            if ($k -like 'act|*') { continue }
            $m = $byId["$($u.Id)"]
            $uk = "$($m.BySession)|$k"
            # keep the latest undo time for this item (the undo write happens just before its mark)
            if (-not $undoWrites.ContainsKey($uk) -or "$($m.Time)" -gt $undoWrites[$uk]) { $undoWrites[$uk] = "$($m.Time)" }
        }
    }
    $entries = @($entries | Where-Object { -not $_.Undone })
    # latest entry per target
    $latest = [ordered]@{}
    foreach ($e in $entries) {
        $key = _WHDVerifyKey $e
        $latest[$key] = $e
    }
    # The item's latest write came from an undo -> Windows' own value is back; nothing for WHD to protect.
    foreach ($k in @($latest.Keys)) {
        $le = $latest[$k]
        $uk = "$($le.Session)|$k"
        if ($le.ByUndo -or ($undoWrites.ContainsKey($uk) -and "$($le.Time)" -le $undoWrites[$uk])) { $latest.Remove($k) }
    }
    $res = @(foreach ($e in $latest.Values) {
        if ("$($e.Kind)" -eq 'action') { continue }
        $r = Test-WHDJournalEntry $e
        # Camera / microphone / radios / location are "off but not locked": the user may switch them on.
        if ($r.Result -ne 'PASS' -and (_WHDIsUserChoice $e)) { $r.Result = 'n/a'; $r.Now = "$($r.Now)  (your choice - off but not locked)" }
        $r
    })
    Write-WHDLog ("VERIFY: {0} - {1} item(s) checked" -f $label, $res.Count) 'ACT'
    if (-not $res.Count) { Write-WHDLog 'No journaled changes to verify (sessions from before the change journal existed only have .reg backups).' 'INFO'; return @() }
    foreach ($r in $res) {
        $lvl = switch ($r.Result) { 'PASS' { 'OK' } 'n/a' { 'INFO' } default { 'WARN' } }
        if (-not $Quiet -or $r.Result -ne 'PASS') {
            Write-WHDLog ("{0,-8} {1}   now: {2}" -f $r.Result, $r.Target, $r.Now) $lvl
        }
    }
    $pass = @($res | Where-Object { $_.Result -eq 'PASS' }).Count
    $bad  = @($res | Where-Object { $_.Result -in @('CHANGED','RETURNED') }).Count
    $sumLvl = if ($bad) { 'WARN' } else { 'OK' }
    Write-WHDLog ("VERIFY summary: {0} pass, {1} changed/returned since applied" -f $pass, $bad) $sumLvl
    return $res
}

# One key per verified item (same item in different sessions -> same key).
function _WHDVerifyKey {
    param($e)
    switch ("$($e.Kind)") {
        'reg'         { "reg|$($e.Path)|$($e.Name)".ToLower() }
        'service'     { "svc|$($e.Service)".ToLower() }
        'feature'     { "feat|$($e.Feature)".ToLower() }
        'appx'        { "appx|$($e.Package)".ToLower() }
        'provisioned' { "prov|$($e.Package)".ToLower() }
        'auditpol'    { "audit|$($e.Guid)".ToLower() }
        'eventlog'    { "evt|$($e.LogName)".ToLower() }
        'fwrule'      { "fw|$($e.RuleName)".ToLower() }
        'mppref'      { "mp|$($e.Setting)".ToLower() }
        'asr'         { "asr|$($e.RuleId)".ToLower() }
        'netacct'     { "pw|$($e.Setting)".ToLower() }
        'schtask'     { "task|$($e.TaskPath)$($e.TaskName)".ToLower() }
        'task'        { "utask|$($e.TaskPath)$($e.TaskName)".ToLower() }
        'pnpdev'      { "pnp|$($e.InstanceId)".ToLower() }
        'deprov'      { "deprov|$($e.Pfn)".ToLower() }
        'fwlog'       { "fwlog|$($e.Profile)".ToLower() }
        'tz'          { 'tz|system' }
        'file'        { "file|$($e.Path)".ToLower() }
        default       { "act|$($e.Id)" }
    }
}

# True for the Settings switches the user may turn on (Permissions.ps1 $WHDPrivacyLockKeep:
# camera, microphone, radios, location). Only the consent-store switch values count - the policy
# values WHD removes for these stay verified.
function _WHDIsUserChoice {
    param($e)
    if ("$($e.Kind)" -ne 'reg' -or "$($e.Name)" -ne 'Value') { return $false }
    $keep = @($script:WHDPrivacyLockKeep)
    if (-not $keep.Count) { $keep = @('webcam', 'microphone', 'radios', 'location') }
    foreach ($cap in $keep) {
        if ("$($e.Path)" -match ('\\CapabilityAccessManager\\ConsentStore\\{0}(\\NonPackaged)?$' -f [regex]::Escape($cap))) { return $true }
    }
    return $false
}

# Time zone (Classic 1.4, user decision 2026-09-30): journaled kind 'tz' (OldId/NewId), auto undo,
# Verify watches it and re-apply sets it back. Same setting as Settings > Time & language > Date & time > Time zone.
function Set-WHDTimeZoneId {
    param([Parameter(Mandatory)][string]$Id)
    $tzOld = "$((Get-TimeZone -EA SilentlyContinue).Id)"
    if ($tzOld -eq $Id) { Write-WHDLog ("time zone already {0}" -f $Id) 'OK'; return }
    $tzNew = $Id
    $jr = @{ Kind = 'tz'; OldId = $tzOld; NewId = $tzNew }
    Invoke-WHDChange -Description ("time zone: {0} -> {1}" -f $tzOld, $tzNew) -Force -Journal $jr -Action {
        Set-TimeZone -Id $tzNew -EA Stop
        $tzNow = "$((Get-TimeZone).Id)"
        if ($tzNow -ne $tzNew) { throw ("read-back mismatch: wanted '{0}', found '{1}'" -f $tzNew, $tzNow) }
    } | Out-Null
}

# ---- Phase 6 engine helpers (journaled, reversible) ---------------------------
# Runs a native tool without letting a stderr line become a terminating error
# (PS 5.1 + transcript + EAP Stop). Returns exit code + output lines.
function Invoke-WHDNative {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ArgList = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $Exe @ArgList 2>&1 | ForEach-Object { "$_" })
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    } catch {
        return [pscustomobject]@{ Code = 1; Out = @("$($_.Exception.Message)") }
    } finally { $ErrorActionPreference = $prev }
}

# Advanced audit policy for one subcategory (by GUID, so it works in any language).
function Get-WHDAuditSetting {
    param([Parameter(Mandatory)][string]$Guid)
    $r = Invoke-WHDNative -Exe 'auditpol.exe' -ArgList @('/get', "/subcategory:$Guid", '/r')
    if ($r.Code -ne 0) { return $null }
    $row = @($r.Out | Where-Object { $_ -and $_.Trim() } | ConvertFrom-Csv -EA SilentlyContinue | Select-Object -First 1)
    if (-not $row.Count) { return $null }
    $inc = "$($row[0].'Inclusion Setting')"
    [pscustomobject]@{ Success = ($inc -match 'Success'); Failure = ($inc -match 'Failure'); Text = $inc }
}
function Set-WHDAuditSetting {
    param([Parameter(Mandatory)][string]$Guid, [string]$Name = $Guid, [bool]$Success, [bool]$Failure)
    $old = Get-WHDAuditSetting -Guid $Guid
    $jr = @{ Kind = 'auditpol'; Guid = $Guid; Subcategory = $Name
             OldSuccess = $(if ($old) { [bool]$old.Success } else { $false }); OldFailure = $(if ($old) { [bool]$old.Failure } else { $false })
             NewSuccess = $Success; NewFailure = $Failure }
    $sArg = if ($Success) { 'enable' } else { 'disable' }
    $fArg = if ($Failure) { 'enable' } else { 'disable' }
    Invoke-WHDChange -Description ("audit policy '{0}': success={1} failure={2}" -f $Name, $sArg, $fArg) -Force -Journal $jr -Action {
        $r = Invoke-WHDNative -Exe 'auditpol.exe' -ArgList @('/set', "/subcategory:$Guid", "/success:$sArg", "/failure:$fArg")
        if ($r.Code -ne 0) { throw ("auditpol exit {0}: {1}" -f $r.Code, ($r.Out -join ' ')) }
        $now = Get-WHDAuditSetting -Guid $Guid
        if (-not $now -or $now.Success -ne $Success -or $now.Failure -ne $Failure) { throw 'read-back mismatch: audit setting did not stick' }
    }
}

# Event log size + mode (Circular = "overwrite events as needed").
function Get-WHDEventLogConfig {
    param([Parameter(Mandatory)][string]$LogName)
    try { $c = Get-WinEvent -ListLog $LogName -EA Stop } catch { return $null }
    [pscustomobject]@{ MaxBytes = [int64]$c.MaximumSizeInBytes; Mode = "$($c.LogMode)"; UsedBytes = [int64]$c.FileSize; Records = $c.RecordCount }
}
function Set-WHDEventLogConfig {
    param([Parameter(Mandatory)][string]$LogName, [Parameter(Mandatory)][int64]$MaxBytes, [ValidateSet('Circular','AutoBackup','Retain')][string]$Mode = 'Circular')
    $old = Get-WHDEventLogConfig -LogName $LogName
    $jr = @{ Kind = 'eventlog'; LogName = $LogName
             OldMaxBytes = $(if ($old) { $old.MaxBytes } else { 20971520 }); OldMode = $(if ($old) { $old.Mode } else { 'Circular' })
             NewMaxBytes = $MaxBytes; NewMode = $Mode }
    Invoke-WHDChange -Description ("event log '{0}': max {1:N0} MB, mode {2}" -f $LogName, ($MaxBytes / 1MB), $Mode) -Force -Journal $jr -Action {
        $c = Get-WinEvent -ListLog $LogName -EA Stop
        $c.MaximumSizeInBytes = $MaxBytes
        $c.LogMode = [System.Diagnostics.Eventing.Reader.EventLogMode]$Mode
        $c.SaveChanges()
        $now = Get-WHDEventLogConfig -LogName $LogName
        if (-not $now -or $now.MaxBytes -ne $MaxBytes -or $now.Mode -ne $Mode) { throw 'read-back mismatch: event log settings did not stick' }
    }
}

# Replace a file with a backup copy (journaled: the current file is backed up first).
function Restore-WHDFileFromBackup {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Backup)
    if (-not $script:WHDRestore) { Initialize-WHDPaths }
    $newBak = Join-Path $script:WHDRestore ((Split-Path $Path -Leaf) + '.before-undo.' + (Get-Date -Format 'HHmmss'))
    $jr = @{ Kind = 'file'; Path = $Path; Backup = $newBak
             NewHash = $(if (Test-Path -LiteralPath $Backup) { (Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash } else { '' }) }
    Invoke-WHDChange -Description ("restore {0} from {1}" -f $Path, $Backup) -Force -Journal $jr -Action {
        if (Test-Path -LiteralPath $Path) { Copy-Item -LiteralPath $Path -Destination $newBak -Force -EA Stop }
        Copy-Item -LiteralPath $Backup -Destination $Path -Force -EA Stop
    }
}

# ---- terminal Undo center ----------------------------------------------------
function Show-WHDUndoEntries {
    param([object[]]$Entries)
    $i = 0
    foreach ($e in $Entries) {
        $i++
        $flag  = if ($e.Undone) { 'undone' } elseif ($e.UndoMode -eq 'auto') { 'auto  ' } else { 'manual' }
        $color = if ($e.Undone) { 'DarkGray' } elseif ($e.UndoMode -eq 'auto') { 'Green' } else { 'Yellow' }
        Write-Host ("  {0,3}. " -f $i) -NoNewline
        Write-Host ("[{0}] " -f $flag) -NoNewline -ForegroundColor $color
        Write-Host ("{0}  {1}" -f $e.Time, $e.Description)
    }
}

Write-WHDLog 'Common.ps1 engine loaded.' 'INFO'

