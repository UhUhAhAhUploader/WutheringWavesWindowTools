param(
    [Parameter(Position=0)][string]$ExePath = "",
    [Parameter(Position=1)][string]$WindowTitle = "鸣潮  ",
    [Parameter(Position=2)][string]$GameArgs = "-windowed",
    [Parameter(Position=3)][int]$GameW = 1920,
    [Parameter(Position=4)][int]$GameH = 800
)


# ── Load Assemblies ──
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host "FATAL: Failed to load assemblies: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── Global Exception Handlers ──
try {
    [System.Windows.Forms.Application]::add_ThreadException({
        param($sender, $e)
        [System.Windows.Forms.MessageBox]::Show("UI异常:`n$($e.Exception.Message)", "错误", "OK", "Error") | Out-Null
    })
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $e)
        [System.Windows.Forms.MessageBox]::Show("后台异常:`n$($e.ExceptionObject.Message)", "错误", "OK", "Error") | Out-Null
    })
} catch {
    Write-Host "FATAL: Failed to register exception handlers: $($_.Exception.Message)" -ForegroundColor Red
}

# ── DPI Awareness ──
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class DpiUtil {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int awareness);
}
"@ -ErrorAction SilentlyContinue
try { [DpiUtil]::SetProcessDpiAwareness(2) | Out-Null } catch { [DpiUtil]::SetProcessDPIAware() | Out-Null }

# ── Win32 API Types ──
try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
public delegate void WinEventProc(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
public delegate void ForegroundChangedHandler(IntPtr hwnd);
public delegate void WindowCreatedHandler(IntPtr hwnd);

public class Win32 {
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int idx);
    [DllImport("user32.dll", EntryPoint = "SetWindowLong")] public static extern int SetWindowLong32(IntPtr hWnd, int idx, int val);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] public static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int idx, IntPtr val);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventProc lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateRoundRectRgn(int nLeftRect, int nTopRect, int nRightRect, int nBottomRect, int nWidthEllipse, int nHeightEllipse);
    [DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    public const uint WS_CAPTION = 0x00C00000, WS_THICKFRAME = 0x00040000;
    public const uint WS_MINIMIZEBOX = 0x00020000, WS_MAXIMIZEBOX = 0x00010000, WS_SYSMENU = 0x00080000;
    public const int GWL_STYLE = -16;
    public const uint SWP_FRAMECHANGED = 0x0020, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;
    public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002;
    public const int SW_SHOW = 5, SW_HIDE = 0;
    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint EVENT_OBJECT_CREATE = 0x8000;
    public const uint EVENT_OBJECT_SHOW = 0x8002;
    public const int OBJID_WINDOW = 0;
    public const int CHILDID_SELF = 0;
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);
    public const uint WM_CLOSE = 0x0010;

    public static void SetWindowLongCompat(IntPtr hWnd, int idx, int val) {
        if (IntPtr.Size == 8) SetWindowLongPtr64(hWnd, idx, new IntPtr(val));
        else SetWindowLong32(hWnd, idx, val);
    }
}

public class BlackBgForm : Form {
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= (int)0x08000000;
            cp.ExStyle |= (int)0x00000080;
            return cp;
        }
    }
}

public class FocusWatcher {
    private WinEventProc _proc;
    private IntPtr _hook;
    public event ForegroundChangedHandler ForegroundChanged;

    public void Start() {
        _proc = new WinEventProc(OnEvent);
        _hook = Win32.SetWinEventHook(Win32.EVENT_SYSTEM_FOREGROUND, Win32.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, _proc, 0, 0, Win32.WINEVENT_OUTOFCONTEXT);
    }

    public void Stop() {
        if (_hook != IntPtr.Zero) { Win32.UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
    }

    private void OnEvent(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime) {
        if (ForegroundChanged != null) ForegroundChanged(hwnd);
    }
}

public class WindowCreatedWatcher {
    private WinEventProc _proc;
    private IntPtr _hook;
    public event WindowCreatedHandler WindowCreated;

    public void Start(uint pid) {
        _proc = new WinEventProc(OnEvent);
        _hook = Win32.SetWinEventHook(Win32.EVENT_OBJECT_CREATE, Win32.EVENT_OBJECT_SHOW, IntPtr.Zero, _proc, pid, 0, Win32.WINEVENT_OUTOFCONTEXT);
    }

    public void Stop() {
        if (_hook != IntPtr.Zero) { Win32.UnhookWinEvent(_hook); _hook = IntPtr.Zero; }
    }

    private void OnEvent(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime) {
        if (idObject != Win32.OBJID_WINDOW || idChild != Win32.CHILDID_SELF) return;
        if (WindowCreated != null) WindowCreated(hwnd);
    }
}
"@ -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop
} catch {
    Write-Host "FATAL: Failed to load Win32 types: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ── State ──
enum SessionState { Idle; Finding; Configuring; Running; Stopping }
$script:state = [SessionState]::Idle
$script:cancelToken = $false
$script:gameHwnd = [IntPtr]::Zero
$script:bg = $null
$script:bgHwnd = [IntPtr]::Zero
$script:watcher = $null
$script:windowWatcher = $null
$script:originalStyle = 0
$script:originalRect = New-Object Win32+RECT
$script:targetPid = 0
$script:lastFgHwnd = [IntPtr]::Zero
$script:screen = $null
$script:sw = 0
$script:sh = 0
$script:x = 0
$script:y = 0
$script:targetW = 0
$script:targetH = 0
$script:resValid = $true
$script:isAdmin = $false

# ── Color Palette ──
$script:C_BG       = [System.Drawing.Color]::FromArgb(30, 30, 36)
$script:C_CARD     = [System.Drawing.Color]::FromArgb(40, 42, 50)
$script:C_BORDER   = [System.Drawing.Color]::FromArgb(55, 58, 68)
$script:C_TEXT     = [System.Drawing.Color]::FromArgb(230, 230, 235)
$script:C_TEXT_SEC = [System.Drawing.Color]::FromArgb(150, 155, 165)
$script:C_ACCENT   = [System.Drawing.Color]::FromArgb(88, 165, 255)
$script:C_SUCCESS  = [System.Drawing.Color]::FromArgb(80, 200, 120)
$script:C_WARN     = [System.Drawing.Color]::FromArgb(255, 180, 80)
$script:C_DANGER   = [System.Drawing.Color]::FromArgb(240, 90, 90)
$script:C_LOG_BG   = [System.Drawing.Color]::FromArgb(25, 26, 32)
$script:C_DISABLED = [System.Drawing.Color]::FromArgb(45, 47, 55)

# ── Custom Tooltip ──
$script:tipForm = New-Object System.Windows.Forms.Form
$script:tipForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:tipForm.ShowInTaskbar = $false
$script:tipForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:tipForm.Size = New-Object System.Drawing.Size(460, 130)
$script:tipForm.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 225)
$script:tipForm.Visible = $false

$tipBox = New-Object System.Windows.Forms.RichTextBox
$tipBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$tipBox.ReadOnly = $true
$tipBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tipBox.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 225)
$tipBox.ForeColor = [System.Drawing.Color]::Black
$tipBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$tipBox.DetectUrls = $true
$tipBox.Text = "UE4 的窗口并非裸 Win32 窗口，而是由 Slate → FWindowsWindow 逐层封装。`n直接修改分辨率，下一帧事件循环或视口更新时极易出现回弹或坐标错乱。`n对于无边框 UE4 也推荐走GameUserSettings，但本程序实测下来无边框使用 win32 api 似乎没有问题。`nhttps://github.com/YawLighthouse/UMG-Slate-Compendium"
$tipBox.Add_LinkClicked({
    try { [System.Diagnostics.Process]::Start($_.LinkText) | Out-Null } catch {}
})
$script:tipForm.Controls.Add($tipBox)

$script:tipShowTimer = New-Object System.Windows.Forms.Timer
$script:tipShowTimer.Interval = 50
$script:tipShowTimer.Add_Tick({
    $script:tipShowTimer.Stop()
    $pt = [System.Windows.Forms.Cursor]::Position
    $helpRect = $script:btnHelp.RectangleToScreen($script:btnHelp.ClientRectangle)
    if ($helpRect.Contains($pt)) {
        $loc = $script:btnHelp.PointToScreen([System.Drawing.Point]::new(0, $script:btnHelp.Height + 2))
        $script:tipForm.Location = $loc
        $script:tipForm.Show()
    }
})

$script:tipHideTimer = New-Object System.Windows.Forms.Timer
$script:tipHideTimer.Interval = 50
$script:tipHideTimer.Add_Tick({
    $pt = [System.Windows.Forms.Cursor]::Position
    $helpRect = $script:btnHelp.RectangleToScreen($script:btnHelp.ClientRectangle)
    $tipRect = $script:tipForm.RectangleToScreen($script:tipForm.ClientRectangle)
    if (-not $helpRect.Contains($pt) -and -not $tipRect.Contains($pt)) {
        $script:tipForm.Hide()
        $script:tipHideTimer.Stop()
    }
})

$script:tipForm.Add_MouseEnter({ $script:tipHideTimer.Stop() })
$script:tipForm.Add_MouseLeave({ $script:tipHideTimer.Start() })

# ── Borderless Tooltip ──
$script:tipBorderlessForm = New-Object System.Windows.Forms.Form
$script:tipBorderlessForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:tipBorderlessForm.ShowInTaskbar = $false
$script:tipBorderlessForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:tipBorderlessForm.Size = New-Object System.Drawing.Size(480, 140)
$script:tipBorderlessForm.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 225)
$script:tipBorderlessForm.Visible = $false

$tipBorderlessBox = New-Object System.Windows.Forms.RichTextBox
$tipBorderlessBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$tipBorderlessBox.ReadOnly = $true
$tipBorderlessBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$tipBorderlessBox.BackColor = [System.Drawing.Color]::FromArgb(255, 255, 225)
$tipBorderlessBox.ForeColor = [System.Drawing.Color]::Black
$tipBorderlessBox.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$tipBorderlessBox.Text = "修改其他进程窗口的边框样式（SetWindowLong GWL_STYLE）需要管理员权限。`n`n在 Windows UAC 机制下，标准用户进程无法修改高完整性级别进程（如游戏）的窗口样式位，否则会被系统拒绝（ERROR_ACCESS_DENIED）。`n`n请以管理员身份运行本工具以启用此功能。"
$script:tipBorderlessForm.Controls.Add($tipBorderlessBox)

$script:tipBorderlessShowTimer = New-Object System.Windows.Forms.Timer
$script:tipBorderlessShowTimer.Interval = 50
$script:tipBorderlessShowTimer.Add_Tick({
    $script:tipBorderlessShowTimer.Stop()
    $pt = [System.Windows.Forms.Cursor]::Position
    $helpRect = $script:btnBorderlessHelp.RectangleToScreen($script:btnBorderlessHelp.ClientRectangle)
    if ($helpRect.Contains($pt)) {
        $loc = $script:btnBorderlessHelp.PointToScreen([System.Drawing.Point]::new(0, $script:btnBorderlessHelp.Height + 2))
        $script:tipBorderlessForm.Location = $loc
        $script:tipBorderlessForm.Show()
    }
})

$script:tipBorderlessHideTimer = New-Object System.Windows.Forms.Timer
$script:tipBorderlessHideTimer.Interval = 50
$script:tipBorderlessHideTimer.Add_Tick({
    $pt = [System.Windows.Forms.Cursor]::Position
    $helpRect = $script:btnBorderlessHelp.RectangleToScreen($script:btnBorderlessHelp.ClientRectangle)
    $tipRect = $script:tipBorderlessForm.RectangleToScreen($script:tipBorderlessForm.ClientRectangle)
    if (-not $helpRect.Contains($pt) -and -not $tipRect.Contains($pt)) {
        $script:tipBorderlessForm.Hide()
        $script:tipBorderlessHideTimer.Stop()
    }
})

$script:tipBorderlessForm.Add_MouseEnter({ $script:tipBorderlessHideTimer.Stop() })
$script:tipBorderlessForm.Add_MouseLeave({ $script:tipBorderlessHideTimer.Start() })

# ── Safe UI Invoke ──
function Safe-Invoke($control, [scriptblock]$action) {
    try {
        if ($control -and -not $control.IsDisposed -and -not $control.Disposing) {
            if ($control.InvokeRequired) {
                $control.BeginInvoke($action) | Out-Null
            } else {
                & $action
            }
        }
    } catch {
        try { Log "[WARN] Safe-Invoke: $($_.Exception.Message)" "Yellow" } catch {}
    }
}

# ── Log to UI ──
function Log($msg, $color="Gray") {
    Safe-Invoke $script:logBox {
        try {
            $script:logBox.SelectionStart = $script:logBox.TextLength
            $script:logBox.SelectionColor = switch($color) {
                "Red"    { $script:C_DANGER }
                "Yellow" { $script:C_WARN }
                "Green"  { $script:C_SUCCESS }
                default  { $script:C_TEXT_SEC }
            }
            $script:logBox.AppendText("$msg`r`n")
            $script:logBox.SelectionColor = $script:C_TEXT_SEC
            $script:logBox.ScrollToCaret()

            # 限制日志行数
            $lines = $script:logBox.Lines
            if ($lines.Length -gt 500) {
                $script:logBox.Text = [string]::Join("`r`n", $lines[($lines.Length - 500)..($lines.Length - 1)])
                $script:logBox.SelectionStart = $script:logBox.TextLength
            }
        } catch {}
    }
}

# ── Bidirectional Sync: Resolution <-> Args ──
$script:_syncing = $false

function Sync-ArgsFromUI() {
    if ($script:_syncing) { return }
    $script:_syncing = $true
    try {
        $argsText = $script:txtArgs.Text
        $w = $script:txtW.Text
        $h = $script:txtH.Text

        $argsText = $argsText -replace '\s*-ResX=\S*', ''
        $argsText = $argsText -replace '\s*-ResY=\S*', ''
        $argsText = $argsText.Trim()

        # 根据窗口模式调整启动参数
        $mode = $script:cmbWindowMode.SelectedIndex
        $argsText = $argsText -replace '\s*-windowed', ''
        $argsText = $argsText -replace '\s*-fullscreen', ''
        $argsText = $argsText.Trim()

        if ($mode -eq 0) { $argsText = "$argsText -windowed".Trim() }
        elseif ($mode -eq 1) { $argsText = "$argsText -fullscreen".Trim() }

        $argsText = "$argsText -ResX=$w -ResY=$h".Trim()
        $script:txtArgs.Text = $argsText
    } catch {} finally {
        $script:_syncing = $false
    }
}

function Sync-UIFromArgs() {
    if ($script:_syncing) { return }
    $script:_syncing = $true
    try {
        $argsText = $script:txtArgs.Text
        if ($argsText -match '-ResX=(\d+)') {
            $script:txtW.Text = $matches[1]
        }
        if ($argsText -match '-ResY=(\d+)') {
            $script:txtH.Text = $matches[1]
        }
    } catch {} finally {
        $script:_syncing = $false
    }
}

# ── Resolution Validation ──
function Validate-Resolution() {
    try {
        $w = [int]$script:txtW.Text
        $h = [int]$script:txtH.Text

        # 检查所有屏幕的最大尺寸
        $maxW = 0; $maxH = 0
        foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
            if ($scr.Bounds.Width -gt $maxW) { $maxW = $scr.Bounds.Width }
            if ($scr.Bounds.Height -gt $maxH) { $maxH = $scr.Bounds.Height }
        }

        if ($w -le 0 -or $h -le 0) {
            throw "分辨率必须大于 0"
        }
        if ($w -gt $maxW -or $h -gt $maxH) {
            throw "不能超过最大显示器大小 (${maxW}×${maxH})"
        }

        $script:txtW.BackColor = $script:C_BG
        $script:txtH.BackColor = $script:C_BG
        $script:lblResWarning.Visible = $false
        $script:resValid = $true
        Update-UIState
        return $true
    } catch {
        $script:txtW.BackColor = [System.Drawing.Color]::FromArgb(80, 40, 40)
        $script:txtH.BackColor = [System.Drawing.Color]::FromArgb(80, 40, 40)
        $script:lblResWarning.Text = "⚠ 分辨率无效: $($_.Exception.Message)"
        $script:lblResWarning.Visible = $true
        $script:resValid = $false
        Update-UIState
        return $false
    }
}

# ── Auto-Start Toggle: Disable Path & Args when unchecked ──
function Update-AutoStartUI() {
    $enabled = $script:chkAutoStart.Checked
    $script:txtExe.Enabled = $enabled
    $script:txtArgs.Enabled = $enabled
    $script:btnBrowse.Enabled = $enabled
    $script:txtW.Enabled = $enabled
    $script:txtH.Enabled = $enabled
    $script:cmbWindowMode.Enabled = $enabled
    # 帮助按钮可见性：只在自动启动禁用时显示（Win32 API 修改现有窗口时提示）
    $script:btnHelp.Visible = -not $enabled

    # 无边框选项：需要管理员权限才能修改其他进程窗口样式
    $borderlessEnabled = $script:isAdmin
    $script:chkBorderless.Enabled = $borderlessEnabled
    $script:btnBorderlessHelp.Visible = -not $borderlessEnabled
    if (-not $borderlessEnabled) {
        $script:chkBorderless.Checked = $false
    }

    $bg = if ($enabled) { $script:C_BG } else { $script:C_DISABLED }
    $fg = if ($enabled) { $script:C_TEXT } else { $script:C_TEXT_SEC }

    $script:txtExe.BackColor = $bg
    $script:txtExe.ForeColor = $fg
    $script:txtArgs.BackColor = $bg
    $script:txtArgs.ForeColor = $fg
    $script:txtW.BackColor = $bg
    $script:txtW.ForeColor = $fg
    $script:txtH.BackColor = $bg
    $script:txtH.ForeColor = $fg
    $script:cmbWindowMode.BackColor = $bg
    $script:cmbWindowMode.ForeColor = $fg
}

# ── Window Mode Changed ──
function OnWindowModeChanged() {
    Sync-ArgsFromUI
}

# ── Find Game Window ──
function Find-GameWindow($title) {
    try {
        $sb = New-Object System.Text.StringBuilder(256)
        $script:_fg_foundHwnd = [IntPtr]::Zero
        $script:_fg_checkCount = 0

        $callback = [EnumWindowsProc] {
            param($hWnd, $lParam)
            if ([Win32]::IsWindowVisible($hWnd)) {
                [Win32]::GetWindowText($hWnd, $sb, 256) | Out-Null
                $t = $sb.ToString()

                if ($t -ne "") {
                    $script:_fg_checkCount++
                    Log "  [Enum #$($script:_fg_checkCount)] hWnd=$hWnd | Title='$t'" "Gray"
                }

                if ($t -eq $title) {
                    Log "  >>> MATCH: hWnd=$hWnd | Title='$t'" "Green"
                    $script:_fg_foundHwnd = $hWnd
                    return $false
                }
            }
            return $true
        }

        [Win32]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        Log "  [EnumWindows] 共检查 $($script:_fg_checkCount) 个可见窗口" "Gray"
        return $script:_fg_foundHwnd
    } catch {
        Log "[ERROR] 查找窗口异常: $($_.Exception.Message)" "Red"
        return [IntPtr]::Zero
    }
}

function Stop-Session() {
    try {
        if ($script:state -eq [SessionState]::Idle -or $script:state -eq [SessionState]::Stopping) { return }
        $script:state = [SessionState]::Stopping
        $script:cancelToken = $true

        if ($script:windowWatcher) {
            try { $script:windowWatcher.Stop() } catch {}
            $script:windowWatcher = $null
        }
        if ($script:watcher) {
            try { $script:watcher.Stop() } catch {}
            $script:watcher = $null
        }
        if ($script:bg -and -not $script:bg.IsDisposed -and -not $script:bg.Disposing) {
            Safe-Invoke $script:bg { $script:bg.Close() }
        }

        if ([Win32]::IsWindow($script:gameHwnd)) {
            Log "[INFO] 正在恢复游戏窗口样式..."
            try { 
                [Win32]::SetWindowLongCompat($script:gameHwnd,[Win32]::GWL_STYLE,$script:originalStyle) 
                # 恢复样式后必须发送 SWP_FRAMECHANGED 使系统重新计算非客户区
                [Win32]::SetWindowPos($script:gameHwnd,[IntPtr]::Zero,0,0,0,0,
                    [Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE -bor [Win32]::SWP_NOZORDER -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_FRAMECHANGED) | Out-Null
            } catch {}
            try {
                # 恢复样式后重新获取当前窗口尺寸，避免非客户区计算错误
                $currRect = New-Object Win32+RECT
                [Win32]::GetWindowRect($script:gameHwnd, [ref]$currRect) | Out-Null
                $w = $currRect.Right - $currRect.Left
                $h = $currRect.Bottom - $currRect.Top
                [Win32]::SetWindowPos($script:gameHwnd,[IntPtr]::Zero,$script:originalRect.Left,$script:originalRect.Top,$w,$h,
                    [Win32]::SWP_SHOWWINDOW) | Out-Null
            } catch {}
            try { [Win32]::ShowWindow($script:gameHwnd,[Win32]::SW_SHOW) | Out-Null } catch {}
        } else {
            if ($script:targetPid -gt 0) {
                try {
                    $proc = Get-Process -Id $script:targetPid -ErrorAction SilentlyContinue
                    if ($proc -and -not $proc.HasExited) {
                        # 先尝试优雅关闭
                        $gameHwnd = $proc.MainWindowHandle
                        if ($gameHwnd -ne [IntPtr]::Zero) {
                            [Win32]::PostMessage($gameHwnd, [Win32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
                            # 等待 3 秒
                            $sw = [System.Diagnostics.Stopwatch]::StartNew()
                            while ($sw.ElapsedMilliseconds -lt 3000 -and -not $proc.HasExited) {
                                Start-Sleep -Milliseconds 100
                            }
                        }
                        # 如果仍未退出，再强制终止
                        if (-not $proc.HasExited) { $proc.Kill() }
                    }
                } catch {}
            }
        }

        $script:gameHwnd = [IntPtr]::Zero
        $script:bg = $null
        $script:targetPid = 0
        $script:state = [SessionState]::Idle
        Log "[INFO] 已停止运行。"
        Update-UIState
    } catch {
        Log "[FATAL] Stop-Session: $($_.Exception.Message)" "Red"
        $script:state = [SessionState]::Idle
        Update-UIState
    }
}

function Update-UIState() {
    $running = ($script:state -eq [SessionState]::Running -or $script:state -eq [SessionState]::Finding -or $script:state -eq [SessionState]::Configuring)
    Safe-Invoke $script:btnStart {
        try {
            $script:btnStart.Enabled = (-not $running) -and $script:resValid
            $script:btnStop.Enabled = $running
            if ($running) {
                $script:lblStatus.Text = switch($script:state) {
                    ([SessionState]::Finding) { "查找中..." }
                    ([SessionState]::Configuring) { "配置中..." }
                    ([SessionState]::Running) { "运行中" }
                    default { "处理中..." }
                }
                $script:lblStatus.ForeColor = $script:C_SUCCESS
                $script:btnStart.BackColor = $script:C_CARD
                $script:btnStart.ForeColor = $script:C_TEXT_SEC
            } else {
                $script:lblStatus.Text = "等待中"
                $script:lblStatus.ForeColor = $script:C_TEXT_SEC
                $script:btnStart.BackColor = $script:C_ACCENT
                $script:btnStart.ForeColor = [System.Drawing.Color]::White
            }
        } catch {}
    }
}

# ── Window Configuration ──
function Configure-Window() {
    try {
        if ($script:cancelToken) { throw "已取消" }
        $script:state = [SessionState]::Configuring
        Update-UIState

        $w = $script:targetW
        $h = $script:targetH

        # 使用游戏窗口所在屏幕而非主屏
        $script:screen = [System.Windows.Forms.Screen]::FromHandle($script:gameHwnd)
        if (-not $script:screen) { $script:screen = [System.Windows.Forms.Screen]::PrimaryScreen }
        if (-not $script:screen) { throw "无法获取屏幕" }
        $script:sw = $script:screen.Bounds.Width
        $script:sh = $script:screen.Bounds.Height

        # 保存原始目标值，只在 SetWindowPos 时临时调整
        $actualW = $w
        $actualH = $h
        if ($actualW -gt $script:sw) { $actualW = $script:sw }
        if ($actualH -gt $script:sh) { $actualH = $script:sh }
        $script:x = [math]::Floor(($script:sw - $actualW)/2) + $script:screen.Bounds.Left
        $script:y = [math]::Floor(($script:sh - $actualH)/2) + $script:screen.Bounds.Top

        $mode = $script:cmbWindowMode.SelectedIndex
        $borderless = $script:chkBorderless.Checked
        $fullscreen = ($mode -eq 1)
        $blackBg = $script:chkBlackBg.Checked
        $topmost = $script:chkTopmost.Checked

        $script:originalStyle = [Win32]::GetWindowLong($script:gameHwnd,[Win32]::GWL_STYLE)
        [Win32]::GetWindowRect($script:gameHwnd,[ref]$script:originalRect) | Out-Null

        if ($borderless -or $fullscreen) {
            if ($script:isAdmin) {
                $newStyle = $script:originalStyle -band -bnot ([int]([Win32]::WS_CAPTION -bor [Win32]::WS_THICKFRAME -bor [Win32]::WS_MINIMIZEBOX -bor [Win32]::WS_MAXIMIZEBOX -bor [Win32]::WS_SYSMENU))
                [Win32]::SetWindowLongCompat($script:gameHwnd,[Win32]::GWL_STYLE,$newStyle)
                # 修改样式后必须发送 SWP_FRAMECHANGED，否则系统不会重新计算非客户区（边框/标题栏）
                [Win32]::SetWindowPos($script:gameHwnd,[IntPtr]::Zero,0,0,0,0,
                    [Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOSIZE -bor [Win32]::SWP_NOZORDER -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_FRAMECHANGED) | Out-Null
            } else {
                Log "[WARN] 无边框/全屏模式需要管理员权限，当前以标准用户运行，跳过窗口样式修改" "Yellow"
            }
        }

        if ($fullscreen) {
            $actualW = $script:sw
            $actualH = $script:sh
            $script:x = $script:screen.Bounds.Left
            $script:y = $script:screen.Bounds.Top
        }

        [Win32]::SetWindowPos($script:gameHwnd,[IntPtr]::Zero,$script:x,$script:y,$actualW,$actualH,
            [Win32]::SWP_NOZORDER -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_SHOWWINDOW) | Out-Null
        [Win32]::ShowWindow($script:gameHwnd,[Win32]::SW_SHOW) | Out-Null
        Log "[INFO] 游戏窗口已设定 ${actualW}x${actualH} @ ${script:x},${script:y}"

        if ($blackBg) {
            $script:bg = New-Object BlackBgForm
            $script:bg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
            $script:bg.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            $script:bg.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $script:bg.Location = New-Object System.Drawing.Point($script:screen.Bounds.Left,$script:screen.Bounds.Top)
            $script:bg.Size = New-Object System.Drawing.Size($script:sw,$script:sh)
            $script:bg.BackColor = [System.Drawing.Color]::Black
            $script:bg.ShowInTaskbar = $false
            $script:bg.Show()
            $script:bgHwnd = $script:bg.Handle
            Log "[INFO] 黑底遮罩已就绪"
            [Win32]::SetWindowPos($script:gameHwnd, [IntPtr]::Zero, $script:x, $script:y, $actualW, $actualH,
                [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_SHOWWINDOW) | Out-Null
        }

        if ($topmost) {
            $script:watcher = New-Object FocusWatcher
            $script:lastFgHwnd = [IntPtr]::Zero

            $handler = [ForegroundChangedHandler]{
                param($hwnd)
                try {
                    if ($script:state -ne [SessionState]::Running) { return }
                    if (-not $script:bg -or $script:bg.IsDisposed) { return }

                    # 先检查游戏窗口是否还存在
                    if (-not [Win32]::IsWindow($script:gameHwnd)) {
                        Log "[INFO] 游戏已关闭，停止..."
                        Stop-Session
                        return
                    }

                    if ($hwnd -eq $script:lastFgHwnd) { return }
                    $script:lastFgHwnd = $hwnd

                    Safe-Invoke $script:bg {
                        try {
                            $currBlackBg = $script:chkBlackBg.Checked
                            if ($hwnd -eq $script:gameHwnd) {
                                if ($currBlackBg -and -not $script:bg.Visible) { $script:bg.Show() }
                                if ($currBlackBg) {
                                    [Win32]::SetWindowPos($script:bgHwnd,[Win32]::HWND_TOPMOST,0,0,0,0,
                                        [Win32]::SWP_NOSIZE -bor [Win32]::SWP_NOMOVE -bor [Win32]::SWP_NOACTIVATE -bor [Win32]::SWP_SHOWWINDOW) | Out-Null
                                }
                                [Win32]::SetWindowPos($script:gameHwnd,[Win32]::HWND_TOPMOST,$script:x,$script:y,$script:targetW,$script:targetH,
                                    [Win32]::SWP_NOACTIVATE) | Out-Null
                            } else {
                                if ($currBlackBg -and $script:bg.Visible) { $script:bg.Hide() }
                                [Win32]::SetWindowPos($script:gameHwnd,[Win32]::HWND_NOTOPMOST,$script:x,$script:y,$script:targetW,$script:targetH,
                                    [Win32]::SWP_NOACTIVATE) | Out-Null
                            }
                        } catch {}
                    }
                } catch {}
            }
            $script:watcher.add_ForegroundChanged($handler)
            $script:watcher.Start()
            Log "[INFO] 智能置顶监听已启动"
        }

        $script:state = [SessionState]::Running
        Update-UIState
    } catch {
        Log "[ERROR] 窗口配置失败: $($_.Exception.Message)" "Red"
        Stop-Session
    }
}

# ── Start Session ──
function OnStart() {
    try {
        if ($script:state -ne [SessionState]::Idle) { return }

        if (-not (Validate-Resolution)) {
            [System.Windows.Forms.MessageBox]::Show("分辨率设置无效，请修正后再启动。", "参数错误", "OK", "Warning") | Out-Null
            return
        }

        $script:cancelToken = $false
        $script:state = [SessionState]::Finding
        Update-UIState

        $exe = $script:txtExe.Text
        $script:targetTitle = $script:txtTitle.Text
        $launchArgs = $script:txtArgs.Text

        Log "[DEBUG] 启动参数: exe='$exe', title='$($script:targetTitle)', args='$launchArgs'"

        $w = $null; $h = $null
        if ($launchArgs -match '-ResX=(\d+)') { $w = [int]$matches[1] }
        if ($launchArgs -match '-ResY=(\d+)') { $h = [int]$matches[1] }

        if (-not $w) { $w = [int]$script:txtW.Text }
        if (-not $h) { $h = [int]$script:txtH.Text }

        Log "[INFO] 目标分辨率: ${w}x${h}"
        $script:targetW = $w
        $script:targetH = $h

        $autoStart = $script:chkAutoStart.Checked

        $existingHwnd = Find-GameWindow $script:targetTitle
        if ($existingHwnd -ne [IntPtr]::Zero) {
            $script:gameHwnd = $existingHwnd
            Configure-Window
            return
        }

        if ($autoStart -and $exe -ne "" -and (Test-Path $exe)) {
            Log "[INFO] 正在启动游戏..."
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $exe
                $psi.Arguments = $launchArgs
                $psi.UseShellExecute = $true
                $psi.WorkingDirectory = [System.IO.Path]::GetDirectoryName($exe)
                $proc = [System.Diagnostics.Process]::Start($psi)
                $script:targetPid = $proc.Id
                Log "[INFO] 游戏已启动 (PID=$($proc.Id))"

                $script:windowWatcher = New-Object WindowCreatedWatcher
                $createdHandler = [WindowCreatedHandler]{
                    param($hwnd)
                    try {
                        if ($script:state -ne [SessionState]::Finding) { return }
                        if (-not [Win32]::IsWindowVisible($hwnd)) { return }
                        $sb2 = New-Object System.Text.StringBuilder(256)
                        [Win32]::GetWindowText($hwnd, $sb2, 256) | Out-Null
                        $t = $sb2.ToString()

                        if ($t -eq $script:targetTitle) {
                            Safe-Invoke $script:mainForm {
                                if ($script:state -ne [SessionState]::Finding) { return }
                                Log "[INFO] 匹配目标窗口: HWND=$hwnd, Title='$t'" "Green"
                                if ($script:windowWatcher) {
                                    try { $script:windowWatcher.Stop() } catch {}
                                    $script:windowWatcher = $null
                                }
                                $script:gameHwnd = $hwnd
                                Configure-Window
                            }
                        }
                    } catch {}
                }
                $script:windowWatcher.add_WindowCreated($createdHandler)
                $script:windowWatcher.Start(0)
                Log "[INFO] 事件监听已启动 (PID=$($script:targetPid), 等待窗口创建事件...)"
            } catch {
                Log "[ERROR] 启动失败: $($_.Exception.Message)" "Red"
                Stop-Session
                return
            }
        } elseif ($autoStart -and ($exe -eq "" -or -not (Test-Path $exe))) {
            Log "[ERROR] 游戏路径无效，无法自动启动" "Red"
            Stop-Session
            return
        } else {
            Log "[ERROR] 未找到窗口且未设置自动启动" "Red"
            Stop-Session
            return
        }

    } catch {
        Log "[FATAL] $($_.Exception.Message)" "Red"
        [System.Windows.Forms.MessageBox]::Show("启动失败: $($_.Exception.Message)", "错误", "OK", "Error") | Out-Null
        Stop-Session
    }
}

# ═══════════════════════════════════════════════════════════
# ── GUI Builder (Refactored) ──
# ═══════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text = "鸣潮窗口工具"
$form.Size = New-Object System.Drawing.Size(680, 640)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = $script:C_BG
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

# 主布局
$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainLayout.ColumnCount = 1
$mainLayout.RowCount = 5
$mainLayout.Padding = New-Object System.Windows.Forms.Padding(20, 15, 20, 15)
[void]$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))   # Header
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 210)))  # Config (标题+5行)
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 90)))   # Options
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 55)))   # Controls
[void]$mainLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) # Log
$form.Controls.Add($mainLayout)

# ── Header ──
$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainLayout.Controls.Add($headerPanel, 0, 0)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "鸣潮窗口工具"
$lblTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $script:C_TEXT
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(0, 5)
$headerPanel.Controls.Add($lblTitle)

# ── Config Card ──
$configCard = New-Object System.Windows.Forms.Panel
$configCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$configCard.BackColor = $script:C_CARD
$configCard.Padding = New-Object System.Windows.Forms.Padding(15, 28, 15, 14)
$configCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$mainLayout.Controls.Add($configCard, 0, 1)

# Card 标题
$lblCardTitle = New-Object System.Windows.Forms.Label
$lblCardTitle.Text = "启动参数"
$lblCardTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$lblCardTitle.ForeColor = [System.Drawing.Color]::FromArgb(120, 125, 135)
$lblCardTitle.AutoSize = $true
$lblCardTitle.Location = New-Object System.Drawing.Point(15, 8)
$configCard.Controls.Add($lblCardTitle)

# 配置布局：4列，5行
$configLayout = New-Object System.Windows.Forms.TableLayoutPanel
$configLayout.Dock = [System.Windows.Forms.DockStyle]::Fill
$configLayout.ColumnCount = 4
$configLayout.RowCount = 5
$configLayout.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$configLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 75)))
[void]$configLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$configLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
[void]$configLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))

$ROW_H = 40
$INPUT_H = 26
$VM = [math]::Floor(($ROW_H - $INPUT_H) / 2)
[void]$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $ROW_H)))
[void]$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $ROW_H)))
[void]$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $ROW_H)))
[void]$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 1)))       # 分隔线 1px
[void]$configLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $ROW_H)))
$configCard.Controls.Add($configLayout)

# 辅助函数
function New-ConfigLabel($text) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $text
    $lbl.ForeColor = $script:C_TEXT_SEC
    $lbl.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lbl.AutoSize = $false
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.Margin = New-Object System.Windows.Forms.Padding(0, $VM, 8, $VM)
    return $lbl
}

function New-ConfigTextBox($text) {
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Text = $text
    $tb.BackColor = $script:C_BG
    $tb.ForeColor = $script:C_TEXT
    $tb.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $tb.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $tb.Height = $INPUT_H
    $tb.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $tb.Margin = New-Object System.Windows.Forms.Padding(0, $VM, 8, $VM)
    return $tb
}

# Row 0: 窗口标题
$lbl = New-ConfigLabel "窗口标题"
$configLayout.Controls.Add($lbl, 0, 0)
$script:txtTitle = New-ConfigTextBox $WindowTitle
$script:txtTitle.Margin = New-Object System.Windows.Forms.Padding(0, $VM, 0, $VM)
$configLayout.Controls.Add($script:txtTitle, 1, 0)
$configLayout.SetColumnSpan($script:txtTitle, 3)

# Row 1: 游戏路径
$lbl = New-ConfigLabel "游戏路径"
$configLayout.Controls.Add($lbl, 0, 1)
$script:txtExe = New-ConfigTextBox $ExePath
$configLayout.Controls.Add($script:txtExe, 1, 1)
$configLayout.SetColumnSpan($script:txtExe, 2)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "浏览..."
$btnBrowse.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnBrowse.FlatAppearance.BorderSize = 0
$btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(60, 63, 75)
$btnBrowse.ForeColor = $script:C_TEXT
$btnBrowse.Height = $INPUT_H
$btnBrowse.Padding = New-Object System.Windows.Forms.Padding(0)
$btnBrowse.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$btnBrowse.Margin = New-Object System.Windows.Forms.Padding(0, $VM, 0, $VM)
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Executable (*.exe)|*.exe"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:txtExe.Text = $dlg.FileName
    }
})
$configLayout.Controls.Add($btnBrowse, 3, 1)

# Row 2: 启动参数
$lbl = New-ConfigLabel "启动参数"
$configLayout.Controls.Add($lbl, 0, 2)
$script:txtArgs = New-ConfigTextBox $GameArgs
$script:txtArgs.Margin = New-Object System.Windows.Forms.Padding(0, $VM, 0, $VM)
$script:txtArgs.Add_TextChanged({ Sync-UIFromArgs })
$configLayout.Controls.Add($script:txtArgs, 1, 2)
$configLayout.SetColumnSpan($script:txtArgs, 3)

# Row 3: 分隔线 —— 1px 细线
$sepLine = New-Object System.Windows.Forms.Label
$sepLine.Dock = [System.Windows.Forms.DockStyle]::Fill
$sepLine.BackColor = [System.Drawing.Color]::FromArgb(45, 48, 58)
$sepLine.Margin = New-Object System.Windows.Forms.Padding(0)
$sepLine.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$configLayout.Controls.Add($sepLine, 0, 3)
$configLayout.SetColumnSpan($sepLine, 4)

# Row 4: 便捷参数设置（分辨率 + 窗口模式）
$lbl = New-ConfigLabel "分辨率"
$lbl.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
$lbl.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
$configLayout.Controls.Add($lbl, 0, 4)

$resPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$resPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$resPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$resPanel.WrapContents = $false
$resPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$resPanel.Padding = New-Object System.Windows.Forms.Padding(0, $VM, 0, $VM)
$configLayout.Controls.Add($resPanel, 1, 4)
$configLayout.SetColumnSpan($resPanel, 3)

# 分辨率输入框 —— 固定 Size，不用 Anchor，和 lblX 等控件保持一致
$script:txtW = New-Object System.Windows.Forms.TextBox
$script:txtW.Text = $GameW.ToString()
$script:txtW.Size = New-Object System.Drawing.Size(80, $INPUT_H)
$script:txtW.BackColor = $script:C_BG
$script:txtW.ForeColor = $script:C_TEXT
$script:txtW.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:txtW.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:txtW.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
$script:txtW.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$script:txtW.Add_TextChanged({ 
    Sync-ArgsFromUI
    Validate-Resolution 
})
$resPanel.Controls.Add($script:txtW)

$lblX = New-Object System.Windows.Forms.Label
$lblX.Text = "x"
$lblX.ForeColor = $script:C_TEXT_SEC
$lblX.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
$lblX.Size = New-Object System.Drawing.Size(20, $INPUT_H)
$lblX.Margin = New-Object System.Windows.Forms.Padding(0, 0, 4, 0)
$lblX.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$resPanel.Controls.Add($lblX)

$script:txtH = New-Object System.Windows.Forms.TextBox
$script:txtH.Text = $GameH.ToString()
$script:txtH.Size = New-Object System.Drawing.Size(80, $INPUT_H)
$script:txtH.BackColor = $script:C_BG
$script:txtH.ForeColor = $script:C_TEXT
$script:txtH.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$script:txtH.Font = New-Object System.Drawing.Font("Consolas", 10)
$script:txtH.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
$script:txtH.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
$script:txtH.Add_TextChanged({ 
    Sync-ArgsFromUI
    Validate-Resolution 
})
$resPanel.Controls.Add($script:txtH)

# 窗口模式下拉
$script:cmbWindowMode = New-Object System.Windows.Forms.ComboBox
$script:cmbWindowMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$script:cmbWindowMode.Items.AddRange(@("窗口模式", "全屏"))
$script:cmbWindowMode.SelectedIndex = 0
$script:cmbWindowMode.Size = New-Object System.Drawing.Size(90, $INPUT_H)
$script:cmbWindowMode.BackColor = $script:C_BG
$script:cmbWindowMode.ForeColor = $script:C_TEXT
$script:cmbWindowMode.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:cmbWindowMode.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$script:cmbWindowMode.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$resPanel.Controls.Add($script:cmbWindowMode)

# 警告标签
$script:lblResWarning = New-Object System.Windows.Forms.Label
$script:lblResWarning.Text = ""
$script:lblResWarning.ForeColor = $script:C_DANGER
$script:lblResWarning.AutoSize = $false
$script:lblResWarning.Size = New-Object System.Drawing.Size(220, $INPUT_H)
$script:lblResWarning.Visible = $false
$script:lblResWarning.Margin = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$script:lblResWarning.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 8)
$script:lblResWarning.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$resPanel.Controls.Add($script:lblResWarning)

# 帮助按钮
$script:btnHelp = New-Object System.Windows.Forms.Label
$script:btnHelp.Text = "?"
$script:btnHelp.ForeColor = $script:C_ACCENT
$script:btnHelp.AutoSize = $false
$script:btnHelp.Size = New-Object System.Drawing.Size(20, $INPUT_H)
$script:btnHelp.Margin = New-Object System.Windows.Forms.Padding(6, 0, 0, 0)
$script:btnHelp.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnHelp.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$script:btnHelp.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:btnHelp.Add_MouseEnter({ $script:tipShowTimer.Start() })
$script:btnHelp.Add_MouseLeave({ $script:tipShowTimer.Stop(); $script:tipHideTimer.Start() })
$resPanel.Controls.Add($script:btnHelp)

# ── Options Card ──
$optCard = New-Object System.Windows.Forms.Panel
$optCard.Dock = [System.Windows.Forms.DockStyle]::Fill
$optCard.BackColor = $script:C_CARD
$optCard.Padding = New-Object System.Windows.Forms.Padding(15, 28, 15, 14)
$optCard.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$mainLayout.Controls.Add($optCard, 0, 2)

# Card 标题
$lblOptTitle = New-Object System.Windows.Forms.Label
$lblOptTitle.Text = "窗口选项"
$lblOptTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$lblOptTitle.ForeColor = [System.Drawing.Color]::FromArgb(120, 125, 135)
$lblOptTitle.AutoSize = $true
$lblOptTitle.Location = New-Object System.Drawing.Point(15, 8)
$optCard.Controls.Add($lblOptTitle)

$optPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$optPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$optPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
$optPanel.WrapContents = $false
$optPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$optPanel.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$optCard.Controls.Add($optPanel)

function New-ModernCheckBox($text, $checked) {
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Text = $text
    $chk.Checked = $checked
    $chk.ForeColor = $script:C_TEXT
    $chk.AutoSize = $true
    $chk.Margin = New-Object System.Windows.Forms.Padding(0, 0, 25, 0)
    return $chk
}

# 自动启动默认勾选
$script:chkAutoStart = New-ModernCheckBox "自动启动" $true
$script:chkAutoStart.Add_CheckedChanged({ Update-AutoStartUI })
$optPanel.Controls.Add($script:chkAutoStart)


# 无边框帮助按钮（无UAC时显示）
$script:btnBorderlessHelp = New-Object System.Windows.Forms.Label
$script:btnBorderlessHelp.Text = "?"
$script:btnBorderlessHelp.ForeColor = $script:C_WARN
$script:btnBorderlessHelp.AutoSize = $false
$script:btnBorderlessHelp.Size = New-Object System.Drawing.Size(20, 20)
$script:btnBorderlessHelp.Margin = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
$script:btnBorderlessHelp.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:btnBorderlessHelp.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
$script:btnBorderlessHelp.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:btnBorderlessHelp.Visible = $false
$script:btnBorderlessHelp.Add_MouseEnter({ $script:tipBorderlessShowTimer.Start() })
$script:btnBorderlessHelp.Add_MouseLeave({ $script:tipBorderlessShowTimer.Stop(); $script:tipBorderlessHideTimer.Start() })
$optPanel.Controls.Add($script:btnBorderlessHelp)

# 无边框 —— 需要管理员权限才能修改其他进程窗口的 WS_STYLE
$script:chkBorderless = New-ModernCheckBox "无边框" $true
$script:chkBorderless.Add_CheckedChanged({ Sync-ArgsFromUI })
$optPanel.Controls.Add($script:chkBorderless)


$script:chkBlackBg = New-ModernCheckBox "黑底遮罩" $true
$optPanel.Controls.Add($script:chkBlackBg)
$script:chkTopmost = New-ModernCheckBox "智能置顶(根据置顶窗口，选择黑底是否显示)" $true
$optPanel.Controls.Add($script:chkTopmost)

# ── Control Bar ──
$ctrlPanel = New-Object System.Windows.Forms.Panel
$ctrlPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$ctrlPanel.Height = 55
$ctrlPanel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 10)
$mainLayout.Controls.Add($ctrlPanel, 0, 3)

$script:btnStart = New-Object System.Windows.Forms.Button
$script:btnStart.Text = "▶  启动"
$script:btnStart.Size = New-Object System.Drawing.Size(120, 40)
$script:btnStart.Location = New-Object System.Drawing.Point(0, 5)
$script:btnStart.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:btnStart.FlatAppearance.BorderSize = 0
$script:btnStart.BackColor = $script:C_ACCENT
$script:btnStart.ForeColor = [System.Drawing.Color]::White
$script:btnStart.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$script:btnStart.Add_Click({
    try { OnStart } catch {
        [System.Windows.Forms.MessageBox]::Show("启动失败: $($_.Exception.Message)", "错误", "OK", "Error") | Out-Null
    }
})
$ctrlPanel.Controls.Add($script:btnStart)

$script:btnStop = New-Object System.Windows.Forms.Button
$script:btnStop.Text = "■  停止"
$script:btnStop.Size = New-Object System.Drawing.Size(120, 40)
$script:btnStop.Location = New-Object System.Drawing.Point(135, 5)
$script:btnStop.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$script:btnStop.FlatAppearance.BorderSize = 0
$script:btnStop.BackColor = [System.Drawing.Color]::FromArgb(60, 50, 55)
$script:btnStop.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 100)
$script:btnStop.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$script:btnStop.Enabled = $false
$script:btnStop.Add_Click({ try { Stop-Session } catch {} })
$ctrlPanel.Controls.Add($script:btnStop)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = "等待中"
$script:lblStatus.Size = New-Object System.Drawing.Size(200, 40)
$script:lblStatus.Location = New-Object System.Drawing.Point(280, 5)
$script:lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:lblStatus.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$script:lblStatus.ForeColor = $script:C_TEXT_SEC
$ctrlPanel.Controls.Add($script:lblStatus)

# ── Log Box ──
$script:logBox = New-Object System.Windows.Forms.RichTextBox
$script:logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:logBox.ReadOnly = $true
$script:logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$script:logBox.BackColor = $script:C_LOG_BG
$script:logBox.ForeColor = $script:C_TEXT_SEC
$script:logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:logBox.Margin = New-Object System.Windows.Forms.Padding(8)
$mainLayout.Controls.Add($script:logBox, 0, 4)

$script:mainForm = $form

$form.Add_FormClosing({
    if ($script:state -ne [SessionState]::Idle) {
        try { Stop-Session } catch {}
        Start-Sleep -Milliseconds 300
    }
})

# ── Initial Sync & Validation ──
if ($GameArgs -match '-ResX=(\d+)') { $script:txtW.Text = $matches[1] }
if ($GameArgs -match '-ResY=(\d+)') { $script:txtH.Text = $matches[1] }

# 先绑定事件，再设置 SelectedIndex
$script:cmbWindowMode.Add_SelectedIndexChanged({ OnWindowModeChanged })
$script:cmbWindowMode.SelectedIndex = 0

Sync-ArgsFromUI
Validate-Resolution | Out-Null

# 注意：此时 isAdmin 还未检测，先不调用 Update-AutoStartUI
# 等管理员检测完成后再统一更新 UI 状态

$script:tipForm.Owner = $form
$script:tipBorderlessForm.Owner = $form

# ── 1px 圆角（在 HandleCreated 中设置，避免闪烁） ──
function Set-RoundCorner($ctrl) {
    if ($ctrl -and $ctrl.Handle -ne [IntPtr]::Zero) {
        $newRgn = [Win32]::CreateRoundRectRgn(0, 0, $ctrl.Width + 1, $ctrl.Height + 1, 2, 2)
        $prevRgn = [Win32]::SetWindowRgn($ctrl.Handle, $newRgn, $true)
        if ($prevRgn -ne [IntPtr]::Zero) {
            [Win32]::DeleteObject($prevRgn) | Out-Null
        }
    }
}

$roundTargets = @(
    $configCard, $optCard,
    $script:txtTitle, $script:txtW, $script:txtH, $script:txtArgs, $script:txtExe,
    $btnBrowse, $script:cmbWindowMode,
    $script:btnStart, $script:btnStop, $script:logBox,
    $script:btnBorderlessHelp
)

# 使用 HandleCreated 事件设置圆角
foreach ($ctrl in $roundTargets) {
    if ($ctrl) {
        $handler = {
            param($sender, $e)
            Set-RoundCorner $sender
        }
        $ctrl.Add_HandleCreated($handler)
    }
}

$form.Show()
$form.Activate()

if (-not $form.IsHandleCreated) {
    $null = $form.Handle
}

# ── Admin check & Auto-elevate ──
$script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 修复1：管理员检测完成后，重新更新 UI 状态（确保无边框复选框正确启用/禁用）
Update-AutoStartUI

if (-not $script:isAdmin) {
    $result = [System.Windows.Forms.MessageBox]::Show(
        "需要管理员权限才能修改游戏窗口。`n点击 [是] 以管理员身份重启。",
        "需要管理员权限",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )

    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrEmpty($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }

        if ([string]::IsNullOrEmpty($scriptPath)) {
            [System.Windows.Forms.MessageBox]::Show("无法确定脚本路径", "错误", "OK", "Error")
            $form.Close()
            return
        }

        $q = { param($s) $s -replace "'", "''" }
        $command = "& '$(&$q $scriptPath)' -ExePath '$(&$q $ExePath)' -WindowTitle '$(&$q $WindowTitle)' -GameArgs '$(&$q $GameArgs)' -GameW $GameW -GameH $GameH"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"$command`""
        $psi.Verb = "RunAs"
        $psi.UseShellExecute = $true
        try {
            [System.Diagnostics.Process]::Start($psi) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "无法以管理员身份启动: $($_.Exception.Message)",
                "错误", "OK", "Error"
            ) | Out-Null
            return
        }

        $form.Close()
        return
    }
}
[System.Windows.Forms.Application]::Run($form)
