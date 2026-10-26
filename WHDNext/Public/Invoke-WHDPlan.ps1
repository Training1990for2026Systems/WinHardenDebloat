#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDPlan.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 WHD.ps1 -Plan (build step 6a, D81): the full dry-run of everything, as WHD
 Next 2.0 - AI, General, privacy, app permissions (Balanced as the example),
 component store, the firewall state. EXECUTE is off for the whole plan and
 put back after; nothing is asked and nothing changes. All of it goes to the
 log in logs\.
#>
function Invoke-WHDPlan {
    # Always a preview: EXECUTE is off for the whole plan and put back after. Nothing is asked, nothing changes.
    [CmdletBinding()]
    param()
    $st = $script:WHDState
    $wasExec = $st.Execute
    $prevConfirm = $st.Confirm
    $st.Execute = $false
    $st.Confirm = { param($What) [void]$What; $true }
    try {
        Write-WHDLog -Message '================ FULL DRY-RUN PLAN (no changes) ================' -Level 'DRY'
        Invoke-WHDPlanStep -Title 'AI - remove + off-switch, every surface' -Do { Invoke-WHDAiBatch -Modules @($script:WHDAiModules) -Action remove }
        Invoke-WHDPlanStep -Title 'AI - Store / silent reinstall suppression' -Do { Invoke-WHDStoreSuppression }
        Invoke-WHDPlanStep -Title 'General - non-AI Store apps' -Do { Invoke-WHDGeneralBatch -Entries @(Get-WHDGeneralCatalog) }
        Invoke-WHDPlanStep -Title 'General - privacy hardening' -Do { Invoke-WHDPrivacyHardening }
        Invoke-WHDPlanStep -Title 'General - telemetry service (DiagTrack)' -Do { Disable-WHDDiagTrack }
        Invoke-WHDPlanStep -Title 'More privacy settings - all' -Do { Invoke-WHDPrivacyBatch -Items @($script:WHDPrivacyItems) }
        Invoke-WHDPlanStep -Title 'App permissions - Balanced (shown as an example)' -Do { Invoke-WHDPermissionProfile -ProfileName 'Balanced' }
        Invoke-WHDPlanStep -Title 'Component store - analysis (read-only) and cleanup (plan)' -Do { Invoke-WHDComponentAnalyze; Invoke-WHDComponentCleanup }
        Invoke-WHDPlanStep -Title 'Firewall - the state now (read-only)' -Do { Show-WHDFirewallSummary }
        Write-WHDLog -Message '================ END OF PLAN ================' -Level 'DRY'
    } finally {
        $st.Execute = $wasExec
        $st.Confirm = $prevConfirm
    }
}
