# WHD Next 3.0 - module manifest
#  Author : Training1990for2026Systems   Contact: t90018273@gmail.com
#  License: MIT (see LICENSE)            Built with Claude by Anthropic
# Runs only on PowerShell 7.6 or a newer stable version (Core edition).
@{
    RootModule           = 'WHDNext.psm1'
    ModuleVersion        = '3.0.0'
    GUID                 = '7e68057d-eb00-437d-98ab-d39eb3febb29'
    Author               = 'Training1990for2026Systems'
    CompanyName          = 'Training1990for2026Systems'
    Copyright            = '(c) 2026 Training1990for2026Systems. MIT License.'
    Description          = 'WHD Next - Windows hardening and debloat, PowerShell 7.6 edition. Built with Claude by Anthropic.'
    PowerShellVersion    = '7.6'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Get-WHDEngineInfo', 'Get-WHDHistory', 'Get-WHDResult', 'Get-WHDSession', 'Get-WHDUndoList', 'Initialize-WHDSession', 'Invoke-WHDEngineTest', 'Invoke-WHDGuardRun', 'Invoke-WHDHistoryTakeover', 'Invoke-WHDMenu', 'Invoke-WHDPlan', 'Invoke-WHDProfileRun', 'Invoke-WHDUndo', 'Invoke-WHDVerify', 'New-WHDCheckpoint', 'Restore-WHDSessionBackup', 'Set-WHDMode', 'Show-WHDWindow', 'Update-WHDGuardRefresh')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            # release 3.0.0 (D99) - no prerelease label
        }
    }
}
