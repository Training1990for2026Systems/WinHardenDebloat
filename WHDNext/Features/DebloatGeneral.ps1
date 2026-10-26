#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/DebloatGeneral.ps1   (non-AI apps + privacy)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Same features and values as WHD Next 2.0 (D8), rewritten for PowerShell 7.6.
 Build step 5.4b (D30).
   * General apps: a hand-checked list from a real Windows 11 Home inventory
     (codecs, runtimes, Store, winget, Defender UI, Terminal and SystemApps are
     deliberately NOT in it) + the apps found on THIS PC that are not made by
     Microsoft. Remove = all users + staged copy + Deprovisioned mark.
     Several at once: 1,3,5  2-6  *  *,3,7  (* = recommended); A = all
     recommended. One question for the whole list.
   * P  privacy / telemetry hardening (advertising ID, tailored experiences,
        telemetry 0 - Home keeps "basic"), D  DiagTrack service off, PD both.
   * M  more privacy settings (activity history, clipboard, ads + suggestions,
        speech / inking, Edge background, Edge diagnostics) - D33: reached from
        this menu now; the main menu (step 6) gets it too.
 Every value / service / removal goes through the engine and is recorded.
================================================================================
#>

$script:WHDGeneralApps = @(
    [ordered]@{ Key = 'clipchamp'; Name = 'Clipchamp (video editor)'; Package = 'Clipchamp.Clipchamp'; Risk = 'reversible'; Rec = $true; Note = 'Store video editor.' }
    [ordered]@{ Key = 'solitaire'; Name = 'Solitaire Collection'; Package = 'Microsoft.MicrosoftSolitaireCollection'; Risk = 'reversible'; Rec = $true; Note = 'Ad-supported game.' }
    [ordered]@{ Key = 'todos'; Name = 'Microsoft To Do'; Package = 'Microsoft.Todos'; Risk = 'reversible'; Rec = $false; Note = 'Task app.' }
    [ordered]@{ Key = 'sticky'; Name = 'Sticky Notes'; Package = 'Microsoft.MicrosoftStickyNotes'; Risk = 'reversible'; Rec = $false; Note = 'Notes app.' }
    [ordered]@{ Key = 'feedback'; Name = 'Feedback Hub'; Package = 'Microsoft.WindowsFeedbackHub'; Risk = 'reversible'; Rec = $true; Note = 'Sends feedback to Microsoft.' }
    [ordered]@{ Key = 'gethelp'; Name = 'Get Help'; Package = 'Microsoft.GetHelp'; Risk = 'reversible'; Rec = $true; Note = 'Support app.' }
    [ordered]@{ Key = 'quickassist'; Name = 'Quick Assist'; Package = 'MicrosoftCorporationII.QuickAssist'; Risk = 'reversible'; Rec = $false; Note = 'Remote assistance - remove if unused (also misused by scammers).' }
    [ordered]@{ Key = 'devhome'; Name = 'Dev Home'; Package = 'Microsoft.Windows.DevHome'; Risk = 'reversible'; Rec = $true; Note = 'Developer dashboard.' }
    [ordered]@{ Key = 'family'; Name = 'Microsoft Family'; Package = 'MicrosoftCorporationII.MicrosoftFamily'; Risk = 'reversible'; Rec = $false; Note = 'Family safety.' }
    [ordered]@{ Key = 'outlooknew'; Name = 'Outlook for Windows (new)'; Package = 'Microsoft.OutlookForWindows'; Risk = 'reversible'; Rec = $false; Note = 'New Outlook web app.' }
    [ordered]@{ Key = 'teams'; Name = 'Microsoft Teams (personal)'; Package = 'MSTeams'; Risk = 'reversible'; Rec = $true; Note = 'Consumer Teams / chat.' }
    [ordered]@{ Key = 'crossdevice'; Name = 'Cross Device (Link to Windows)'; Package = 'MicrosoftWindows.CrossDevice'; Risk = 'caution'; Rec = $false; Note = 'Phone / cross-device integration; removal may affect Phone Link.' }
    [ordered]@{ Key = 'alarms'; Name = 'Clock / Alarms'; Package = 'Microsoft.WindowsAlarms'; Risk = 'reversible'; Rec = $false; Note = 'Clock, timers, alarms.' }
    [ordered]@{ Key = 'soundrec'; Name = 'Sound Recorder'; Package = 'Microsoft.WindowsSoundRecorder'; Risk = 'reversible'; Rec = $false; Note = 'Voice recorder.' }
    [ordered]@{ Key = 'zune'; Name = 'Media Player (Groove/Zune)'; Package = 'Microsoft.ZuneMusic'; Risk = 'caution'; Rec = $false; Note = 'Default music / media player - removal loses it.' }
    [ordered]@{ Key = 'camera'; Name = 'Camera'; Package = 'Microsoft.WindowsCamera'; Risk = 'caution'; Rec = $false; Note = 'Webcam app - removal loses the camera window.' }
    [ordered]@{ Key = 'calc'; Name = 'Calculator'; Package = 'Microsoft.WindowsCalculator'; Risk = 'caution'; Rec = $false; Note = 'Most people keep it; listed for completeness.' }
    [ordered]@{ Key = 'xboxapp'; Name = 'Xbox app'; Package = 'Microsoft.GamingApp'; Risk = 'reversible'; Rec = $false; Note = 'Xbox app / Game Pass.' }
    [ordered]@{ Key = 'xboxoverlay'; Name = 'Xbox Game Bar'; Package = 'Microsoft.XboxGamingOverlay'; Risk = 'caution'; Rec = $false; Note = 'Game Bar (Win+G); some games expect it.' }
    [ordered]@{ Key = 'xboxstt'; Name = 'Xbox Speech-to-Text'; Package = 'Microsoft.XboxSpeechToTextOverlay'; Risk = 'reversible'; Rec = $false; Note = 'Game chat captions.' }
    [ordered]@{ Key = 'xboxtcui'; Name = 'Xbox Game UI (TCUI)'; Package = 'Microsoft.Xbox.TCUI'; Risk = 'caution'; Rec = $false; Note = 'Xbox in-game screens; leave if you keep Xbox.' }
    [ordered]@{ Key = 'xboxid'; Name = 'Xbox Identity Provider'; Package = 'Microsoft.XboxIdentityProvider'; Risk = 'caution'; Rec = $false; Note = 'Xbox sign-in for games; remove only if you do not play.' }
)

# P - privacy / telemetry hardening (same five values as WHD Next 2.0).
$script:WHDPrivacyHardeningOps = @(
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; N = 'Enabled'; V = 0; T = 'DWord' }
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy'; N = 'TailoredExperiencesWithDiagnosticDataEnabled'; V = 0; T = 'DWord' }
    @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-310093Enabled'; V = 0; T = 'DWord' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'AllowTelemetry'; V = 0; T = 'DWord' }
    @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; N = 'DoNotShowFeedbackNotifications'; V = 1; T = 'DWord' }
)

# M - more privacy settings (same items and values as WHD Next 2.0).
$script:WHDPrivacyItems = @(
    [ordered]@{ Key = 'activity'; Name = 'Activity history (timeline)'; Risk = 'reversible'
        Note = 'Windows stops recording and uploading your activity history (Privacy CSP EnableActivityFeed, PublishUserActivities, UploadUserActivities).'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'EnableActivityFeed'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'PublishUserActivities'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'UploadUserActivities'; V = 0; T = 'DWord' }) }
    [ordered]@{ Key = 'clipboard'; Name = 'Clipboard history + cross-device sync'; Risk = 'caution'
        Note = 'Turns off Win+V clipboard history and clipboard sync to other devices. Plain copy / paste keeps working.'
        Ops = @(@{ P = 'HKCU:\Software\Microsoft\Clipboard'; N = 'EnableClipboardHistory'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'AllowClipboardHistory'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; N = 'AllowCrossDeviceClipboard'; V = 0; T = 'DWord' }) }
    [ordered]@{ Key = 'suggestions'; Name = 'Ads, suggestions + account nags'; Risk = 'reversible'
        Note = 'Start recommendations, lock-screen tips, Settings suggestions, tips notifications, "finish setting up your device" and Microsoft account prompts.'
        Ops = @(@{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'RotatingLockScreenOverlayEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338387Enabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338389Enabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-338393Enabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-353694Enabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SubscribedContent-353696Enabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SystemPaneSuggestionsEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; N = 'SoftLandingEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_IrisRecommendations'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; N = 'Start_AccountNotifications'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement'; N = 'ScoobeSystemSettingEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; N = 'DisableThirdPartySuggestions'; V = 1; T = 'DWord' }
            @{ P = 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent'; N = 'DisableTailoredExperiencesWithDiagnosticData'; V = 1; T = 'DWord' }) }
    [ordered]@{ Key = 'speech'; Name = 'Online speech + inking/typing data'; Risk = 'reversible'
        Note = 'Online speech recognition off; Windows stops learning from your typing / handwriting and harvesting contacts for it (Privacy CSP AllowInputPersonalization + the Settings values).'
        Ops = @(@{ P = 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy'; N = 'HasAccepted'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitInkCollection'; V = 1; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\InputPersonalization'; N = 'RestrictImplicitTextCollection'; V = 1; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore'; N = 'HarvestContacts'; V = 0; T = 'DWord' }
            @{ P = 'HKCU:\Software\Microsoft\Personalization\Settings'; N = 'AcceptedPrivacyPolicy'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'; N = 'AllowInputPersonalization'; V = 0; T = 'DWord' }) }
    [ordered]@{ Key = 'edgebg'; Name = 'Edge: background, startup boost, shopping'; Risk = 'reversible'
        Note = 'Edge stops running after you close it, stops preloading at sign-in, and shows no shopping pop-ups (Edge policies BackgroundModeEnabled, StartupBoostEnabled, EdgeShoppingAssistantEnabled).'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'BackgroundModeEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'StartupBoostEnabled'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'EdgeShoppingAssistantEnabled'; V = 0; T = 'DWord' }) }
    [ordered]@{ Key = 'edgediag'; Name = 'Edge: diagnostic data + personalization'; Risk = 'reversible'
        Note = 'Edge sends no optional diagnostic data (DiagnosticData=0) and no browsing data for ad / feed personalization (PersonalizationReportingEnabled=0).'
        Ops = @(@{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'DiagnosticData'; V = 0; T = 'DWord' }
            @{ P = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'; N = 'PersonalizationReportingEnabled'; V = 0; T = 'DWord' }) }
)

function Set-WHDRegOpSet {
    # Writes the values of a group that are not already as wanted (each one recorded as kind reg).
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][object[]]$Ops)
    foreach ($op in $Ops) {
        $cur = Get-WHDRegValueState -Path $op.P -Name $op.N
        if ($cur.Exists -and (Test-WHDRegValueEqual -A $cur.Value -B $op.V -Type $op.T)) { continue }
        if (-not $PSCmdlet.ShouldProcess(('{0}\{1}' -f $op.P, $op.N), 'set value')) { continue }
        Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null
    }
}

# ---- general apps ---------------------------------------------------------------------
function Test-WHDAppPresent {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Package)
    [bool]@(Get-AppxPackage -AllUsers -Name $Package -ErrorAction SilentlyContinue).Count
}

function Test-WHDMicrosoftPublisher {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Publisher)
    $Publisher -match 'O=Microsoft Corporation|CN=Microsoft Windows|CN=Microsoft Corporation'
}

function Get-WHDFoundApp {
    # Store apps on THIS PC not made by Microsoft (frameworks, resource packs, non-removable parts left out).
    # Staged = also provisioned for new users (how driver / OEM apps arrive). Read fresh on every PC.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DisplayName })
    $seen = @{}
    $list = foreach ($a in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
        if ($a.IsFramework -or $a.IsResourcePackage -or $a.NonRemovable -or (Test-WHDMicrosoftPublisher -Publisher ([string]$a.Publisher))) { continue }
        $nm = [string]$a.Name
        if ($seen.ContainsKey($nm)) { continue }
        $seen[$nm] = $true
        $pub = [string]$a.Publisher
        $org = if ($pub -match 'O=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } elseif ($pub -match 'CN=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } else { $pub }
        $staged = $prov -contains $nm
        [ordered]@{ Key = 'found:' + $nm; Package = $nm; Publisher = $org; Staged = $staged; Found = $true; Risk = 'caution'; Rec = $false
            Name = ('{0}  ({1}{2})' -f $nm, $org, $(if ($staged) { ', staged' } else { '' }))
            Note = ('Found on this PC, not made by Microsoft (publisher: {0}){1}. Removed for all users + staged copy + Deprovisioned mark; reinstall from the Store or the maker if needed. A driver that bundles it can bring it back.' -f $org, $(if ($staged) { '; staged = it came with Windows or a driver' } else { '; installed by a user' })) }
    }
    return @(@($list) | Sort-Object @{ e = { -not $_['Staged'] } }, @{ e = { $_['Package'] } })
}

function Get-WHDGeneralCatalog {
    # The fixed list + what was found on this PC; menu numbers come from this one list.
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    @($script:WHDGeneralApps) + @(Get-WHDFoundApp)
}

function Invoke-WHDGeneralBatch {
    # One list, ONE question, then every removal without further questions.
    [CmdletBinding()]
    param([object[]]$Entries)
    $list = @($Entries | Where-Object { $_ })
    if (-not $list.Count) { Write-WHDLog -Message 'Nothing selected.' -Level 'WARN'; return }
    Write-WHDLog -Message ('GENERAL APPS - remove {0} app(s)' -f $list.Count) -Level 'ACT'
    foreach ($e in $list) { Write-WHDLog -Message ('   {0}   ({1})' -f $e['Name'], $e['Package']) }
    $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DisplayName })
    $here = @($list | Where-Object { (Test-WHDAppPresent -Package $_['Package']) -or ($prov -like $_['Package']).Count })
    if (-not $here.Count) { Write-WHDLog -Message 'None of these apps is on this PC (installed or staged) - nothing to remove.' -Level 'OK'; return }
    if ($here.Count -lt $list.Count) { Write-WHDLog -Message ('  {0} of them are already gone; {1} to remove.' -f ($list.Count - $here.Count), $here.Count) }
    $list = $here
    $tier = if (@($list | Where-Object { [string]$_['Risk'] -ne 'reversible' }).Count) { 'caution' } else { 'reversible' }
    if ($list.Count -eq 1) { Write-WHDRisk -Tier $tier -Text $list[0]['Note'] }
    else { Write-WHDRisk -Tier $tier -Text 'Removed for all users with the staged copy and the Deprovisioned mark. Re-install from the Microsoft Store if needed. Every removal is recorded (Undo center).' }
    if (-not (Confirm-WHDProceed -What ('remove the {0} app(s) listed above' -f $list.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do {
        foreach ($e in $list) {
            if ($script:WHDState.JournalStop) { break }
            Remove-WHDAppxAllUser -NameLike $e['Package']
            Remove-WHDProvisioned -NameLike $e['Package']
        }
    }
    Write-WHDLog -Message ('GENERAL APPS - finished ({0} app(s)).' -f $list.Count) -Level 'OK'
}

# ---- P / D / PD ------------------------------------------------------------------------
function Invoke-WHDPrivacyHardening {
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'PRIVACY / TELEMETRY HARDENING' -Level 'ACT'
    Write-WHDRisk -Tier 'reversible' -Text 'Advertising ID off, tailored experiences off, telemetry minimized (best-effort on Home).'
    if ((Get-WHDRegOpsState -Ops $script:WHDPrivacyHardeningOps) -eq 'set') { Write-WHDLog -Message 'Already set - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What 'apply privacy / telemetry registry hardening')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDRegOpSet -Ops $script:WHDPrivacyHardeningOps
    Write-WHDLog -Message 'On Home the telemetry floor is "basic" - AllowTelemetry=0 is set, but Windows may still send basic diagnostics.'
}

function Disable-WHDDiagTrack {
    # Connected User Experiences and Telemetry: stop + Disabled; recorded as kind service (Undo puts the start type back).
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'DISABLE DiagTrack service (Connected User Experiences and Telemetry)' -Level 'ACT'
    Write-WHDRisk -Tier 'caution' -Text 'Stops and disables the telemetry service. Reversible (Undo center puts the start type back). Safe on a standalone Home PC.'
    $svc = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    if (-not $svc) { Write-WHDLog -Message 'DiagTrack service not found.' -Level 'WARN'; return }
    if ([string]$svc.StartType -eq 'Disabled' -and [string]$svc.Status -ne 'Running') { Write-WHDLog -Message 'Already disabled and stopped - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What 'stop + disable DiagTrack')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    $dtOld = [string]$svc.StartType
    Invoke-WHDChange -Description ('stop + disable service DiagTrack (start type {0} -> Disabled)' -f $dtOld) -Journal @{ Kind = 'service'; Service = 'DiagTrack'; OldStartType = $dtOld; NewStartType = 'Disabled' } -Action {
        Stop-Service -Name 'DiagTrack' -Force -ErrorAction SilentlyContinue
        Set-Service -Name 'DiagTrack' -StartupType Disabled -ErrorAction Stop
    } | Out-Null
}

function Invoke-WHDPrivacyAndDiagTrack {
    # PD: one question for both.
    [CmdletBinding()]
    param()
    Write-WHDLog -Message 'PRIVACY / TELEMETRY HARDENING + DISABLE DiagTrack (both)' -Level 'ACT'
    $pdSvc = Get-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    $dDone = (-not $pdSvc) -or ([string]$pdSvc.StartType -eq 'Disabled' -and [string]$pdSvc.Status -ne 'Running')
    if ((Get-WHDRegOpsState -Ops $script:WHDPrivacyHardeningOps) -eq 'set' -and $dDone) { Write-WHDLog -Message 'Both already done - nothing to change.' -Level 'OK'; return }
    Write-WHDRisk -Tier 'caution' -Text 'P: advertising ID off, tailored experiences off, telemetry minimized.  D: stops + disables the telemetry service. Both reversible.'
    if (-not (Confirm-WHDProceed -What 'apply privacy / telemetry hardening AND disable DiagTrack')) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do { Invoke-WHDPrivacyHardening; if (-not $script:WHDState.JournalStop) { Disable-WHDDiagTrack } }
}

# ---- M: more privacy settings -------------------------------------------------------------
function Invoke-WHDPrivacyItem {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Item)
    Write-WHDLog -Message ('PRIVACY: {0}' -f $Item['Name']) -Level 'ACT'
    Write-WHDRisk -Tier $Item['Risk'] -Text $Item['Note']
    if ((Get-WHDRegOpsState -Ops @($Item['Ops'])) -eq 'set') { Write-WHDLog -Message 'Already set - nothing to change.' -Level 'OK'; return }
    if (-not (Confirm-WHDProceed -What ('apply privacy setting: {0}' -f $Item['Name']))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Set-WHDRegOpSet -Ops @($Item['Ops'])
    if ([string]$Item['Key'] -like 'edge*') { Write-WHDLog -Message 'Restart Edge for this to take effect (edge://policy shows applied policies).' }
    if ([string]$Item['Key'] -eq 'suggestions') { Write-WHDLog -Message 'Some Start / lock-screen changes show after signing out and back in.' }
}

function Invoke-WHDPrivacyBatch {
    [CmdletBinding()]
    param([object[]]$Items)
    $list = @($Items | Where-Object { $_ })
    if (-not $list.Count) { Write-WHDLog -Message 'Nothing selected.' -Level 'WARN'; return }
    Write-WHDLog -Message ('PRIVACY - apply {0} setting(s)' -f $list.Count) -Level 'ACT'
    foreach ($it in $list) { Write-WHDLog -Message ('   {0}' -f $it['Name']) }
    $tier = if (@($list | Where-Object { [string]$_['Risk'] -ne 'reversible' }).Count) { 'caution' } else { 'reversible' }
    Write-WHDRisk -Tier $tier -Text 'Registry values only. Every value is recorded (Undo center).'
    if (-not (Confirm-WHDProceed -What ('apply the {0} privacy setting(s) listed above' -f $list.Count))) { Write-WHDLog -Message 'skipped.' -Level 'WARN'; return }
    Invoke-WHDConfirmOnce -Do { foreach ($it in $list) { if ($script:WHDState.JournalStop) { break }; Invoke-WHDPrivacyItem -Item $it } }
}

function Show-WHDPrivacyMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== More privacy settings ===============' -ForegroundColor White
    for ($i = 0; $i -lt $script:WHDPrivacyItems.Count; $i++) {
        $it = $script:WHDPrivacyItems[$i]
        $st = Get-WHDRegOpsState -Ops @($it['Ops'])
        Write-WHDParts -Parts @(('  {0,2}. {1,-44} ' -f ($i + 1), $it['Name']), @(('[{0}]' -f $st), $(switch ($st) { 'set' { 'Green' } 'partly' { 'Yellow' } default { 'Gray' } })))
    }
    Write-Host '   #  apply one      several: 1,3,5 or 2-4      A = apply all' -ForegroundColor DarkGray
    Write-Host '   Policy values are documented for Pro+; best-effort on Home. Undo: Undo center.' -ForegroundColor DarkGray
    Write-WHDMenuCommonKey
}

function Invoke-WHDPrivacyChoice {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    if ($c -match '^[Bb]$' -or -not $c) { return $false }
    if ($c -match '^[Aa]$') { Invoke-WHDPrivacyBatch -Items @($script:WHDPrivacyItems); return $true }
    $sel = ConvertFrom-WHDSelection -Text $c -Max $script:WHDPrivacyItems.Count
    if (-not $sel) { Write-Host '  invalid.' -ForegroundColor Yellow; return $true }
    if ($sel.Count -eq 1) { Invoke-WHDPrivacyItem -Item $script:WHDPrivacyItems[$sel[0] - 1] }
    else { Invoke-WHDPrivacyBatch -Items @(foreach ($n in $sel) { $script:WHDPrivacyItems[$n - 1] }) }
    return $true
}

# ---- General menu --------------------------------------------------------------------------
$script:WHDGenCatalog = @()

function Show-WHDGeneralMenu {
    [CmdletBinding()]
    param()
    Write-Host ''
    Write-Host '  =============== General (non-AI) apps ===============' -ForegroundColor White
    $script:WHDGenCatalog = @(Get-WHDGeneralCatalog)
    $foundHdr = $false
    for ($i = 0; $i -lt $script:WHDGenCatalog.Count; $i++) {
        $e = $script:WHDGenCatalog[$i]
        if ($e['Found'] -and -not $foundHdr) { Write-Host '  -- Found on this PC (not made by Microsoft) --' -ForegroundColor DarkGray; $foundHdr = $true }
        $state = if ($e['Found'] -or (Test-WHDAppPresent -Package $e['Package'])) { 'present' } else { 'absent ' }
        $col = @{ reversible = 'Green'; caution = 'Yellow'; hard = 'Red' }[[string]$e['Risk']]
        Write-WHDParts -Parts @(('  {0,2}.{1} ' -f ($i + 1), $(if ($e['Rec']) { '*' } else { ' ' })), @(('{0,-34}' -f $e['Name']), $col), ('  [{0}]' -f $state))
    }
    if (-not $foundHdr) { Write-Host '  -- Found on this PC (not made by Microsoft): none --' -ForegroundColor DarkGray }
    Write-Host '   * = recommended.  One app: its number.  Several: 1,3,5  2-6  *  *,3,7  (one question for the list)' -ForegroundColor DarkGray
    Write-WHDMenuItem -Key 'A' -Label 'Remove ALL recommended (*)'
    Write-WHDMenuItem -Key 'P' -Label 'Privacy / telemetry hardening' -Hint ('[{0}]' -f (Get-WHDRegOpsState -Ops $script:WHDPrivacyHardeningOps))
    Write-WHDMenuItem -Key 'D' -Label 'Disable DiagTrack telemetry service'
    Write-WHDMenuItem -Key 'PD' -Label 'P and D together'
    Write-WHDMenuItem -Key 'M' -Label 'More privacy settings' -Hint '(main menu M in WHD Next 2.0)'
    Write-WHDMenuCommonKey
}

function Invoke-WHDGeneralChoice {
    # One menu choice. Returns $false for B (back).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    if ($c -match '^[Bb]$') { return $false }
    if ($c -match '^([Pp][Dd]|[Dd][Pp])$') { Invoke-WHDPrivacyAndDiagTrack; return $true }
    if ($c -match '^[Pp]$') { Invoke-WHDPrivacyHardening; return $true }
    if ($c -match '^[Dd]$') { Disable-WHDDiagTrack; return $true }
    if ($c -match '^[Mm]$') { Invoke-WHDMenu -Name Privacy; return $true }
    if ($c -match '^[Aa]$') { $c = '*' }
    if (-not $script:WHDGenCatalog.Count) { $script:WHDGenCatalog = @(Get-WHDGeneralCatalog) }
    $cat = $script:WHDGenCatalog
    $star = @(for ($k = 1; $k -le $cat.Count; $k++) { if ($cat[$k - 1]['Rec']) { $k } })
    $sel = ConvertFrom-WHDSelection -Text $c -Max $cat.Count -Star $star
    if (-not $sel) { Write-Host '  invalid.' -ForegroundColor Yellow; return $true }
    Invoke-WHDGeneralBatch -Entries @(foreach ($n in $sel) { $cat[$n - 1] })
    return $true
}
