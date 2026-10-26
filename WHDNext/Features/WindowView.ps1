#requires -Version 7.6
<#
================================================================================
 WHD Next 3.0  -  Features/WindowView.ps1   (build step 6b, P51)
 Author : Training1990for2026Systems   Contact: t90018273@gmail.com
 License: MIT (see LICENSE)            Built with Claude by Anthropic
--------------------------------------------------------------------------------
 The window's screen. Show-WHDWindow runs this on its OWN thread (an STA
 runspace) so it keeps drawing while the engine works on the main thread - a
 long action (Theme 1, inventory, the plan) never freezes it. It calls no
 module code: it only sends requests and draws what comes back, through $Link
 (Features\Window.ps1, Initialize-WHDWindowLink). Given by Show-WHDWindow:
 $Link, $Info (Product, Version, PowerShell) and $Headers (the tab names).
================================================================================
#>

$script:WHDWindowView = {
    Set-StrictMode -Version 3.0
    $ErrorActionPreference = 'Stop'
    # every key read below is set here or further down before the window opens (strict mode, P49)
    $V = @{ InTick = $false; Quiet = $false; Pending = '' }
    try {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
        $brush = { param($hex) [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
        $V.Bg = & $brush '#0F1218'; $V.Panel = & $brush '#161B24'; $V.Fg = & $brush '#E8EBF2'; $V.Dim = & $brush '#9AA6BF'; $V.Accent = & $brush '#7CC4FF'
        $V.Title = ('{0} {1}  -  PowerShell {2}' -f $Info.Product, $Info.Version, $Info.PowerShell)

        # ---- the window ----
        $win = [System.Windows.Window]::new()
        $win.Title = $V.Title
        $win.Width = 1180; $win.Height = 820; $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen; $win.Background = $V.Bg
        $V.Window = $win
        $dock = [System.Windows.Controls.DockPanel]::new(); $dock.Margin = [System.Windows.Thickness]::new(10, 10, 10, 10)
        $win.Content = $dock

        # top bar
        $top = [System.Windows.Controls.DockPanel]::new(); $top.LastChildFill = $false; $top.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
        [System.Windows.Controls.DockPanel]::SetDock($top, 'Top'); [void]$dock.Children.Add($top)
        $t = [System.Windows.Controls.TextBlock]::new(); $t.Text = 'WHD Next 3.0'; $t.FontSize = 20; $t.FontWeight = [System.Windows.FontWeights]::Bold; $t.Foreground = $V.Fg; $t.VerticalAlignment = 'Center'
        [void]$top.Children.Add($t)
        $V.Mode = [System.Windows.Controls.TextBlock]::new(); $V.Mode.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0); $V.Mode.VerticalAlignment = 'Center'; $V.Mode.Foreground = $V.Dim
        [void]$top.Children.Add($V.Mode)
        $V.Exec = [System.Windows.Controls.CheckBox]::new(); $V.Exec.Content = 'EXECUTE (apply changes)'; $V.Exec.Foreground = & $brush '#E8735B'; $V.Exec.FontWeight = [System.Windows.FontWeights]::Bold; $V.Exec.VerticalAlignment = 'Center'; $V.Exec.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($V.Exec, 'Right'); [void]$top.Children.Add($V.Exec)
        $V.Safe = [System.Windows.Controls.CheckBox]::new(); $V.Safe.Content = 'Safe mode'; $V.Safe.Foreground = $V.Fg; $V.Safe.VerticalAlignment = 'Center'; $V.Safe.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($V.Safe, 'Right'); [void]$top.Children.Add($V.Safe)
        $V.Rp = [System.Windows.Controls.Button]::new(); $V.Rp.Content = 'Restore point now'; $V.Rp.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3); $V.Rp.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($V.Rp, 'Right'); [void]$top.Children.Add($V.Rp)

        # the working notice (D: "both" - keep the window alive AND say so)
        $V.Work = [System.Windows.Controls.TextBlock]::new(); $V.Work.Foreground = & $brush '#F2C94C'; $V.Work.FontWeight = [System.Windows.FontWeights]::Bold; $V.Work.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6); $V.Work.TextWrapping = 'Wrap'
        [System.Windows.Controls.DockPanel]::SetDock($V.Work, 'Top'); [void]$dock.Children.Add($V.Work)

        # bottom: the log pane
        $V.Log = [System.Windows.Controls.TextBox]::new()
        $V.Log.Height = 230; $V.Log.IsReadOnly = $true; $V.Log.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas'); $V.Log.FontSize = 12; $V.Log.Background = $V.Panel; $V.Log.Foreground = $V.Fg
        $V.Log.VerticalScrollBarVisibility = 'Auto'; $V.Log.HorizontalScrollBarVisibility = 'Auto'; $V.Log.TextWrapping = 'NoWrap'; $V.Log.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($V.Log, 'Bottom'); [void]$dock.Children.Add($V.Log)

        # middle: the tabs (their contents come from the engine)
        $V.Tabs = [System.Windows.Controls.TabControl]::new(); $V.Tabs.Background = $V.Panel
        [void]$dock.Children.Add($V.Tabs)
        foreach ($h in $Headers) {
            $ti = [System.Windows.Controls.TabItem]::new(); $ti.Header = $h
            $wait = [System.Windows.Controls.TextBlock]::new(); $wait.Text = 'reading ...'; $wait.Foreground = $V.Dim; $wait.Margin = [System.Windows.Thickness]::new(10, 10, 10, 10); $ti.Content = $wait
            [void]$V.Tabs.Items.Add($ti)
        }
        $V.Tabs.SelectedIndex = 0

        # ---- helpers ----
        $V.Say = {
            param($Text, $Color)
            [void]$Color
            $V.Log.AppendText(([string]$Text) + [Environment]::NewLine)
            $V.Log.ScrollToEnd()
        }
        $V.Guard = {
            # every event runs through here: an error is shown in the pane and sent to the log file; the window goes on
            param([string]$What, [scriptblock]$Do)
            try { & $Do }
            catch {
                $where = if ($_.InvocationInfo) { 'line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim() } else { '' }
                $msg = 'WINDOW ERROR ({0}): {1}  [{2}]' -f $What, $_.Exception.Message, $where
                try { & $V.Say $msg 'Red' } catch { [void]$_ }
                try { $Link.ToEngine.Add(@{ Type = 'log'; Message = $msg }) } catch { [void]$_ }
            }
        }
        $V.SetBusy = {
            param([bool]$On)
            $Link.Flags['Busy'] = $On
            $V.Tabs.IsEnabled = -not $On; $V.Exec.IsEnabled = -not $On; $V.Safe.IsEnabled = -not $On; $V.Rp.IsEnabled = -not $On
            $V.Work.Text = $(if ($On) { 'WORKING - please wait. The log below fills as it goes. Do not close this window or the PowerShell window until it says "done".' } else { '' })
            $V.Window.Cursor = $(if ($On) { [System.Windows.Input.Cursors]::AppStarting } else { $null })
            $V.Window.Title = $(if ($On) { $V.Title + '   -   WORKING' } else { $V.Title })
        }
        $V.Send = {
            # one request to the engine; nothing new is sent while it works on the last one
            param([hashtable]$Request, [string]$Pending)
            if ($Link.Flags['Busy']) { return $false }
            $V.Pending = $Pending
            & $V.SetBusy $true
            $Link.ToEngine.Add($Request)
            return $true
        }
        $V.Act = {
            param([string]$Key)
            if (-not $Key.Trim()) { return }
            [void](& $V.Send @{ Type = 'action'; Index = $V.Tabs.SelectedIndex; Key = $Key } 'action')
        }
        $V.Build = {
            # one tab's buttons, choice box and status text
            param([int]$Index, $Model)
            $ti = $V.Tabs.Items[$Index]
            $grid = [System.Windows.Controls.Grid]::new(); $grid.Margin = [System.Windows.Thickness]::new(6, 6, 6, 6)
            $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(380)
            $c2 = [System.Windows.Controls.ColumnDefinition]::new()
            [void]$grid.ColumnDefinitions.Add($c1); [void]$grid.ColumnDefinitions.Add($c2)
            $sv = [System.Windows.Controls.ScrollViewer]::new(); $sv.VerticalScrollBarVisibility = 'Auto'
            $sp = [System.Windows.Controls.StackPanel]::new(); $sp.Margin = [System.Windows.Thickness]::new(2, 2, 2, 2)
            $sv.Content = $sp; [System.Windows.Controls.Grid]::SetColumn($sv, 0); [void]$grid.Children.Add($sv)
            foreach ($g in $Model.Groups) {
                if ($g.Title) {
                    $h = [System.Windows.Controls.TextBlock]::new(); $h.Text = $g.Title; $h.Foreground = $V.Accent; $h.FontWeight = [System.Windows.FontWeights]::Bold; $h.Margin = [System.Windows.Thickness]::new(2, 8, 2, 2); $h.TextWrapping = 'Wrap'
                    [void]$sp.Children.Add($h)
                }
                foreach ($it in $g.Items) {
                    $b = [System.Windows.Controls.Button]::new()
                    $tb = [System.Windows.Controls.TextBlock]::new(); $tb.Text = ('{0,-4} {1}' -f ($it.Key -replace '^M:', ''), $it.Label); $tb.TextWrapping = 'Wrap'
                    $b.Content = $tb; $b.HorizontalContentAlignment = 'Left'; $b.Margin = [System.Windows.Thickness]::new(3, 3, 3, 3); $b.Padding = [System.Windows.Thickness]::new(6, 3, 6, 3); $b.Tag = $it.Key
                    if ($it.Hint) { $b.ToolTip = $it.Hint }
                    if ($it.Later) { $b.IsEnabled = $false; $b.ToolTip = $(if ($it.Hint) { $it.Hint } else { 'comes in a later build step' }) }
                    $b.add_Click({ param($sender, $e) [void]$e; $k = [string]$sender.Tag; & $V.Guard 'button' { & $V.Act $k } })
                    [void]$sp.Children.Add($b)
                }
            }
            $lbl = [System.Windows.Controls.TextBlock]::new(); $lbl.Text = 'Type a choice as in the menu (e.g. 1,3 r) and press Enter:'; $lbl.Foreground = $V.Dim; $lbl.Margin = [System.Windows.Thickness]::new(2, 12, 2, 2); $lbl.TextWrapping = 'Wrap'
            [void]$sp.Children.Add($lbl)
            $box = [System.Windows.Controls.TextBox]::new(); $box.Margin = [System.Windows.Thickness]::new(3, 3, 3, 3); $box.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas')
            $box.add_KeyDown({ param($sender, $e) if ([string]$e.Key -eq 'Return') { $v = [string]$sender.Text; $sender.Text = ''; & $V.Guard 'choice box' { & $V.Act $v } } })
            [void]$sp.Children.Add($box)
            $rf = [System.Windows.Controls.Button]::new(); $rf.Content = 'Refresh this tab'; $rf.Margin = [System.Windows.Thickness]::new(3, 10, 3, 3)
            $rf.add_Click({ & $V.Guard 'refresh' { [void](& $V.Send @{ Type = 'model'; Index = $V.Tabs.SelectedIndex } '') } })
            [void]$sp.Children.Add($rf)
            $st = [System.Windows.Controls.TextBox]::new(); $st.IsReadOnly = $true; $st.FontFamily = [System.Windows.Media.FontFamily]::new('Consolas'); $st.FontSize = 12; $st.Background = $V.Bg; $st.Foreground = $V.Fg
            $st.VerticalScrollBarVisibility = 'Auto'; $st.HorizontalScrollBarVisibility = 'Auto'; $st.TextWrapping = 'NoWrap'; $st.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
            $st.Text = (@($Model.Status) -join [Environment]::NewLine)
            [System.Windows.Controls.Grid]::SetColumn($st, 1); [void]$grid.Children.Add($st)
            $ti.Content = $grid
        }
        $V.AskBox = {
            # an input dialog; Enter or OK = the text, closed = empty
            param([string]$Prompt)
            $d = [System.Windows.Window]::new(); $d.Title = 'WHD Next 3.0 - question'; $d.SizeToContent = 'WidthAndHeight'; $d.WindowStartupLocation = 'CenterOwner'; $d.Owner = $V.Window
            $p = [System.Windows.Controls.StackPanel]::new(); $p.Margin = [System.Windows.Thickness]::new(14, 14, 14, 14); $d.Content = $p
            $q = [System.Windows.Controls.TextBlock]::new(); $q.Text = $Prompt.Trim(); $q.MaxWidth = 640; $q.TextWrapping = 'Wrap'; $q.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8); [void]$p.Children.Add($q)
            $tb = [System.Windows.Controls.TextBox]::new(); $tb.MinWidth = 420; [void]$p.Children.Add($tb)
            $ok = [System.Windows.Controls.Button]::new(); $ok.Content = 'OK'; $ok.IsDefault = $true; $ok.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0); $ok.Padding = [System.Windows.Thickness]::new(18, 3, 18, 3); $ok.HorizontalAlignment = 'Right'
            $ok.add_Click({ param($sender, $e) [void]$e; [System.Windows.Window]::GetWindow($sender).DialogResult = $true })
            [void]$p.Children.Add($ok)
            $d.add_ContentRendered({ param($sender, $e) [void]$sender; [void]$e; [void]$tb.Focus() }.GetNewClosure())
            if ($d.ShowDialog()) { return $tb.Text }
            return ''
        }
        $V.OnMessage = {
            param($m)
            switch ([string]$m.Type) {
                'line' { & $V.Say $m.Text $m.Color }
                'mode' { $V.Mode.Text = $m.Mode.Text; $V.Exec.IsChecked = [bool]$m.Mode.Exec; $V.Safe.IsChecked = [bool]$m.Mode.Safe }
                'model' { & $V.Build ([int]$m.Index) $m.Model }
                'ask' {
                    $ans = ''
                    try { & $V.Say ('? {0}' -f ([string]$m.Prompt).Trim()) ''; $ans = [string](& $V.AskBox ([string]$m.Prompt)); & $V.Say ('  answer: {0}' -f $ans) '' }
                    finally { $Link.Answers.Add($ans) }
                }
                'confirm' {
                    $yes = $false
                    try {
                        $r = [System.Windows.MessageBox]::Show($V.Window, ('Proceed with: {0}?' -f $m.What), 'WHD Next 3.0', [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question, [System.Windows.MessageBoxResult]::No)
                        $yes = ($r -eq [System.Windows.MessageBoxResult]::Yes)
                        & $V.Say ('  Proceed with: {0}? {1}' -f $m.What, $(if ($yes) { 'yes' } else { 'no' })) ''
                    } finally { $Link.Answers.Add($yes) }
                }
                'done' {
                    & $V.SetBusy $false
                    if ($V.Pending -eq 'action') { & $V.Say '  done.' '' }
                    $V.Pending = ''
                    if ([int]$m.Select -ge 0 -and [int]$m.Select -ne $V.Tabs.SelectedIndex) {
                        $V.Quiet = $true
                        try { $V.Tabs.SelectedIndex = [int]$m.Select } finally { $V.Quiet = $false }
                    }
                }
            }
        }

        # ---- what comes from the engine: read 10 times a second ----
        $V.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $V.Timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $V.Timer.add_Tick({
            if ($V.InTick) { return }          # a question dialog is open: its own message loop keeps ticking
            $V.InTick = $true
            try {
                $n = 0; $m = $null
                while ($n -lt 300 -and $Link.ToView.TryDequeue([ref]$m)) { $n++; & $V.Guard 'message' { & $V.OnMessage $m } }
            } finally { $V.InTick = $false }
        })

        # ---- events ----
        $V.Tabs.add_SelectionChanged({ param($sender, $e) [void]$sender; if ($e.OriginalSource -eq $V.Tabs -and -not $V.Quiet) { & $V.Guard 'tab' { [void](& $V.Send @{ Type = 'model'; Index = $V.Tabs.SelectedIndex } '') } } })
        $V.Exec.add_Click({ & $V.Guard 'EXECUTE switch' { [void](& $V.Send @{ Type = 'exec'; On = [bool]$V.Exec.IsChecked } '') } })
        $V.Safe.add_Click({ & $V.Guard 'safe-mode switch' { [void](& $V.Send @{ Type = 'safe'; On = [bool]$V.Safe.IsChecked } '') } })
        $V.Rp.add_Click({ & $V.Guard 'restore point' { [void](& $V.Send @{ Type = 'rp' } 'action') } })
        $win.add_Closing({
            param($sender, $e)
            [void]$sender
            if ($Link.Flags['Busy']) {
                $e.Cancel = $true
                [void][System.Windows.MessageBox]::Show($V.Window, 'WHD is still working on the last action. Please wait until the log says "done", then close the window.', 'WHD Next 3.0', [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        })
        $win.add_ContentRendered({ & $V.Guard 'first tab' { [void](& $V.Send @{ Type = 'model'; Index = 0 } '') } })
        $V.Timer.Start()
        [void]$win.ShowDialog()
        $V.Timer.Stop()
    } finally {
        $Link.Flags['ViewGone'] = $true
        try { $Link.ToEngine.Add(@{ Type = 'close' }) } catch { [void]$_ }
    }
}
