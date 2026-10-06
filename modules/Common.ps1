<#
================================================================================
 WHD Next  -  modules\Common.ps1
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

# ---- WHD Next: FULL mode / SAFE mode (decision D6, Option C) ---------------
# FULL mode  = PowerShell 7.6 or newer: everything works as in Classic.
# SAFE mode  = Windows PowerShell 5.1 (or an older PowerShell 7): read-only screens, the dry-run plan,
#              Verify, Undo, re-apply and re-remove only. NEW changes need FULL mode.
# How it is enforced (two locks):
#   1. In SAFE mode $script:WHDExecute is never switched on globally. The EXECUTE toggle only sets
#      $script:WHDSafeExecute ("I want my undo / re-apply to be real"). Every code path that checks
#      $script:WHDExecute therefore stays a dry-run.
#   2. The change gate (Invoke-WHDChange) refuses anything that is not inside an allowed operation.
# The allowed operations call Invoke-WHDSafeAllowed, which switches EXECUTE on for that one operation.
if (-not (Get-Variable -Name WHDSafeMode -Scope Script -EA SilentlyContinue)) {
    $whdEngineOk = ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion -ge [version]'7.6.0')
    $script:WHDSafeMode = (-not $whdEngineOk)
}
if (-not (Get-Variable -Name WHDSafeExecute -Scope Script -EA SilentlyContinue)) { $script:WHDSafeExecute = $false }
$script:WHDSafeAllow = 0                # >0 while an allowed operation (undo / re-apply / re-remove) is running
if ($script:WHDSafeMode) { $script:WHDExecute = $false }

# ---- WHD Next: stop when WHD Next cannot write its own files ----------------
# (user decisions 2026-10-01 gap G10, and 2026-10-02 gap G11)
# A change that cannot be written to the change journal has no Undo and no Verify. So the FIRST failed
# journal write stops the run: EXECUTE is switched off and the change gate refuses everything else until
# WHD Next is started again. The same stop (Kind 'data') is used when the write test that follows
# "folder protection -> Block" fails: nothing unrecorded has happened yet, WHD Next just must not go on.
$script:WHDJournalStop = $null          # $null = fine; otherwise the facts about the failed write
function Test-WHDJournalStop { return [bool]$script:WHDJournalStop }
function Get-WHDThisProgram {
    $p = ''
    try { $p = (Get-Process -Id $PID -ErrorAction Stop).Path } catch {}
    return "$p"
}
# The "what to do" lines, shared by every message about a blocked write.
function Show-WHDWriteBlockedHelp {
    param([string]$Program)
    if (-not $Program) { $Program = Get-WHDThisProgram }
    $ps51 = ''
    if ($env:SystemRoot) { $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    Write-WHDLog 'Likely cause: folder protection (Controlled folder access) is blocking this PowerShell.' 'WARN'
    Write-WHDLog 'To allow it: Windows Security > Virus & threat protection > Ransomware protection >' 'WARN'
    Write-WHDLog ('  Allow an app through Controlled folder access > add: {0}' -f $Program) 'WARN'
    if ($ps51 -and "$Program" -ne "$ps51") { Write-WHDLog ('  The launcher and the update guard scan also use: {0}' -f $ps51) 'WARN' }
    if ($env:ProgramData) {
        Write-WHDLog ('Or, without any permission: quit and start WHD Next again with  Start-WHD.ps1 -CopyToUnlocked  - the launcher') 'WARN'
        Write-WHDLog ('  copies WHD Next to {0} and runs it from there.' -f (Join-Path $env:ProgramData 'WinHardenDebloatNext\app')) 'WARN'
    }
    Write-WHDLog 'Other causes: disk full, or the WHD folder is read-only.' 'WARN'
}
function Show-WHDJournalStop {
    if (-not $script:WHDJournalStop) { return }
    $j = $script:WHDJournalStop
    # Through Write-WHDLog so the same lines reach the console, the transcript and the window's log.
    Write-WHDLog '################################################################################' 'ERR'
    if ("$($j.Kind)" -eq 'data') {
        Write-WHDLog 'STOPPED - WHD Next can no longer write its own files (journal, logs, reports).' 'ERR'
        Write-WHDLog 'No further change is made in this run. EXECUTE is switched off.' 'ERR'
        Write-WHDLog ('File   : {0}' -f $j.File) 'WARN'
        Write-WHDLog ('Reason : {0}' -f $j.Reason) 'WARN'
        Write-WHDLog ('Found right after: {0}   (that change itself IS recorded)' -f $j.Description) 'WARN'
    } else {
        Write-WHDLog 'STOPPED - the change journal could not be written.' 'ERR'
        Write-WHDLog 'No further change is made in this run. EXECUTE is switched off.' 'ERR'
        Write-WHDLog ('File   : {0}' -f $j.File) 'WARN'
        Write-WHDLog ('Reason : {0}' -f $j.Reason) 'WARN'
        Write-WHDLog ('This change WAS made but is NOT recorded (no Undo / Verify for it): {0}' -f $j.Description) 'WARN'
        if ($j.Line) { Write-WHDLog ('Its record (keep this line): {0}' -f $j.Line) 'WARN' }
    }
    Show-WHDWriteBlockedHelp -Program $j.Program
    Write-WHDLog 'Fix it, then start WHD Next again.' 'WARN'
    Write-WHDLog '################################################################################' 'ERR'
}
function Set-WHDJournalStop {
    param([string]$Description, [string]$Reason, [string]$File, [string]$Line, [ValidateSet('journal','data')][string]$Kind = 'journal')
    if ($script:WHDJournalStop) { return }          # keep the first failure; later ones cannot happen (gate is closed)
    $script:WHDJournalStop = [pscustomobject]@{ Time = (Get-Date); Kind = $Kind; Description = $Description; Reason = $Reason; File = $File; Line = $Line; Program = (Get-WHDThisProgram) }
    $script:WHDExecute     = $false
    $script:WHDSafeExecute = $false
    try { Show-WHDJournalStop } catch { Write-Host ('STOPPED - WHD Next cannot write its files: {0}' -f $Reason) -ForegroundColor Red }   # the message must never break the stop
    # The window version hooks in here to untick its EXECUTE box.
    if ($script:WHDJournalStopHook) { try { & $script:WHDJournalStopHook } catch {} }
}

# Can this PowerShell write into WHD Next's data folder right now? One small fixed file (logs\write-test.txt)
# is overwritten - nothing is deleted. Folder protection blocks such a write with "Could not find file".
function Test-WHDDataWritable {
    $f = ''
    try {
        if (-not $script:WHDLogs) { Initialize-WHDPaths }
        $f = Join-Path $script:WHDLogs 'write-test.txt'
        Set-Content -LiteralPath $f -Value ('WHD Next write test {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding ASCII -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; File = $f; Reason = '' }
    } catch { return [pscustomobject]@{ Ok = $false; File = $f; Reason = "$($_.Exception.Message)" } }
}
# Called right after folder protection was switched to Block for real (user decision 2026-10-02).
# The block needs some seconds to take effect, so the write test is repeated for about 25 seconds unless this
# PowerShell is already on the allowed list. If the test fails: explain, let the user allow the program and
# test again (y), or stop making changes in this run (n). Returns $true when WHD Next can write.
function Wait-WHDFolderProtectionCheck {
    param([string]$After = 'folder protection -> Block')
    if (-not $script:WHDExecute) { return $true }
    $prog = Get-WHDThisProgram
    $allowed = $false
    try {
        $whdMp = Get-WHDMpPreference
        $allowed = (@($whdMp.ControlledFolderAccessAllowedApplications | Where-Object { $_ } | ForEach-Object { "$_".ToLower() }) -contains $prog.ToLower())
    } catch {}
    $r = $null
    if ($allowed) {
        $r = Test-WHDDataWritable
    } else {
        Write-WHDLog 'Checking that WHD Next can still write its own files (folder protection needs some seconds to take effect; about 25 s)...' 'INFO'
        for ($whdTry = 1; $whdTry -le 5; $whdTry++) {
            Start-Sleep -Seconds 5
            $r = Test-WHDDataWritable
            if (-not $r.Ok) { break }
        }
    }
    $whdAsk = 0
    while (-not $r.Ok) {
        $whdAsk++
        Write-WHDLog 'FOLDER PROTECTION NOW BLOCKS WHD NEXT from writing its own files (journal, logs, reports).' 'ERR'
        Write-WHDLog ('File   : {0}' -f $r.File) 'WARN'
        Write-WHDLog ('Reason : {0}' -f $r.Reason) 'WARN'
        Show-WHDWriteBlockedHelp -Program $prog
        if ($whdAsk -gt 5 -or -not (Confirm-WHDProceed 'test again (answer y AFTER you allowed the program; n = stop making changes in this run)')) {
            Set-WHDJournalStop -Kind 'data' -Description $After -Reason $r.Reason -File $r.File -Line ''
            return $false
        }
        Start-Sleep -Seconds 2
        $r = Test-WHDDataWritable
    }
    Write-WHDLog 'OK - WHD Next can write its own files with folder protection on.' 'OK'
    return $true
}

# Is the user asking for real changes? (FULL: the EXECUTE toggle. SAFE: the toggle, for allowed operations only.)
function Test-WHDExecuteWanted {
    return [bool]($script:WHDExecute -or ($script:WHDSafeMode -and $script:WHDSafeExecute))
}
function Get-WHDModeText {
    if ($script:WHDSafeMode) { return 'SAFE MODE (PowerShell {0}) - checks, Verify, Undo and re-apply only' -f $PSVersionTable.PSVersion }
    return 'FULL mode (PowerShell {0})' -f $PSVersionTable.PSVersion
}
# Runs one allowed operation. FULL mode: just runs it. SAFE mode: marks it as allowed and, when the
# user switched EXECUTE on, makes it real for the duration of this operation only.
function Invoke-WHDSafeAllowed {
    param([Parameter(Mandatory)][scriptblock]$Do)
    if (-not $script:WHDSafeMode) { & $Do; return }
    $script:WHDSafeAllow = [int]$script:WHDSafeAllow + 1
    if ($script:WHDSafeExecute) { $script:WHDExecute = $true }
    try { & $Do }
    finally {
        $script:WHDSafeAllow = [int]$script:WHDSafeAllow - 1
        if ($script:WHDSafeAllow -le 0) { $script:WHDSafeAllow = 0; $script:WHDExecute = $false }
    }
}

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
    Write-WHDLog ("Session start | {0} | Execute={1} | Root={2}" -f (Get-WHDModeText), (Test-WHDExecuteWanted), $script:WHDRoot)
}
function Stop-WHDTranscript { try { Stop-Transcript | Out-Null } catch {} }

# ---- elevation --------------------------------------------------------------
function Test-WHDAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- one screen line made of coloured parts ---------------------------------
# WHD Next (user decision 2026-10-02, log clutter): PowerShell 7 writes every "Write-Host -NoNewline" piece on
# its own line in the log file, which made the menus unreadable there. On PowerShell 7 the line is therefore
# written with ONE Write-Host that carries colour codes (the log gets one clean line). Windows PowerShell 5.1,
# or a host without colour-code support, keeps the classic piece-by-piece way.
#   Write-WHDParts @('   1. ', @('Name', 'Green'), '  [present]')
$script:WHDAnsiColor = @{ Black = 'Black'; DarkBlue = 'Blue'; DarkGreen = 'Green'; DarkCyan = 'Cyan'; DarkRed = 'Red'; DarkMagenta = 'Magenta'
                          DarkYellow = 'Yellow'; Gray = 'White'; DarkGray = 'BrightBlack'; Blue = 'BrightBlue'; Green = 'BrightGreen'; Cyan = 'BrightCyan'
                          Red = 'BrightRed'; Magenta = 'BrightMagenta'; Yellow = 'BrightYellow'; White = 'BrightWhite' }
function Write-WHDParts {
    param([Parameter(Mandatory)][object[]]$Parts)
    $whdAnsi = $false
    try { $whdAnsi = ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $PSStyle -and $Host.UI.SupportsVirtualTerminal -and "$($PSStyle.OutputRendering)" -ne 'PlainText') } catch { $whdAnsi = $false }
    if ($whdAnsi) {
        $sb = New-Object System.Text.StringBuilder
        foreach ($p in $Parts) {
            if ($p -is [array]) { $t = "$($p[0])"; $c = "$($p[1])" } else { $t = "$p"; $c = '' }
            if ($c -and $script:WHDAnsiColor.ContainsKey($c)) { [void]$sb.Append($PSStyle.Foreground.($script:WHDAnsiColor[$c])).Append($t).Append($PSStyle.Reset) }
            else { [void]$sb.Append($t) }
        }
        Write-Host $sb.ToString()
        return
    }
    foreach ($p in $Parts) {
        if ($p -is [array]) { $t = "$($p[0])"; $c = "$($p[1])" } else { $t = "$p"; $c = '' }
        if ($c) { Write-Host $t -ForegroundColor $c -NoNewline } else { Write-Host $t -NoNewline }
    }
    Write-Host ''
}

# ---- "1,3,5-7" style selections (user request 2026-10-02) --------------------
# Numbers separated by commas or spaces, ranges like 5-7, and * for the recommended set ($Star).
# Returns the sorted, unique numbers (all within 1..$Max), or $null when the text is not understood.
function ConvertFrom-WHDSelection {
    param([string]$Text, [int]$Max, [int[]]$Star = @())
    $t = "$Text".Trim()
    if (-not $t) { return $null }
    $out = New-Object System.Collections.Generic.List[int]
    foreach ($tok in @($t -split '[,\s]+' | Where-Object { $_ })) {
        if ($tok -eq '*') { foreach ($s in @($Star)) { if (-not $out.Contains([int]$s)) { $out.Add([int]$s) } }; continue }
        if ($tok -match '^(\d+)-(\d+)$') {
            $a = [int]$Matches[1]; $b = [int]$Matches[2]
            if ($a -gt $b) { $x = $a; $a = $b; $b = $x }
            if ($a -lt 1 -or $b -gt $Max) { return $null }
            for ($n = $a; $n -le $b; $n++) { if (-not $out.Contains($n)) { $out.Add($n) } }
            continue
        }
        if ($tok -match '^\d+$') {
            $n = [int]$tok
            if ($n -lt 1 -or $n -gt $Max) { return $null }
            if (-not $out.Contains($n)) { $out.Add($n) }
            continue
        }
        return $null
    }
    return ,@($out.ToArray() | Sort-Object)
}

# ---- progress for slow loops (user request 2026-10-02) -----------------------
# A progress bar in the console plus a log line every $Every steps, so a long action is seen working
# (the log lines also reach the window version's log box).
function Write-WHDProgressStep {
    param([string]$Activity, [int]$Done, [int]$Total, [int]$Every = 25)
    try { Write-Progress -Activity $Activity -Status ('{0} of {1}' -f $Done, $Total) -PercentComplete ([math]::Min(100, [int](100 * $Done / [math]::Max(1, $Total)))) } catch {}
    if ($Done -ge $Total) { try { Write-Progress -Activity $Activity -Completed } catch {} }
    # The window version hooks in here to move its progress bar.
    if ($script:WHDProgressHook) { try { & $script:WHDProgressHook $Activity $Done $Total } catch {} }
    if ($Done -ge $Total -or ($Every -gt 0 -and ($Done % $Every) -eq 0)) { Write-WHDLog ('  {0}: {1} of {2}' -f $Activity, $Done, $Total) 'INFO' }
}

# ---- risk labelling ---------------------------------------------------------
function Write-WHDRisk {
    param([ValidateSet('reversible','caution','hard')]$Tier, [string]$Text)
    $map = @{ reversible = 'Green'; caution = 'Yellow'; hard = 'Red' }
    Write-WHDParts @(@(("    [{0}] " -f $Tier.ToUpper()), $map[$Tier]), $Text)
    if ($script:WHDLogSink) { try { & $script:WHDLogSink ("    [{0}] {1}" -f $Tier.ToUpper(), $Text) 'INFO' } catch {} }
}

# =============================================================================
#  WHD Next - Windows' built-in CIM for Defender and System Restore (build step 5)
# -----------------------------------------------------------------------------
#  PowerShell 7.6 cannot load the Defender module or the restore-point cmdlets
#  natively (they only work through its Windows PowerShell 5.1 helper). The CIM
#  classes underneath them work natively in BOTH engines, so WHD Next talks to
#  those directly - one code path, no helper:
#     root/Microsoft/Windows/Defender : MSFT_MpPreference   (methods Set / Add / Remove)
#                                       MSFT_MpComputerStatus
#     root/default                    : SystemRestore       (Enable, CreateRestorePoint)
#  Checked on the user's PC 2026-10-01 (tools\Test-WHDCompat.ps1, area "CIM").
# =============================================================================
$script:WHDDefenderNs = 'root/Microsoft/Windows/Defender'

function Get-WHDMpPreference     { Get-CimInstance -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpPreference'     -ErrorAction Stop }
function Get-WHDMpComputerStatus { Get-CimInstance -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpComputerStatus' -ErrorAction Stop }
function Test-WHDDefenderCim {
    try { [void](Get-CimClass -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpPreference' -ErrorAction Stop); return $true } catch { return $false }
}

# Converts a value to the exact CIM type a method parameter declares (uint8, uint8[], string[], ...).
function ConvertTo-WHDCimValue {
    param($Value, [string]$CimType)
    switch ($CimType) {
        'Boolean'     { return [bool]$Value }
        'UInt8'       { return [byte]$Value }
        'UInt16'      { return [uint16]$Value }
        'UInt32'      { return [uint32]$Value }
        'UInt64'      { return [uint64]$Value }
        'SInt8'       { return [sbyte]$Value }
        'SInt16'      { return [int16]$Value }
        'SInt32'      { return [int32]$Value }
        'SInt64'      { return [int64]$Value }
        'String'      { return [string]$Value }
        'UInt8Array'  { return ,([byte[]]@($Value)) }
        'UInt16Array' { return ,([uint16[]]@($Value)) }
        'UInt32Array' { return ,([uint32[]]@($Value)) }
        'SInt32Array' { return ,([int32[]]@($Value)) }
        'SInt64Array' { return ,([int64[]]@($Value)) }
        'StringArray' { return ,([string[]]@($Value)) }
        default       { return $Value }
    }
}

# Calls a static CIM method. The parameter types are read from the class on THIS Windows version,
# so a renamed or missing parameter gives a clear error instead of a silent no-op.
function Invoke-WHDCimStatic {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$ClassName,
          [Parameter(Mandatory)][string]$Method, [hashtable]$Values = @{})
    $cls = Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    $m = $cls.CimClassMethods[$Method]
    if (-not $m) { throw ("CIM method {0}.{1} does not exist on this Windows version" -f $ClassName, $Method) }
    $cimArgs = @{}
    foreach ($k in @($Values.Keys)) {
        $p = $m.Parameters[$k]
        if (-not $p) { throw ("CIM method {0}.{1} has no parameter '{2}' on this Windows version" -f $ClassName, $Method, $k) }
        $cimArgs[$k] = ConvertTo-WHDCimValue -Value $Values[$k] -CimType "$($p.CimType)"
    }
    $r = Invoke-CimMethod -Namespace $Namespace -ClassName $ClassName -MethodName $Method -Arguments $cimArgs -ErrorAction Stop
    if ($r -and $null -ne $r.ReturnValue -and [int64]$r.ReturnValue -ne 0) {
        throw ("CIM {0}.{1} returned error code {2}" -f $ClassName, $Method, $r.ReturnValue)
    }
    return $r
}

# System Restore (Microsoft Learn: SystemRestore class; RESTOREPOINTINFO values MODIFY_SETTINGS = 12, BEGIN_SYSTEM_CHANGE = 100).
function Enable-WHDSystemRestore {
    param([string]$Drive = "$env:SystemDrive\")
    $v = @{ Drive = $Drive }
    # This PC's class also has WaitTillEnabled (seen 2026-10-01): wait, so a restore point can follow at once.
    try {
        $srm = (Get-CimClass -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop).CimClassMethods['Enable']
        if ($srm -and $srm.Parameters['WaitTillEnabled']) { $v['WaitTillEnabled'] = $true }
    } catch { }
    [void](Invoke-WHDCimStatic -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'Enable' -Values $v)
}
function New-WHDSystemRestorePoint {
    param([Parameter(Mandatory)][string]$Description)
    [void](Invoke-WHDCimStatic -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'CreateRestorePoint' -Values @{
        Description = $Description; RestorePointType = 12; EventType = 100 })
}
# Defender definitions update (replaces Update-MpSignature). UpdateSource numbers are from Microsoft's own
# definition file on the PC (ConfigDefender\MSFT_MpSignature.cdxml, read 2026-10-01):
#   0 = InternalDefinitionUpdateServer, 1 = MicrosoftUpdateServer, 2 = MMPC, 3 = FileShares
function Update-WHDMpSignature {
    param([ValidateSet('InternalDefinitionUpdateServer', 'MicrosoftUpdateServer', 'MMPC', 'FileShares')][string]$UpdateSource = 'MMPC')
    $map = @{ InternalDefinitionUpdateServer = 0; MicrosoftUpdateServer = 1; MMPC = 2; FileShares = 3 }
    [void](Invoke-WHDCimStatic -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpSignature' -Method 'Update' -Values @{ UpdateSource = $map[$UpdateSource] })
}
function Get-WHDSystemRestorePoints {
    @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop)
}

# =============================================================================
#  WHD Next - alerts: a small window + a Windows event log entry (build step 5)
# -----------------------------------------------------------------------------
#  Used by the update guard next to opening its .txt report (as Classic did).
#  The event source is registered when the guard is INSTALLED (a journaled
#  change) - a guard CHECK itself only writes an entry, it never registers.
# =============================================================================
$script:WHDEventSource = 'WHD Next'
$script:WHDEventLog    = 'Application'

function Test-WHDEventSource {
    # Looks at the registration itself. (EventLog.SourceExists also searches the Security log and throws when not elevated.)
    return [bool](Test-Path -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\{0}\{1}' -f $script:WHDEventLog, $script:WHDEventSource))
}
function Register-WHDEventSource {
    if (Test-WHDEventSource) { return }
    [System.Diagnostics.EventLog]::CreateEventSource($script:WHDEventSource, $script:WHDEventLog)
}
function Unregister-WHDEventSource {
    if (-not (Test-WHDEventSource)) { return }
    [System.Diagnostics.EventLog]::DeleteEventSource($script:WHDEventSource)
}
# Writes one entry (Event Viewer > Windows Logs > Application, source "WHD Next"). Never throws.
# Returns $true when it was written, $false when the source is not registered or writing failed.
function Write-WHDEventLog {
    param([Parameter(Mandatory)][string]$Message,
          [ValidateSet('Information','Warning','Error')][string]$Type = 'Information', [int]$EventId = 1000)
    try {
        if (-not (Test-WHDEventSource)) { return $false }
        $et = [System.Diagnostics.EventLogEntryType]::$Type
        if ($Message.Length -gt 30000) { $Message = $Message.Substring(0, 30000) + ' ...' }
        [System.Diagnostics.EventLog]::WriteEntry($script:WHDEventSource, $Message, $et, $EventId)
        return $true
    } catch { return $false }
}

# A small always-on-top window with a few lines and two buttons. Blocks until it is closed.
# Built from plain WPF objects (works in Windows PowerShell 5.1 and PowerShell 7). Never throws.
function Show-WHDAlertWindow {
    param([string]$Title = 'WHD Next', [string]$Heading = '', [string[]]$Lines = @(), [string]$ReportPath = '')
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        $win = New-Object System.Windows.Window
        $win.Title = $Title
        $win.Width = 620
        $win.SizeToContent = [System.Windows.SizeToContent]::Height
        $win.MaxHeight = 520
        $win.Topmost = $true
        $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
        $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen

        $root = New-Object System.Windows.Controls.StackPanel
        $root.Margin = New-Object System.Windows.Thickness(16)

        if ($Heading) {
            $h = New-Object System.Windows.Controls.TextBlock
            $h.Text = $Heading
            $h.FontSize = 16
            $h.FontWeight = [System.Windows.FontWeights]::Bold
            $h.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $h.Margin = New-Object System.Windows.Thickness(0, 0, 0, 10)
            [void]$root.Children.Add($h)
        }

        $body = New-Object System.Windows.Controls.TextBox
        $body.Text = (@($Lines) -join "`r`n")
        $body.IsReadOnly = $true
        $body.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $body.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $body.MaxHeight = 320
        $body.BorderThickness = New-Object System.Windows.Thickness(0)
        $body.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
        [void]$root.Children.Add($body)

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
        $buttons.Margin = New-Object System.Windows.Thickness(0, 14, 0, 0)

        if ($ReportPath) {
            $open = New-Object System.Windows.Controls.Button
            $open.Content = 'Open the report'
            $open.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
            $open.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
            $whdAlertReport = $ReportPath
            $open.Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $whdAlertReport) } catch { } }.GetNewClosure())
            [void]$buttons.Children.Add($open)
        }
        $close = New-Object System.Windows.Controls.Button
        $close.Content = 'Close'
        $close.IsDefault = $true
        $close.IsCancel = $true
        $close.Padding = New-Object System.Windows.Thickness(12, 4, 12, 4)
        $whdAlertWin = $win
        $close.Add_Click({ $whdAlertWin.Close() }.GetNewClosure())
        [void]$buttons.Children.Add($close)
        [void]$root.Children.Add($buttons)

        $win.Content = $root
        [void]$win.ShowDialog()
        return $true
    } catch {
        try { Write-WHDLog ("alert window could not be shown: {0}" -f $_.Exception.Message) 'WARN' } catch { }
        return $false
    }
}

# ---- restore point + registry backup (before first real change) ------------
function New-WHDRestorePoint {
    # Idempotent per session. Enables System Protection on C: if needed, lifts
    # the 24h throttle, then checkpoints. Best-effort: warns, never blocks.
    if ($script:WHDRestoreDone) { return }
    if (-not $script:WHDExecute) { return }
    Write-WHDLog 'Creating System Restore point before first change...' 'ACT'
    try {
        Enable-WHDSystemRestore -Drive "$env:SystemDrive\"      # WHD Next: CIM instead of Enable-ComputerRestore
    } catch { Write-WHDLog "turn on System Restore: $($_.Exception.Message)" 'WARN' }
    # lift the once-per-24h throttle so our checkpoint isn't silently skipped
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    try {
        if (-not (Test-Path $srKey)) { New-Item -Path $srKey -Force | Out-Null }
        New-ItemProperty -Path $srKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
    } catch {}
    try {
        New-WHDSystemRestorePoint -Description ("WHD Next {0}" -f $script:WHDStamp)      # WHD Next: CIM instead of Checkpoint-Computer
        Write-WHDLog ("System Restore point created: WHD Next {0}" -f $script:WHDStamp) 'OK'
    } catch {
        Write-WHDLog "restore point could not be created: $($_.Exception.Message)" 'WARN'
        Write-WHDLog 'Continuing; registry/package exports in restore\ are still captured.' 'WARN'
    }
    $script:WHDRestoreDone = $true
}

function New-WHDCheckpointNow {
    # On-demand restore point (ignores the once-per-session guard).
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { Invoke-WHDSafeAllowed { New-WHDCheckpointNow }; return }   # WHD Next: allowed in SAFE mode (protective)
    if (-not $script:WHDExecute) { Write-WHDLog 'would: create a System Restore point now' 'DRY'; return }
    Write-WHDLog 'Creating a System Restore point on demand...' 'ACT'
    $script:WHDRestoreDone = $false
    New-WHDRestorePoint
}

function Backup-WHDRegistryKey {
    param([string]$PsPath)   # PowerShell form: HKLM:\...  or  HKCU:\...
    if (-not $script:WHDExecute) { return }
    Initialize-WHDPaths
    # Only export keys that already exist. A key we are about to CREATE has
    # nothing to back up (rollback = delete it), and running reg.exe on a
    # missing key just throws a noisy (caught) error into the transcript.
    if (-not (Test-Path -LiteralPath $PsPath)) { return }
    $regPath = $PsPath -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
    $safe = ($PsPath -replace '[:\\]', '_')
    $out  = Join-Path $script:WHDRestore ("$safe.reg")
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
    # WHD Next, journal stop: after a failed journal write nothing else is changed in this run.
    if ($script:WHDJournalStop) {
        Write-WHDLog ("STOPPED - not done (WHD Next cannot write its files - see the STOPPED box): {0}" -f $Description) 'WARN'
        return (New-WHDResult -Action $Description -Status 'skipped' -Detail 'stopped: WHD Next could not write its own files')
    }
    # WHD Next, lock 2: in SAFE mode only an allowed operation (undo / re-apply / re-remove) may pass.
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) {
        if ($script:WHDExecute -or $script:WHDSafeExecute) {
            Write-WHDLog ("SAFE MODE - not done (new changes need PowerShell 7.6 / FULL mode): {0}" -f $Description) 'WARN'
            return (New-WHDResult -Action $Description -Status 'skipped' -Detail 'safe mode: new changes need PowerShell 7.6 (FULL mode)')
        }
        Write-WHDLog ("would (FULL mode only): {0}" -f $Description) 'DRY'
        return (New-WHDResult -Action $Description -Status 'planned')
    }
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
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        # Set-ItemProperty creates-or-updates; New-ItemProperty -Force throws
        # "unauthorized operation" when the value already exists.
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
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
        Invoke-WHDChange -Description ("remove Appx (all users): {0}" -f $p.PackageFullName) -Force -Journal $jr -Action {
            Remove-AppxPackage -Package $p.PackageFullName -AllUsers -EA Stop
        }
        if ("$($p.PackageFamilyName)") { Add-WHDDeprovisionMark -Pfn "$($p.PackageFamilyName)" }
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
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Invoke-WHDReApplyChanged @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
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
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Invoke-WHDReRemoveReturned @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
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
        Invoke-WHDChange -Description ("deprovision (new users won't get): {0}" -f $p.PackageName) -Force -Journal $jr -Action {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -AllUsers -EA Stop
        }
        if ("$($p.DisplayName)" -and "$($p.PublisherId)") { Add-WHDDeprovisionMark -Pfn ("{0}_{1}" -f $p.DisplayName, $p.PublisherId) }
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
    $line = ''
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
        # WHD Next: a change without a journal record has no Undo / Verify - stop the run here.
        $jf = ''; try { $jf = Join-Path $script:WHDRestore 'journal.jsonl' } catch {}
        Set-WHDJournalStop -Description $Description -Reason $_.Exception.Message -File $jf -Line $line
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
    } catch {
        # WHD Next: the undo WAS done but could not be marked in the history - stop the run here.
        $uf = ''; try { $uf = Join-Path $Entry.SessionPath 'undo.jsonl' } catch {}
        Set-WHDJournalStop -Description ("undo mark for: {0}" -f $Entry.Description) -Reason $_.Exception.Message -File $uf -Line ''
    }
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
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Invoke-WHDUndo @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
    $todo = @($Entries | Where-Object { -not $_.Undone } | Sort-Object @{e={"$($_.Session)"};Descending=$true}, @{e={[int]$_.Seq};Descending=$true})
    if (-not $todo.Count) { Write-WHDLog 'Nothing to undo (already undone or empty selection).' 'INFO'; return }
    $auto = @($todo | Where-Object { $_.UndoMode -eq 'auto' }).Count
    Write-WHDLog ("UNDO: {0} selected change(s), {1} can be undone automatically" -f $todo.Count, $auto) 'ACT'
    Write-WHDRisk 'caution' 'Puts the previous values back. Each undo is itself journaled, so it can be undone again.'
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
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Restore-WHDSessionFirewall @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
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
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Restore-WHDSessionHosts @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
    $f = Join-Path $SessionPath 'hosts.bak'
    if (-not (Test-Path -LiteralPath $f)) { Write-WHDLog 'This session has no hosts backup.' 'WARN'; return }
    $len = (Get-Item -LiteralPath $f).Length
    Write-WHDLog ("RESTORE HOSTS FILE from {0} ({1:N0} bytes)" -f $f, $len) 'ACT'
    if ($len -eq 0) { Write-WHDRisk 'caution' 'This backup is EMPTY - restoring it leaves an empty hosts file (Windows works fine without entries).' }
    else            { Write-WHDRisk 'caution' 'Replaces the current hosts file with the saved copy.' }
    if (-not (Confirm-WHDProceed 'replace the hosts file with this backup')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Invoke-WHDChange -Description ("restore hosts file from {0}" -f $f) -Force -Action {
        Copy-Item -LiteralPath $hosts -Destination (Join-Path $script:WHDRestore 'hosts.bak') -Force -EA SilentlyContinue
        Copy-Item -LiteralPath $f -Destination $hosts -Force -EA Stop
        & ipconfig.exe /flushdns | Out-Null
    } | Out-Null
}

# Older sessions (before the journal existed) only have .reg exports.
function Import-WHDLegacyRegBackups {
    param([Parameter(Mandatory)][string]$SessionPath)
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { $whdSafeArgs = $PSBoundParameters; Invoke-WHDSafeAllowed { Import-WHDLegacyRegBackups @whdSafeArgs }; return }   # WHD Next: allowed in SAFE mode
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
            try { $v = [int](Get-WHDMpPreference).($Entry.Setting); $r.Now = "$v"; $r.Result = if ($v -eq [int]$Entry.NewValue) { 'PASS' } else { 'CHANGED' } }
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
# WHD Next (user decision 2026-10-02, gap G13): inventory scans and the update-guard status that came along
# from another PC / an earlier Windows install are found here and archived together with the journal sessions.
# A scan is "this PC" when its os-info.json carries this MachineId; older scans without one are judged by
# their scan time (UTC) against the Windows install date, then by the folder name.
function Test-WHDScanIsThisPC {
    param([Parameter(Mandatory)][string]$ScanDir)
    $inst = Get-WHDWindowsInstallDate
    $f = Join-Path $ScanDir 'os-info.json'
    if (Test-Path -LiteralPath $f) {
        $o = $null
        try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $o = $null }
        if ($o -and "$($o.MachineId)") { return ("$($o.MachineId)".ToLower() -eq (Get-WHDMachineId)) }
        if ($o -and $o.ScannedUtc -and $inst) {
            $u = $null
            # PowerShell 7 hands the time back as a date, Windows PowerShell 5.1 as text.
            if ($o.ScannedUtc -is [datetime]) { $u = $o.ScannedUtc }
            else { try { $u = [datetime]::Parse("$($o.ScannedUtc)", [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { $u = $null } }
            if ($u) { return ($u.ToUniversalTime() -ge $inst.ToUniversalTime()) }
        }
    }
    $stamp = $null
    try { $stamp = [datetime]::ParseExact((Split-Path $ScanDir -Leaf), 'yyyy-MM-dd_HHmmss', $null) } catch { $stamp = $null }
    if ($inst -and $stamp -and $stamp -lt $inst) { return $false }
    return $true
}
function Get-WHDOtherPcScans {
    $root = Join-Path $script:WHDRoot 'inventory'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Directory -EA SilentlyContinue | Where-Object { -not (Test-WHDScanIsThisPC -ScanDir $_.FullName) } | Sort-Object Name)
}
# Update-guard files of another PC / an earlier install: state.json (when it is not this PC's) and
# guard_<stamp>.txt reports older than this Windows install.
function Test-WHDGuardStateIsThisPC {
    param($State)
    if (-not $State) { return $true }
    if ("$($State.MachineId)") { return ("$($State.MachineId)".ToLower() -eq (Get-WHDMachineId)) }
    $inst = Get-WHDWindowsInstallDate
    $lc = $null
    try { $lc = [datetime]::ParseExact("$($State.LastCheck)", 'yyyy-MM-dd HH:mm', $null) } catch { $lc = $null }
    if ($inst -and $lc -and $lc -lt $inst) { return $false }
    return $true
}
function Get-WHDOtherPcGuardFiles {
    $dir = Join-Path $script:WHDRoot 'restore\update-guard'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = New-Object System.Collections.Generic.List[object]
    $sf = Join-Path $dir 'state.json'
    if (Test-Path -LiteralPath $sf) {
        $st = $null
        try { $st = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $st = $null }
        if ($st -and -not (Test-WHDGuardStateIsThisPC -State $st)) { $out.Add((Get-Item -LiteralPath $sf)) }
    }
    $inst = Get-WHDWindowsInstallDate
    foreach ($g in @(Get-ChildItem -LiteralPath $dir -Filter 'guard_*.txt' -File -EA SilentlyContinue)) {
        $stamp = $null
        try { $stamp = [datetime]::ParseExact(($g.BaseName -replace '^guard_', ''), 'yyyy-MM-dd_HHmmss', $null) } catch { $stamp = $null }
        if ($inst -and $stamp -and $stamp -lt $inst) { $out.Add($g) }
    }
    return @($out.ToArray())
}

function Invoke-WHDArchiveOtherHistory {
    if ($script:WHDSafeMode -and [int]$script:WHDSafeAllow -le 0) { Invoke-WHDSafeAllowed { Invoke-WHDArchiveOtherHistory }; return }   # WHD Next: allowed in SAFE mode (history housekeeping, project files only)
    $root = Get-WHDRestoreRoot
    $scans  = @(Get-WHDOtherPcScans)          # WHD Next: old inventory scans
    $gfiles = @(Get-WHDOtherPcGuardFiles)     # WHD Next: old update-guard status + reports
    if (-not (Test-Path $root) -and -not $scans.Count) { Write-WHDLog 'No history yet.' 'INFO'; return }
    $all = @(Get-WHDUndoSessions -IncludeOtherPCs)
    $other = @($all | Where-Object { $_.Owner -in @('other','legacy-other') })
    $claim = @($all | Where-Object { $_.Owner -eq 'legacy-this' })
    $inst = Get-WHDWindowsInstallDate
    Write-WHDLog 'HISTORY FROM OTHER PCs / PREVIOUS WINDOWS INSTALLS' 'ACT'
    Write-WHDLog ("This PC: {0}   (Windows installed {1})" -f $env:COMPUTERNAME, $(if ($inst) { $inst.ToString('yyyy-MM-dd HH:mm') } else { 'unknown' })) 'INFO'
    Write-WHDLog ("  {0} session(s) belong to another PC or an earlier install -> move to archive\other-pcs\" -f $other.Count) 'INFO'
    foreach ($o in $other) { Write-WHDLog ("     {0}" -f $o.Label) 'INFO' }
    Write-WHDLog ("  {0} untagged session(s) from this install -> tag as this PC" -f $claim.Count) 'INFO'
    Write-WHDLog ("  {0} inventory scan(s) from another PC or an earlier install -> move to archive\other-pcs\...\inventory\" -f $scans.Count) 'INFO'
    foreach ($sc in $scans) { Write-WHDLog ("     {0}" -f $sc.Name) 'INFO' }
    Write-WHDLog ("  {0} update-guard file(s) from another PC or an earlier install -> move to archive\other-pcs\...\update-guard\" -f $gfiles.Count) 'INFO'
    foreach ($gf in $gfiles) { Write-WHDLog ("     {0}" -f $gf.Name) 'INFO' }
    if (-not $other.Count -and -not $claim.Count -and -not $scans.Count -and -not $gfiles.Count) { Write-WHDLog 'Nothing to do - all history belongs to this PC and is tagged.' 'OK'; return }
    Write-WHDRisk 'reversible' 'Nothing is deleted: folders and files are moved to archive\other-pcs\ (move them back to restore them). Verify, the update guard, the inventory compare and CAME BACK flags then only use this PC''s history.'
    if (-not (Confirm-WHDProceed 'archive other-PC history and tag this PC''s sessions')) { Write-WHDLog 'skipped.' 'WARN'; return }
    if (-not $script:WHDExecute) {
        foreach ($o in $other) { Write-WHDLog ("would: move {0} -> archive\other-pcs\" -f $o.Stamp) 'DRY' }
        foreach ($c in $claim) { Write-WHDLog ("would: tag {0} as this PC" -f $c.Stamp) 'DRY' }
        foreach ($sc in $scans)  { Write-WHDLog ("would: move inventory\{0} -> archive\other-pcs\" -f $sc.Name) 'DRY' }
        foreach ($gf in $gfiles) { Write-WHDLog ("would: move restore\update-guard\{0} -> archive\other-pcs\" -f $gf.Name) 'DRY' }
        return
    }
    $dest = Join-Path $script:WHDRoot ('archive\other-pcs\' + (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    if ($other.Count -or $scans.Count -or $gfiles.Count) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
    $moved = 0
    foreach ($o in $other) {
        try { Move-Item -LiteralPath $o.Path -Destination (Join-Path $dest $o.Stamp) -EA Stop; $moved++ }
        catch { Write-WHDLog ("could not move {0}: {1}" -f $o.Stamp, $_.Exception.Message) 'ERR' }
    }
    foreach ($c in $claim) { try { _WHDWriteSessionMachine -SessionPath $c.Path } catch { Write-WHDLog ("could not tag {0}: {1}" -f $c.Stamp, $_.Exception.Message) 'ERR' } }
    $movedScans = 0; $movedGuard = 0
    if ($scans.Count) {
        $destInv = Join-Path $dest 'inventory'
        try { New-Item -ItemType Directory -Path $destInv -Force | Out-Null } catch {}
        foreach ($sc in $scans) {
            try { Move-Item -LiteralPath $sc.FullName -Destination (Join-Path $destInv $sc.Name) -EA Stop; $movedScans++ }
            catch { Write-WHDLog ("could not move inventory\{0}: {1}" -f $sc.Name, $_.Exception.Message) 'ERR' }
        }
    }
    if ($gfiles.Count) {
        $destGuard = Join-Path $dest 'update-guard'
        try { New-Item -ItemType Directory -Path $destGuard -Force | Out-Null } catch {}
        foreach ($gf in $gfiles) {
            try { Move-Item -LiteralPath $gf.FullName -Destination (Join-Path $destGuard $gf.Name) -EA Stop; $movedGuard++ }
            catch { Write-WHDLog ("could not move update-guard\{0}: {1}" -f $gf.Name, $_.Exception.Message) 'ERR' }
        }
    }
    Write-WHDLog ("Done: {0} session(s), {1} inventory scan(s) and {2} update-guard file(s) archived to {3}; {4} session(s) tagged as this PC." -f $moved, $movedScans, $movedGuard, $dest, $claim.Count) 'OK'
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
    if (-not $res.Count) { Write-WHDLog 'No journaled changes to verify (journal starts with Phase 5; older sessions only have .reg backups).' 'INFO'; return @() }
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
        Write-WHDParts @(("  {0,3}. " -f $i), @(("[{0}] " -f $flag), $color), ("{0}  {1}" -f $e.Time, $e.Description))
    }
}

Write-WHDLog 'Common.ps1 engine loaded.' 'INFO'

