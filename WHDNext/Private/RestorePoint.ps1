#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/RestorePoint.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 System Restore through Windows' built-in CIM class (root/default:SystemRestore;
 Microsoft Learn: CreateRestorePoint with RestorePointType 12 = MODIFY_SETTINGS,
 EventType 100 = BEGIN_SYSTEM_CHANGE). Made once per session, before the first
 real change (owner, D19). Best effort: a failed restore point warns, never blocks.
#>
function ConvertTo-WHDCimValue {
    # The exact CIM type a method parameter declares on THIS Windows (uint8, uint8[], string[] ...).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'returns the type the target needs')]
    [CmdletBinding()]
    [OutputType([object])]
    param([AllowNull()]$Value, [string]$CimType)
    switch ($CimType) {
        'Boolean' { return [bool]$Value } 'UInt8' { return [byte]$Value } 'UInt16' { return [uint16]$Value } 'UInt32' { return [uint32]$Value }
        'UInt64' { return [uint64]$Value } 'SInt8' { return [sbyte]$Value } 'SInt16' { return [int16]$Value } 'SInt32' { return [int32]$Value }
        'SInt64' { return [int64]$Value } 'String' { return [string]$Value }
        'UInt8Array' { return , ([byte[]]@($Value)) } 'UInt16Array' { return , ([uint16[]]@($Value)) } 'UInt32Array' { return , ([uint32[]]@($Value)) }
        'SInt32Array' { return , ([int32[]]@($Value)) } 'SInt64Array' { return , ([int64[]]@($Value)) } 'StringArray' { return , ([string[]]@($Value)) }
        default { return $Value }
    }
}

function Invoke-WHDCimMethod {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$ClassName, [Parameter(Mandatory)][string]$Method, [hashtable]$Arguments = @{})
    $cls = Get-CimClass -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop
    $m = $cls.CimClassMethods[$Method]
    if (-not $m) { throw ('CIM method {0}.{1} does not exist on this Windows version' -f $ClassName, $Method) }
    $typed = @{}
    foreach ($k in @($Arguments.Keys)) {
        $p = $m.Parameters[$k]
        if (-not $p) { throw ('CIM method {0}.{1} has no parameter {2} on this Windows version' -f $ClassName, $Method, $k) }
        $typed[$k] = ConvertTo-WHDCimValue -Value $Arguments[$k] -CimType ([string]$p.CimType)
    }
    # Some providers (Defender's MSFT_MpSignature.Update) send progress records that are never closed, and the
    # bar would then stay on screen at every menu redraw - so progress is not shown for this call.
    $ProgressPreference = 'SilentlyContinue'
    $r = Invoke-CimMethod -Namespace $Namespace -ClassName $ClassName -MethodName $Method -Arguments $typed -ErrorAction Stop
    # A method without a return value (Defender's Update) has no ReturnValue property at all.
    $rv = if ($r -and $r.PSObject.Properties['ReturnValue']) { $r.ReturnValue } else { $null }
    if ($null -ne $rv -and [int64]$rv -ne 0) { throw ('CIM {0}.{1} returned error code {2}' -f $ClassName, $Method, $rv) }
    return $r
}

function Invoke-WHDRestorePointWindows {
    # The real one: turn System Protection on for the system drive, lift Windows' once-a-day limit, make the point.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Description)
    $drive = '{0}\' -f $env:SystemDrive
    try {
        $en = @{ Drive = $drive }
        $srm = (Get-CimClass -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop).CimClassMethods['Enable']
        if ($srm -and $srm.Parameters['WaitTillEnabled']) { $en['WaitTillEnabled'] = $true }
        [void](Invoke-WHDCimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'Enable' -Arguments $en)
    } catch { Write-WHDLog -Message ('turn on System Restore: {0}' -f $_.Exception.Message) -Level 'WARN' }
    # Same as WHD Next 2.0: Windows makes at most one restore point a day unless this value is 0.
    try {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        if (-not (Test-Path -LiteralPath $k)) { [void](New-Item -Path $k -Force -ErrorAction Stop) }
        [void](New-ItemProperty -LiteralPath $k -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force -ErrorAction Stop)
    } catch { Write-WHDLog -Message ('restore point frequency: {0}' -f $_.Exception.Message) -Level 'WARN' }
    [void](Invoke-WHDCimMethod -Namespace 'root/default' -ClassName 'SystemRestore' -Method 'CreateRestorePoint' -Arguments @{ Description = $Description; RestorePointType = [uint32]12; EventType = [uint32]100 })
}

function New-WHDRestorePoint {
    # Once per session, only when a change is about to be real.
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Again)
    $s = $script:WHDState
    if ($s.RestoreDone -and -not $Again) { return }
    if (-not $s.Execute) { return }
    if (-not $PSCmdlet.ShouldProcess('System Restore point')) { return }
    $desc = 'WHD Next {0}' -f $s.Stamp
    Write-WHDLog -Message 'Creating a System Restore point before the first change ...' -Level 'ACT'
    try {
        if ($s.RestorePoint) { & $s.RestorePoint $desc } else { Invoke-WHDRestorePointWindows -Description $desc }
        Write-WHDLog -Message ('System Restore point created: {0}' -f $desc) -Level 'OK'
    } catch {
        Write-WHDLog -Message ('restore point could not be created: {0}' -f $_.Exception.Message) -Level 'WARN'
        Write-WHDLog -Message 'Continuing - every change is still recorded in the change history and can be undone there.' -Level 'WARN'
    }
    $s.RestoreDone = $true
}
