# Switch-Window — paste this whole file into a PowerShell 7 prompt, then call:  Switch-Window
# That launches a hidden background switcher; press Ctrl+Alt+W to summon it.
# Docs, debugging & roadmap: README.md

# The switcher GUI. Kept as a scriptblock so Switch-Window can ship its source
# text to a detached hidden pwsh process. (A scriptblock is brace-delimited, so
# the C# here-string inside it doesn't collide the way a nested here-string would.)
$SwitchWindowGui = {

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "Switch-Window needs PowerShell 7 -- this is Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Type  pwsh  to drop into PowerShell 7, then load and run again." -ForegroundColor Yellow
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Win32 + hotkey shim -- compiled once per session (a .NET type can't be redefined).
    if (-not ('WinSwitch' -as [type])) {
        # .NET splits WinForms/BCL across many small assemblies; force the whole
        # WinForms closure to load, then reference every loaded assembly that
        # has a file on disk. System.Private.CoreLib (which holds List<>) loads
        # with a blank .Location, so the filter drops it -- add its path back.
        (New-Object System.Windows.Forms.Form).Dispose()
        $null = [System.Windows.Forms.Message]    # loads System.Windows.Forms.Primitives
        $refs = @(
            [System.AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { -not $_.IsDynamic -and $_.Location } |
                ForEach-Object Location
            Join-Path ([System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'System.Private.CoreLib.dll'
        )
        Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class WinSwitch {
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int  GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("dwmapi.dll")] static extern int  DwmGetWindowAttribute(IntPtr h, int attr, out int val, int size);

    delegate bool EnumProc(IntPtr h, IntPtr p);
    public class Win { public IntPtr Handle; public string Title; public int Pid; }

    public static Win[] GetWindows() {
        Win[] arr = new Win[0];
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            int len = GetWindowTextLength(h);
            if (len == 0) return true;
            int cloaked;
            if (DwmGetWindowAttribute(h, 14, out cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var sb = new StringBuilder(len + 1);
            GetWindowText(h, sb, sb.Capacity);
            string t = sb.ToString();
            if (t.Length == 0 || t == "Program Manager") return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            Array.Resize(ref arr, arr.Length + 1);
            arr[arr.Length - 1] = new Win { Handle = h, Title = t, Pid = (int)pid };
            return true;
        }, IntPtr.Zero);
        return arr;
    }

    public static void Activate(IntPtr h) {
        if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
        SetForegroundWindow(h);
    }
}

// A ListBox with double-buffering on -- kills the owner-draw flicker when the
// live timer rebuilds the list (worst in !aot always-visible mode, where it
// rerenders every couple of seconds).
public class BufferedListBox : ListBox {
    public BufferedListBox() { this.DoubleBuffered = true; }
}

// A Form that registers one global hotkey and raises Hotkey when it is pressed.
public class HotForm : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_HOTKEY = 0x0312;
    const int ID = 0xB1B1;
    public event EventHandler Hotkey;

    public bool RegisterHotkey(uint mod, uint vk) { return RegisterHotKey(this.Handle, ID, mod, vk); }
    public void ReleaseHotkey() { UnregisterHotKey(this.Handle, ID); }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && (int)m.WParam == ID && Hotkey != null) Hotkey(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@
    }

    # Per-user state lives in the registry: custom labels under the Labels
    # subkey (keyed by window title), scalar settings as values on the parent.
    $rootKey  = 'HKCU:\Software\SwitchWindow'
    $labelKey = "$rootKey\Labels"
    if (-not (Test-Path $labelKey)) { New-Item -Path $labelKey -Force | Out-Null }

    # --- enumerate visible top-level windows (Handle / App / Title / Label) ---
    $getWindows = {
        $procs = @{}
        foreach ($p in Get-Process) { $procs[$p.Id] = $p.ProcessName }
        $self = $PID
        # custom labels (window title -> label) from the registry
        $labels = @{}
        $lk = Get-Item -LiteralPath $labelKey -ErrorAction SilentlyContinue
        if ($lk) { foreach ($n in $lk.GetValueNames()) { $labels[$n] = [string]$lk.GetValue($n) } }
        [WinSwitch]::GetWindows() |
            Where-Object { $_.Pid -ne $self } |
            ForEach-Object {
                $name = $procs[[int]$_.Pid]; if (-not $name) { $name = '?' }
                [pscustomobject]@{ Handle = $_.Handle; App = $name; Title = $_.Title; Label = $labels[$_.Title] }
            }
    }

    # --- form ---
    $form = New-Object HotForm
    $form.Text            = 'Switch Window'
    $form.ClientSize      = New-Object System.Drawing.Size(744, 424)
    $form.StartPosition   = 'CenterScreen'
    $form.FormBorderStyle = 'Sizable'        # resizable
    $form.TopMost         = $true            # always on top
    $form.ShowInTaskbar   = $false
    $form.KeyPreview      = $true

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point(8, 8)
    $box.Width    = 728
    $box.Anchor   = 'Top, Left, Right'
    $box.Font     = New-Object System.Drawing.Font('Consolas', 11)

    $list = New-Object BufferedListBox
    $list.IntegralHeight = $false   # keep exact height -- no partial-row snapping
    $list.Location       = New-Object System.Drawing.Point(8, 38)
    $list.Size           = New-Object System.Drawing.Size(728, 356)
    $list.Anchor         = 'Top, Bottom, Left, Right'
    $list.Font           = New-Object System.Drawing.Font('Consolas', 11)
    $list.DrawMode       = 'OwnerDrawFixed'
    $list.ItemHeight     = 20

    # Owner-draw each row: bold accent-coloured app headers, indented windows.
    $headerFont = New-Object System.Drawing.Font($list.Font, [System.Drawing.FontStyle]::Bold)
    $list.Add_DrawItem({
        param($s, $e)
        $e.DrawBackground()
        if ($e.Index -lt 0) { return }
        $text = [string]$s.Items[$e.Index]
        if ($script:rows[$e.Index]) {
            # window row -- title in normal text (white when selected); a labelled
            # window gets a green [tag] before it, also white when selected.
            $w = $script:rows[$e.Index]
            if ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) {
                $brush    = [System.Drawing.SystemBrushes]::HighlightText
                $tagBrush = [System.Drawing.SystemBrushes]::HighlightText
            } else {
                $brush    = [System.Drawing.SystemBrushes]::WindowText
                $tagBrush = [System.Drawing.Brushes]::ForestGreen
            }
            $x = [single]($e.Bounds.X + 18)
            $y = [single]($e.Bounds.Y + 2)
            if ($w.Label) {
                $tag = "[$($w.Label)] "
                $e.Graphics.DrawString($tag, $s.Font, $tagBrush, $x, $y)
                $x += $e.Graphics.MeasureString($tag, $s.Font).Width
            }
            $e.Graphics.DrawString($w.Title, $s.Font, $brush, $x, $y)
        } else {
            # app header -- overpaint any selection bar, then bold accent text
            $e.Graphics.FillRectangle([System.Drawing.SystemBrushes]::Window, $e.Bounds)
            $e.Graphics.DrawString($text, $headerFont, [System.Drawing.Brushes]::SteelBlue,
                [single]($e.Bounds.X + 3), [single]($e.Bounds.Y + 2))
        }
    })

    # status bar -- window/app count on the left, live clock on the right
    $status = New-Object System.Windows.Forms.Label
    $status.Location  = New-Object System.Drawing.Point(8, 398)
    $status.Size      = New-Object System.Drawing.Size(560, 18)
    $status.Anchor    = 'Bottom, Left'
    $status.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $status.ForeColor = [System.Drawing.Color]::DimGray

    $clock = New-Object System.Windows.Forms.Label
    $clock.Location  = New-Object System.Drawing.Point(626, 398)
    $clock.Size      = New-Object System.Drawing.Size(110, 18)
    $clock.Anchor    = 'Bottom, Right'
    $clock.TextAlign = 'MiddleRight'
    $clock.Font      = New-Object System.Drawing.Font('Consolas', 9)
    $clock.ForeColor = [System.Drawing.Color]::DimGray

    $form.Controls.Add($box)
    $form.Controls.Add($list)
    $form.Controls.Add($status)
    $form.Controls.Add($clock)

    $script:all  = @()
    $script:rows = @()   # one entry per list row: $null for a header, else the window
    # !aot's stay-visible setting persists between runs.
    $savedAot = (Get-ItemProperty -Path $rootKey -Name AlwaysVisible -ErrorAction SilentlyContinue).AlwaysVisible
    $script:stayVisible = ($savedAot -eq 1)

    # Rebuild the list: filter, group by app, emit a header row per app then its
    # windows. $script:rows runs parallel to $list.Items, so a selected row maps
    # back to its window object (or to $null when the row is a group header).
    $refilter = {
        param([bool]$preserveScroll = $false)
        # remember the selected window so it survives the rebuild
        $keep = $null
        $sel  = $list.SelectedIndex
        if ($sel -ge 0 -and $script:rows[$sel]) { $keep = $script:rows[$sel].Handle }
        # remember scroll position when the caller asks (the live timer does, so a
        # tick doesn't yank the user back to the top while they're browsing).
        $keepTop = if ($preserveScroll) { $list.TopIndex } else { -1 }

        $q = $box.Text.Trim()
        if ($q) { $matched = @($script:all | Where-Object { "$($_.App) $($_.Title) $($_.Label)" -like "*$q*" }) }
        else    { $matched = @($script:all) }

        $groups = $matched | Group-Object App | Sort-Object Name
        $rows   = [System.Collections.Generic.List[object]]::new()
        $apps   = 0

        $list.BeginUpdate()
        $list.Items.Clear()
        foreach ($g in $groups) {
            $apps++
            [void]$list.Items.Add("$($g.Name) ($($g.Count))")
            $rows.Add($null)
            # sort each group by display name -- the [label] tag floats labelled windows up
            foreach ($w in ($g.Group | Sort-Object @{ Expression = { if ($_.Label) { "[$($_.Label)] $($_.Title)" } else { $_.Title } } })) {
                [void]$list.Items.Add($w.Title)
                $rows.Add($w)
            }
        }
        $list.EndUpdate()
        $script:rows = $rows

        # re-select the same window if it's still listed, else the first window
        $want = -1
        if ($null -ne $keep) {
            for ($k = 0; $k -lt $rows.Count; $k++) {
                if ($rows[$k] -and $rows[$k].Handle.ToInt64() -eq $keep.ToInt64()) { $want = $k; break }
            }
        }
        if ($want -lt 0 -and $list.Items.Count -gt 1) { $want = 1 }
        if ($want -ge 0) { $list.SelectedIndex = $want }
        # Restore scroll AFTER setting the selection (setting SelectedIndex can
        # auto-scroll to make it visible; we override that to keep the user's view).
        if ($keepTop -ge 0 -and $list.Items.Count -gt 0) {
            $list.TopIndex = [Math]::Min($keepTop, $list.Items.Count - 1)
        }

        $s = "{0} of {1} windows     {2} apps" -f $matched.Count, $script:all.Count, $apps
        if ($script:stayVisible) { $s += '     [always visible]' }
        $status.Text = $s
    }

    # Refresh the list, clear the filter, show the form and focus it. Runs on each hotkey.
    $summon = {
        $script:all = @(& $getWindows)
        $box.Clear()
        & $refilter
        $form.Show()
        $form.TopMost = $true
        $form.Activate()
        $box.Focus()
    }

    # Activate the chosen window. Normally the switcher hides afterwards (it stays
    # loaded -- re-summon with the hotkey); in !aot "always visible" mode it stays
    # open. A header row maps to $null in $script:rows -- picking one does nothing.
    $pick = {
        $i = $list.SelectedIndex
        if ($i -ge 0 -and $script:rows[$i]) {
            $h = $script:rows[$i].Handle
            if (-not $script:stayVisible) { $form.Hide() }
            [WinSwitch]::Activate($h)
        }
    }

    # Modal feedback helper -- the 2 s live refresh wipes status-bar messages
    # before the user can read them, so anything worth surfacing goes through
    # a dialog instead. Parented to $form, which is TopMost.
    $tell = {
        param($msg, $icon = 'Information')
        [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Switch Window', 'OK', $icon) | Out-Null
    }

    # Run a !command typed in the search box -- Enter dispatches here when the
    # box text starts with '!'.
    $runCommand = {
        param($cmd)
        # capture the selected window before clearing the box -- the clear
        # triggers a refilter, and a command may need the window that was picked.
        $i   = $list.SelectedIndex
        $sel = if ($i -ge 0) { $script:rows[$i] } else { $null }
        $box.Clear()   # leave command mode; the clear triggers a refilter
        $parts = $cmd.Trim() -split '\s+', 2
        $arg   = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
        switch ($parts[0].ToLower()) {
            '!aot' {
                $script:stayVisible = -not $script:stayVisible
                Set-ItemProperty -Path $rootKey -Name AlwaysVisible -Value ([int]$script:stayVisible) -Type DWord
                & $refilter   # the [always visible] tag in the status bar is the cue
            }
            '!hotkey' {
                if (-not $arg) {
                    & $tell "Hotkey: $($script:hotkeyStr)"
                } else {
                    $parsed = & $parseHotkey $arg
                    if (-not $parsed) {
                        & $tell "Couldn't parse: $arg" 'Warning'
                    } else {
                        $newStr = & $formatHotkey $parsed.Mod $parsed.Vk
                        $form.ReleaseHotkey()
                        if (-not $form.RegisterHotkey($parsed.Mod, $parsed.Vk)) {
                            # Conflict -- restore the old binding so the user isn't locked out.
                            $form.RegisterHotkey($script:hotkeyMod, $script:hotkeyVk) | Out-Null
                            & $tell "Couldn't claim: $newStr  (already taken)" 'Warning'
                        } else {
                            $script:hotkeyMod = $parsed.Mod
                            $script:hotkeyVk  = $parsed.Vk
                            $script:hotkeyStr = $newStr
                            Set-ItemProperty -Path $rootKey -Name Hotkey -Value $newStr -Type String
                            & $tell "Hotkey: $newStr"
                        }
                    }
                }
            }
            '!label' {
                if (-not $sel) {
                    & $tell '!label -- select a window first' 'Warning'
                } else {
                    if ($arg) {
                        Set-ItemProperty -Path $labelKey -Name $sel.Title -Value $arg
                    } else {
                        Remove-ItemProperty -Path $labelKey -Name $sel.Title -ErrorAction SilentlyContinue
                    }
                    $script:all = @(& $getWindows)   # re-read labels (the green [tag] is the cue)
                    & $refilter
                }
            }
            '!quit' {
                # End the message loop -- Application.Run() returns and the
                # try/finally releases the hotkey before the process exits.
                [System.Windows.Forms.Application]::Exit()
            }
            '!help' {
                # Open the online README (rendered) in the default browser.
                try {
                    Start-Process 'https://github.com/robertvigil/pwsh-switch-window#readme'
                } catch {
                    & $tell "Couldn't open help:  $($_.Exception.Message)" 'Warning'
                }
            }
            default {
                & $tell "Unknown command  '$($parts[0])'  --  try  !help" 'Warning'
            }
        }
    }

    # Typing: '!'-prefixed text is a command (don't filter, freeze the list);
    # anything else filters as normal.
    $box.Add_TextChanged({
        if ($box.Text.StartsWith('!')) {
            $status.Text = 'Command mode -- Enter to run   (!help for commands)'
        } else {
            & $refilter
        }
    })
    $list.Add_DoubleClick($pick)

    # Up/Down move the selection but skip header rows ($null in $script:rows).
    $form.Add_KeyDown({
        param($s, $e)
        switch ($e.KeyCode) {
            'Down' {
                for ($j = $list.SelectedIndex + 1; $j -lt $list.Items.Count; $j++) {
                    if ($script:rows[$j]) { $list.SelectedIndex = $j; break }
                }
                $e.SuppressKeyPress = $true
            }
            'Up' {
                for ($j = $list.SelectedIndex - 1; $j -ge 0; $j--) {
                    if ($script:rows[$j]) { $list.SelectedIndex = $j; break }
                }
                $e.SuppressKeyPress = $true
            }
            'Return' {
                if ($box.Text.StartsWith('!')) { & $runCommand $box.Text } else { & $pick }
                $e.SuppressKeyPress = $true
            }
            'Escape' { $form.Hide(); $e.SuppressKeyPress = $true }
            'F5'     { $script:all = @(& $getWindows); & $refilter; $e.SuppressKeyPress = $true }
        }
    })

    # The X button hides the switcher instead of closing it (keeps it loaded).
    $form.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $form.Hide()
        }
    })

    $form.Add_Hotkey({ & $summon })

    # Live clock in the status bar -- ticks only while the switcher is visible.
    $clockTimer = New-Object System.Windows.Forms.Timer
    $clockTimer.Interval = 1000
    $clockTimer.Add_Tick({ $clock.Text = (Get-Date).ToString('h:mm:ss tt') })

    # Live window-list refresh -- keeps the list current while the switcher is
    # visible (the case that matters: !aot's always-visible mode, where there's
    # no summon to rebuild on). Skips the refilter when the box is mid-command
    # so a tick can't disrupt a command being typed.
    $liveTimer = New-Object System.Windows.Forms.Timer
    $liveTimer.Interval = 2000
    $liveTimer.Add_Tick({
        $script:all = @(& $getWindows)
        if (-not $box.Text.StartsWith('!')) { & $refilter $true }   # preserve scroll
    })

    $form.Add_VisibleChanged({
        if ($form.Visible) {
            $clock.Text = (Get-Date).ToString('h:mm:ss tt')
            $clockTimer.Start()
            $liveTimer.Start()
        } else {
            $clockTimer.Stop()
            $liveTimer.Stop()
        }
    })

    # Parse a "Ctrl+Alt+W"-style spec into Win32 (modMask, vk). Modifiers:
    # Ctrl/Control, Alt, Shift, Win. Keys: A-Z, 0-9, F1-F12, Space, Tab,
    # Escape/Esc, Enter/Return. Returns $null on any unrecognised part,
    # duplicate key, or no key.
    $parseHotkey = {
        param($spec)
        if (-not $spec) { return $null }
        $mod = 0; $vk = 0
        foreach ($p in $spec.Split('+')) {
            $p = $p.Trim()
            $thisVk = 0
            switch ($p) {
                'ctrl'    { $mod = $mod -bor 2 }
                'control' { $mod = $mod -bor 2 }
                'alt'     { $mod = $mod -bor 1 }
                'shift'   { $mod = $mod -bor 4 }
                'win'     { $mod = $mod -bor 8 }
                'space'   { $thisVk = 0x20 }
                'tab'     { $thisVk = 0x09 }
                'escape'  { $thisVk = 0x1B }
                'esc'     { $thisVk = 0x1B }
                'enter'   { $thisVk = 0x0D }
                'return'  { $thisVk = 0x0D }
                default {
                    if     ($p -match '^[A-Za-z]$')           { $thisVk = [int][char]$p.ToUpper() }
                    elseif ($p -match '^[0-9]$')              { $thisVk = [int][char]$p }
                    elseif ($p -match '^[Ff]([1-9]|1[0-2])$') { $thisVk = 0x70 + [int]$Matches[1] - 1 }
                    else                                      { return $null }
                }
            }
            if ($thisVk -ne 0) {
                if ($vk -ne 0) { return $null }   # more than one key part
                $vk = $thisVk
            }
        }
        if ($vk -eq 0) { return $null }   # only modifiers, no key
        return @{ Mod = $mod; Vk = $vk }
    }

    # Format (modMask, vk) back into a canonical "Ctrl+Alt+W" string. Used to
    # canonicalize what the user typed and to display the current binding.
    $formatHotkey = {
        param($mod, $vk)
        $out = ''
        if ($mod -band 2) { $out += 'Ctrl+' }
        if ($mod -band 1) { $out += 'Alt+' }
        if ($mod -band 4) { $out += 'Shift+' }
        if ($mod -band 8) { $out += 'Win+' }
        $key = switch ($vk) {
            0x20    { 'Space' }
            0x09    { 'Tab' }
            0x1B    { 'Escape' }
            0x0D    { 'Enter' }
            default {
                if     ($vk -ge 0x41 -and $vk -le 0x5A) { [string][char]$vk }
                elseif ($vk -ge 0x30 -and $vk -le 0x39) { [string][char]$vk }
                elseif ($vk -ge 0x70 -and $vk -le 0x7B) { "F$($vk - 0x6F)" }
                else                                    { "VK{0:X2}" -f $vk }
            }
        }
        $out + $key
    }

    # Read the saved hotkey (default Ctrl+Alt+W). Fall back to the default if
    # the saved string is corrupt; if the resulting combo's already taken by
    # another program, show the message-box and exit -- same recovery path as
    # before, just for whichever combo is configured.
    $savedHotkey = (Get-ItemProperty -Path $rootKey -Name Hotkey -ErrorAction SilentlyContinue).Hotkey
    if (-not $savedHotkey) { $savedHotkey = 'Ctrl+Alt+W' }
    $parsed = & $parseHotkey $savedHotkey
    if (-not $parsed) {
        $savedHotkey = 'Ctrl+Alt+W'
        $parsed = & $parseHotkey $savedHotkey
    }
    $script:hotkeyMod = $parsed.Mod
    $script:hotkeyVk  = $parsed.Vk
    $script:hotkeyStr = & $formatHotkey $parsed.Mod $parsed.Vk

    [void]$form.Handle
    if (-not $form.RegisterHotkey($script:hotkeyMod, $script:hotkeyVk)) {
        # An always-visible window from another process (or a leftover switcher
        # still holding the hotkey) would otherwise eclipse this message-box.
        # Parent it to a throwaway topmost off-screen owner so it floats above.
        $msgOwner = New-Object System.Windows.Forms.Form
        $msgOwner.FormBorderStyle = 'None'
        $msgOwner.ShowInTaskbar   = $false
        $msgOwner.TopMost         = $true
        $msgOwner.StartPosition   = 'Manual'
        $msgOwner.Location        = New-Object System.Drawing.Point(-32000, -32000)
        $msgOwner.Size            = New-Object System.Drawing.Size(1, 1)
        $msgOwner.Show()
        [System.Windows.Forms.MessageBox]::Show($msgOwner,
            "Switch-Window could not register $($script:hotkeyStr) -- another program or a leftover switcher already owns it. Close that one and start again.",
            'Switch Window', 'OK', 'Warning') | Out-Null
        $msgOwner.Dispose()
        return
    }
    try { [System.Windows.Forms.Application]::Run() }
    finally {
        # On Ctrl+C the form is still alive -- release the hotkey by hand. After
        # !quit, Application.Exit() has already disposed the form and the OS
        # released the hotkey when its window handle was destroyed.
        if (-not $form.IsDisposed) { $form.ReleaseHotkey() }
    }
}

function Switch-Window {
    [CmdletBinding()]
    param()
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Host "Switch-Window needs PowerShell 7 -- this is Windows PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Red
        Write-Host "Type  pwsh  to drop into PowerShell 7, then load and run again." -ForegroundColor Yellow
        return
    }
    # Hand the GUI source to the detached process through an inherited environment
    # variable -- no temp file (this machine's policy locks .ps1 files) and no
    # command-line length limit; the command line carries only a tiny loader.
    # -STA is required: pwsh defaults to MTA for -EncodedCommand, but WinForms and
    # RegisterHotKey need a single-threaded apartment.
    $env:SwitchWindowGuiSrc = $SwitchWindowGui.ToString()
    $loader  = 'Invoke-Expression $env:SwitchWindowGuiSrc'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($loader))
    $pwshExe = (Get-Process -Id $PID).Path
    $proc    = Start-Process -FilePath $pwshExe -PassThru -WindowStyle Hidden `
                             -ArgumentList '-STA', '-NoProfile', '-EncodedCommand', $encoded
    Remove-Item Env:\SwitchWindowGuiSrc -ErrorAction SilentlyContinue
    Write-Host "Window switcher running (PID $($proc.Id)) -- press Ctrl+Alt+W to summon it." -ForegroundColor Cyan
    Write-Host "Stop it with:  Stop-Process -Id $($proc.Id)" -ForegroundColor DarkGray
}