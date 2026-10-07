<#
================================================================================
 WinHardenDebloat  -  modules\Debloat-AI.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Per-surface AI debloat. Each module offers TWO independent paths:
   * FEATURE-OFF : disable the AI behaviour via registry policy (reversible),
                   leaving the app in place. Not every surface has a supported
                   key on Home -- those are marked honestly.
   * APP-REMOVE  : remove the package for all users, then deprovision so new
                   users don't get it.
 Reinstall-blocking on Windows Home = registry keys + deprovision +
 (separately) Store/ContentDeliveryManager suppression. AppLocker/WDAC are not used.

 Requires Common.ps1 (dot-sourced first).
================================================================================
#>

# reg op shorthand: @{ P=<path>; N=<name>; V=<value>; T=<type> }
function _reg($p,$n,$v,$t='DWord') { @{ P=$p; N=$n; V=$v; T=$t } }

$script:WHDAiModules = @(
    [ordered]@{
        Key='copilot'; Name='Copilot'; Packages=@('Microsoft.Copilot')
        Risk='reversible'; CanRemove=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            _reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
            # v1.5: on current Windows 11 the Copilot app is installed and updated by Microsoft Edge Update.
            # Microsoft Learn, "Microsoft Copilot update policies for Windows": Install{app id} = 0 "installs
            # disabled", Update{app id} = 0 "updates disabled" (Edge Update 1.3.253.25 or later).
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Install{C50565E9-CCCF-44B4-BA15-5AC5C6569197}' 0
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'Update{C50565E9-CCCF-44B4-BA15-5AC5C6569197}' 0
        )
        Note='Legacy TurnOffWindowsCopilot key (Microsoft is deprecating it, but it still works on Home and needs no AppLocker): targets the app + Win+C launch. Plus the two Edge Update policies for the Copilot app (install off, update off): on current Windows 11 Copilot comes with Microsoft Edge Update, so an Edge update could bring a removed Copilot back. Microsoft documents them as Edge Update policies; on Home they are TRIED - Verify and the update guard report it if Copilot returns.'
    }
    [ordered]@{
        Key='recall'; Name='Recall'; Packages=@()
        Risk='reversible'; CanRemove=$false; OptionalFeature='Recall'
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0
        )
        Note='Policy AllowRecallEnablement=0 keeps Recall off. Turning Recall off this way also deletes existing Recall snapshots. Feature-off only: WHD does not remove the Recall optional feature itself.'
    }
    [ordered]@{
        Key='powerautomate'; Name='Power Automate'; Packages=@('Microsoft.PowerAutomateDesktop')
        Risk='reversible'; CanRemove=$true; FeatureOff=@()
        Note='No separate AI toggle - it is a standalone app. Remove-only.'
    }
    [ordered]@{
        Key='bing'; Name='Bing / web search surfaces'; Packages=@('Microsoft.BingSearch','Microsoft.BingNews','Microsoft.BingWeather')
        Risk='reversible'; CanRemove=$true
        FeatureOff=@(
            _reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
            _reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        )
        Note='Feature-off removes web/Bing results from Start search. Removing Microsoft.BingSearch can also affect Start web integration.'
    }
    [ordered]@{
        Key='webexp'; Name='Web Experience / Widgets'; Packages=@('MicrosoftWindows.Client.WebExperience')
        Risk='reversible'; CanRemove=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
            _reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
        )
        Note='Feature-off disables Widgets. The HKLM Dsh policy is best-effort (often locked on Home); TaskbarDa hides the Widgets button where Windows allows the value to be written (newer builds protect it; it then shows as skipped). Removing the package disables Widgets entirely.'
    }
    [ordered]@{
        Key='notepad'; Name='Notepad (Rewrite AI)'; Packages=@('Microsoft.WindowsNotepad')
        Risk='caution'; CanRemove=$true; FeatureOff=@()
        Note='Remove the whole Notepad app here, or keep it and use "Notepad AI (Rewrite/Summarize)" below to switch only the AI off.'
    }
    [ordered]@{
        Key='paint'; Name='Paint (Cocreator AI)'; Packages=@('Microsoft.Paint')
        Risk='caution'; CanRemove=$true; FeatureOff=@()
        Note='Remove the whole Paint app here, or keep it and use "Paint AI" below to switch only the AI tools off.'
    }
    [ordered]@{
        Key='photos'; Name='Photos (Generative erase AI)'; Packages=@('Microsoft.Windows.Photos')
        Risk='caution'; CanRemove=$true; FeatureOff=@()
        Note='No supported per-app key on Home to kill only the generative tools. Options: leave it, or remove the whole Photos app (you lose the default photo viewer).'
    }
    [ordered]@{
        Key='phonelink'; Name='Phone Link'; Packages=@('Microsoft.YourPhone')
        Risk='reversible'; CanRemove=$true; FeatureOff=@()
        Note='Not strictly AI, but flagged. Remove-only.'
    }
    # ---- Phase 7 (A1): policy switch-offs (user-selected 2026-09-23) --------
    # Documented by Microsoft as Pro/Enterprise policies (Policy CSP WindowsAI /
    # Paint); on Home they are best-effort - Verify shows whether they stick.
    [ordered]@{
        Key='clicktodo'; Name='Click to Do + Settings AI agent'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
            _reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableSettingsAgent' 1
        )
        Note='Policy CSP WindowsAI: DisableClickToDo (device+user), DisableSettingsAgent (AI search in Settings). Documented for Pro+; best-effort on Home.'
    }
    [ordered]@{
        Key='recallsnap'; Name='Recall snapshots (extra lock)'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
            _reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        )
        Note='Policy CSP WindowsAI DisableAIDataAnalysis = no Recall snapshots. A second lock next to the Recall switch, in case Recall is present or comes back.'
    }
    [ordered]@{
        Key='paintai'; Name='Paint AI (Cocreator/Image Creator/Fill)'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableCocreator' 1
            _reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableImageCreator' 1
            _reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint' 'DisableGenerativeFill' 1
        )
        Note='Policy CSP WindowsAI (Paint): keeps Paint but turns its AI tools off. If Paint is not installed, the values stay in place and apply when it is installed again.'
    }
    [ordered]@{
        Key='notepadai'; Name='Notepad AI (Rewrite/Summarize)'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\WindowsNotepad' 'DisableAIFeatures' 1
        )
        Note='Microsoft policy "DisableAIFeaturesInNotepad" (Notepad 11.2503+). Registry path taken from a widely used community tool because Microsoft''s page does not state it. If Notepad is not installed, the value stays in place and applies when it is installed again.'
    }
    [ordered]@{
        Key='edgeai'; Name='Edge: Copilot + sidebar'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'EdgeCopilotEnabled' 0
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'Microsoft365CopilotChatIconEnabled' 0
        )
        Note='Microsoft Edge policies. Edge stays installed; restart Edge to see the change (edge://policy lists what is applied).'
    }
    [ordered]@{
        Key='edgelocalai'; Name='Edge: on-device AI model + AI themes'; Packages=@()
        Risk='reversible'; CanRemove=$false; PolicyOnly=$true
        FeatureOff=@(
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'GenAILocalFoundationalModelSettings' 1
            _reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'AIGenThemesEnabled' 0
        )
        Note='GenAILocalFoundationalModelSettings=1 = Edge does not download its local AI model; AIGenThemesEnabled=0 = no AI-generated themes.'
    }
    [ordered]@{
        Key='coreai'; Name='CoreAI / AI Fabric (OS platform)'; Packages=@('MicrosoftWindows.Client.CoreAI','MicrosoftWindows.Client.AIX','Microsoft.AIFabric.CBS*')
        Risk='hard'; CanRemove=$false; FeatureOff=@()
        Note='DEEP OS AI PLATFORM in SystemApps, marked non-removable. Removing these can break Windows. No safe per-component toggle. FLAGGED FOR AWARENESS ONLY - no action offered.'
    }
)

function Get-WHDModulePresence {
    param($Module)
    $inst = $false; $prov = $false
    foreach ($pat in @($Module.Packages)) {
        if (@(Get-AppxPackage -AllUsers -Name $pat -EA SilentlyContinue).Count -gt 0) { $inst = $true }
    }
    if ($Module.OptionalFeature) {
        try {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $Module.OptionalFeature -EA Stop
            if ($f -and $f.State -eq 'Enabled') { $inst = $true }
        } catch {}
    }
    [pscustomobject]@{ Installed = $inst }
}
# Confirm-WHDProceed now lives in Common.ps1 (injected-strategy version).

function Invoke-WHDAiFeatureOff {
    param($Module)
    Write-WHDLog ("FEATURE-OFF: {0}" -f $Module.Name) 'ACT'
    Write-WHDRisk $Module.Risk $Module.Note
    if (-not @($Module.FeatureOff).Count) {
        Write-WHDLog 'No supported feature-off key for this surface (see note). Use app-remove instead.' 'WARN'
        return
    }
    if (-not (Confirm-WHDProceed ("feature-off {0}" -f $Module.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in @($Module.FeatureOff)) {
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T
    }
}

function Invoke-WHDAiRemove {
    param($Module)
    Write-WHDLog ("APP-REMOVE: {0}" -f $Module.Name) 'ACT'
    if (-not $Module.CanRemove) {
        Write-WHDLog ('This surface is not safe to remove - ' + $Module.Note) 'WARN'
        return
    }
    Write-WHDRisk $Module.Risk ("removes: {0}" -f (($Module.Packages) -join ', '))
    if (-not (Confirm-WHDProceed ("remove {0}" -f $Module.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($pat in @($Module.Packages)) {
        Remove-WHDAppxAllUsers -NameLike $pat
        Remove-WHDProvisioned  -NameLike $pat
    }
    if ($Module.OptionalFeature) {
        $jr = @{ Kind = 'feature'; Feature = $Module.OptionalFeature }
        Invoke-WHDChange -Description ("disable optional feature: {0}" -f $Module.OptionalFeature) -Force -Journal $jr -Action {
            Disable-WindowsOptionalFeature -Online -FeatureName $Module.OptionalFeature -NoRestart -EA Stop | Out-Null
        }
    }
}

# ---- global Store / ContentDeliveryManager suppression (stop silent re-adds) -
function Invoke-WHDStoreSuppression {
    Write-WHDLog 'STORE / silent-reinstall suppression (machine + current user)' 'ACT'
    Write-WHDRisk 'reversible' 'Stops Windows silently re-adding suggested/removed apps. Fully reversible.'
    if (-not (Confirm-WHDProceed 'apply Store/CDM suppression')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($n in @('SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
                     'ContentDeliveryAllowed','SubscribedContent-338388Enabled','FeatureManagementEnabled')) {
        Set-WHDRegistryValue -Path $cdm -Name $n -Value 0 -Type DWord
    }
    # DisableWindowsConsumerFeatures: documented for Pro/Ent/Edu; may be ignored on Home, set best-effort.
    Set-WHDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type DWord
    Write-WHDLog 'Note: DisableWindowsConsumerFeatures is best-effort on Home; the CDM keys above are the reliable part.' 'INFO'
}

# ---- several AI items at once: one plan list, one y/N --------------------------
# "Recommended" (the * in the menu) = every item marked reversible (green) that has an action.
# The yellow (caution) apps - Notepad, Paint, Photos - and the red OS platform item are never in it.
function Test-WHDAiRecommended {
    param($Module)
    return ("$($Module.Risk)" -eq 'reversible' -and ([bool]$Module.CanRemove -or @($Module.FeatureOff).Count -gt 0))
}
# What a batch does with one item.
#   remove: remove the app AND set its off-switch when it has one;
#           when the app cannot be removed, turn it OFF if an off-switch exists.
#   off   : set the off-switch only.
# Returns 'remove+off', 'remove', 'off' or 'none'.
function Get-WHDAiBatchPlan {
    param($Module, [ValidateSet('remove','off')][string]$Action)
    if ($Action -eq 'remove') {
        if ($Module.CanRemove -and @($Module.FeatureOff).Count) { return 'remove+off' }
        if ($Module.CanRemove) { return 'remove' }
        if (@($Module.FeatureOff).Count) { return 'off' }
        return 'none'
    }
    if (@($Module.FeatureOff).Count) { return 'off' }
    return 'none'
}
# One list with every item's own note, ONE y/N, then every step runs without further questions
# (the per-item functions are the same ones a single item uses; only their question is answered once, up front).
function Invoke-WHDAiBatch {
    param([object[]]$Modules, [ValidateSet('remove','off')][string]$Action)
    $Modules = @($Modules | Where-Object { $_ })
    if (-not $Modules.Count) { Write-WHDLog 'Nothing selected.' 'WARN'; return }
    $whdAiActText = if ($Action -eq 'remove') { 'remove + set the off-switch (turn OFF where it cannot be removed)' } else { 'feature-off' }
    Write-WHDLog ("AI DEBLOAT - {0} selected item(s), action: {1}" -f $Modules.Count, $whdAiActText) 'ACT'
    $whdAiPlan = @(foreach ($whdAiM in $Modules) { [pscustomobject]@{ Module = $whdAiM; Step = (Get-WHDAiBatchPlan -Module $whdAiM -Action $Action) } })
    foreach ($whdAiP in $whdAiPlan) {
        $whdAiPk = (@($whdAiP.Module.Packages) -join ', ')
        $whdAiTxt = switch ($whdAiP.Step) {
            'remove+off' { "remove the app ($whdAiPk) + set its off-switch" }
            'remove'     { "remove the app ($whdAiPk) - it has no off-switch" }
            'off'        { if ($Action -eq 'remove') { 'turn OFF (cannot be removed)' } else { 'turn OFF' } }
            default      { if ($Action -eq 'remove') { 'skip - no action is offered for this item' } else { 'skip - this item has no off-switch' } }
        }
        Write-WHDLog ("   {0,-40} -> {1}" -f $whdAiP.Module.Name, $whdAiTxt) 'INFO'
        Write-WHDRisk $whdAiP.Module.Risk $whdAiP.Module.Note
    }
    $whdAiTodo = @($whdAiPlan | Where-Object { $_.Step -ne 'none' })
    if (-not $whdAiTodo.Count) { Write-WHDLog 'Nothing to do for this selection.' 'WARN'; return }
    $whdAiTier = 'reversible'
    if (@($whdAiTodo | Where-Object { "$($_.Module.Risk)" -ne 'reversible' }).Count) { $whdAiTier = 'caution' }
    if (@($whdAiTodo | Where-Object { "$($_.Step)" -like 'remove*' }).Count) {
        Write-WHDRisk $whdAiTier 'Apps are removed for ALL users of the PC and their local data is deleted (undo = reinstall from the Store). Off-switches are registry values (Undo center puts the old values back).'
    } else {
        Write-WHDRisk $whdAiTier 'No app is removed. Off-switches are registry values (Undo center puts the old values back).'
    }
    if (-not (Confirm-WHDProceed ("apply the {0} item(s) listed above" -f $whdAiTodo.Count))) { Write-WHDLog 'skipped.' 'WARN'; return }
    $whdAiF0 = [int]$script:WHDCounts['failed']; $whdAiS0 = [int]$script:WHDCounts['skipped']
    $whdAiPrevC = $script:WHDConfirm; $script:WHDConfirm = { param($m) $true }
    try {
        foreach ($whdAiP in $whdAiTodo) {
            switch ($whdAiP.Step) {
                'remove+off' { Invoke-WHDAiRemove -Module $whdAiP.Module | Out-Null; Invoke-WHDAiFeatureOff -Module $whdAiP.Module | Out-Null }
                'remove'     { Invoke-WHDAiRemove -Module $whdAiP.Module | Out-Null }
                default      { Invoke-WHDAiFeatureOff -Module $whdAiP.Module | Out-Null }
            }
        }
    } finally { $script:WHDConfirm = $whdAiPrevC }
    $whdAiBad = ([int]$script:WHDCounts['failed'] - $whdAiF0) + ([int]$script:WHDCounts['skipped'] - $whdAiS0)
    if ($script:WHDExecute -and $whdAiBad -gt 0) { Write-WHDLog ("AI DEBLOAT - batch finished ({0} item(s)), but {1} step(s) FAILED or were blocked - see the lines above." -f $whdAiTodo.Count, $whdAiBad) 'WARN' }
    elseif ($script:WHDExecute) { Write-WHDLog ("AI DEBLOAT - batch finished ({0} item(s))." -f $whdAiTodo.Count) 'OK' }
    else                    { Write-WHDLog ("AI DEBLOAT - dry-run only: {0} item(s) previewed, nothing was changed." -f $whdAiTodo.Count) 'DRY' }
}

function Show-WHDAiMenu {
    Write-Host ''
    Write-Host '  AI SURFACES' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    $i = 0
    foreach ($m in $script:WHDAiModules) {
        $i++
        if ($m.PolicyOnly) {
            $ps = Get-WHDRegOpsState -Ops @($m.FeatureOff)
            $state = switch ($ps) { 'set' { 'OFF(set)' } 'partly' { 'partly ' } default { 'on     ' } }
        } else {
            $p = Get-WHDModulePresence -Module $m
            $state = if ($p.Installed) { 'present' } else { 'absent ' }
        }
        $fo = if (@($m.FeatureOff).Count) { 'feature-off' } else { '   --     ' }
        $rm = if ($m.CanRemove) { 'remove' } else { ' --   ' }
        $color = switch ($m.Risk) { 'reversible' {'Green'} 'caution' {'Yellow'} 'hard' {'Red'} }
        $rec = if (Test-WHDAiRecommended -Module $m) { '*' } else { ' ' }
        Write-Host ("  {0,2}.{1} " -f $i, $rec) -NoNewline
        Write-Host ("{0,-32}" -f $m.Name) -NoNewline -ForegroundColor $color
        Write-Host ("  [{0}]  {1}  {2}" -f $state, $fo, $rm)
    }
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '   * = recommended (green = reversible, and the item has an action)'
    Write-Host '   One item   : its number, then f or r when asked (same meaning as below)'
    Write-Host '   Several    : numbers + action, e.g.  1,3,5 r    2-6 f    * r    *,7 r     (one y/N for the whole list)'
    Write-Host '                r = remove the app AND set its off-switch (an item that cannot be removed is turned OFF)'
    Write-Host '                f = feature-off only (the app stays)'
    Write-Host '   Policy switches show on / partly / OFF(set). Documented for Pro+, best-effort on Home.' -ForegroundColor DarkGray
    Write-Host '   S. Store / silent-reinstall suppression (global)'
    Write-Host '   B. Back'
}
