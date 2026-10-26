#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDEngineTest.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 BUILD STEP 3 CHECK. Sends one harmless test change through the change gate:
   HKCU:\Software\WinHardenDebloatNext\EngineTest  value Step3 = 1 (DWord)
 (your own user hive; nothing else). Dry-run: only shows "would". EXECUTE:
 asks first, makes the restore point, writes the value, reads it back and
 records it in the change history - so Undo can take it out in build step 4.
 In safe mode the test change is refused (as it should be).
#>
function Invoke-WHDEngineTest {
    [CmdletBinding()]
    param()
    $path = 'HKCU:\Software\WinHardenDebloatNext\EngineTest'
    Write-WHDLog -Message ('Engine test - mode: {0}' -f (Get-WHDModeText))
    if (-not (Confirm-WHDProceed -What ('write test value {0}\Step3 = 1' -f $path))) {
        Write-WHDLog -Message 'Engine test: not confirmed - nothing changed.' -Level 'WARN'
        return (Get-WHDSession)
    }
    Set-WHDRegistryValue -Path $path -Name 'Step3' -Value 1 -Type 'DWord' | Out-Null
    $r = @(Get-WHDResult)[-1]
    Write-WHDLog -Message ('Engine test result: {0}{1}' -f $r.Status, $(if ($r.Detail) { ' - ' + $r.Detail } else { '' }))
    return (Get-WHDSession)
}
