#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/MainMenu.ps1   (build step 6a)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The main menu (WHD.ps1 with no other switch) and the full dry-run plan
 (WHD.ps1 -Plan). Keys as WHD Next 2.0, except where every 3.0 menu already
 uses the key (D80): X = EXECUTE on/off and S = safe mode on/off everywhere,
 so Security = SE and Theme = TH. Profiles (P) come in their own step (D78).
================================================================================
#>

$script:WHDMainItems = @(
    @{ Key = '1';  Label = 'Inventory (read-only scan)';             Hint = '[apps installed / staged, SystemApps, features, AppLocker, programs; AI flagged]' }
    @{ Key = 'D';  Label = 'Compare the two newest inventory scans'; Hint = '[what appeared, went or changed; apps WHD removed that are back]' }
    @{ Key = '2';  Label = 'AI debloat';                             Hint = '[feature-off / remove, per surface]' }
    @{ Key = '3';  Label = 'General debloat';                        Hint = '[non-AI Store apps + privacy / telemetry]' }
    @{ Key = 'M';  Label = 'More privacy settings';                  Hint = '[activity, clipboard, ads, speech, Edge - several at once]' }
    @{ Key = '4';  Label = 'App permissions';                        Hint = '[Lockdown / Balanced / Open / Custom, per app, usage]' }
    @{ Key = '5';  Label = 'Win32 programs';                         Hint = '[uninstall + block re-appearance]' }
    @{ Key = '6';  Label = 'Component store';                        Hint = '[WinSxS analyze / cleanup with DISM]' }
    @{ Key = '9';  Label = 'Firewall';                               Hint = '[IPv6, rules, allow-list, default-deny, block lists, DNS, time]' }
    @{ Key = 'SE'; Label = 'Security+';                              Hint = '[Defender, attack-surface rules, old protocols, UAC, report]' }
    @{ Key = 'W';  Label = 'Updates';                                Hint = '[update gate, Windows Update / driver / Store policies, app updaters]' }
    @{ Key = 'N';  Label = 'Devices';                                Hint = '[Bluetooth network, Wi-Fi Direct, WAN Miniports]' }
    @{ Key = 'T';  Label = 'Time & region';                          Hint = '[time zone, date and time]' }
    @{ Key = 'TH'; Label = 'Theme (optional)';                       Hint = '[ship sounds, pictures, dark mode, lock screen, sign-in sounds]' }
    @{ Key = '7';  Label = 'Create a System Restore point now' }
    @{ Key = 'U';  Label = 'Undo center';                            Hint = '[list / undo past changes, backups, other PCs'' history]' }
    @{ Key = 'V';  Label = 'Verify changes are still in place';      Hint = '[then re-apply / re-remove what came back]' }
    @{ Key = 'G';  Label = 'Update guard (alert only)';              Hint = '[checks after sign-in and daily; install, check now, report, remove]' }
    @{ Key = 'P';  Label = 'Apply a profile';                        Hint = '[minimum / average / strict / your own - many actions in one go]' }
)

function Show-WHDMainMenu {
    [CmdletBinding()]
    param()
    $st = $script:WHDState
    $info = Get-WHDEngineInfo
    Write-Host ''
    Write-Host ('  ===================== {0} {1} =====================' -f $info.Product, $info.Version) -ForegroundColor White
    Write-Host '  Provided as is, with no warranty (MIT License) - use at your own risk. Dry run first.' -ForegroundColor DarkGray
    Write-Host ('  Folder: {0}' -f $st.Root) -ForegroundColor DarkGray
    if (-not $st.IsAdmin) { Write-Host '  NOT an administrator window - scans are limited and nothing can be changed.' -ForegroundColor Yellow }
    Write-Host '  Type a key and press Enter.' -ForegroundColor DarkGray
    foreach ($i in $script:WHDMainItems) {
        if ($i['Later']) { Write-WHDMenuItem -Key $i['Key'] -Label $i['Label'] -Later -Hint $i['Hint'] }
        elseif ($i['Hint']) { Write-WHDMenuItem -Key $i['Key'] -Label $i['Label'] -Hint $i['Hint'] }
        else { Write-WHDMenuItem -Key $i['Key'] -Label $i['Label'] }
    }
    Write-Host ('   X. EXECUTE {0}    S. Safe mode {1}    Q. Quit' -f $(if ($st.Execute) { 'OFF (back to dry-run)' } else { 'ON' }), $(if ($st.SafeMode) { 'OFF' } else { 'ON' })) -ForegroundColor DarkGray
}

function Invoke-WHDMainChoice {
    # One main-menu choice. Returns $false for Q (quit).
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Choice)
    $c = $Choice.Trim()
    if (Invoke-WHDMenuCommonKey -Choice $c) { return $true }
    switch -regex ($c) {
        '^[Qq]$' { Write-WHDLog -Message 'Quit selected.'; return $false }
        '^$' { return $true }
        '^1$' { [void](Invoke-WHDInventory) }
        '^[Dd]$' { [void](Invoke-WHDInventoryCompare) }
        '^2$' { Invoke-WHDMenu -Name AI }
        '^3$' { Invoke-WHDMenu -Name General }
        '^[Mm]$' { Invoke-WHDMenu -Name Privacy }
        '^4$' { Invoke-WHDMenu -Name Permissions }
        '^5$' { Invoke-WHDMenu -Name Win32 }
        '^6$' { Invoke-WHDMenu -Name Maintenance }
        '^9$' { Invoke-WHDMenu -Name Firewall }
        '^[Ss][Ee]$' { Invoke-WHDMenu -Name Security }
        '^[Ww]$' { Invoke-WHDMenu -Name Updates }
        '^[Nn]$' { Invoke-WHDMenu -Name Devices }
        '^[Tt]$' { Invoke-WHDMenu -Name TimeRegion }
        '^[Tt][Hh]$' { Invoke-WHDMenu -Name Theme }
        '^7$' { New-WHDCheckpoint }
        '^[Uu]$' { $script:WHDUndoOpen = $null; Invoke-WHDMenu -Name Undo }
        '^[Vv]$' { Invoke-WHDVerifyAndRepair }
        '^[Gg]$' { Invoke-WHDMenu -Name Guard }
        '^[Pp]$' { Invoke-WHDMenu -Name Profiles }
        default { Write-Host '  invalid.' -ForegroundColor Yellow }
    }
    return $true
}

# ---- -Plan: the full dry-run of everything (as 2.0) --------------------------------------------------------------
function Invoke-WHDPlanStep {
    # One part of the plan; an error is written down and the plan goes on.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Title, [Parameter(Mandatory)][scriptblock]$Do)
    Write-Host ''
    Write-WHDLog -Message ('---- {0} ----' -f $Title) -Level 'DRY'
    try { & $Do } catch { Write-WHDLog -Message ('That part of the plan stopped on an error: {0}' -f $_.Exception.Message) -Level 'ERR' }
}
