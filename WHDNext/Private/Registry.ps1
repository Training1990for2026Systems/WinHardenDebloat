#requires -Version 7.6
<#
 WHD Next 3.0  -  Private/Registry.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Registry changes through the gate: the old state is captured for the change
 history (Undo puts it back exactly) and every write is read back - a write
 that Windows silently ignored (policy lock) counts as failed.
#>
function Get-WHDRegValueState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $st = [pscustomobject]@{ KeyExists = $false; Exists = $false; Value = $null; Type = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $st }
    $k = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $k) { return $st }
    $st.KeyExists = $true
    if (@($k.GetValueNames()) -contains $Name) {
        $st.Exists = $true
        $st.Value = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $st.Type = [string]$k.GetValueKind($Name)
    }
    return $st
}

function Test-WHDRegValueEqual {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$A, [AllowNull()]$B, [string]$Type)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    switch ($Type) {
        'DWord'       { return (([int64]$A -band 0xFFFFFFFFL) -eq ([int64]$B -band 0xFFFFFFFFL)) }
        'QWord'       { return ([int64]$A -eq [int64]$B) }
        'MultiString' { return ((@($A) -join "`n") -eq (@($B) -join "`n")) }
        'Binary'      { return ((@($A) -join ',') -eq (@($B) -join ',')) }
        default       { return ([string]$A -eq [string]$B) }
    }
}

function Set-WHDRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord', 'MultiString', 'Binary')][string]$Type = 'DWord'
    )
    $before = Get-WHDRegValueState -Path $Path -Name $Name
    $jr = @{ Kind = 'reg'; Path = $Path; Name = $Name
             OldKeyExists = [bool]$before.KeyExists; OldExists = [bool]$before.Exists; OldValue = $before.Value; OldType = $before.Type
             NewExists = $true; NewValue = $Value; NewType = $Type }
    $desc = 'reg set {0}\{1} = {2} ({3})' -f $Path, $Name, $Value, $Type
    if (-not $PSCmdlet.ShouldProcess($desc)) { return }
    Invoke-WHDChange -Description $desc -Journal $jr -Action {
        Backup-WHDRegistryKey -Path $Path
        if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force -ErrorAction Stop) }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        $after = Get-WHDRegValueState -Path $Path -Name $Name
        if (-not $after.Exists -or -not (Test-WHDRegValueEqual -A $after.Value -B $Value -Type $Type)) {
            throw ('read-back mismatch: wanted {0}, found {1}' -f $Value, $(if ($after.Exists) { $after.Value } else { '(missing)' }))
        }
    }
}

function Remove-WHDRegistryValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $before = Get-WHDRegValueState -Path $Path -Name $Name
    if (-not $before.Exists) { Write-WHDLog -Message ('reg value already absent: {0}\{1}' -f $Path, $Name); return }
    $jr = @{ Kind = 'reg'; Path = $Path; Name = $Name
             OldKeyExists = $true; OldExists = $true; OldValue = $before.Value; OldType = $before.Type
             NewExists = $false; NewValue = $null; NewType = $null }
    $desc = 'reg delete {0}\{1}' -f $Path, $Name
    if (-not $PSCmdlet.ShouldProcess($desc)) { return }
    Invoke-WHDChange -Description $desc -Journal $jr -Action {
        Backup-WHDRegistryKey -Path $Path
        Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ((Get-WHDRegValueState -Path $Path -Name $Name).Exists) { throw 'read-back mismatch: value still present' }
    }
}

function Backup-WHDRegistryKey {
    # Same as WHD Next 2.0: an existing key is exported to restore\<session>\ before it is changed
    # (a key about to be created has nothing to back up). Only when the change is real.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-WHDRealChange)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $folder = Get-WHDRestoreFolder
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop) }
        $regPath = $Path -replace '^HKLM:\\', 'HKLM\' -replace '^HKCU:\\', 'HKCU\'
        $out = Join-Path $folder (($Path -replace '[:\\]', '_') + '.reg')
        & reg.exe export $regPath $out /y 2>$null 1>$null
    } catch { Write-WHDLog -Message ('registry backup skipped: {0}' -f $_.Exception.Message) -Level 'WARN' }
}
