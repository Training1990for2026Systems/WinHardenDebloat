<#
================================================================================
 WinHardenDebloat  -  WHD-GUI.ps1   (PowerShell + WPF front end)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 A native WPF window that drives the SAME engine modules as the menu. No
 compiler, no third-party libraries, fully offline. Self-elevates (UAC).

 DRY-RUN by default (the mode toggle is off). Tick "EXECUTE (apply changes)"
 to make real changes; each destructive action then asks Yes/No, and a System
 Restore point is made before the first change. Everything is logged, both to
 the on-screen pane and to logs\.

   powershell -ExecutionPolicy Bypass -File .\WHD-GUI.ps1
================================================================================
#>
[CmdletBinding()]
param([switch]$NoElevate)
$ErrorActionPreference = 'Stop'

# WHD Classic is written for Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh).
if ($PSVersionTable.PSVersion.Major -ne 5) {
    Write-Host 'WHD Classic needs Windows PowerShell 5.1. Start it with powershell.exe (not pwsh):' -ForegroundColor Red
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\WHD-GUI.ps1' -ForegroundColor Red
    exit 1
}

function _isAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $NoElevate -and -not (_isAdmin)) {
    $psExe = (Get-Process -Id $PID).Path
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $argList = @('-ExecutionPolicy','Bypass','-NoProfile','-File', "`"$($MyInvocation.MyCommand.Path)`"", '-NoElevate')
    try { Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argList -WorkingDirectory $scriptDir; return }
    catch { Write-Host "Elevation declined: $($_.Exception.Message)" -ForegroundColor Red; return }
}

# ---- load engine + modules --------------------------------------------------
$Root = $PSScriptRoot
$script:WHDRoot    = $Root
$script:WHDExecute = $false
$script:WHDGuiMode = $true
. (Join-Path $Root 'modules\Common.ps1')
. (Join-Path $Root 'modules\Debloat-AI.ps1')
. (Join-Path $Root 'modules\Debloat-General.ps1')
. (Join-Path $Root 'modules\Permissions.ps1')
. (Join-Path $Root 'modules\Debloat-Win32.ps1')
. (Join-Path $Root 'modules\Maintenance.ps1')
. (Join-Path $Root 'modules\Firewall.ps1')
. (Join-Path $Root 'modules\Security.ps1')
. (Join-Path $Root 'modules\Updates.ps1')
. (Join-Path $Root 'modules\Devices.ps1')
. (Join-Path $Root 'modules\TimeRegion.ps1')
. (Join-Path $Root 'modules\Profiles.ps1')
try { Start-WHDTranscript } catch { $startErr = $_; Write-WHDProtectedFolderWarning; throw $startErr }   # if the WHD folder cannot be written, say why first

Add-Type -AssemblyName PresentationFramework

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinHardenDebloat" Height="740" Width="1060" WindowStartupLocation="CenterScreen"
        Background="#0F1218">
  <Window.Resources>
    <Style TargetType="Button"><Setter Property="Margin" Value="4"/><Setter Property="Padding" Value="8,4"/></Style>
    <Style TargetType="TabItem"><Setter Property="Padding" Value="10,4"/></Style>
  </Window.Resources>
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="200"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- top bar -->
    <DockPanel Grid.Row="0" LastChildFill="False" Margin="0,0,0,8">
      <TextBlock Text="WinHardenDebloat" Foreground="#E8EBF2" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
      <TextBlock x:Name="ElevTxt" Margin="14,0,0,0" VerticalAlignment="Center" Foreground="#9AA6BF"/>
      <CheckBox x:Name="ModeChk" DockPanel.Dock="Right" Content="EXECUTE (apply changes)" Foreground="#E8735B"
                FontWeight="Bold" VerticalAlignment="Center" Margin="10,0,0,0"/>
      <Button   x:Name="RpBtn"  DockPanel.Dock="Right" Content="Restore point now"/>
      <Button   x:Name="GuardRefreshBtn" DockPanel.Dock="Right" Content="Refresh update guard" ToolTip="Same as GU in the menus: refresh the guard's protected copy + task (works from every tab)"/>
    </DockPanel>

    <!-- tabs -->
    <TabControl Grid.Row="1" x:Name="Tabs" Background="#161B24">
      <TabItem Header="Firewall">
        <Grid Margin="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="250"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <!-- left: grouped actions -->
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="2">
              <TextBlock Text="IPv6" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,2,2,2"/>
              <Button x:Name="FwIpv6Btn"   Content="Suppress IPv6 (keep ::1)"/>
              <Button x:Name="FwIpv6LoBtn" Content="Suppress IPv6 + block ::1  [strict]"/>
              <Button x:Name="FwIpv6OnBtn" Content="Re-enable IPv6"/>
              <TextBlock Text="DNS" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwDnsBtn"    Content="Set Cloudflare 1.1.1.2 + DoH"/>
              <Button x:Name="FwDnsOffBtn" Content="Reset DNS to automatic (DHCP)"/>
              <TextBlock Text="Outbound / strict" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwAllowBtn"  Content="Apply outbound allow-list"/>
              <DockPanel LastChildFill="False" Margin="4,2">
                <Button x:Name="FwDenyBtn" DockPanel.Dock="Left" Content="Default-deny out" Margin="0,0,6,0"/>
                <TextBox x:Name="FwRollback" DockPanel.Dock="Right" Width="34" Text="10" VerticalContentAlignment="Center"/>
                <TextBlock DockPanel.Dock="Right" Text="min:" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="0,0,4,0"/>
              </DockPanel>
              <DockPanel LastChildFill="False" Margin="0">
                <Button x:Name="FwKeepBtn"   DockPanel.Dock="Left" Content="Confirm keep"/>
                <Button x:Name="FwRevertBtn" DockPanel.Dock="Left" Content="Revert"/>
              </DockPanel>
              <TextBlock Text="Blacklist" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwBlockIpBtn" Content="Block IP list (your profiles\blacklist-ip.txt)"/>
              <Button x:Name="FwHostsBtn"   Content="Hosts sinkhole"/>
              <Button x:Name="FwClearBlBtn" Content="Clear blacklist"/>
              <Button x:Name="FwRefreshBlBtn" Content="Refresh blocklist (incoming)"/>
              <TextBlock Text="Blocked connections" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwLogOnBtn"    Content="Firewall log ON (dropped + allowed, max size)"/>
              <Button x:Name="FwLogOffBtn"   Content="Logging OFF"/>
              <Button x:Name="FwAppClearBtn" Content="Remove all program allows"/>
              <TextBlock Text="Time sync" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwTimeCfBtn"   Content="Use time.cloudflare.com" ToolTip="UDP 123 pinned to Cloudflare + time jumps limited to 1 h (bigger corrections refused and logged)"/>
              <Button x:Name="FwTimeWinBtn"  Content="Use Windows default" ToolTip="time.windows.com + Windows default time settings (15 h jump limit, Secure Time Seeding on)"/>
              <Button x:Name="FwTimeStatBtn" Content="Time + logging status"/>
              <TextBlock Text="Time zone + date/time" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <ComboBox x:Name="FwTzCombo" Margin="2" DisplayMemberPath="Label" ToolTip="* = common US zones; the rest is every Windows time zone"/>
              <Button x:Name="FwTzSetBtn" Content="Set time zone" ToolTip="Journaled; Verify / the update guard put it back if something changes it"/>
              <TextBox x:Name="FwDateBox" Margin="2" ToolTip="Local date and time as yyyy-MM-dd HH:mm"/>
              <Button x:Name="FwDateSetBtn" Content="Set date/time" ToolTip="Automatic time sync stays on"/>
              <TextBlock Text="Policy files" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="FwApplyBtn"  Content="Apply baseline profile"/>
              <Button x:Name="FwExportBtn" Content="Export (json + .wfw)"/>
              <Button x:Name="FwImportBtn" Content="Import policy..."/>
              <Button x:Name="FwResetBtn"  Content="Reset to Windows defaults"/>
              <Button x:Name="FwWipeBtn"   Content="Wipe ALL rules (empty slate)"/>
            </StackPanel>
          </ScrollViewer>
          <!-- right: status + rule grid -->
          <DockPanel Grid.Column="1" Margin="8,0,0,0">
            <Border DockPanel.Dock="Top" Background="#0B0E13" Padding="8" Margin="0,0,0,6" CornerRadius="3">
              <TextBlock x:Name="FwStatus" Foreground="#C9D3E5" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"/>
            </Border>
            <TabControl x:Name="FwSubTabs" Background="#161B24">
              <TabItem Header="Rules">
                <DockPanel Margin="2">
            <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4">
              <Button   x:Name="FwRulesBtn"  DockPanel.Dock="Right" Content="Refresh rules"/>
              <CheckBox x:Name="FwCustomChk" DockPanel.Dock="Right" Content="Custom only" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="6,0,8,0"/>
              <TextBlock DockPanel.Dock="Left" Text="filter:" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="0,0,4,0"/>
              <TextBox  x:Name="FwFilter" VerticalContentAlignment="Center"/>
            </DockPanel>
            <DataGrid x:Name="FwGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                      Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                      HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                      AlternatingRowBackground="#11151C" BorderBrush="#22303C">
              <DataGrid.Columns>
                <DataGridTextColumn Header="Dir"      Binding="{Binding Dir}"        Width="66"/>
                <DataGridTextColumn Header="Action"   Binding="{Binding Action}"     Width="56"/>
                <DataGridTextColumn Header="On"       Binding="{Binding Enabled}"    Width="44"/>
                <DataGridTextColumn Header="Proto"    Binding="{Binding Protocol}"   Width="54"/>
                <DataGridTextColumn Header="LPort"    Binding="{Binding LocalPort}"  Width="54"/>
                <DataGridTextColumn Header="RPort"    Binding="{Binding RemotePort}" Width="54"/>
                <DataGridTextColumn Header="Remote IP" Binding="{Binding RemoteIP}"  Width="130"/>
                <DataGridTextColumn Header="Name"     Binding="{Binding DisplayName}" Width="*"/>
                <DataGridTextColumn Header="Group"    Binding="{Binding Group}"      Width="150"/>
              </DataGrid.Columns>
            </DataGrid>
                </DockPanel>
              </TabItem>
              <TabItem Header="Blocked connections">
                <DockPanel Margin="2">
                  <DockPanel DockPanel.Dock="Top" Margin="0,0,0,4" LastChildFill="False">
                    <TextBlock Text="hours:" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="0,0,4,0"/>
                    <TextBox  x:Name="FwBlkHours" Width="40" Text="24" VerticalContentAlignment="Center"/>
                    <CheckBox x:Name="FwBlkInChk" Content="include inbound" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="8,0,4,0"/>
                    <Button   x:Name="FwBlkLoadBtn"  Content="Load"/>
                    <Button   x:Name="FwBlkAllowBtn" Content="Allow selected rows (that program, that port, outbound)"/>
                  </DockPanel>
                  <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="0,0,0,4" TextWrapping="Wrap"
                             Text="Needs logging ON. Grouped by program + protocol + port; rows that can be allowed come first (column 'Can allow'). Select one or several rows (Ctrl or Shift + click) - one question for all of them. svchost/System (Windows services), inbound rows and programs that have closed cannot be allowed from here. With the update gate on PROGRAMS an allow works at once; with the gate CLOSED it is saved switched off until the gate is set to PROGRAMS or OPEN."/>
                  <DataGrid x:Name="FwBlkGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                            SelectionMode="Extended" Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                            HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                            AlternatingRowBackground="#11151C" BorderBrush="#22303C">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Count"     Binding="{Binding Count}"      Width="50"/>
                      <DataGridTextColumn Header="Last seen" Binding="{Binding Last, StringFormat='MM-dd HH:mm:ss'}" Width="100"/>
                      <DataGridTextColumn Header="Dir"       Binding="{Binding Direction}"  Width="62"/>
                      <DataGridTextColumn Header="Proto"     Binding="{Binding Protocol}"   Width="46"/>
                      <DataGridTextColumn Header="Port"      Binding="{Binding RemotePort}" Width="50"/>
                      <DataGridTextColumn Header="Name"      Binding="{Binding Exe}"        Width="130"/>
                      <DataGridTextColumn Header="Can allow" Binding="{Binding StateText}"  Width="150"/>
                      <DataGridTextColumn Header="Program"   Binding="{Binding Program}"    Width="*"/>
                      <DataGridTextColumn Header="Addresses" Binding="{Binding Addresses}"  Width="190"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </DockPanel>
              </TabItem>
            </TabControl>
          </DockPanel>
        </Grid>
      </TabItem>

      <TabItem Header="Updates">
        <Grid Margin="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="270"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="2">
              <Button x:Name="UpdStatusBtn" Content="Updates status (read-only)" FontWeight="Bold"/>
              <TextBlock Text="Update gate" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="UpdGateCloseBtn" Content="CLOSE gate (Defender + DoH only)" ToolTip="Outbound default-deny; only Microsoft Defender and DNS-over-HTTPS may use HTTP/HTTPS. Windows Update, Store, drivers, app updaters, browsers, the programs you allowed and other apps are offline."/>
              <Button x:Name="UpdGateProgBtn"  Content="PROGRAMS gate (+ programs you allowed)" ToolTip="Outbound default-deny; only Microsoft Defender, DNS-over-HTTPS and the programs you allowed (Firewall tab, Blocked connections) may go out. Windows Update, Store, drivers and app updaters stay offline."/>
              <Button x:Name="UpdGateOpenBtn"  Content="OPEN gate (let updates in)" ToolTip="Puts back every rule the gate switched off; stays open until you change it."/>
              <Button x:Name="UpdDefenderBtn"  Content="Defender: update definitions now"/>
              <TextBlock Text="Policies (Home: tried + verified)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="UpdWuBtn"      Content="Windows Update: no auto updates"/>
              <Button x:Name="UpdDrvBtn"     Content="Drivers: Device Installation = No"/>
              <Button x:Name="UpdDrvPolBtn"  Content="Drivers: 'don't include drivers' policy"/>
              <Button x:Name="UpdStoreBtn"   Content="Store: auto app updates off"/>
              <Button x:Name="UpdAllPolBtn"  Content="All four policies"/>
              <TextBlock Text="App self-updaters" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="UpdEdgeBtn"    Content="Edge Update off"/>
            </StackPanel>
          </ScrollViewer>
          <DockPanel Grid.Column="1" Margin="8,0,0,0">
            <Border DockPanel.Dock="Top" Background="#0B0E13" Padding="8" Margin="0,0,0,6" CornerRadius="3">
              <TextBlock x:Name="UpdStatus" Foreground="#C9D3E5" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" Text="Update gate: ..."/>
            </Border>
            <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="2,0,2,4" TextWrapping="Wrap"
                       Text="App self-updaters found on this PC (non-Windows scheduled tasks and services named update / updater / maintenance). Select (Ctrl/Shift for several) and turn off. Journaled - Undo center puts them back."/>
            <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,4,0,0">
              <Button x:Name="UpdScanBtn"   Content="Scan"/>
              <Button x:Name="UpdOffSelBtn" Content="Turn off selected"/>
            </StackPanel>
            <ListBox x:Name="UpdList" SelectionMode="Extended" Background="#0F1218" Foreground="#E8EBF2" FontFamily="Consolas" FontSize="11"/>
          </DockPanel>
        </Grid>
      </TabItem>

      <TabItem Header="Security+">
        <Grid Margin="6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="270"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel Margin="2">
              <Button x:Name="SecReportBtn" Content="Security report (read-only)" FontWeight="Bold"/>
              <TextBlock Text="Defender" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecPuaBtn"      Content="Block unwanted apps (PUA): ON"/>
              <Button x:Name="SecNetAuditBtn" Content="Network protection: AUDIT"/>
              <Button x:Name="SecNetBlockBtn" Content="Network protection: BLOCK"/>
              <Button x:Name="SecCfaAuditBtn" Content="Ransomware folder protection: AUDIT"/>
              <Button x:Name="SecCfaBlockBtn" Content="Ransomware folder protection: BLOCK"/>
              <TextBlock Text="Attack-surface rules (start in AUDIT)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecAsrStdBtn"     Content="Microsoft standard 3"/>
              <Button x:Name="SecAsrScrBtn"     Content="Script + download rules"/>
              <Button x:Name="SecAsrOffBtn"     Content="Office / Adobe / email rules"/>
              <Button x:Name="SecAsrPromoteBtn" Content="Switch audited rules to BLOCK"/>
              <TextBlock Text="Old network protocols (turn off)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecLlmnrBtn"    Content="LLMNR"/>
              <Button x:Name="SecNetbiosBtn"  Content="NetBIOS over TCP/IP"/>
              <Button x:Name="SecWpadBtn"     Content="WPAD proxy auto-discovery"/>
              <Button x:Name="SecRaBtn"       Content="Remote Assistance"/>
              <Button x:Name="SecProtoAllBtn" Content="All four"/>
              <TextBlock Text="Network services (turn off; restart after)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecSvcFileBtn"  Content="Workstation + Server"/>
              <Button x:Name="SecSvcSmbBtn"   Content="SMB 1/2/3 protocol"/>
              <Button x:Name="SecSvcDialBtn"  Content="Dial-up + built-in VPN"/>
              <Button x:Name="SecSvcIpsecBtn" Content="IPsec VPN keying"/>
              <Button x:Name="SecSvcProxyBtn" Content="Proxy auto-detect (Settings switch only)"/>
              <Button x:Name="SecSvcFaxBtn"   Content="Fax + Phone service"/>
              <Button x:Name="SecSvcAllBtn"   Content="All safe ones (not the WinHTTP service)"/>
              <Button x:Name="SecSvcProxySvcBtn" Content="WinHTTP proxy SERVICE off (test: broke Wi-Fi)" Foreground="#E8735B" ToolTip="Test only: in testing this stopped Wi-Fi from connecting after a restart. Undo: Undo center, then restart."/>
              <TextBlock Text="Devices (network adapters)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="DevBtBtn"     Content="Bluetooth network part off"/>
              <Button x:Name="DevWfdBtn"    Content="Wi-Fi Direct adapters off + block"/>
              <Button x:Name="DevWanBtn"    Content="WAN Miniports: block + remove"/>
              <Button x:Name="DevStatusBtn" Content="Devices status"/>
              <TextBlock Text="Account" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecUacBtn" Content="UAC: Always notify"/>
              <Button x:Name="SecPwBtn"  Content="Password + lockout rules" ToolTip="Local accounts: 14 chars min, remember 5, never expire, lock after 3 bad tries for 10 min"/>
              <TextBlock Text="Update guard (alert only)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,8,2,2"/>
              <Button x:Name="SecGuardInstBtn" Content="Install / refresh guard" ToolTip="Scheduled task 10 min after sign-in; checks WHD changes + apps after Windows updates; opens a report only if something changed"/>
              <Button x:Name="SecGuardRunBtn"  Content="Run the check now"/>
              <Button x:Name="SecGuardOpenBtn" Content="Open the last report"/>
              <Button x:Name="SecGuardDelBtn"  Content="Remove guard"/>
            </StackPanel>
          </ScrollViewer>
          <DockPanel Grid.Column="1" Margin="8,0,0,0">
            <Border DockPanel.Dock="Top" Background="#0B0E13" Padding="8" Margin="0,0,0,6" CornerRadius="3">
              <TextBlock x:Name="SecStatus" Foreground="#C9D3E5" FontFamily="Consolas" FontSize="12" TextWrapping="Wrap"
                         Text="Press 'Security report' for memory integrity, LSA protection, Secure Boot, UAC, password/lockout, Defender and protocol status (shown in the log below)."/>
            </Border>
            <TabControl Background="#161B24">
              <TabItem Header="ASR rules">
                <DockPanel Margin="2">
                  <Button DockPanel.Dock="Top" x:Name="SecAsrLoadBtn" Content="Refresh" HorizontalAlignment="Left"/>
                  <DataGrid x:Name="SecAsrGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                            Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                            HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                            AlternatingRowBackground="#11151C" BorderBrush="#22303C">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="State" Binding="{Binding Action}" Width="60"/>
                      <DataGridTextColumn Header="Group" Binding="{Binding Group}"  Width="170"/>
                      <DataGridTextColumn Header="Rule"  Binding="{Binding Name}"   Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </DockPanel>
              </TabItem>
              <TabItem Header="What was caught (7 days)">
                <DockPanel Margin="2">
                  <Button DockPanel.Dock="Top" x:Name="SecEvLoadBtn" Content="Load" HorizontalAlignment="Left"/>
                  <DataGrid x:Name="SecEvGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                            Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                            HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                            AlternatingRowBackground="#11151C" BorderBrush="#22303C">
                    <DataGrid.Columns>
                      <DataGridTextColumn Header="Time"    Binding="{Binding Time, StringFormat='MM-dd HH:mm'}" Width="85"/>
                      <DataGridTextColumn Header="Type"    Binding="{Binding Type}"    Width="95"/>
                      <DataGridTextColumn Header="Rule"    Binding="{Binding Rule}"    Width="220"/>
                      <DataGridTextColumn Header="Program" Binding="{Binding Program}" Width="*"/>
                      <DataGridTextColumn Header="Target"  Binding="{Binding Target}"  Width="*"/>
                    </DataGrid.Columns>
                  </DataGrid>
                </DockPanel>
              </TabItem>
            </TabControl>
          </DockPanel>
        </Grid>
      </TabItem>

      <TabItem Header="AI">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
            <Button x:Name="AiSelRecBtn"  Content="Select recommended (*)" ToolTip="Selects every item marked * (reversible, and it has an action). Notepad, Paint, Photos and the OS AI platform are never in it."/>
            <Button x:Name="AiFeatureBtn" Content="Feature-off selected" ToolTip="Sets the off-switch of each selected item; the apps stay. One question for the whole selection."/>
            <Button x:Name="AiRemoveBtn"  Content="Remove selected (+ off-switch)" ToolTip="Removes each selected app AND sets its off-switch; an item that cannot be removed is turned OFF. One question for the whole selection."/>
            <Button x:Name="AiStoreBtn"   Content="Store suppression"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="2,2,2,6" TextWrapping="Wrap"
                     Text="Select one or more AI surfaces (Ctrl or Shift + click), then choose an action. * = recommended. Policy-only entries show their current state in brackets. One question for the whole selection."/>
          <ListBox x:Name="AiList" SelectionMode="Extended" Background="#0F1218" Foreground="#E8EBF2"/>
        </DockPanel>
      </TabItem>

      <TabItem Header="General">
        <DockPanel Margin="6">
          <DockPanel DockPanel.Dock="Bottom" Height="170" Margin="0,8,0,0">
            <TextBlock DockPanel.Dock="Top" Text="More privacy settings  (select one or more, then Apply - state shown in brackets)" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,0,2,4"/>
            <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
              <Button x:Name="PrivAllBtn"     Content="Select all"/>
              <Button x:Name="PrivApplyBtn"   Content="Apply selected privacy settings"/>
              <Button x:Name="PrivRefreshBtn" Content="Refresh"/>
            </StackPanel>
            <ListBox x:Name="PrivList" SelectionMode="Extended" Background="#0F1218" Foreground="#E8EBF2"/>
          </DockPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
            <Button x:Name="GenRemoveBtn"  Content="Remove selected"/>
            <Button x:Name="GenRecBtn"     Content="Remove recommended (*)" ToolTip="Removes every app marked *. One question for all of them."/>
            <Button x:Name="GenPrivBtn"    Content="Privacy hardening"/>
            <Button x:Name="GenDiagBtn"    Content="Disable DiagTrack"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="2,2,2,6" TextWrapping="Wrap" Text="Curated non-AI Store apps, plus the non-Microsoft apps found on this PC (not reviewed). Select one or more (Ctrl or Shift + click). * = recommended. One question for the whole selection."/>
          <ListBox x:Name="GenList" SelectionMode="Extended" Background="#0F1218" Foreground="#E8EBF2"/>
        </DockPanel>
      </TabItem>

      <TabItem Header="Permissions">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Foreground="#9AA6BF" Margin="2,2,2,8" Text="Set the global App-permission profile (Privacy and security -> App permissions)."/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="PermPolicyLockBtn" Content="Lock (policy; cam/mic/radios/location off, not locked)" FontWeight="Bold"/>
              <Button x:Name="PermLockBtn" Content="Lockdown (deny all)"/>
              <Button x:Name="PermBalBtn"  Content="Balanced"/>
              <Button x:Name="PermOpenBtn" Content="Open (reset to Allow)"/>
            </StackPanel>
          </StackPanel>
          <TabControl Margin="0,8,0,0" Background="#161B24">
            <TabItem Header="Usage history (camera / mic / location)">
              <DockPanel Margin="2">
                <DockPanel DockPanel.Dock="Top" LastChildFill="False" Margin="0,0,0,4">
                  <Button x:Name="UsageLoadBtn" Content="Load"/>
                  <TextBlock Foreground="#9AA6BF" VerticalAlignment="Center" Margin="8,0,0,0" Text="Last use per app for this user. Read-only. 'In use' = using it right now."/>
                </DockPanel>
                <DataGrid x:Name="UsageGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                          Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                          HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                          AlternatingRowBackground="#11151C" BorderBrush="#22303C">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="What"         Binding="{Binding Capability}" Width="90"/>
                    <DataGridTextColumn Header="App"          Binding="{Binding App}"        Width="*"/>
                    <DataGridTextColumn Header="Type"         Binding="{Binding Type}"       Width="60"/>
                    <DataGridTextColumn Header="Last started" Binding="{Binding LastStart, StringFormat='yyyy-MM-dd HH:mm'}" Width="120"/>
                    <DataGridTextColumn Header="Last stopped" Binding="{Binding LastStop, StringFormat='yyyy-MM-dd HH:mm'}"  Width="120"/>
                    <DataGridTextColumn Header="In use"       Binding="{Binding InUse}"      Width="55"/>
                    <DataGridTextColumn Header="Permission"   Binding="{Binding Permission}" Width="75"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
            <TabItem Header="Per-app (Store apps)">
              <DockPanel Margin="2">
                <DockPanel DockPanel.Dock="Top" LastChildFill="False" Margin="0,0,0,4">
                  <TextBlock Text="permission:" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="0,0,4,0"/>
                  <ComboBox  x:Name="PerAppCap" Width="190" DisplayMemberPath="Name" VerticalContentAlignment="Center"/>
                  <TextBlock x:Name="PerAppGlobal" Foreground="#E8B35B" VerticalAlignment="Center" Margin="10,0,10,0"/>
                  <Button    x:Name="PerAppAllowBtn" Content="Allow selected"/>
                  <Button    x:Name="PerAppDenyBtn"  Content="Deny selected"/>
                </DockPanel>
                <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="0,0,0,4" TextWrapping="Wrap"
                           Text="Store apps only (desktop programs share one switch in Settings). The global switch above still wins: if it is Deny, no app gets access."/>
                <DataGrid x:Name="PerAppGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                          SelectionMode="Extended" Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                          HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                          AlternatingRowBackground="#11151C" BorderBrush="#22303C">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="App"       Binding="{Binding App}"       Width="*"/>
                    <DataGridTextColumn Header="Installed" Binding="{Binding Installed}" Width="65"/>
                    <DataGridTextColumn Header="Setting"   Binding="{Binding Value}"     Width="70"/>
                    <DataGridTextColumn Header="Package family" Binding="{Binding Pfn}" Width="260"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </TabItem>
          </TabControl>
        </DockPanel>
      </TabItem>

      <TabItem Header="Win32">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
            <Button x:Name="W32UninstBtn" Content="Uninstall selected"/>
            <Button x:Name="W32RefreshBtn" Content="Refresh"/>
            <TextBox x:Name="W32Name" Width="180" Margin="12,4,4,4" VerticalContentAlignment="Center"/>
            <Button x:Name="W32FindBtn"  Content="Find"/>
            <Button x:Name="W32RemAllBtn" Content="Remove everywhere"/>
            <Button x:Name="W32BlockBtn" Content="Block .exe"/>
          </StackPanel>
          <TextBlock DockPanel.Dock="Top" Foreground="#9AA6BF" Margin="2,2,2,6" Text="Traditional desktop programs. Protected entries (Edge/WebView2/servicing) are refused."/>
          <ListBox x:Name="W32List" SelectionMode="Extended" Background="#0F1218" Foreground="#E8EBF2"/>
        </DockPanel>
      </TabItem>

      <TabItem Header="Component store">
        <StackPanel Margin="10">
          <TextBlock Foreground="#9AA6BF" Margin="2,2,2,8" TextWrapping="Wrap"
                     Text="Reclaim space the supported way (DISM). Never hand-deletes WinSxS."/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="CsAnalyzeBtn" Content="Analyze (read-only)"/>
            <Button x:Name="CsCleanBtn"   Content="Clean up"/>
            <Button x:Name="CsResetBtn"   Content="Clean up + ResetBase"/>
          </StackPanel>
        </StackPanel>
      </TabItem>

      <TabItem Header="Profiles">
        <StackPanel Margin="10">
          <TextBlock Foreground="#9AA6BF" Margin="2,2,2,8" TextWrapping="Wrap"
                     Text="Apply a whole profile at once (respects the mode toggle). Great for re-imaging."/>
          <StackPanel Orientation="Horizontal">
            <Button x:Name="ProfLeanBtn"   Content="Apply lean.json"/>
            <Button x:Name="ProfPickBtn"   Content="Apply profile..."/>
            <Button x:Name="ProfExportBtn" Content="Export starter profile"/>
          </StackPanel>
        </StackPanel>
      </TabItem>

      <TabItem Header="Inventory / Undo">
        <DockPanel Margin="6">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Foreground="#9AA6BF" Margin="2,2,2,4" TextWrapping="Wrap"
                       Text="Inventory is read-only (CSVs + REPORT.txt under inventory\). Each scan is compared with the previous one automatically."/>
            <StackPanel Orientation="Horizontal">
              <Button x:Name="InvBtn"     Content="Run inventory"/>
              <Button x:Name="InvDiffBtn" Content="Compare last two scans"/>
              <Button x:Name="VerAllBtn"  Content="Verify all changes still in place"/>
              <Button x:Name="ReRemoveBtn" Content="Re-remove apps that came back"/>
              <Button x:Name="ReApplyBtn"  Content="Re-apply settings that changed back"/>
              <Button x:Name="UndoArchiveBtn" Content="Archive other-PC history" ToolTip="Moves history made on another PC / a previous Windows install to archive\other-pcs\ (nothing deleted) and tags this PC's sessions"/>
            </StackPanel>
            <TextBlock Text="Undo center" Foreground="#7CC4FF" FontWeight="Bold" Margin="2,10,2,2"/>
            <TextBlock Foreground="#9AA6BF" Margin="2,0,2,4" TextWrapping="Wrap"
                       Text="auto = put back automatically (exact previous value)   manual = see hint in the log   Older sessions (from before the change journal) only have .reg / firewall / hosts backups."/>
            <DockPanel Margin="0,2,0,4">
              <TextBlock DockPanel.Dock="Left" Text="Session:" Foreground="#9AA6BF" VerticalAlignment="Center" Margin="2,0,6,0"/>
              <Button   DockPanel.Dock="Right" x:Name="UndoRefreshBtn" Content="Refresh"/>
              <ComboBox x:Name="UndoSession" DisplayMemberPath="Label" VerticalContentAlignment="Center"/>
            </DockPanel>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal">
            <Button x:Name="UndoSelBtn"   Content="Undo selected"/>
            <Button x:Name="UndoAllBtn"   Content="Undo whole session (auto)"/>
            <Button x:Name="UndoFwBtn"    Content="Restore firewall backup"/>
            <Button x:Name="UndoHostsBtn" Content="Restore hosts backup"/>
            <Button x:Name="UndoRegBtn"   Content="Import .reg backups"/>
            <Button x:Name="VerSessBtn"   Content="Verify session"/>
          </StackPanel>
          <DataGrid x:Name="UndoGrid" AutoGenerateColumns="False" IsReadOnly="True" CanUserSortColumns="True"
                    SelectionMode="Extended" Background="#0B0E13" Foreground="#C9D3E5" GridLinesVisibility="Horizontal"
                    HeadersVisibility="Column" FontSize="11" RowHeight="18" RowBackground="#0B0E13"
                    AlternatingRowBackground="#11151C" BorderBrush="#22303C">
            <DataGrid.Columns>
              <DataGridTextColumn Header="Time"   Binding="{Binding Time}"     Width="130"/>
              <DataGridTextColumn Header="Kind"   Binding="{Binding Kind}"     Width="80"/>
              <DataGridTextColumn Header="Undo"   Binding="{Binding UndoMode}" Width="60"/>
              <DataGridTextColumn Header="Undone" Binding="{Binding Undone}"   Width="60"/>
              <DataGridTextColumn Header="Change" Binding="{Binding Description}" Width="*"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>
    </TabControl>

    <!-- log -->
    <TextBox Grid.Row="2" x:Name="LogBox" Margin="0,8,0,0" IsReadOnly="True" FontFamily="Consolas"
             FontSize="12" Background="#0B0E13" Foreground="#C9D3E5" VerticalScrollBarVisibility="Auto"
             TextWrapping="NoWrap" HorizontalScrollBarVisibility="Auto"/>

    <!-- status -->
    <DockPanel Grid.Row="3" Margin="2,6,0,0" LastChildFill="True">
      <ProgressBar x:Name="BusyBar" DockPanel.Dock="Right" Width="240" Height="12" Minimum="0" Maximum="100" Value="0" Margin="10,0,2,0" Visibility="Collapsed"/>
      <TextBlock x:Name="StatusTxt" Foreground="#7CC4FF"/>
    </DockPanel>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)
# Small or scaled screens (1366x768, full HD at 150 %): never larger than the work area.
try {
    $whdWorkArea = [System.Windows.SystemParameters]::WorkArea
    if ($win.Height -gt $whdWorkArea.Height) { $win.Height = $whdWorkArea.Height }
    if ($win.Width  -gt $whdWorkArea.Width)  { $win.Width  = $whdWorkArea.Width }
} catch { }

# ---- grab controls ----------------------------------------------------------
foreach ($n in 'ElevTxt','ModeChk','RpBtn','GuardRefreshBtn','ReRemoveBtn','ReApplyBtn','AiList','AiFeatureBtn','AiRemoveBtn','AiStoreBtn',
                'GenList','GenRemoveBtn','GenRecBtn','GenPrivBtn','GenDiagBtn','AiSelRecBtn','PrivAllBtn','BusyBar',
                'PermPolicyLockBtn','PermLockBtn','PermBalBtn','PermOpenBtn','SecSvcFileBtn','SecSvcSmbBtn','SecSvcDialBtn','SecSvcIpsecBtn','SecSvcProxyBtn','SecSvcFaxBtn','SecSvcAllBtn','SecSvcProxySvcBtn','DevBtBtn','DevWfdBtn','DevWanBtn','DevStatusBtn',
                'W32List','W32UninstBtn','W32RefreshBtn','W32Name','W32FindBtn','W32RemAllBtn','W32BlockBtn',
                'CsAnalyzeBtn','CsCleanBtn','CsResetBtn',
                'ProfLeanBtn','ProfPickBtn','ProfExportBtn','InvBtn','LogBox','StatusTxt',
                'FwIpv6Btn','FwIpv6LoBtn','FwIpv6OnBtn','FwDnsBtn','FwDnsOffBtn','FwAllowBtn',
                'FwDenyBtn','FwRollback','FwKeepBtn','FwRevertBtn','FwBlockIpBtn','FwHostsBtn','FwClearBlBtn',
                'FwApplyBtn','FwExportBtn','FwImportBtn','FwResetBtn','FwWipeBtn',
                'FwStatus','FwRulesBtn','FwCustomChk','FwFilter','FwGrid',
                'FwRefreshBlBtn','FwLogOnBtn','FwLogOffBtn','FwAppClearBtn','FwTimeCfBtn','FwTimeWinBtn','FwTimeStatBtn','FwTzCombo','FwTzSetBtn','FwDateBox','FwDateSetBtn',
                'FwBlkHours','FwBlkInChk','FwBlkLoadBtn','FwBlkAllowBtn','FwBlkGrid',
                'SecReportBtn','SecPuaBtn','SecNetAuditBtn','SecNetBlockBtn','SecCfaAuditBtn','SecCfaBlockBtn',
                'SecAsrStdBtn','SecAsrScrBtn','SecAsrOffBtn','SecAsrPromoteBtn','SecLlmnrBtn','SecNetbiosBtn','SecWpadBtn',
                'SecRaBtn','SecProtoAllBtn','SecUacBtn','SecPwBtn','SecGuardInstBtn','SecGuardRunBtn','SecGuardOpenBtn','SecGuardDelBtn','SecStatus','SecAsrLoadBtn','SecAsrGrid','SecEvLoadBtn','SecEvGrid',
                'UpdStatusBtn','UpdGateCloseBtn','UpdGateProgBtn','UpdGateOpenBtn','UpdDefenderBtn','UpdWuBtn','UpdDrvBtn','UpdDrvPolBtn','UpdStoreBtn','UpdAllPolBtn','UpdEdgeBtn','UpdStatus','UpdScanBtn','UpdOffSelBtn','UpdList',
                'PrivApplyBtn','PrivRefreshBtn','PrivList','UsageLoadBtn','UsageGrid',
                'PerAppCap','PerAppGlobal','PerAppAllowBtn','PerAppDenyBtn','PerAppGrid',
                'InvDiffBtn','VerAllBtn','UndoArchiveBtn','UndoSession','UndoRefreshBtn','UndoGrid',
                'UndoSelBtn','UndoAllBtn','UndoFwBtn','UndoHostsBtn','UndoRegBtn','VerSessBtn') {
    Set-Variable -Name $n -Value $win.FindName($n) -Scope Script
}

# ---- log sink -> the on-screen pane (with a render flush so it updates live) -
$script:WHDLogSink = {
    param($line, $level)
    $LogBox.AppendText($line + "`r`n")
    $LogBox.ScrollToEnd()
    $LogBox.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
}
# ---- confirm strategy -> a Yes/No dialog ------------------------------------
$script:WHDConfirm = {
    param($msg)
    ([System.Windows.MessageBox]::Show($win, ($msg + "`n`nProceed?"), 'WinHardenDebloat - confirm', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)) -eq 'Yes'
}

function Set-WHDStatus { param($t) $StatusTxt.Text = $t }
# ---- progress bar beside the status line (slow loops, e.g. the firewall wipe) -
# The engine calls this through Write-WHDProgressStep. It never throws and does nothing when the bar is not
# there or the call does not come from the window's own thread; the bar hides itself at the last step, and
# every action hides it again when it ends (Reset-WHDBusyBar), also after an error.
$script:WHDProgressHook = {
    param($Activity, $Done, $Total)
    try {
        if (-not $BusyBar -or -not $BusyBar.Dispatcher.CheckAccess()) { return }
        $BusyBar.Visibility = [System.Windows.Visibility]::Visible
        $BusyBar.Value = Get-GuiProgressPercent -Done $Done -Total $Total
        $StatusTxt.Text = ('{0}: {1} of {2}' -f $Activity, $Done, $Total)
        if ([int]$Done -ge [int]$Total) { $BusyBar.Visibility = [System.Windows.Visibility]::Collapsed; $BusyBar.Value = 0 }
        $BusyBar.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    } catch { }
}
function Get-GuiProgressPercent {
    param($Done, $Total)
    $whdPcD = 0; $whdPcT = 0
    try { $whdPcD = [int]$Done; $whdPcT = [int]$Total } catch { return 0 }
    return [int][math]::Max(0, [math]::Min(100, [math]::Floor(100 * $whdPcD / [math]::Max(1, $whdPcT))))
}
function Reset-WHDBusyBar { try { if ($BusyBar) { $BusyBar.Visibility = [System.Windows.Visibility]::Collapsed; $BusyBar.Value = 0 } } catch { } }

# run an action with a header, busy-guard and error catch
function Invoke-GuiAction {
    param([string]$Title, [scriptblock]$Body)
    Set-WHDStatus ("Working: " + $Title + " ...")
    Write-WHDLog ("=== " + $Title + " (" + $(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'}) + ") ===") 'ACT'
    try { & $Body } catch { Write-WHDLog ("error: " + $_.Exception.Message) 'ERR' }
    Reset-WHDBusyBar
    Set-WHDStatus ("Ready. " + $Title + " finished.")
}

# ---- several items at once: ONE question, with the plan IN the question -------
# The engine's batch functions (Invoke-WHDAiBatch, Invoke-WHDGeneralBatch, Add-WHDProgramAllows) write their
# plan to the log and then ask ONCE through Confirm-WHDProceed. The log box cannot be scrolled while a dialog
# is open, so for these actions the dialog itself lists what will be done: for the one action the confirm
# strategy is a dialog that shows the plan above the engine's question. Nothing is asked twice - this dialog IS
# the batch's own single question (after it the batch runs its items without asking), in DRY-RUN nothing is
# asked, and when the batch finds nothing to do no dialog appears at all.
# $script:WHDGuiPlanYes tells the caller afterwards whether the question was answered Yes (= something may
# have changed); after a preview or a No the lists are left as they are, so the selection is kept.
$script:WHDGuiPlan = ''
$script:WHDGuiPlanYes = $false
function Invoke-GuiPlanAction {
    param([string]$Title, [string]$PlanText, [scriptblock]$Body)
    $whdGpPrev = $script:WHDConfirm
    $script:WHDGuiPlan = "$PlanText"
    $script:WHDGuiPlanYes = $false
    $script:WHDConfirm = {
        param($msg)
        $whdGpYes = ([System.Windows.MessageBox]::Show($win, ($script:WHDGuiPlan + "`n`n" + $msg + "`n`nProceed?"), 'WinHardenDebloat - confirm', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)) -eq 'Yes'
        if ($whdGpYes) { $script:WHDGuiPlanYes = $true }
        return $whdGpYes
    }
    try { Invoke-GuiAction $Title $Body }
    finally { $script:WHDConfirm = $whdGpPrev; $script:WHDGuiPlan = '' }
}
# The text of such a plan: a head line, one line per item (at most $Max; the rest follows in one run-on line, so every item is named), closing lines.
function Get-GuiPlanText {
    param([string]$Head, [string[]]$Lines, [string[]]$Foot = @(), [int]$Max = 16)
    $whdPtAll = @($Lines | Where-Object { $_ })
    $whdPtOut = New-Object System.Collections.Generic.List[string]
    $whdPtOut.Add($Head); $whdPtOut.Add('')
    foreach ($whdPtL in @($whdPtAll | Select-Object -First $Max)) { $whdPtOut.Add('   ' + $whdPtL) }
    if ($whdPtAll.Count -gt $Max) { $whdPtOut.Add(('   and {0} more:  {1}' -f ($whdPtAll.Count - $Max), ((@($whdPtAll | Select-Object -Skip $Max) | ForEach-Object { "$_".Trim() }) -join ';  '))) }
    foreach ($whdPtF in @($Foot | Where-Object { $_ })) { $whdPtOut.Add(''); $whdPtOut.Add($whdPtF) }
    return ($whdPtOut.ToArray() -join "`n")
}
# AI items: what the batch will do with each one (the same rule the engine uses: Get-WHDAiBatchPlan).
function Get-GuiAiPlanText {
    param([object[]]$Modules, [ValidateSet('remove','off')][string]$Action)
    $whdApLines = @(foreach ($whdApM in @($Modules | Where-Object { $_ })) {
        $whdApTxt = switch (Get-WHDAiBatchPlan -Module $whdApM -Action $Action) {
            'remove+off' { 'remove the app + set its off-switch' }
            'remove'     { 'remove the app (it has no off-switch)' }
            'off'        { if ($Action -eq 'remove') { 'turn OFF (cannot be removed)' } else { 'turn OFF' } }
            default      { if ($Action -eq 'remove') { 'skip - no action is offered for this item' } else { 'skip - this item has no off-switch' } }
        }
        ('{0}  ->  {1}' -f $whdApM.Name, $whdApTxt)
    })
    if ($Action -eq 'remove') {
        return (Get-GuiPlanText -Head 'AI items - remove + set the off-switch (an item that cannot be removed is turned OFF):' -Lines $whdApLines -Foot @(
            'Apps are removed for ALL users of the PC and their local data is deleted (undo = reinstall from the Store). Off-switches are registry values (the Undo center puts the old values back).',
            'The note of each item is in the log.'))
    }
    return (Get-GuiPlanText -Head 'AI items - feature-off (the apps stay):' -Lines $whdApLines -Foot @(
        'Off-switches are registry values (the Undo center puts the old values back).', 'The note of each item is in the log.'))
}
# General apps: the names, as the list shows them.
function Get-GuiGeneralPlanText {
    param([object[]]$Entries)
    $whdGpLines = @(foreach ($whdGpE in @($Entries | Where-Object { $_ })) {
        $whdGpName = "$($whdGpE.Name)"; if ($whdGpE.Found) { $whdGpName = '[found on this PC] ' + $whdGpName }
        if ("$($whdGpE.Risk)" -ne 'reversible') { $whdGpName += '   (caution)' }
        $whdGpName
    })
    return (Get-GuiPlanText -Head 'Remove these Store apps:' -Lines $whdGpLines -Foot @(
        "Store apps are removed for ALL users of the PC and the app's local data is deleted; undo = reinstall from the Store.",
        'The note of each app is in the log.'))
}
# Blocked connections: the lines that will get an allow rule.
function Get-GuiAllowPlanText {
    param([object[]]$Items, [string]$GateMode = '')
    $whdAlLines = @(foreach ($whdAlI in @($Items | Where-Object { $_ })) { ('{0}   {1} {2}   {3}' -f $whdAlI.Exe, $whdAlI.Protocol, $whdAlI.RemotePort, $whdAlI.Program) })
    $whdAlFoot = @('Each line allows only that program, only that protocol + remote port, to any destination, outbound. Removable in the Undo center or with "Remove all program allows".')
    if ("$GateMode" -eq 'closed') { $whdAlFoot += 'The update gate is CLOSED: a new allow is saved switched OFF until the gate is set to PROGRAMS or OPEN (Updates tab).' }
    return (Get-GuiPlanText -Head 'Allow these blocked programs out:' -Lines $whdAlLines -Foot $whdAlFoot)
}
# The engine items behind the selected rows of the AI / General list, in the order the list shows them
# (SelectedItems is in click order). Each list row is {Name, Obj, Pos}.
function Get-GuiSelectedObjs {
    param([object[]]$Rows)
    @(@($Rows | Where-Object { $_ }) | Sort-Object { [int]$_.Pos } | ForEach-Object { $_.Obj })
}
# Of the selected blocked-connection rows, the ones that can be allowed from here (State 'can').
function Select-GuiAllowable {
    param([object[]]$Rows)
    @($Rows | Where-Object { $_ -and "$($_.State)" -eq 'can' })
}

# ---- populate lists ---------------------------------------------------------
# AI/General modules are ordered-dictionaries; WPF DisplayMemberPath needs real
# properties, so wrap each as {Name, Obj}. Win32 apps are already objects.
function Update-AiList {
    $whdAiPos = 0
    $AiList.ItemsSource = @(foreach ($m in $script:WHDAiModules) {
        $lbl = $m.Name
        if ($m.PolicyOnly) { $lbl = "{0}   [{1}]" -f $m.Name, $(switch (Get-WHDRegOpsState -Ops @($m.FeatureOff)) { 'set' { 'OFF - set' } 'partly' { 'partly set' } default { 'on' } }) }
        # * marks the recommended (reversible) items, as in the console menu
        $lbl = $(if (Test-WHDAiRecommended -Module $m) { '* ' } else { '   ' }) + $lbl
        $whdAiPos++
        [pscustomobject]@{ Name = $lbl; Obj = $m; Pos = $whdAiPos }
    })
    $AiList.DisplayMemberPath = 'Name'
}
Update-AiList
# Classic 1.4: fixed list + non-Microsoft apps found on THIS PC (marked "found:")
function Update-GenList { $whdGenPos = 0; $GenList.ItemsSource = @(foreach ($e in @(Get-WHDGeneralCatalog)) { $whdGenPos++; [pscustomobject]@{ Name = ($(if ($e.Rec) { '* ' } else { '   ' }) + $(if ($e.Found) { "[found on this PC] " + $e.Name } else { $e.Name })); Obj = $e; Pos = $whdGenPos } }) }
Update-GenList
$GenList.DisplayMemberPath = 'Name'
function Update-W32List { $W32List.ItemsSource = @(Get-WHDWin32Apps); $W32List.DisplayMemberPath = 'DisplayName' }
Update-W32List

# ---- Phase 7: privacy list, usage history, per-app --------------------------
function Update-PrivList {
    $PrivList.ItemsSource = @(foreach ($it in $script:WHDPrivacyItems) {
        [pscustomobject]@{ Label = ("{0}   [{1}]" -f $it.Name, (Get-WHDRegOpsState -Ops @($it.Ops))); Obj = $it }
    })
    $PrivList.DisplayMemberPath = 'Label'
}
Update-PrivList
$PerAppCap.ItemsSource = @(foreach ($c in $script:WHDCapabilities) { [pscustomobject]@{ Name = $c.Name; Cap = $c.Cap } })
function Update-PerApp {
    $c = $PerAppCap.SelectedItem
    if (-not $c) { $PerAppGrid.ItemsSource = @(); $PerAppGlobal.Text = ''; return }
    $PerAppGlobal.Text = ("global switch: {0}" -f (Get-WHDCapabilityValue -Cap $c.Cap))
    $rows = @(Get-WHDAppPermissions -Cap $c.Cap)
    $PerAppGrid.ItemsSource = $rows
    Set-WHDStatus ("{0}: {1} Store app(s) have asked for this permission." -f $c.Name, $rows.Count)
}

# ---- mode toggle ------------------------------------------------------------
$ElevTxt.Text = if (_isAdmin) { 'elevated' } else { 'NOT elevated - changes will fail' }
$ModeChk.Add_Checked({   $script:WHDExecute = $true;  Set-WHDStatus 'EXECUTE mode - actions will change the system (with confirm).' })
$ModeChk.Add_Unchecked({ $script:WHDExecute = $false; Set-WHDStatus 'DRY-RUN mode - actions only preview.' })

# ---- handlers ---------------------------------------------------------------
$RpBtn.Add_Click({ Invoke-GuiAction 'Create restore point' { New-WHDCheckpointNow } })
$InvBtn.Add_Click({ Invoke-GuiAction 'Inventory' { & (Join-Path $script:WHDRoot 'Inventory.ps1') -NoElevate } })

# The whole selection is ONE batch with ONE question (the same engine function as the console menu: Invoke-WHDAiBatch).
# "Remove" also sets the off-switch, and turns an item OFF when it cannot be removed.
$AiSelRecBtn.Add_Click({
    $AiList.SelectedItems.Clear()
    foreach ($whdAiIt in @($AiList.Items)) { if (Test-WHDAiRecommended -Module $whdAiIt.Obj) { [void]$AiList.SelectedItems.Add($whdAiIt) } }
    Set-WHDStatus ('{0} recommended item(s) selected - now choose Feature-off or Remove.' -f $AiList.SelectedItems.Count)
})
$AiFeatureBtn.Add_Click({
    $whdAiSel = @(Get-GuiSelectedObjs -Rows @($AiList.SelectedItems))
    if (-not $whdAiSel.Count) { Set-WHDStatus 'Select one or more AI items first.'; return }
    Invoke-GuiPlanAction 'AI feature-off' (Get-GuiAiPlanText -Modules $whdAiSel -Action off) { Invoke-WHDAiBatch -Modules $whdAiSel -Action off }
    if ($script:WHDGuiPlanYes) { Update-AiList }
})
$AiRemoveBtn.Add_Click({
    $whdAiSel = @(Get-GuiSelectedObjs -Rows @($AiList.SelectedItems))
    if (-not $whdAiSel.Count) { Set-WHDStatus 'Select one or more AI items first.'; return }
    Invoke-GuiPlanAction 'AI remove + off-switch' (Get-GuiAiPlanText -Modules $whdAiSel -Action remove) { Invoke-WHDAiBatch -Modules $whdAiSel -Action remove }
    if ($script:WHDGuiPlanYes) { Update-AiList }
})
$AiStoreBtn.Add_Click({   Invoke-GuiAction 'Store suppression' { Invoke-WHDStoreSuppression } })

# General apps: the selection (or every recommended app) is ONE batch with ONE question (Invoke-WHDGeneralBatch).
$GenRemoveBtn.Add_Click({
    $whdGenSel = @(Get-GuiSelectedObjs -Rows @($GenList.SelectedItems))
    if (-not $whdGenSel.Count) { Set-WHDStatus 'Select one or more apps first.'; return }
    Invoke-GuiPlanAction 'General remove' (Get-GuiGeneralPlanText -Entries $whdGenSel) { Invoke-WHDGeneralBatch -Entries $whdGenSel }
    if ($script:WHDGuiPlanYes) { Update-GenList }
})
$GenRecBtn.Add_Click({
    $whdGenSel = @($script:WHDGeneralApps | Where-Object { $_.Rec })
    Invoke-GuiPlanAction 'General remove recommended' (Get-GuiGeneralPlanText -Entries $whdGenSel) { Invoke-WHDGeneralBatch -Entries $whdGenSel }
    if ($script:WHDGuiPlanYes) { Update-GenList }
})
$GenPrivBtn.Add_Click({   Invoke-GuiAction 'Privacy hardening' { Invoke-WHDPrivacyHardening } })
$GenDiagBtn.Add_Click({   Invoke-GuiAction 'Disable DiagTrack' { Invoke-WHDDisableDiagTrack } })

$PermPolicyLockBtn.Add_Click({ Invoke-GuiAction 'Permissions Lock (policy)' { Invoke-WHDPrivacyLock } })
$PermLockBtn.Add_Click({ Invoke-GuiAction 'Permissions Lockdown' { Invoke-WHDPermissionProfile -Profile 'Lockdown' } })
$PermBalBtn.Add_Click({  Invoke-GuiAction 'Permissions Balanced' { Invoke-WHDPermissionProfile -Profile 'Balanced' } })
$PermOpenBtn.Add_Click({ Invoke-GuiAction 'Permissions Open'     { Invoke-WHDPermissionProfile -Profile 'Open' } })

$W32UninstBtn.Add_Click({ Invoke-GuiAction 'Win32 uninstall' { foreach ($a in @($W32List.SelectedItems)) { Invoke-WHDWin32Uninstall -App $a } ; Update-W32List } })
$W32RefreshBtn.Add_Click({ Update-W32List; Set-WHDStatus 'Win32 list refreshed.' })
$W32FindBtn.Add_Click({   $n=$W32Name.Text.Trim(); if ($n) { Invoke-GuiAction ("Find '"+$n+"'") { Find-WHDApp -Name $n | Out-Null } } })
$W32RemAllBtn.Add_Click({ $n=$W32Name.Text.Trim(); if ($n) { Invoke-GuiAction ("Remove everywhere '"+$n+"'") { Remove-WHDAppEverywhere -Name $n; Update-W32List } } })
$W32BlockBtn.Add_Click({  $n=$W32Name.Text.Trim(); if ($n) { Invoke-GuiAction ("Block exe '"+$n+"'") { Block-WHDExecutable -ExeName $n } } })

$CsAnalyzeBtn.Add_Click({ Invoke-GuiAction 'Component store analyze' { Invoke-WHDComponentAnalyze } })
$CsCleanBtn.Add_Click({   Invoke-GuiAction 'Component store cleanup' { Invoke-WHDComponentCleanup } })
$CsResetBtn.Add_Click({   Invoke-GuiAction 'Component store cleanup + ResetBase' { Invoke-WHDComponentCleanup -ResetBase } })

$ProfLeanBtn.Add_Click({   Invoke-GuiAction 'Apply lean.json' { Invoke-WHDApplyProfile -Path (Join-Path $script:WHDRoot 'profiles\lean.json') } })
$ProfExportBtn.Add_Click({ Invoke-GuiAction 'Export starter profile' { Export-WHDProfile -Path (Join-Path $script:WHDRoot 'profiles\lean.json') } })
$ProfPickBtn.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.InitialDirectory = (Join-Path $script:WHDRoot 'profiles')
    $dlg.Filter = 'Profiles (*.json)|*.json'
    if ($dlg.ShowDialog()) { Invoke-GuiAction ('Apply ' + (Split-Path $dlg.FileName -Leaf)) { Invoke-WHDApplyProfile -Path $dlg.FileName } }
})

# ---- Firewall tab -----------------------------------------------------------
$FwProfilesPath = Join-Path $script:WHDRoot 'profiles'

function Refresh-FwStatus {
    try {
        $p   = Get-WHDFwProfiles
        $all = @(Get-NetFirewallRule -EA SilentlyContinue)
        $gi  = @(Get-NetFirewallRule -Group $script:WHDFwGroupIPv6  -EA SilentlyContinue).Count
        $ga  = @(Get-NetFirewallRule -Group $script:WHDFwGroupAllow -EA SilentlyContinue).Count
        $gb  = @(Get-NetFirewallRule -Group $script:WHDFwGroupBlock -EA SilentlyContinue).Count
        $prof = (@($p) | ForEach-Object {
                    '{0} {1}/{2}' -f $_.Name.ToString().Substring(0,3),
                        $_.DefaultInboundAction.ToString().Substring(0,1),
                        $_.DefaultOutboundAction.ToString().Substring(0,1) }) -join '    '
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue |
                    Where-Object { @($_.ServerAddresses).Count -gt 0 } | Select-Object -First 1)
        $dnsTxt = if ($dns) { (@($dns.ServerAddresses) -join ', ') } else { '(automatic)' }
        $dohTxt = 'n/a'
        if (Get-Command Get-DnsClientDohServerAddress -EA SilentlyContinue) {
            $dohTxt = if (@(Get-DnsClientDohServerAddress -EA SilentlyContinue |
                Where-Object { $script:WHDDnsServers -contains "$($_.ServerAddress)" }).Count) { 'ON (encrypted)' } else { 'off' }
        }
        $gp  = @(Get-NetFirewallRule -Group $script:WHDFwGroupApp -EA SilentlyContinue).Count
        $ntp = Get-WHDRegValueState -Path $script:WHDW32TimeKey -Name 'NtpServer'
        $ntpTxt = if ($ntp.Exists) { "$($ntp.Value)" } else { '(default)' }
        $lgTxt = if ((Get-WHDConnectionLoggingState).On) { 'ON (dropped + allowed)' } else { 'off' }
        $gateTxt = '?'; try { $gateTxt = "$((Get-WHDGateState).Text)" } catch { }      # update gate position (OPEN / PROGRAMS / CLOSED)
        $FwStatus.Text = ("Profiles in/out:  {0}`nRules: {1} total   |   WHD - IPv6 {2}, Allow-list {3}, Blacklist {4}, Program allows {5}`nDNS: {6}    DoH: {7}`nTime: {8}    Firewall log: {9}`nUpdate gate: {10}" -f `
            $prof, $all.Count, $gi, $ga, $gb, $gp, $dnsTxt, $dohTxt, $ntpTxt, $lgTxt, $gateTxt)
    } catch { $FwStatus.Text = "status error: $($_.Exception.Message)" }
}
function Set-FwGrid {
    $rows = @($script:FwAllRules)
    $q = $FwFilter.Text.Trim()
    if ($q) {
        $rows = @($rows | Where-Object {
            ('{0} {1} {2} {3} {4} {5} {6} {7}' -f $_.Dir,$_.Action,$_.Protocol,$_.LocalPort,$_.RemotePort,$_.RemoteIP,$_.DisplayName,$_.Group) -match [regex]::Escape($q) })
    }
    $FwGrid.ItemsSource = $rows
}
function Refresh-FwGrid {
    Set-WHDStatus 'Loading firewall rules...'
    $script:FwAllRules = if ($FwCustomChk.IsChecked) { Get-WHDFirewallRules -CustomOnly -Detail } else { Get-WHDFirewallRules -Detail }
    Set-FwGrid
    Refresh-FwStatus
    Set-WHDStatus ("Firewall rules loaded: {0}" -f @($script:FwAllRules).Count)
}
# One upfront confirm in EXECUTE, then auto-approve the batch (no dialog spam).
function Invoke-FwAction {
    param([string]$Title, [scriptblock]$Body, [switch]$Reload)
    Set-WHDStatus ("Working: $Title ...")
    Write-WHDLog ("=== $Title ($(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'})) ===") 'ACT'
    $prev = $script:WHDConfirm
    if ($script:WHDExecute) {
        $ok = ([System.Windows.MessageBox]::Show($win, "About to: $Title`n`nThis changes Windows firewall, DNS or time settings. Proceed?", 'WinHardenDebloat - firewall', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)) -eq 'Yes'
        if (-not $ok) { Write-WHDLog 'cancelled.' 'INFO'; Set-WHDStatus 'Cancelled.'; return }
        $script:WHDConfirm = { param($m) $true }
    }
    try { & $Body } catch { Write-WHDLog ("error: " + $_.Exception.Message) 'ERR' }
    finally { $script:WHDConfirm = $prev }
    Reset-WHDBusyBar
    Refresh-FwStatus
    if ($Reload) { Refresh-FwGrid }
    Set-WHDStatus ("Ready. $Title finished.")
}

$FwIpv6Btn.Add_Click({   Invoke-FwAction 'Suppress IPv6 (keep ::1)' { Invoke-WHDDisableIPv6 } -Reload })
$FwIpv6LoBtn.Add_Click({ Invoke-FwAction 'Suppress IPv6 + block ::1 loopback' { Invoke-WHDDisableIPv6 -BlockLoopback } -Reload })
$FwIpv6OnBtn.Add_Click({ Invoke-FwAction 'Re-enable IPv6' { Invoke-WHDEnableIPv6 } -Reload })
$FwDnsBtn.Add_Click({    Invoke-FwAction 'Set Cloudflare 1.1.1.2 + DoH' { Invoke-WHDSetDns -Mode Cloudflare } })
$FwDnsOffBtn.Add_Click({ Invoke-FwAction 'Reset DNS to automatic' { Invoke-WHDSetDns -Mode Reset } })
$FwAllowBtn.Add_Click({  Invoke-FwAction 'Apply outbound allow-list' { Invoke-WHDFirewallAllowList } -Reload })
$FwDenyBtn.Add_Click({
    $m = 10; $tmp = 0
    if ([int]::TryParse($FwRollback.Text.Trim(), [ref]$tmp) -and $tmp -ge 1) { $m = $tmp }
    Invoke-FwAction 'Enable default-deny outbound' ([scriptblock]::Create("Enable-WHDDefaultDenyOutbound -RollbackMinutes $m"))
})
$FwKeepBtn.Add_Click({   Invoke-FwAction 'Confirm keep default-deny' { Confirm-WHDDefaultDenyKeep } })
$FwRevertBtn.Add_Click({ Invoke-FwAction 'Revert default-deny' { Disable-WHDDefaultDenyOutbound } })
$FwBlockIpBtn.Add_Click({ Invoke-FwAction 'Block IP list (your profiles\blacklist-ip.txt)' { Block-WHDIPList -Path (Join-Path $FwProfilesPath 'blacklist-ip.txt') } -Reload })
$FwHostsBtn.Add_Click({   Invoke-FwAction 'Hosts sinkhole' { Block-WHDHostsList -Path (Join-Path $FwProfilesPath 'blacklist-hosts.txt') } })
$FwClearBlBtn.Add_Click({ Invoke-FwAction 'Clear blacklist' { Remove-WHDBlacklist } -Reload })
$FwApplyBtn.Add_Click({   Invoke-FwAction 'Apply baseline profile' { Invoke-WHDApplyFirewallProfile -Path (Join-Path $FwProfilesPath 'firewall-baseline.json') } -Reload })
$FwExportBtn.Add_Click({  Invoke-FwAction 'Export policy (json + .wfw)' { Export-WHDFirewallPolicy } })
$FwResetBtn.Add_Click({   Invoke-FwAction 'Reset to Windows defaults' { Invoke-WHDFirewallReset } -Reload })
$FwWipeBtn.Add_Click({    Invoke-FwAction 'Wipe ALL firewall rules' { Invoke-WHDFirewallWipe } -Reload })
$FwImportBtn.Add_Click({
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.InitialDirectory = $FwProfilesPath
    $dlg.Filter = 'Firewall policy (*.json;*.wfw)|*.json;*.wfw'
    if ($dlg.ShowDialog()) {
        $mode = if ($dlg.FileName -match '\.wfw$') { 'Wfw' } else { 'Json' }
        # No code built from the file name: the block reads these handler variables when it runs.
        $fwImpFile = $dlg.FileName; $fwImpMode = $mode
        Invoke-FwAction ('Import ' + (Split-Path $fwImpFile -Leaf)) { Import-WHDFirewallPolicy -Path $fwImpFile -Mode $fwImpMode } -Reload
    }
})
$FwRulesBtn.Add_Click({ Refresh-FwGrid })

# ---- Phase 6: blocked connections, time sync, blocklist refresh ------------
function Refresh-FwBlocked {
    $h = 24; $tmp = 0
    if ([int]::TryParse($FwBlkHours.Text.Trim(), [ref]$tmp) -and $tmp -ge 1) { $h = $tmp }
    $dir = if ($FwBlkInChk.IsChecked) { 'Any' } else { 'Outbound' }
    Set-WHDStatus ("Reading blocked connections (last {0} h)..." -f $h)
    $rows = @(Get-WHDBlockedConnections -Hours $h -Direction $dir)
    $FwBlkGrid.ItemsSource = $rows
    Set-WHDStatus ("Blocked connections: {0} group(s) in the last {1} h - {2} can be allowed." -f $rows.Count, $h, @(Select-GuiAllowable -Rows $rows).Count)
    if (-not $rows.Count) { Write-WHDLog 'No blocked connections found in that window. Is logging ON? (Firewall tab -> Logging ON)' 'INFO' }
}
$FwBlkLoadBtn.Add_Click({ Refresh-FwBlocked })
$FwBlkAllowBtn.Add_Click({
    $whdBlkAll = @($FwBlkGrid.SelectedItems)
    if (-not $whdBlkAll.Count) { Set-WHDStatus 'Select one or more rows first.'; return }
    # only the rows marked "yes" in the column 'Can allow'; one question for all of them (Add-WHDProgramAllows)
    $whdBlkCan = @(Select-GuiAllowable -Rows $whdBlkAll)
    if (-not $whdBlkCan.Count) {
        Write-WHDLog ("None of the {0} selected row(s) can be allowed from here - see the column 'Can allow' for the reason." -f $whdBlkAll.Count) 'WARN'
        Set-WHDStatus "None of the selected rows can be allowed from here (see the column 'Can allow')."
        return
    }
    if ($whdBlkCan.Count -lt $whdBlkAll.Count) { Write-WHDLog ("{0} selected row(s) left out - they cannot be allowed from here (see the column 'Can allow')." -f ($whdBlkAll.Count - $whdBlkCan.Count)) 'INFO' }
    $whdBlkGate = ''; try { $whdBlkGate = "$((Get-WHDGateState).Mode)" } catch { }
    Invoke-GuiPlanAction ("Allow {0} blocked program line(s) (outbound)" -f $whdBlkCan.Count) (Get-GuiAllowPlanText -Items $whdBlkCan -GateMode $whdBlkGate) { Add-WHDProgramAllows -Items $whdBlkCan }
    if ($script:WHDGuiPlanYes) { Refresh-FwGrid; Refresh-FwBlocked }      # rules were made: show them, and the new 'Can allow' texts
})
$FwLogOnBtn.Add_Click({    Invoke-FwAction 'Turn ON the Windows Firewall log (default file, dropped + allowed, 32,767 KB)' { Enable-WHDConnectionLogging } })
$FwLogOffBtn.Add_Click({   Invoke-FwAction 'Turn OFF the Windows Firewall log' { Disable-WHDConnectionLogging } })
$FwAppClearBtn.Add_Click({ Invoke-FwAction 'Remove all per-program allow rules' { Remove-WHDProgramAllows } -Reload })
$FwTimeCfBtn.Add_Click({   Invoke-FwAction 'Time sync -> time.cloudflare.com (UDP 123 pinned, 1 h jump limit)' { Invoke-WHDSetTimeSync -Mode Cloudflare } -Reload })
$FwTimeWinBtn.Add_Click({  Invoke-FwAction 'Time sync -> Windows default (time.windows.com)' { Invoke-WHDSetTimeSync -Mode Windows } -Reload })
$FwTimeStatBtn.Add_Click({ Invoke-GuiAction 'Time + logging status' { Show-WHDTimeStatus; Show-WHDConnectionLoggingState; Show-WHDTimeRegionStatus } })
# ---- Classic 1.4: time zone + date/time (same engine as main menu T) -------
function Update-TzControls {
    try {
        $FwTzCombo.ItemsSource = @(Get-WHDTimeZoneChoices)
        $curTz = "$((Get-TimeZone).Id)"
        $FwTzCombo.SelectedItem = @($FwTzCombo.ItemsSource | Where-Object { $_.Id -eq $curTz -and $_.Label -notlike '[*]*' })[0]
        $FwDateBox.Text = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    } catch { Write-WHDLog ("time zone list: " + $_.Exception.Message) 'WARN' }
}
Update-TzControls
$FwTzSetBtn.Add_Click({
    $sel = $FwTzCombo.SelectedItem
    if (-not $sel) { Write-WHDLog 'Pick a time zone first.' 'WARN'; return }
    $tzId = "$($sel.Id)"
    Invoke-GuiAction ("Set time zone -> " + $tzId) {
        if ($tzId -eq "$((Get-TimeZone).Id)") { Write-WHDLog ("time zone already {0} - nothing to change." -f $tzId) 'OK'; return }
        Write-WHDRisk 'reversible' 'Changes the time zone (Settings > Date & time). Journaled: Undo center puts the old zone back; Verify / the update guard put this one back if something changes it.'
        if (Confirm-WHDProceed ("set the time zone to {0}" -f $tzId)) { Set-WHDTimeZoneId -Id $tzId; Show-WHDTimeRegionStatus } else { Write-WHDLog 'skipped.' 'WARN' }
    }
    Update-TzControls
})
$FwDateSetBtn.Add_Click({
    $dtTxt = "$($FwDateBox.Text)".Trim()
    $dtVal = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($dtTxt, 'yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dtVal)) {
        Write-WHDLog 'Date/time not understood - use e.g. 2026-09-30 17:45' 'WARN'; return
    }
    Invoke-GuiAction ("Set date/time -> " + $dtVal.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) { Set-WHDDateTimeManual -Date $dtVal }
    Update-TzControls
})
$FwRefreshBlBtn.Add_Click({
    Set-WHDStatus 'Blocklist refresh: reading profiles\incoming ...'
    Write-WHDLog ("=== Blocklist refresh ({0}) ===" -f $(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'})) 'ACT'
    $sum = $null
    try { $sum = Invoke-WHDBlocklistRefresh -Mode Preview } catch { Write-WHDLog ("error: " + $_.Exception.Message) 'ERR' }
    if (-not $sum) { Set-WHDStatus 'Blocklist refresh: nothing to do.'; return }
    if (-not $script:WHDExecute) { Write-WHDLog 'DRY-RUN: preview only. Tick EXECUTE to merge or replace.' 'DRY'; Set-WHDStatus 'Preview done (DRY-RUN).'; return }
    $msg = ("Current list: {0} ranges. Incoming: {1} ranges.`n`nMERGE   -> {2} ranges (keep all, add {3} new)`nREPLACE -> {4} ranges (drops {5} not in the new files)`n`nYes = MERGE     No = REPLACE     Cancel = do nothing" -f `
        $sum.Current, $sum.Incoming, $sum.MergeTotal, $sum.Added, $sum.ReplaceTotal, $sum.Removed)
    $ans = [System.Windows.MessageBox]::Show($win, $msg, 'WinHardenDebloat - blocklist refresh', [System.Windows.MessageBoxButton]::YesNoCancel, [System.Windows.MessageBoxImage]::Question, [System.Windows.MessageBoxResult]::Cancel)
    if ("$ans" -eq 'Cancel') { Write-WHDLog 'cancelled.' 'INFO'; Set-WHDStatus 'Cancelled.'; return }
    $mode = if ("$ans" -eq 'Yes') { 'Merge' } else { 'Replace' }
    $prev = $script:WHDConfirm; $script:WHDConfirm = { param($m) $true }
    try {
        Invoke-WHDBlocklistRefresh -Mode $mode | Out-Null
        $rb = [System.Windows.MessageBox]::Show($win, 'Blocklist file updated. Rebuild the firewall block rules from it now?', 'WinHardenDebloat - blocklist refresh', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question, [System.Windows.MessageBoxResult]::No)
        if ("$rb" -eq 'Yes') { Update-WHDBlocklistRules }
    } catch { Write-WHDLog ("error: " + $_.Exception.Message) 'ERR' }
    finally { $script:WHDConfirm = $prev }
    Refresh-FwGrid
    Set-WHDStatus ("Blocklist refresh ({0}) finished." -f $mode)
})
$FwCustomChk.Add_Checked({ Refresh-FwGrid })
$FwCustomChk.Add_Unchecked({ Refresh-FwGrid })
$FwFilter.Add_TextChanged({ if ($script:FwAllRules) { Set-FwGrid } })
Refresh-FwStatus

# ---- General / Permissions handlers (Phase 7) --------------------------------
$PrivRefreshBtn.Add_Click({ Update-PrivList })
$PrivAllBtn.Add_Click({ $PrivList.SelectAll(); Set-WHDStatus ('{0} privacy setting(s) selected - now choose Apply.' -f $PrivList.SelectedItems.Count) })
$PrivApplyBtn.Add_Click({
    $sel = @($PrivList.SelectedItems)
    if (-not $sel.Count) { Set-WHDStatus 'Select one or more privacy settings first.'; return }
    Invoke-UndoAction ("Apply {0} privacy setting(s)" -f $sel.Count) { foreach ($i in $sel) { Invoke-WHDPrivacyItem -Item $i.Obj } }
    Update-PrivList
})
$UsageLoadBtn.Add_Click({
    $rows = @(Get-WHDCapabilityUsage)
    $UsageGrid.ItemsSource = $rows
    Set-WHDStatus ("Usage history: {0} app record(s)." -f $rows.Count)
})
$PerAppCap.Add_SelectionChanged({ Update-PerApp })
$PerAppAllowBtn.Add_Click({
    $c = $PerAppCap.SelectedItem; $sel = @($PerAppGrid.SelectedItems)
    if (-not $c -or -not $sel.Count) { Set-WHDStatus 'Pick a permission and select one or more apps first.'; return }
    Invoke-GuiAction ("Allow {0} for {1} app(s)" -f $c.Name, $sel.Count) { Invoke-WHDAppPermission -Cap $c.Cap -Apps $sel -Value 'Allow' }
    Update-PerApp
})
$PerAppDenyBtn.Add_Click({
    $c = $PerAppCap.SelectedItem; $sel = @($PerAppGrid.SelectedItems)
    if (-not $c -or -not $sel.Count) { Set-WHDStatus 'Pick a permission and select one or more apps first.'; return }
    Invoke-GuiAction ("Deny {0} for {1} app(s)" -f $c.Name, $sel.Count) { Invoke-WHDAppPermission -Cap $c.Cap -Apps $sel -Value 'Deny' }
    Update-PerApp
})

# ---- Security+ tab (Phase 8) -------------------------------------------------
function Update-SecAsr { try { $SecAsrGrid.ItemsSource = @(Get-WHDAsrState) } catch { $SecAsrGrid.ItemsSource = @() } }
function Invoke-SecAction {
    param([string]$Title, [scriptblock]$Body)
    Invoke-UndoAction $Title $Body
    Update-SecAsr
}

# ---- Updates tab (v1.1: stop auto-installs) ----------------------------------
function Update-UpdStatus { try { $g = Get-WHDGateState; $UpdStatus.Text = ("Update gate: {0}   (outbound {1})" -f $g.Text, $g.Outbound) } catch { $UpdStatus.Text = 'Update gate: ?' } }
function Update-UpdList   { try { $UpdList.ItemsSource = @(Find-WHDAppUpdaters); $UpdList.DisplayMemberPath = 'Label' } catch { $UpdList.ItemsSource = @() } }
function Invoke-UpdAction { param([string]$Title, [scriptblock]$Body) Invoke-GuiAction $Title $Body; Update-UpdStatus }
$UpdStatusBtn.Add_Click({    Invoke-UpdAction 'Updates status' { Show-WHDUpdatesStatus } })
# (the Firewall tab's status shows the gate position too, so it is refreshed as well)
$UpdGateCloseBtn.Add_Click({ Invoke-UpdAction 'Update gate: CLOSE' { Close-WHDUpdateGate }; Refresh-FwStatus })
$UpdGateProgBtn.Add_Click({  Invoke-UpdAction 'Update gate: PROGRAMS' { Close-WHDUpdateGate -Mode programs }; Refresh-FwStatus })
$UpdGateOpenBtn.Add_Click({  Invoke-UpdAction 'Update gate: OPEN'  { Open-WHDUpdateGate }; Refresh-FwStatus })
$UpdDefenderBtn.Add_Click({  Invoke-UpdAction 'Defender: update definitions' { Invoke-WHDDefenderUpdateTest } })
$UpdWuBtn.Add_Click({        Invoke-UpdAction $script:WHDUpdatePolicies[0].Name { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[0] } })
$UpdDrvBtn.Add_Click({       Invoke-UpdAction $script:WHDUpdatePolicies[1].Name { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[1] } })
$UpdDrvPolBtn.Add_Click({    Invoke-UpdAction $script:WHDUpdatePolicies[2].Name { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[2] } })
$UpdStoreBtn.Add_Click({     Invoke-UpdAction $script:WHDUpdatePolicies[3].Name { Invoke-WHDUpdatePolicy -Item $script:WHDUpdatePolicies[3] } })
$UpdAllPolBtn.Add_Click({    Invoke-UpdAction 'All four update policies' { foreach ($it in $script:WHDUpdatePolicies) { Invoke-WHDUpdatePolicy -Item $it } } })
$UpdEdgeBtn.Add_Click({      Invoke-UpdAction 'Edge Update off' { Invoke-WHDAppUpdatersOff -EdgeOnly }; Update-UpdList })
$UpdScanBtn.Add_Click({ Update-UpdList; Set-WHDStatus ("Found {0} app updater(s)." -f @($UpdList.ItemsSource).Count) })
$UpdOffSelBtn.Add_Click({
    $sel = @($UpdList.SelectedItems)
    if (-not $sel.Count) { Set-WHDStatus 'Select one or more updaters first.'; return }
    Invoke-UpdAction ("Turn off {0} app updater(s)" -f $sel.Count) { Invoke-WHDAppUpdatersOff -Items $sel }
    Update-UpdList
})
Update-UpdStatus
$SecReportBtn.Add_Click({ Invoke-GuiAction 'Security report' { Show-WHDSecurityReport }; $SecStatus.Text = ("UAC: {0}   |   report written to the log below ({1})" -f (Get-WHDUacState).Level, (Get-Date -Format 'HH:mm:ss')) })
$SecPuaBtn.Add_Click({      Invoke-SecAction 'Defender: block unwanted apps (PUA) ON' { Invoke-WHDDefenderProtection -Which PUA -Mode On } })
$SecNetAuditBtn.Add_Click({ Invoke-SecAction 'Defender: network protection AUDIT' { Invoke-WHDDefenderProtection -Which Network -Mode Audit } })
$SecNetBlockBtn.Add_Click({ Invoke-SecAction 'Defender: network protection BLOCK' { Invoke-WHDDefenderProtection -Which Network -Mode On } })
$SecCfaAuditBtn.Add_Click({ Invoke-SecAction 'Defender: ransomware folder protection AUDIT' { Invoke-WHDDefenderProtection -Which Folders -Mode Audit } })
$SecCfaBlockBtn.Add_Click({
    # WHD folder inside a protected folder: ask first, because the warning in the log would come after the confirm.
    $cfaDir = ''
    try { $cfaDir = Get-WHDProtectedFolderOfRoot } catch {}
    if ($cfaDir -and $script:WHDExecute) {
        $cfaMsg = ("WHD runs from inside the protected folder:`n{0}`n`nIn BLOCK mode Windows does not treat PowerShell as a trusted app there. WHD's log may stop and later changes may not be recorded for undo.`n`nBetter: answer No, move the WHD folder outside the protected folders (for example C:\WHD) and start it from there.`n`nSwitch it on anyway?" -f $cfaDir)
        $cfaOk = ([System.Windows.MessageBox]::Show($win, $cfaMsg, 'WinHardenDebloat - warning', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)) -eq 'Yes'
        if (-not $cfaOk) { Write-WHDLog 'Ransomware folder protection BLOCK: cancelled (WHD folder is inside a protected folder).' 'INFO'; return }
    }
    Invoke-SecAction 'Defender: ransomware folder protection BLOCK' { Invoke-WHDDefenderProtection -Which Folders -Mode On }
})
$SecAsrStdBtn.Add_Click({   Invoke-SecAction 'ASR: Microsoft standard 3 (AUDIT)' { Invoke-WHDAsrGroups -Groups standard -Mode Audit } })
$SecAsrScrBtn.Add_Click({   Invoke-SecAction 'ASR: script + download rules (AUDIT)' { Invoke-WHDAsrGroups -Groups scripts -Mode Audit } })
$SecAsrOffBtn.Add_Click({   Invoke-SecAction 'ASR: Office / Adobe / email rules (AUDIT)' { Invoke-WHDAsrGroups -Groups office -Mode Audit } })
$SecAsrPromoteBtn.Add_Click({ Invoke-SecAction 'ASR: switch audited rules to BLOCK' { Invoke-WHDAsrPromote } })
$SecLlmnrBtn.Add_Click({    Invoke-SecAction 'Turn off LLMNR' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[0] } })
$SecNetbiosBtn.Add_Click({  Invoke-SecAction 'Turn off NetBIOS over TCP/IP' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[1] } })
$SecWpadBtn.Add_Click({     Invoke-SecAction 'Turn off WPAD' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[2] } })
$SecRaBtn.Add_Click({       Invoke-SecAction 'Turn off Remote Assistance' { Invoke-WHDProtocolOff -Item $script:WHDProtocols[3] } })
$SecProtoAllBtn.Add_Click({ Invoke-SecAction 'Turn off all four old protocols' { foreach ($it in $script:WHDProtocols) { Invoke-WHDProtocolOff -Item $it } } })
$SecSvcFileBtn.Add_Click({  Invoke-SecAction 'Turn off Workstation + Server' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[0] } })
$SecSvcSmbBtn.Add_Click({   Invoke-SecAction 'Turn off SMB 1/2/3' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[1] } })
$SecSvcDialBtn.Add_Click({  Invoke-SecAction 'Turn off dial-up + built-in VPN' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[2] } })
$SecSvcIpsecBtn.Add_Click({ Invoke-SecAction 'Turn off IPsec VPN keying' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[3] } })
$SecSvcProxyBtn.Add_Click({ Invoke-SecAction 'Turn off proxy auto-detect' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[4] } })
$SecSvcFaxBtn.Add_Click({   Invoke-SecAction 'Turn off Fax + Phone service' { Invoke-WHDNetServiceOff -Item $script:WHDNetServiceGroups[5] } })
$DevBtBtn.Add_Click({     Invoke-SecAction 'Bluetooth network part off' { Invoke-WHDBtNetworkOff } })
$DevWfdBtn.Add_Click({    Invoke-SecAction 'Wi-Fi Direct adapters off + block' { Invoke-WHDWifiDirectOff } })
$DevWanBtn.Add_Click({    Invoke-SecAction 'WAN Miniports: block + remove' { Invoke-WHDWanMiniportsOff } })
$DevStatusBtn.Add_Click({ Invoke-GuiAction 'Devices status' { Show-WHDDevicesStatus } })
$SecSvcAllBtn.Add_Click({   Invoke-SecAction 'Turn off all safe service groups' { foreach ($g in @($script:WHDNetServiceGroups | Where-Object { -not $_.NotInAll })) { Invoke-WHDNetServiceOff -Item $g } } })
$SecSvcProxySvcBtn.Add_Click({ Invoke-SecAction 'WinHTTP proxy SERVICE off - test only: in testing this stopped Wi-Fi from connecting after a restart (undo: Undo center, then restart)' { Invoke-WHDNetServiceOff -Item @($script:WHDNetServiceGroups | Where-Object { $_.Key -eq 'proxysvc' })[0] } })
$SecUacBtn.Add_Click({      Invoke-SecAction 'UAC: Always notify' { Set-WHDUacAlwaysNotify } })
$SecPwBtn.Add_Click({       Invoke-SecAction 'Password + lockout rules (14 chars, remember 5, never expire, 3 tries / 10 min)' { Invoke-WHDPasswordPolicy } })
function Update-SecGuard { try { $SecStatus.Text = ("Update guard: {0}" -f (Get-WHDGuardStatus).Text) } catch {} }
$SecGuardInstBtn.Add_Click({ Invoke-SecAction 'Update guard: install / refresh' { Install-WHDUpdateGuard }; Update-SecGuard })
$SecGuardDelBtn.Add_Click({  Invoke-SecAction 'Update guard: remove' { Uninstall-WHDUpdateGuard }; Update-SecGuard })
$SecGuardRunBtn.Add_Click({  Invoke-GuiAction 'Update guard: run the check now' { Invoke-WHDUpdateGuard -Now | Out-Null }; Update-SecGuard })
$SecGuardOpenBtn.Add_Click({
    $st = Get-WHDGuardState
    if ($st -and $st.LastReport -and (Test-Path -LiteralPath $st.LastReport)) { Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $st.LastReport) }
    else { Set-WHDStatus 'No update-guard report yet.' }
})
$SecAsrLoadBtn.Add_Click({ Update-SecAsr })
$SecEvLoadBtn.Add_Click({
    $rows = @(Get-WHDDefenderEvents)
    $SecEvGrid.ItemsSource = $rows
    Set-WHDStatus ("Defender caught {0} event(s) in the last 7 days (ASR / network / folder protection)." -f $rows.Count)
})
Update-SecAsr

# ---- Inventory / Undo tab (Phase 5) -----------------------------------------
function Refresh-UndoSessions {
    $keep = if ($UndoSession.SelectedItem) { $UndoSession.SelectedItem.Stamp } else { $null }
    $list = @(Get-WHDUndoSessions)
    $UndoSession.ItemsSource = $list
    $idx = 0
    if ($keep) { for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].Stamp -eq $keep) { $idx = $i } } }
    if ($list.Count) { $UndoSession.SelectedIndex = $idx } else { $UndoGrid.ItemsSource = @() }
}
function Refresh-UndoGrid {
    $s = $UndoSession.SelectedItem
    if (-not $s) { $UndoGrid.ItemsSource = @(); return }
    $UndoGrid.ItemsSource = @(Get-WHDJournal -SessionPath $s.Path)
}
# One upfront Yes/No in EXECUTE, then auto-approve inside (same pattern as the firewall tab).
function Invoke-UndoAction {
    param([string]$Title, [scriptblock]$Body)
    Set-WHDStatus ("Working: $Title ...")
    Write-WHDLog ("=== $Title ($(if($script:WHDExecute){'EXECUTE'}else{'DRY-RUN'})) ===") 'ACT'
    $prev = $script:WHDConfirm
    if ($script:WHDExecute) {
        $ok = ([System.Windows.MessageBox]::Show($win, "About to: $Title`n`nProceed?", 'WinHardenDebloat - confirm', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning, [System.Windows.MessageBoxResult]::No)) -eq 'Yes'
        if (-not $ok) { Write-WHDLog 'cancelled.' 'INFO'; Set-WHDStatus 'Cancelled.'; return }
        $script:WHDConfirm = { param($m) $true }
    }
    try { & $Body } catch { Write-WHDLog ("error: " + $_.Exception.Message) 'ERR' }
    finally { $script:WHDConfirm = $prev }
    Reset-WHDBusyBar
    Refresh-UndoSessions; Refresh-UndoGrid
    Set-WHDStatus ("Ready. $Title finished.")
}
$InvDiffBtn.Add_Click({
    Invoke-GuiAction 'Compare last two scans' {
        foreach ($l in @(& (Join-Path $script:WHDRoot 'Inventory.ps1') -Compare -NoElevate)) { Write-WHDLog "$l" 'INFO' }
    }
})
$GuardRefreshBtn.Add_Click({ Invoke-GuiAction 'Refresh update guard' { Install-WHDUpdateGuard } })
$ReApplyBtn.Add_Click({ Invoke-UndoAction 'Re-apply settings that changed back' { Invoke-WHDReApplyChanged } })
$ReRemoveBtn.Add_Click({ Invoke-UndoAction 'Re-remove apps that came back' { Invoke-WHDReRemoveReturned } })
$VerAllBtn.Add_Click({  Invoke-GuiAction 'Verify all changes' { Invoke-WHDVerify -All | Out-Null } })
$VerSessBtn.Add_Click({ $s = $UndoSession.SelectedItem; if ($s) { Invoke-GuiAction ('Verify session ' + $s.Stamp) { Invoke-WHDVerify -SessionPath $s.Path | Out-Null } } })
$UndoRefreshBtn.Add_Click({ Refresh-UndoSessions; Refresh-UndoGrid })
$UndoArchiveBtn.Add_Click({ Invoke-UndoAction 'Archive history from other PCs / previous installs' { Invoke-WHDArchiveOtherHistory } })
$UndoSession.Add_SelectionChanged({ Refresh-UndoGrid })
$UndoSelBtn.Add_Click({
    $sel = @($UndoGrid.SelectedItems)
    if (-not $sel.Count) { Set-WHDStatus 'Select one or more rows first.'; return }
    Invoke-UndoAction ("Undo {0} selected change(s)" -f $sel.Count) { Invoke-WHDUndo -Entries $sel }
})
$UndoAllBtn.Add_Click({   $s = $UndoSession.SelectedItem; if ($s) { Invoke-UndoAction ('Undo session ' + $s.Stamp) { Invoke-WHDUndoSession -SessionPath $s.Path } } })
$UndoFwBtn.Add_Click({    $s = $UndoSession.SelectedItem; if ($s) { Invoke-UndoAction ('Restore firewall from ' + $s.Stamp + ' (replaces the WHOLE firewall policy)') { Restore-WHDSessionFirewall -SessionPath $s.Path } } })
$UndoHostsBtn.Add_Click({ $s = $UndoSession.SelectedItem; if ($s) { Invoke-UndoAction ('Restore hosts file from ' + $s.Stamp) { Restore-WHDSessionHosts -SessionPath $s.Path } } })
$UndoRegBtn.Add_Click({   $s = $UndoSession.SelectedItem; if ($s) { Invoke-UndoAction ('Import .reg backups from ' + $s.Stamp) { Import-WHDLegacyRegBackups -SessionPath $s.Path } } })
Refresh-UndoSessions

Write-WHDLog 'GUI ready. DRY-RUN mode (tick EXECUTE to make changes).' 'INFO'
Write-WHDLog 'Provided as is, with no warranty (MIT License) - use at your own risk.' 'INFO'
Set-WHDStatus 'DRY-RUN mode - actions only preview.'
try { Update-WHDGuardIfStale } catch { }
try { Write-WHDAccountWarning } catch { }
try { Write-WHDProtectedFolderWarning } catch { }
$win.ShowDialog() | Out-Null
Stop-WHDTranscript
