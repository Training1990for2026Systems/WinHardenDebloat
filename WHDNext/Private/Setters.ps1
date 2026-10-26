#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Setters.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Journaled, read-back-checked changes of every kind WHD Next 2.0 records
 (services, audit policy, event logs, Defender, attack-surface rules, time
 zone, password policy, files, firewall log / rules, devices, scheduled tasks,
 deprovisioned marks, optional features). The Undo center uses them now; the
 feature modules (step 5) use the same ones. Each goes through the change gate.
 Note: local variables here never use the gate's own names ($Description,
 $Action, $Journal, $s, $msg) - the change block sees the caller's variables.
#>
function Set-WHDServiceStartType {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Service, [Parameter(Mandatory)][ValidateSet('Automatic', 'AutomaticDelayedStart', 'Manual', 'Disabled')][string]$StartType)
    $svcObj = Get-Service -Name $Service -ErrorAction SilentlyContinue
    if (-not $svcObj) { Write-WHDLog -Message ('service not found: {0}' -f $Service) -Level 'WARN'; return (Add-WHDResult -Action ('service {0}' -f $Service) -Status 'skipped' -Detail 'service not found') }
    $svcOld = [string]$svcObj.StartType; $svcName = $Service; $svcNew = $StartType
    if (-not $PSCmdlet.ShouldProcess($Service, 'start type')) { return }
    Invoke-WHDChange -Description ('service {0}: start type {1} -> {2}' -f $svcName, $svcOld, $svcNew) -Journal @{ Kind = 'service'; Service = $svcName; OldStartType = $svcOld; NewStartType = $svcNew } -Action {
        Set-Service -Name $svcName -StartupType $svcNew -ErrorAction Stop
        $svcNow = [string](Get-Service -Name $svcName -ErrorAction Stop).StartType
        if ($svcNow -ne $svcNew) { throw ('read-back mismatch: start type is {0}' -f $svcNow) }
    }
}

function Set-WHDAuditSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Guid, [string]$Name = $Guid, [bool]$Success, [bool]$Failure)
    $auOld = Get-WHDAuditSetting -Guid $Guid
    $auGuid = $Guid; $auS = if ($Success) { 'enable' } else { 'disable' }; $auF = if ($Failure) { 'enable' } else { 'disable' }; $auWantS = $Success; $auWantF = $Failure
    $jr = @{ Kind = 'auditpol'; Guid = $Guid; Subcategory = $Name
             OldSuccess = $(if ($auOld) { [bool]$auOld.Success } else { $false }); OldFailure = $(if ($auOld) { [bool]$auOld.Failure } else { $false })
             NewSuccess = $Success; NewFailure = $Failure }
    if (-not $PSCmdlet.ShouldProcess($Name, 'audit policy')) { return }
    Invoke-WHDChange -Description ('audit policy {0}: success={1} failure={2}' -f $Name, $auS, $auF) -Journal $jr -Action {
        $r = Invoke-WHDNative -Exe 'auditpol.exe' -ArgList @('/set', ('/subcategory:{0}' -f $auGuid), ('/success:{0}' -f $auS), ('/failure:{0}' -f $auF))
        if ($r.Code -ne 0) { throw ('auditpol exit {0}: {1}' -f $r.Code, ($r.Out -join ' ')) }
        $auNow = Get-WHDAuditSetting -Guid $auGuid
        if (-not $auNow -or $auNow.Success -ne $auWantS -or $auNow.Failure -ne $auWantF) { throw 'read-back mismatch: audit setting did not stick' }
    }
}

function Set-WHDEventLogConfig {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$LogName, [Parameter(Mandatory)][int64]$MaxBytes, [ValidateSet('Circular', 'AutoBackup', 'Retain')][string]$Mode = 'Circular')
    $elOld = Get-WHDEventLogConfig -LogName $LogName
    $elName = $LogName; $elMax = $MaxBytes; $elMode = $Mode
    $jr = @{ Kind = 'eventlog'; LogName = $LogName; OldMaxBytes = $(if ($elOld) { $elOld.MaxBytes } else { 20971520 }); OldMode = $(if ($elOld) { $elOld.Mode } else { 'Circular' }); NewMaxBytes = $MaxBytes; NewMode = $Mode }
    if (-not $PSCmdlet.ShouldProcess($LogName, 'event log size')) { return }
    Invoke-WHDChange -Description ('event log {0}: max {1:N0} MB, mode {2}' -f $LogName, ($MaxBytes / 1MB), $Mode) -Journal $jr -Action {
        $c = Get-WinEvent -ListLog $elName -ErrorAction Stop
        $c.MaximumSizeInBytes = $elMax
        $c.LogMode = [System.Diagnostics.Eventing.Reader.EventLogMode]$elMode
        $c.SaveChanges()
        $elNow = Get-WHDEventLogConfig -LogName $elName
        if (-not $elNow -or $elNow.MaxBytes -ne $elMax -or $elNow.Mode -ne $elMode) { throw 'read-back mismatch: event log settings did not stick' }
    }
}

function Set-WHDMpPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Setting, [Parameter(Mandatory)][int]$Value)
    $mpOld = $null
    try { $mpOld = [int](Get-WHDMpPreference).$Setting } catch { $mpOld = $null }
    if ($null -ne $mpOld -and $mpOld -eq $Value) { Write-WHDLog -Message ('{0} already {1}.' -f $Setting, $Value); return }
    $mpSet = $Setting; $mpVal = $Value
    if (-not $PSCmdlet.ShouldProcess($Setting, 'Defender setting')) { return }
    Invoke-WHDChange -Description ('Defender {0}: {1} -> {2}' -f $Setting, $mpOld, $Value) -Journal @{ Kind = 'mppref'; Setting = $Setting; OldValue = $mpOld; NewValue = $Value } -Action {
        [void](Invoke-WHDCimMethod -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpPreference' -Method 'Set' -Arguments @{ $mpSet = $mpVal })
        $mpNow = [int](Get-WHDMpPreference).$mpSet
        if ($mpNow -ne $mpVal) { throw ('read-back mismatch: {0} is {1} (Tamper Protection or policy may block it)' -f $mpSet, $mpNow) }
    }
}

function Set-WHDAsrRule {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][ValidateSet(0, 1, 2, 6)][int]$Code, [string]$Name = $Id)
    $asrMap = Get-WHDAsrCode
    $asrId = $Id.ToLowerInvariant(); $asrNew = $Code
    $asrOld = if ($asrMap.ContainsKey($asrId)) { $asrMap[$asrId] } else { 0 }
    if ($asrOld -eq $asrNew) { Write-WHDLog -Message ('ASR already {0}: {1}' -f (Get-WHDAsrName -Code $asrNew), $Name); return }
    if (-not $PSCmdlet.ShouldProcess($Name, 'attack-surface rule')) { return }
    Invoke-WHDChange -Description ('ASR {0} -> {1}: {2}' -f (Get-WHDAsrName -Code $asrOld), (Get-WHDAsrName -Code $asrNew), $Name) -Journal @{ Kind = 'asr'; RuleId = $Id; RuleName = $Name; OldAction = $asrOld; NewAction = $asrNew } -Action {
        [void](Invoke-WHDCimMethod -Namespace $script:WHDDefenderNs -ClassName 'MSFT_MpPreference' -Method 'Add' -Arguments @{ AttackSurfaceReductionRules_Ids = [string[]]@($asrId); AttackSurfaceReductionRules_Actions = [byte[]]@($asrNew) })
        $asrNowMap = Get-WHDAsrCode
        $asrNow = if ($asrNowMap.ContainsKey($asrId)) { $asrNowMap[$asrId] } else { 0 }
        if ($asrNow -ne $asrNew) { throw ('read-back mismatch: rule is {0}' -f (Get-WHDAsrName -Code $asrNow)) }
    }
}

function Set-WHDTimeZoneId {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Id)
    $tzOld = [string](Get-TimeZone -ErrorAction SilentlyContinue).Id
    if ($tzOld -eq $Id) { Write-WHDLog -Message ('time zone already {0}' -f $Id) -Level 'OK'; return }
    $tzNew = $Id
    if (-not $PSCmdlet.ShouldProcess($Id, 'time zone')) { return }
    Invoke-WHDChange -Description ('time zone: {0} -> {1}' -f $tzOld, $tzNew) -Journal @{ Kind = 'tz'; OldId = $tzOld; NewId = $tzNew } -Action {
        Set-TimeZone -Id $tzNew -ErrorAction Stop
        $tzNow = [string](Get-TimeZone).Id
        if ($tzNow -ne $tzNew) { throw ('read-back mismatch: time zone is {0}' -f $tzNow) }
    }
}

function Set-WHDPasswordSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidateSet('MinLen', 'History', 'MaxAge', 'Threshold', 'Duration', 'Window')][string]$Setting, [Parameter(Mandatory)][int]$Value)
    $pwCur = Get-WHDPasswordPolicy
    $pwOld = if ($pwCur) { [int]$pwCur[$Setting] } else { $null }
    $pwSet = $Setting; $pwVal = $Value
    $pwArg = switch ($pwSet) {
        'MinLen' { '/minpwlen:{0}' -f $pwVal } 'History' { '/uniquepw:{0}' -f $pwVal }
        'MaxAge' { if ($pwVal -eq 0) { '/maxpwage:unlimited' } else { '/maxpwage:{0}' -f $pwVal } }
        'Threshold' { '/lockoutthreshold:{0}' -f $pwVal } 'Duration' { '/lockoutduration:{0}' -f $pwVal } 'Window' { '/lockoutwindow:{0}' -f $pwVal }
    }
    if (-not $PSCmdlet.ShouldProcess($Setting, 'password policy')) { return }
    Invoke-WHDChange -Description ('password policy {0}: {1} -> {2}' -f $Setting, $(if ($null -eq $pwOld) { '?' } else { $pwOld }), $Value) -Journal @{ Kind = 'netacct'; Setting = $pwSet; OldValue = $pwOld; NewValue = $pwVal } -Action {
        $r = Invoke-WHDNative -Exe 'net.exe' -ArgList @('accounts', $pwArg)
        if ($r.Code -ne 0) { throw ('net accounts exit {0}: {1}' -f $r.Code, (($r.Out | Where-Object { $_ }) -join ' ')) }
        $pwNow = Get-WHDPasswordPolicy
        if (-not $pwNow -or [int]$pwNow[$pwSet] -ne $pwVal) { throw 'read-back mismatch: password setting did not stick' }
    }
}

function Restore-WHDFileFromBackup {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Backup)
    $fbPath = $Path; $fbBackup = $Backup
    $fbNewBak = Join-Path (Get-WHDRestoreFolder) ('{0}.before-undo.{1}' -f (Split-Path $Path -Leaf), (Get-Date -Format 'HHmmss'))
    $fbHash = if (Test-Path -LiteralPath $Backup) { (Get-FileHash -LiteralPath $Backup -Algorithm SHA256).Hash } else { '' }
    if (-not $PSCmdlet.ShouldProcess($Path, 'restore file')) { return }
    Invoke-WHDChange -Description ('restore {0} from {1}' -f $Path, $Backup) -Journal @{ Kind = 'file'; Path = $Path; Backup = $fbNewBak; NewHash = $fbHash } -Action {
        $fbDir = Split-Path $fbNewBak -Parent
        if (-not (Test-Path -LiteralPath $fbDir)) { [void](New-Item -ItemType Directory -Path $fbDir -Force) }
        if (Test-Path -LiteralPath $fbPath) { Copy-Item -LiteralPath $fbPath -Destination $fbNewBak -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $fbBackup -Destination $fbPath -Force -ErrorAction Stop
    }
}

function Set-WHDFirewallLog {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$FwProfile, [Parameter(Mandatory)][string]$Allowed, [Parameter(Mandatory)][string]$Blocked, [Parameter(Mandatory)][int64]$SizeKB)
    $flCur = @(Get-NetFirewallProfile -Name $FwProfile -ErrorAction Stop)[0]
    $flP = $FwProfile; $flA = $Allowed; $flB = $Blocked; $flS = $SizeKB
    $jr = @{ Kind = 'fwlog'; Profile = $flP; OldAllowed = [string]$flCur.LogAllowed; OldBlocked = [string]$flCur.LogBlocked; OldSizeKB = [int64]$flCur.LogMaxSizeKilobytes
             NewAllowed = $flA; NewBlocked = $flB; NewSizeKB = $flS }
    if (-not $PSCmdlet.ShouldProcess($FwProfile, 'firewall log')) { return }
    Invoke-WHDChange -Description ('firewall log ({0}): allowed={1} blocked={2} size={3} KB' -f $flP, $flA, $flB, $flS) -Journal $jr -Action {
        Set-NetFirewallProfile -Name $flP -LogAllowed $flA -LogBlocked $flB -LogMaxSizeKilobytes $flS -ErrorAction Stop
    }
}

function Remove-WHDFirewallRule {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RuleName)
    $fwName = $RuleName
    if (-not $PSCmdlet.ShouldProcess($RuleName, 'remove firewall rule')) { return }
    Invoke-WHDChange -Description ('remove firewall rule {0}' -f $RuleName) -Action {
        $fwR = @(Get-NetFirewallRule -Name $fwName -ErrorAction SilentlyContinue)
        if ($fwR) { $fwR | Remove-NetFirewallRule -ErrorAction Stop }
    }
}

function Set-WHDPnpDeviceEnabled {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$InstanceId, [string]$Name = $InstanceId, [Parameter(Mandatory)][bool]$Enabled, [bool]$WasEnabled = -not $Enabled)
    $pdId = $InstanceId; $pdOn = $Enabled
    if (-not $PSCmdlet.ShouldProcess($Name, 'device')) { return }
    Invoke-WHDChange -Description ('device {0} -> {1}' -f $Name, $(if ($pdOn) { 'enabled' } else { 'disabled' })) -Journal @{ Kind = 'pnpdev'; InstanceId = $pdId; Name = $Name; OldEnabled = $WasEnabled; NewEnabled = $pdOn } -Action {
        if ($pdOn) { Enable-PnpDevice -InstanceId $pdId -Confirm:$false -ErrorAction Stop } else { Disable-PnpDevice -InstanceId $pdId -Confirm:$false -ErrorAction Stop }
    }
}

function Set-WHDScheduledTaskEnabled {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][bool]$Enabled, [bool]$WasEnabled = -not $Enabled)
    $tkP = $TaskPath; $tkN = $TaskName; $tkOn = $Enabled
    if (-not $PSCmdlet.ShouldProcess(('{0}{1}' -f $TaskPath, $TaskName), 'scheduled task')) { return }
    Invoke-WHDChange -Description ('scheduled task {0}{1} -> {2}' -f $tkP, $tkN, $(if ($tkOn) { 'enabled' } else { 'disabled' })) -Journal @{ Kind = 'task'; TaskPath = $tkP; TaskName = $tkN; OldEnabled = $WasEnabled; NewEnabled = $tkOn } -Action {
        if ($tkOn) { [void](Enable-ScheduledTask -TaskPath $tkP -TaskName $tkN -ErrorAction Stop) } else { [void](Disable-ScheduledTask -TaskPath $tkP -TaskName $tkN -ErrorAction Stop) }
    }
}

function Remove-WHDDeprovisionMark {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Pfn)
    $dpKey = Join-Path $script:WHDDeprovKey $Pfn
    if (-not $PSCmdlet.ShouldProcess($Pfn, 'remove Deprovisioned mark')) { return }
    Invoke-WHDChange -Description ('remove Deprovisioned mark: {0}' -f $Pfn) -Action {
        if (Test-Path -LiteralPath $dpKey) { Remove-Item -LiteralPath $dpKey -Recurse -Force -ErrorAction Stop }
    }
}

function Enable-WHDOptionalFeature {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Feature)
    $ofName = $Feature
    if (-not $PSCmdlet.ShouldProcess($Feature, 'enable optional feature')) { return }
    Invoke-WHDChange -Description ('re-enable optional feature: {0}' -f $Feature) -Journal @{ Kind = 'action'; Feature = $Feature } -Action {
        [void](Enable-WindowsOptionalFeature -Online -FeatureName $ofName -NoRestart -ErrorAction Stop)
    }
}
