#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/DebloatAI.ps1   (AI surfaces)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features and values as WHD Next 2.0 (D8), rewritten for PowerShell 7.6.
 Build step 5.4a (D30). Every AI surface offers up to two independent paths:
   FEATURE-OFF : registry values that switch the AI behaviour off (the app stays)
   APP-REMOVE  : remove the app for all users + its staged copy + the
                 Deprovisioned mark (Private\Appx.ps1)
 Several at once: "1,3,5 r", "2-6 f", "* r" (* = recommended = every green item
 that has an action). r = remove the app AND set its off-switch (an item that
 cannot be removed is turned off); f = feature-off only. One question for the
 whole list. SS = Store / silent-reinstall suppression (D31; was S in 2.0).
 Policy values are documented by Microsoft for Pro+; on Home they are tried -
 Verify shows whether they stay. No AppLocker / WDAC.
================================================================================
#>

$script:WHDAiModules = @(
    [ordered]@{ Key = 'copilot'; Name = 'Copilot'; Packages = @('Microsoft.Copilot'); Risk = 'reversible'; CanRemove = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1; T = 'DWord' }, @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; N = 'TurnOffWindowsCopilot'; V = 1; T = 'DWord' })
        Note = 'TurnOffWindowsCopilot (Microsoft is phasing it out, but it still works on Home without AppLocker). Covers the app and Win+C.' }
    [ordered]@{ Key = 'recall'; Name = 'Recall'; Packages = @(); Risk = 'reversible'; CanRemove = $false; OptionalFeature = 'Recall'
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'AllowRecallEnablement'; V = 0; T = 'DWord' })
        Note = 'On some PCs Recall is already off with its files removed (DisabledWithPayloadRemoved). The value is set anyway to keep it off.' }
    [ordered]@{ Key = 'powerautomate'; Name = 'Power Automate'; Packages = @('Microsoft.PowerAutomateDesktop'); Risk = 'reversible'; CanRemove = $true; FeatureOff = @()
        Note = 'A separate app with no AI switch - remove only.' }
    [ordered]@{ Key = 'bing'; Name = 'Bing / web search surfaces'; Packages = @('Microsoft.BingSearch', 'Microsoft.BingNews', 'Microsoft.BingWeather'); Risk = 'reversible'; CanRemove = $true
        FeatureOff = @(@{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; N = 'BingSearchEnabled'; V = 0; T = 'DWord' }, @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; N = 'DisableSearchBoxSuggestions'; V = 1; T = 'DWord' })
        Note = 'Feature-off takes web / Bing results out of Start search. Removing Microsoft.BingSearch can also affect Start web integration.' }
    [ordered]@{ Key = 'webexp'; Name = 'Web Experience / Widgets'; Packages = @('MicrosoftWindows.Client.WebExperience'); Risk = 'reversible'; CanRemove = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; N = 'AllowNewsAndInterests'; V = 0; T = 'DWord' }, @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'TaskbarDa'; V = 0; T = 'DWord' })
        Note = 'Feature-off disables Widgets: the Dsh policy is best-effort on Home (often locked); TaskbarDa reliably hides the button for this user. Removing the package disables Widgets fully.' }
    [ordered]@{ Key = 'notepad'; Name = 'Notepad (Rewrite AI)'; Packages = @('Microsoft.WindowsNotepad'); Risk = 'caution'; CanRemove = $true; FeatureOff = @()
        Note = 'Removes the whole Notepad app - or keep it and use "Notepad AI (Rewrite/Summarize)" below to switch only the AI off.' }
    [ordered]@{ Key = 'paint'; Name = 'Paint (Cocreator AI)'; Packages = @('Microsoft.Paint'); Risk = 'caution'; CanRemove = $true; FeatureOff = @()
        Note = 'Removes the whole Paint app - or keep it and use "Paint AI" below to switch only the AI tools off.' }
    [ordered]@{ Key = 'photos'; Name = 'Photos (Generative erase AI)'; Packages = @('Microsoft.Windows.Photos'); Risk = 'caution'; CanRemove = $true; FeatureOff = @()
        Note = 'No supported key on Home to switch off only the generative tools. Leave it, or remove the whole app (the default photo viewer goes with it).' }
    [ordered]@{ Key = 'phonelink'; Name = 'Phone Link'; Packages = @('Microsoft.YourPhone'); Risk = 'reversible'; CanRemove = $true; FeatureOff = @()
        Note = 'Not strictly AI, but listed. Remove only.' }
    [ordered]@{ Key = 'clicktodo'; Name = 'Click to Do + Settings AI agent'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableClickToDo'; V = 1; T = 'DWord' }, @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableClickToDo'; V = 1; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableSettingsAgent'; V = 1; T = 'DWord' })
        Note = 'Policy CSP WindowsAI: DisableClickToDo (device + user), DisableSettingsAgent (AI search in Settings). Documented for Pro+; best-effort on Home.' }
    [ordered]@{ Key = 'recallsnap'; Name = 'Recall snapshots (extra lock)'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1; T = 'DWord' }, @{ P = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; N = 'DisableAIDataAnalysis'; V = 1; T = 'DWord' })
        Note = 'Policy CSP WindowsAI DisableAIDataAnalysis = no Recall snapshots. A second lock next to the Recall switch.' }
    [ordered]@{ Key = 'paintai'; Name = 'Paint AI (Cocreator/Image Creator/Fill)'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; N = 'DisableCocreator'; V = 1; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; N = 'DisableImageCreator'; V = 1; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; N = 'DisableGenerativeFill'; V = 1; T = 'DWord' })
        Note = 'Keeps Paint, switches its AI tools off. Without Paint installed the values stay and apply when it comes back.' }
    [ordered]@{ Key = 'notepadai'; Name = 'Notepad AI (Rewrite/Summarize)'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\WindowsNotepad'; N = 'DisableAIFeatures'; V = 1; T = 'DWord' })
        Note = 'Microsoft policy "DisableAIFeaturesInNotepad" (Notepad 11.2503+); the registry location is the one WHD Next 2.0 used (Microsoft''s page does not name it). Without Notepad installed the value stays and applies when it comes back.' }
    [ordered]@{ Key = 'edgeai'; Name = 'Edge: Copilot + sidebar'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'EdgeCopilotEnabled'; V = 0; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'HubsSidebarEnabled'; V = 0; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'Microsoft365CopilotChatIconEnabled'; V = 0; T = 'DWord' })
        Note = 'Microsoft Edge policies. Edge stays; restart it to see the change (edge://policy lists what is applied).' }
    [ordered]@{ Key = 'edgelocalai'; Name = 'Edge: on-device AI model + AI themes'; Packages = @(); Risk = 'reversible'; CanRemove = $false; PolicyOnly = $true
        FeatureOff = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'GenAILocalFoundationalModelSettings'; V = 1; T = 'DWord' }, @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'AIGenThemesEnabled'; V = 0; T = 'DWord' })
        Note = 'GenAILocalFoundationalModelSettings=1: Edge does not download its local AI model; AIGenThemesEnabled=0: no AI-generated themes.' }
    [ordered]@{ Key = 'coreai'; Name = 'CoreAI / AI Fabric (OS platform)'; Packages = @('MicrosoftWindows.Client.CoreAI', 'MicrosoftWindows.Client.AIX', 'Microsoft.AIFabric.CBS*'); Risk = 'hard'; CanRemove = $false; FeatureOff = @()
        Note = 'Deep OS AI platform in SystemApps, marked non-removable; removing it can break Windows and there is no safe switch. Listed for awareness only - no action.' }
)

function Get-WHDAiPresence {
    # Installed = any of its packages present for any user, or its optional feature enabled. Read-only.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Module)
    foreach ($pat in @($Module['Packages'])) { if (@(Get-AppxPackage -AllUsers -Name $pat -ErrorAction SilentlyContinue).Count) { return $true } }
    if ($Module['OptionalFeature']) {
        try { if ([string](Get-WindowsOptionalFeature -Online -FeatureName $Module['OptionalFeature'] -ErrorAction Stop).State -eq 'Enabled') { return $true } } catch { Write-Verbose 'optional feature unreadable' }
    }
    return $false
}

function Invoke-WHDAiFeatureOff {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Module)
    Write-WHDLog -Message ('FEATURE-OFF: {0}' -f $Module['Name']) -Level 'ACT'
    Write-WHDRisk -Tier $Module['Risk'] -Text $Module['Note']
    $ops = @($Module['FeatureOff'])
    if (-not $ops.Count) { Write-WHDLog -Message $(if ($Module['CanRemove']) { 'No supported off-switch for this item (see the note). Use remove (r) instead.' } else { 'No action for this item (see the note).' }) -Level 'WARN'; return }
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set') { Write-WHDLog -Message 'Already off - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('feature-off {0}' -f $Module['Name']))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($op in $ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
}

function Invoke-WHDAiRemove {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Module)
    Write-WHDLog -Message ('APP-REMOVE: {0}' -f $Module['Name']) -Level 'ACT'
    if (-not $Module['CanRemove']) { Write-WHDLog -Message ('Not offered for removal - {0}' -f $Module['Note']) -Level 'WARN'; return }
    Write-WHDRisk -Tier $Module['Risk'] -Text ('removes for all users + staged copy + Deprovisioned mark: {0}' -f (@($Module['Packages']) -join ', '))
    if (-not (Confirm-WHDProceed -What ('remove {0}' -f $Module['Name']))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($pat in @($Module['Packages'])) {
        Remove-WHDAppxAllUser -NameLike $pat
        Remove-WHDProvisioned -NameLike $pat
    }
}

function Invoke-WHDStoreSuppression {
    # SS: Windows stops silently re-adding suggested / removed apps (machine + this user).
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'STORE / silent-reinstall suppression (machine + this user)' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'Stops Windows silently re-adding suggested or removed apps. Registry values, recorded (Undo center).'
    $cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $ops = @(foreach ($n in 'SilentInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'ContentDeliveryAllowed', 'SubscribedContent-338388Enabled', 'FeatureManagementEnabled') { @{ P = $cdm; N = $n; V = 0; T = 'DWord' } }) +
        @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; N = 'DisableWindowsConsumerFeatures'; V = 1; T = 'DWord' })
    if ((Get-WHDRegOpsState -Ops $ops) -eq 'set') { Write-WHDLog -Message 'Already set - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What 'apply Store / silent-reinstall suppression')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    foreach ($op in $ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
    Write-WHDLog -Message 'DisableWindowsConsumerFeatures is best-effort on Home; the ContentDeliveryManager values are the reliable part.'
}

function Test-WHDAiRecommended {
    # * = green (reversible) and has an action. Notepad / Paint / Photos (yellow) and the red OS item never are.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Module)
    return ([string]$Module['Risk'] -eq 'reversible' -and ([bool]$Module['CanRemove'] -or @($Module['FeatureOff']).Count -gt 0))
}

function Get-WHDAiBatchPlan {
    # remove: the app AND its off-switch when it has one; off when it cannot be removed. off: the switch only. (pure)
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Module, [ValidateSet('remove', 'off')][string]$Action)
    $hasOff = [bool]@($Module['FeatureOff']).Count
    if ($Action -eq 'remove') {
        if ($Module['CanRemove'] -and $hasOff) { return 'remove+off' }
        if ($Module['CanRemove']) { return 'remove' }
        if ($hasOff) { return 'off' }
        return 'none'
    }
    if ($hasOff) { return 'off' }
    return 'none'
}

function Invoke-WHDAiBatch {
    # One list, ONE question, then every step without further questions.
    [CmdletBinding()]
    param([object[]]$Modules, [ValidateSet('remove', 'off')][string]$Action)
    $mods = @($Modules | Where-Object { $_ })
    if (-not $mods.Count) { Write-WHDLog -Message 'Nothing selected.' -Level 'WARN'; return }
    Write-WHDLog -Message ('AI DEBLOAT - {0} item(s), action: {1}' -f $mods.Count, $(if ($Action -eq 'remove') { 'remove (turn OFF where it cannot be removed)' } else { 'feature-off' })) -Level 'ACT'
    $plan = @(foreach ($md in $mods) { [pscustomobject]@{ Module = $md; Do = (Get-WHDAiBatchPlan -Module $md -Action $Action) } })
    foreach ($p in $plan) {
        $txt = switch ($p.Do) {
            'remove+off' { 'remove the app + set its off-switch' }
            'remove' { 'remove the app (it has no off-switch)' }
            'off' { if ($Action -eq 'remove') { 'turn OFF (cannot be removed)' } else { 'turn OFF' } }
            default { 'skip - no such action for this item' }
        }
        Write-WHDLog -Message ('   {0,-42} -> {1}' -f $p.Module['Name'], $txt)
    }
    $todo = @($plan | Where-Object Do -ne 'none')
    if (-not $todo.Count) { Write-WHDLog -Message 'Nothing to do for this selection.' -Level 'WARN'; return }
    $tier = if (@($todo | Where-Object { [string]$_.Module['Risk'] -ne 'reversible' }).Count) { 'caution' } else { 'reversible' }
    Write-WHDRisk -Tier $tier -Text 'Removed apps can be re-installed from the Microsoft Store; off-switches are registry values. Every step is recorded (Undo center).'
    if (-not (Confirm-WHDProceed -What ('apply the {0} step(s) listed above' -f $todo.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do {
        foreach ($p in $todo) {
            if ($script:WHDState.JournalStop) { break }
            if ($p.Do -in 'remove+off', 'remove') { Invoke-WHDAiRemove -Module $p.Module }
            if ($p.Do -in 'remove+off', 'off' -and -not $script:WHDState.JournalStop) { Invoke-WHDAiFeatureOff -Module $p.Module }
        }
    }
    Write-WHDLog -Message ('AI DEBLOAT - finished ({0} step(s)).' -f $todo.Count) -Level 'OK'
}

function Show-WHDAiMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== AI surfaces ===============' -ForegroundColor White
    for ($i = 0; $i -lt $script:WHDAiModules.Count; $i++) {
        $md = $script:WHDAiModules[$i]
        if ($md['PolicyOnly']) {
            $state = switch (Get-WHDRegOpsState -Ops @($md['FeatureOff'])) { 'set' { 'OFF(set)' } 'partly' { 'partly  ' } default { 'on      ' } }
        } else { $state = if (Get-WHDAiPresence -Module $md) { 'present ' } else { 'absent  ' } }
        $fo = if (@($md['FeatureOff']).Count) { 'feature-off' } else { '    --     ' }
        $rm = if ($md['CanRemove']) { 'remove' } else { '  --  ' }
        $col = @{ reversible = 'Green'; caution = 'Yellow'; hard = 'Red' }[[string]$md['Risk']]
        Write-WHDParts -Parts @(('  {0,2}.{1} ' -f ($i + 1), $(if (Test-WHDAiRecommended -Module $md) { '*' } else { ' ' })), @(('{0,-40}' -f $md['Name']), $col), ('  [{0}]  {1}  {2}' -f $state, $fo, $rm))
    }
    Write-Host '   * = recommended (green = reversible)' -ForegroundColor DarkGray
    Write-Host '   One item : its number, then f or r      Several : 1,3,5 r    2-6 f    * r    *,7 r' -ForegroundColor DarkGray
    Write-Host '   r = remove the app AND set its off-switch (turned OFF where it cannot be removed);  f = feature-off only' -ForegroundColor DarkGray
    Write-Host '   Policy switches show on / partly / OFF(set). Documented for Pro+, best-effort on Home.' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'SS' -Label 'Store / silent-reinstall suppression (global)' -Hint '(was S in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDAiChoice {
    # One menu choice. Returns $false for B (back). -Answer feeds the f / r question (tests, scripted runs).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice, [string[]]$Answer)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    if ($c -match '^[Bb]$') { return $false }
    if ($c -match '^[Ss][Ss]$') { Invoke-WHDStoreSuppression; return $true }
    if ($c -match '^([\d,\s\-\*]+?)\s*([FfRr]?)$') {
        $selText = $Matches[1]; $act = $Matches[2]
        $star = @(for ($k = 1; $k -le $script:WHDAiModules.Count; $k++) { if (Test-WHDAiRecommended -Module $script:WHDAiModules[$k - 1]) { $k } })
        $sel = ConvertFrom-WHDSelection -Text $selText -Max $script:WHDAiModules.Count -Star $star
        if (-not $sel) { Write-Host '  invalid.' -ForegroundColor Yellow; return $true }
        $mods = @(foreach ($n in $sel) { $script:WHDAiModules[$n - 1] })
        if (-not $act) {
            $q = if ($mods.Count -eq 1) { '  [{0}]  f = feature-off,  r = remove + set its off-switch (OFF where it cannot be removed),  c = cancel' -f $mods[0]['Name'] }
                 else { '  {0} item(s) selected:  r = remove + set the off-switch (OFF where it cannot be removed),  f = feature-off,  c = cancel' -f $mods.Count }
            $act = (Read-WHDMenuAnswer -Answer $Answer -Prompt $q).Trim()
        }
        switch -regex ($act) {
            '^[Rr]$' { Invoke-WHDAiBatch -Modules $mods -Action remove }
            '^[Ff]$' { if ($mods.Count -eq 1) { Invoke-WHDAiFeatureOff -Module $mods[0] } else { Invoke-WHDAiBatch -Modules $mods -Action off } }
            default { Write-Host '  cancelled.' -ForegroundColor DarkGray }
        }
        return $true
    }
    Write-Host '  invalid.' -ForegroundColor Yellow
    return $true
}
