#requires -Version 7.6
<#
 WHD Next 3.0  -  Public/Invoke-WHDMenu.ps1
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
 Opens one terminal menu: a module's (build step 5), the Undo center or the
 main menu (build step 6a). Every menu has X = EXECUTE on/off, S = safe mode
 on/off (D14) and B = back (Q = quit in the main menu). An error in one item
 is shown and logged; the menu stays open.
#>
function Invoke-WHDMenu {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Security', 'Firewall', 'Updates', 'AI', 'General', 'Privacy', 'Win32', 'Devices', 'Permissions', 'Maintenance', 'TimeRegion', 'Theme', 'Undo', 'Guard', 'Profiles', 'Main')][string]$Name)
    $show = @{ Security = { Show-WHDSecurityMenu }; Firewall = { Show-WHDFirewallMenu }; Updates = { Show-WHDUpdatesMenu }; AI = { Show-WHDAiMenu }; General = { Show-WHDGeneralMenu }; Privacy = { Show-WHDPrivacyMenu }; Win32 = { Show-WHDWin32Menu }; Devices = { Show-WHDDevicesMenu }; Permissions = { Show-WHDPermissionsMenu }; Maintenance = { Show-WHDMaintenanceMenu }; TimeRegion = { Show-WHDTimeRegionMenu }; Theme = { Show-WHDThemeMenu }; Undo = { Show-WHDUndoCenterMenu }; Guard = { Show-WHDGuardMenu }; Profiles = { Show-WHDProfilesMenu }; Main = { Show-WHDMainMenu } }[$Name]
    $do = @{ Security = { param($c) Invoke-WHDSecurityChoice -Choice $c }; Firewall = { param($c) Invoke-WHDFirewallChoice -Choice $c }; Updates = { param($c) Invoke-WHDUpdatesChoice -Choice $c }; AI = { param($c) Invoke-WHDAiChoice -Choice $c }; General = { param($c) Invoke-WHDGeneralChoice -Choice $c }; Privacy = { param($c) Invoke-WHDPrivacyChoice -Choice $c }; Win32 = { param($c) Invoke-WHDWin32Choice -Choice $c }; Devices = { param($c) Invoke-WHDDevicesChoice -Choice $c }; Permissions = { param($c) Invoke-WHDPermissionsChoice -Choice $c }; Maintenance = { param($c) Invoke-WHDMaintenanceChoice -Choice $c }; TimeRegion = { param($c) Invoke-WHDTimeRegionChoice -Choice $c }; Theme = { param($c) Invoke-WHDThemeChoice -Choice $c }; Undo = { param($c) Invoke-WHDUndoCenterChoice -Choice $c }; Guard = { param($c) Invoke-WHDGuardChoice -Choice $c }; Profiles = { param($c) Invoke-WHDProfilesChoice -Choice $c }; Main = { param($c) Invoke-WHDMainChoice -Choice $c } }[$Name]
    while ($true) {
        Show-WHDMode
        try { & $show } catch { Write-WHDLog -Message ('The menu screen could not be shown completely: {0}' -f $_.Exception.Message) -Level 'WARN' }
        $choice = [string](Read-Host '  Select')
        try { if (-not (& $do $choice)) { return } }
        catch {
            # One failing item never closes the menu; the reason is on screen and in the log.
            Write-WHDLog -Message ('ERROR in "{0}": {1}' -f $choice, $_.Exception.Message) -Level 'ERR'
        }
    }
}
