<#
================================================================================
 WinHardenDebloat  -  modules\Debloat-General.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 Non-AI bloat removal + privacy/telemetry hardening.

 The app list is CURATED from this machine's own inventory and hand-checked:
   * Only apps that are safe to remove on a standalone Home machine are listed.
   * Media codecs/extensions, runtimes (VCLibs/.NET/UI.Xaml/AppRuntime),
     Store, winget (DesktopAppInstaller), Defender (SecHealthUI), Terminal and
     all SystemApps are DELIBERATELY EXCLUDED - removing them breaks things.
   * Xbox/media/OEM items are marked 'caution' with a reason.

 Remove path = Remove-AppxPackage (all users) + deprovision (new users).
 Reuses Common.ps1 (dot-sourced first).
================================================================================
#>

# Rec = recommended for a lean debloat; Risk drives the color + warning.
$script:WHDGeneralApps = @(
    [ordered]@{ Key='clipchamp';   Name='Clipchamp (video editor)';        Package='Clipchamp.Clipchamp';                 Risk='reversible'; Rec=$true;  Note='Store video editor.' }
    [ordered]@{ Key='solitaire';   Name='Solitaire Collection';            Package='Microsoft.MicrosoftSolitaireCollection'; Risk='reversible'; Rec=$true;  Note='Ad-supported game.' }
    [ordered]@{ Key='todos';       Name='Microsoft To Do';                 Package='Microsoft.Todos';                     Risk='reversible'; Rec=$false; Note='Task app.' }
    [ordered]@{ Key='sticky';      Name='Sticky Notes';                    Package='Microsoft.MicrosoftStickyNotes';      Risk='reversible'; Rec=$false; Note='Notes app.' }
    [ordered]@{ Key='feedback';    Name='Feedback Hub';                    Package='Microsoft.WindowsFeedbackHub';        Risk='reversible'; Rec=$true;  Note='Sends feedback to Microsoft.' }
    [ordered]@{ Key='gethelp';     Name='Get Help';                        Package='Microsoft.GetHelp';                   Risk='reversible'; Rec=$true;  Note='Support app.' }
    [ordered]@{ Key='quickassist'; Name='Quick Assist';                    Package='MicrosoftCorporationII.QuickAssist';  Risk='reversible'; Rec=$false; Note='Remote assistance - remove if unused (also an abuse vector).' }
    [ordered]@{ Key='devhome';     Name='Dev Home';                        Package='Microsoft.Windows.DevHome';           Risk='reversible'; Rec=$true;  Note='Developer dashboard.' }
    [ordered]@{ Key='family';      Name='Microsoft Family';                Package='MicrosoftCorporationII.MicrosoftFamily'; Risk='reversible'; Rec=$false; Note='Family safety.' }
    [ordered]@{ Key='outlooknew';  Name='Outlook for Windows (new)';       Package='Microsoft.OutlookForWindows';         Risk='reversible'; Rec=$false; Note='New Outlook web app.' }
    [ordered]@{ Key='teams';       Name='Microsoft Teams (personal)';      Package='MSTeams';                             Risk='reversible'; Rec=$true;  Note='Consumer Teams/chat.' }
    [ordered]@{ Key='crossdevice'; Name='Cross Device (Link to Windows)';  Package='MicrosoftWindows.CrossDevice';        Risk='caution';    Rec=$false; Note='Phone/cross-device integration; removal may affect Phone Link.' }
    [ordered]@{ Key='alarms';      Name='Clock / Alarms';                  Package='Microsoft.WindowsAlarms';             Risk='reversible'; Rec=$false; Note='Clock, timers, alarms.' }
    [ordered]@{ Key='soundrec';    Name='Sound Recorder';                  Package='Microsoft.WindowsSoundRecorder';      Risk='reversible'; Rec=$false; Note='Voice recorder.' }
    [ordered]@{ Key='zune';        Name='Media Player (Groove/Zune)';      Package='Microsoft.ZuneMusic';                 Risk='caution';    Rec=$false; Note='Default music/media player - removal loses that.' }
    [ordered]@{ Key='camera';      Name='Camera';                          Package='Microsoft.WindowsCamera';             Risk='caution';    Rec=$false; Note='Webcam app - removal loses the camera UI.' }
    [ordered]@{ Key='calc';        Name='Calculator';                      Package='Microsoft.WindowsCalculator';         Risk='caution';    Rec=$false; Note='Most people keep this; listed for completeness.' }
    # ---- Xbox / gaming cluster (remove together if you do not game) ----------
    [ordered]@{ Key='xboxapp';     Name='Xbox app';                        Package='Microsoft.GamingApp';                 Risk='reversible'; Rec=$false; Note='Xbox app / Game Pass.' }
    [ordered]@{ Key='xboxoverlay'; Name='Xbox Game Bar';                   Package='Microsoft.XboxGamingOverlay';         Risk='caution';    Rec=$false; Note='Game Bar (Win+G); some games expect it.' }
    [ordered]@{ Key='xboxstt';     Name='Xbox Speech-to-Text';             Package='Microsoft.XboxSpeechToTextOverlay';   Risk='reversible'; Rec=$false; Note='Game chat captions.' }
    [ordered]@{ Key='xboxtcui';    Name='Xbox Game UI (TCUI)';             Package='Microsoft.Xbox.TCUI';                 Risk='caution';    Rec=$false; Note='Xbox in-game UI; leave if you keep Xbox.' }
    [ordered]@{ Key='xboxid';      Name='Xbox Identity Provider';          Package='Microsoft.XboxIdentityProvider';      Risk='caution';    Rec=$false; Note='Xbox sign-in for games; remove only if no gaming.' }
)

# ---- Phase 7 (C13): more privacy settings (user-selected 2026-09-23) --------
# Each item is a set of registry values, applied through the journaled engine
# (Undo center + Verify). Policy values under ...\Policies\... are documented by
# Microsoft for Pro+; the per-user values (HKCU, non-policy) are what the
# Settings app itself writes, so they work on Home.
function _preg($p,$n,$v,$t='DWord') { @{ P=$p; N=$n; V=$v; T=$t } }
$script:WHDPrivacyItems = @(
    [ordered]@{ Key='activity'; Name='Activity history (timeline)'; Risk='reversible'
        Note='Stops Windows recording and uploading your activity history (Privacy CSP EnableActivityFeed, PublishUserActivities, UploadUserActivities).'
        Ops=@(
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
        ) }
    [ordered]@{ Key='clipboard'; Name='Clipboard history + cross-device sync'; Risk='caution'
        Note='Turns off Win+V clipboard history and clipboard sync to other devices. Plain copy/paste keeps working.'
        Ops=@(
            _preg 'HKCU:\Software\Microsoft\Clipboard' 'EnableClipboardHistory' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0
        ) }
    [ordered]@{ Key='suggestions'; Name='Ads, suggestions + account nags'; Risk='reversible'
        Note='Start recommendations, lock-screen tips/"fun facts", Settings suggestions, tips notifications, "finish setting up your device" and Microsoft account prompts.'
        Ops=@(
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
            _preg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
            _preg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
            _preg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_AccountNotifications' 0
            _preg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
            _preg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableThirdPartySuggestions' 1
            _preg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1
        ) }
    [ordered]@{ Key='speech'; Name='Online speech + inking/typing data'; Risk='reversible'
        Note='Online speech recognition off; Windows stops learning from your typing/handwriting and harvesting contacts for it (Privacy CSP AllowInputPersonalization + the Settings values).'
        Ops=@(
            _preg 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 0
            _preg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
            _preg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
            _preg 'HKCU:\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 0
            _preg 'HKCU:\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
        ) }
    [ordered]@{ Key='edgebg'; Name='Edge: background, startup boost, shopping'; Risk='reversible'
        Note='Edge stops running after you close it, stops preloading at sign-in, and shows no shopping pop-ups (Edge policies BackgroundModeEnabled, StartupBoostEnabled, EdgeShoppingAssistantEnabled).'
        Ops=@(
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'EdgeShoppingAssistantEnabled' 0
        ) }
    [ordered]@{ Key='edgediag'; Name='Edge: diagnostic data + personalization'; Risk='reversible'
        Note='Edge sends no optional diagnostic data (DiagnosticData=0) and no browsing data for ad/feed personalization (PersonalizationReportingEnabled=0).'
        Ops=@(
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'DiagnosticData' 0
            _preg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'PersonalizationReportingEnabled' 0
        ) }
)

function Invoke-WHDPrivacyItem {
    param([Parameter(Mandatory)]$Item)
    Write-WHDLog ("PRIVACY: {0}" -f $Item.Name) 'ACT'
    Write-WHDRisk $Item.Risk $Item.Note
    if ((Get-WHDRegOpsState -Ops @($Item.Ops)) -eq 'set') { Write-WHDLog 'Already set - nothing to change.' 'OK'; return }
    if (-not (Confirm-WHDProceed ("apply privacy setting: {0}" -f $Item.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    foreach ($op in @($Item.Ops)) { Set-WHDRegistryValue -Path $op.P -Name $op.N -Value $op.V -Type $op.T | Out-Null }
    if ($Item.Key -like 'edge*') { Write-WHDLog 'Restart Edge for this to take effect (edge://policy shows applied policies).' 'INFO' }
    if ($Item.Key -eq 'suggestions') { Write-WHDLog 'Some Start/lock-screen changes show after signing out and back in.' 'INFO' }
}

function Show-WHDPrivacyMenu {
    Write-Host ''
    Write-Host '  MORE PRIVACY SETTINGS' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    $i = 0
    foreach ($it in $script:WHDPrivacyItems) {
        $i++
        $st = Get-WHDRegOpsState -Ops @($it.Ops)
        $col = switch ($st) { 'set' { 'Green' } 'partly' { 'Yellow' } default { 'Gray' } }
        Write-Host ("  {0,2}. {1,-44} " -f $i, $it.Name) -NoNewline
        Write-Host ("[{0}]" -f $st) -ForegroundColor $col
    }
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '   #  apply one      A. apply all      B. back'
    Write-Host '   (Undo: main menu U. Policy values are documented for Pro+; best-effort on Home.)' -ForegroundColor DarkGray
}

function Test-WHDAppPresent {
    param([string]$Package)
    (@(Get-AppxPackage -AllUsers -Name $Package -EA SilentlyContinue).Count -gt 0)
}

function Invoke-WHDGeneralRemove {
    param($Entry)
    Write-WHDLog ("REMOVE: {0}  ({1})" -f $Entry.Name, $Entry.Package) 'ACT'
    Write-WHDRisk $Entry.Risk $Entry.Note
    if (-not (Confirm-WHDProceed ("remove {0}" -f $Entry.Name))) { Write-WHDLog 'skipped.' 'WARN'; return }
    Remove-WHDAppxAllUsers -NameLike $Entry.Package
    Remove-WHDProvisioned  -NameLike $Entry.Package
}

function Invoke-WHDRemoveRecommended {
    Write-WHDLog 'REMOVE ALL RECOMMENDED (Rec=true) general apps' 'ACT'
    foreach ($e in @($script:WHDGeneralApps | Where-Object { $_.Rec })) {
        Invoke-WHDGeneralRemove -Entry $e
    }
}

# ---- privacy / telemetry hardening (registry + optional service) ------------
function Invoke-WHDPrivacyHardening {
    Write-WHDLog 'PRIVACY / TELEMETRY HARDENING' 'ACT'
    Write-WHDRisk 'reversible' 'Advertising ID off, tailored experiences off, telemetry minimized (best-effort on Home).'
    if (-not (Confirm-WHDProceed 'apply privacy/telemetry registry hardening')) { Write-WHDLog 'skipped.' 'WARN'; return }
    Set-WHDRegistryValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0
    Set-WHDRegistryValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0
    Set-WHDRegistryValue -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-310093Enabled' -Value 0
    Set-WHDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0
    Set-WHDRegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1
    Write-WHDLog 'Note: on Home the telemetry floor is "Basic" - AllowTelemetry=0 is applied but Windows may still send basic diagnostics.' 'INFO'
}

# ---- DiagTrack (Connected User Experiences and Telemetry) service -----------
function Invoke-WHDDisableDiagTrack {
    Write-WHDLog 'DISABLE DiagTrack service (Connected User Experiences and Telemetry)' 'ACT'
    Write-WHDRisk 'caution' 'Stops + disables the telemetry service. Reversible (set back to Automatic). Safe on standalone Home.'
    if (-not (Confirm-WHDProceed 'stop + disable DiagTrack')) { Write-WHDLog 'skipped.' 'WARN'; return }
    $oldStart = "$((Get-Service DiagTrack -EA SilentlyContinue).StartType)"
    if (-not $oldStart) { $oldStart = 'Automatic' }
    $jr = @{ Kind = 'service'; Service = 'DiagTrack'; OldStartType = $oldStart; NewStartType = 'Disabled' }
    Invoke-WHDChange -Description 'stop + disable service DiagTrack' -Force -Journal $jr -Action {
        Stop-Service DiagTrack -Force -EA SilentlyContinue
        Set-Service  DiagTrack -StartupType Disabled -EA Stop
    }
}

# ---- Classic 1.4: apps found on THIS PC (adaptability, user decisions 2026-09-30) ----
# "Any non-Microsoft app" = every installed Store/Appx app whose publisher is not Microsoft (frameworks,
# resource packs and non-removable system parts left out). Nothing is hard-coded per PC model: the list is
# read fresh on whatever PC WHD runs on. "Staged" = also provisioned for new users (how driver/OEM apps arrive).
function Test-WHDMicrosoftPublisher { param([string]$Publisher) $Publisher -match 'O=Microsoft Corporation|CN=Microsoft Windows|CN=Microsoft Corporation' }
function Get-WHDFoundApps {
    $prov = @(Get-AppxProvisionedPackage -Online -EA SilentlyContinue | ForEach-Object { "$($_.DisplayName)" })
    $seen = @{}
    $list = @(Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object {
        -not $_.IsFramework -and -not $_.IsResourcePackage -and -not $_.NonRemovable -and -not (Test-WHDMicrosoftPublisher "$($_.Publisher)")
    } | ForEach-Object {
        if ($seen.ContainsKey("$($_.Name)")) { return }
        $seen["$($_.Name)"] = $true
        $pub = "$($_.Publisher)"
        $org = if ($pub -match 'O=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } elseif ($pub -match 'CN=("[^"]+"|[^,]+)') { $Matches[1].Trim('"') } else { $pub }
        $staged = $prov -contains "$($_.Name)"
        [ordered]@{
            Key = "found:$($_.Name)"; Package = "$($_.Name)"; Publisher = $org; Staged = $staged; Found = $true
            Name = ("{0}  ({1}{2})" -f $_.Name, $org, $(if ($staged) { ', staged' } else { '' }))
            Risk = 'caution'; Rec = $false
            Note = ("Found on this PC, not made by Microsoft (publisher: {0}){1}. Removed for all users + staged copy + Deprovisioned mark; reinstall from the Store or the maker if needed. A driver that bundles it can bring it back - the update guard reports that." -f $org, $(if ($staged) { '; staged = it came with Windows or a driver' } else { '; installed by a user' }))
        }
    })
    @($list | Sort-Object @{ e = { -not $_.Staged } }, @{ e = { $_.Package } })
}
# Fixed list + what was found on this PC; menu numbers come from this one list.
function Get-WHDGeneralCatalog { @($script:WHDGeneralApps) + @(Get-WHDFoundApps) }

# Profile key general.oem = "ask" (user decision 2026-09-30: ask on each new PC). Console only.
function Invoke-WHDFoundAppsAsk {
    Write-WHDLog 'APPS FOUND ON THIS PC (not Microsoft) - you choose which to remove' 'ACT'
    $found = @(Get-WHDFoundApps)
    if (-not $found.Count) { Write-WHDLog 'No non-Microsoft apps found on this PC.' 'OK'; return }
    if ($script:WHDGuiMode -or $script:WHDYes) {
        foreach ($f in $found) { Write-WHDLog ("  found: {0}" -f $f.Name) 'INFO' }
        Write-WHDLog 'Not asked in this run (GUI or -Yes). Pick them in General debloat (console menu 3 or the GUI General tab).' 'WARN'
        return
    }
    $i = 0
    foreach ($f in $found) { $i++; Write-Host ("  {0,3}. {1}" -f $i, $f.Name) }
    $a = (Read-Host '  Numbers to remove (e.g. 1,3), A = all, Enter = none').Trim()
    if (-not $a) { Write-WHDLog 'none chosen.' 'INFO'; return }
    $pick = if ($a -match '^[Aa]$') { $found } else {
        @($a -split '[,\s]+' | Where-Object { $_ -match '^\d+$' -and [int]$_ -ge 1 -and [int]$_ -le $found.Count } | Select-Object -Unique | ForEach-Object { $found[[int]$_ - 1] })
    }
    foreach ($f in $pick) { Invoke-WHDGeneralRemove -Entry $f }
}

function Show-WHDGeneralMenu {
    Write-Host ''
    Write-Host '  GENERAL (NON-AI) APPS' -ForegroundColor White
    Write-Host '  ----------------------------------------------------------------'
    $script:WHDGenCatalog = @(Get-WHDGeneralCatalog)
    $i = 0
    $foundHdr = $false
    foreach ($e in $script:WHDGenCatalog) {
        $i++
        if ($e.Found -and -not $foundHdr) {
            Write-Host '  -- Found on this PC (not made by Microsoft) --' -ForegroundColor DarkGray
            $foundHdr = $true
        }
        $state = if ($e.Found -or (Test-WHDAppPresent -Package $e.Package)) { 'present' } else { 'absent ' }
        $rec   = if ($e.Rec) { '*' } else { ' ' }
        $color = switch ($e.Risk) { 'reversible' {'Green'} 'caution' {'Yellow'} 'hard' {'Red'} }
        Write-Host ("  {0,2}.{1} " -f $i, $rec) -NoNewline
        Write-Host ("{0,-34}" -f $e.Name) -NoNewline -ForegroundColor $color
        Write-Host ("  [{0}]" -f $state)
    }
    if (-not $foundHdr) { Write-Host '  -- Found on this PC (not made by Microsoft): none --' -ForegroundColor DarkGray }
    Write-Host '  ----------------------------------------------------------------'
    Write-Host '   * = recommended for a lean debloat'
    Write-Host '   A. Remove ALL recommended (*)          P. Privacy/telemetry hardening'
    Write-Host '   D. Disable DiagTrack telemetry service  S. More privacy settings'
    Write-Host '   B. Back'
}
