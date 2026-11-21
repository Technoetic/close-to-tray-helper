<#
  close-to-tray.ps1 - Windows system tray helper that keeps the Aside browser
  (unofficial; not affiliated with its makers) running without a taskbar button.
  Pure ASCII so Windows PowerShell 5.1 reads it safely regardless of code page.
  Korean UI labels are encoded as C# Unicode escapes (\uXXXX).

  Contract:
    - Keeps Aside.exe and aside-daemon.exe running while removing minimized Aside
      windows from the Windows taskbar and exposing an Aside icon in the tray.
    - Default mode (DeleteTab): keeps Chromium in its normal minimized state and
      removes only the taskbar button via ITaskbarList::DeleteTab (safest for
      aside repl / screenshots).
    - Optional mode (HideWindow): hides minimized Aside windows with SW_HIDE
      (removes from both taskbar and Alt+Tab). Switchable live from tray menu.
    - Close-to-tray (default ON, toggleable in tray menu): intercepts left-clicks
      on the Close (X) button of the last Aside window via pure Win32 WH_MOUSE_LL
      + WM_NCHITTEST(HTCLOSE) + bounded UI Automation close-button rect cache
      (zero DLL injection) and hides it to the tray instead of closing Aside.
      Extra windows (when 2+ Aside windows exist) close normally; Alt+F4 or
      unchecking the tray menu toggle closes Aside normally.
    - Zero-orphan guarantee: on exit, -Stop, or Windows session ending, the mouse
      hook is unhooked and every hidden Aside window is restored to the taskbar
      (never closes or kills Aside).
    - Single-instance via Local\Close-To-Tray-Helper mutex.
    - Start Aside (tray menu, -StartAside, auto-start): runs an optional launcher
      script (-AsideUpScript, default aside-up.ps1 next to this file) if present,
      otherwise starts Aside.exe directly.
    - Pure offline -SelfTest compiles the embedded C# controller, verifies real
      WH_MOUSE_LL + HTCLOSE + UIA + multi-window + disable behavior on isolated
      WinForms test windows, and exits without holding the runtime mutex.
#>
param(
    [ValidateSet('', 'DeleteTab', 'HideWindow')]
    [string]$Mode = '',
    [string]$AsideExe = '',
    [string]$AsideUpScript = '',
    [string]$PrefsPath = '',
    [string]$StartupDir = '',
    [switch]$CloseToTray,
    [switch]$NoCloseToTray,
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$Stop,
    [switch]$Show,
    [switch]$Hide,
    [switch]$Toggle,
    [switch]$StartAside,
    [switch]$SelfTest,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $AsideUpScript) {
    $AsideUpScript = Join-Path $ScriptDir 'aside-up.ps1'
}
$LauncherVbs = Join-Path $ScriptDir 'close-to-tray-launch.vbs'
if (-not $PrefsPath) {
    $PrefsPath = Join-Path $env:LOCALAPPDATA 'CloseToTrayHelper\prefs.json'
}
if (-not $StartupDir) {
    $StartupDir = [Environment]::GetFolderPath('Startup')
}

function Find-AsideBrowserExe([string]$Explicit) {
    $candidates = @()
    if ($Explicit) {
        $candidates = @($Explicit)
    } elseif ($env:ASIDE_EXE) {
        $candidates = @($env:ASIDE_EXE)
    } else {
        if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Aside\Application\Aside.exe') }
        if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Aside\Application\Aside.exe') }
        if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Aside\Application\Aside.exe') }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return $c
        }
    }
    return ''
}

function Get-StartupShortcutPath([string]$Dir) {
    return (Join-Path $Dir 'Close To Tray Helper.lnk')
}

function Install-StartupShortcut([string]$Dir, [string]$VbsPath, [string]$IconExe) {
    if (-not (Test-Path -LiteralPath $VbsPath -PathType Leaf)) {
        throw "Launcher not found: $VbsPath"
    }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $Dir -Force)
    }
    $lnkPath = Get-StartupShortcutPath $Dir
    $wsh = New-Object -ComObject WScript.Shell
    try {
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
        $sc.Arguments = ('//B //Nologo "{0}"' -f $VbsPath)
        $sc.WorkingDirectory = (Split-Path -Parent $VbsPath)
        $sc.Description = 'Close-to-tray helper (unofficial)'
        if ($IconExe -and (Test-Path -LiteralPath $IconExe -PathType Leaf)) {
            $sc.IconLocation = ($IconExe + ',0')
        }
        $sc.Save()
    } finally {
        if ($wsh) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh) }
    }
    return $lnkPath
}

function Uninstall-StartupShortcut([string]$Dir) {
    $lnkPath = Get-StartupShortcutPath $Dir
    $removed = $false
    if (Test-Path -LiteralPath $lnkPath -PathType Leaf) {
        Remove-Item -LiteralPath $lnkPath -Force
        $removed = $true
    }
    return @{ path = $lnkPath; removed = $removed }
}

function Read-TrayPrefs([string]$Path) {
    $prefs = [ordered]@{
        mode = 'DeleteTab'
        autoStartAside = $false
        closeToTray = $true
    }
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            if ($obj -and ($obj.mode -eq 'DeleteTab' -or $obj.mode -eq 'HideWindow')) {
                $prefs.mode = [string]$obj.mode
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'autoStartAside') -and $null -ne $obj.autoStartAside) {
                $prefs.autoStartAside = [bool]$obj.autoStartAside
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'closeToTray') -and $null -ne $obj.closeToTray) {
                $prefs.closeToTray = [bool]$obj.closeToTray
            }
        } catch {
            # Ignore malformed prefs and keep safe defaults.
        }
    }
    return $prefs
}

function Write-TrayPrefs([string]$Path, [string]$ModeVal, [bool]$AutoStartVal, [bool]$CloseToTrayVal) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $payload = ([ordered]@{
        mode = $ModeVal
        autoStartAside = $AutoStartVal
        closeToTray = $CloseToTrayVal
    } | ConvertTo-Json -Compress)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $payload, $utf8NoBom)
}

function Out-Result($Obj, [string]$TextLine) {
    if ($Json) {
        Write-Output ($Obj | ConvertTo-Json -Depth 5 -Compress)
    } else {
        Write-Output $TextLine
    }
}

$ResolvedAsideExe = Find-AsideBrowserExe $AsideExe

# Handle startup install/uninstall actions without launching the tray loop.
if ($InstallStartup) {
    $lnk = Install-StartupShortcut -Dir $StartupDir -VbsPath $LauncherVbs -IconExe ''
    $res = [ordered]@{
        action = 'install-startup'
        ok = (Test-Path -LiteralPath $lnk -PathType Leaf)
        shortcut = $lnk
        launcher = $LauncherVbs
        icon_exe = ''
        aside_exe = $ResolvedAsideExe
    }
    Out-Result $res ("[close-to-tray] startup shortcut installed: $lnk")
    exit 0
}

if ($UninstallStartup) {
    $info = Uninstall-StartupShortcut -Dir $StartupDir
    $res = [ordered]@{
        action = 'uninstall-startup'
        ok = $true
        shortcut = $info.path
        removed = $info.removed
    }
    Out-Result $res ("[close-to-tray] startup shortcut removed=$($info.removed): $($info.path)")
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes, WindowsBase

$CSharpSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;
using System.Windows.Forms;
using Microsoft.Win32;

namespace CloseToTrayHelper
{
    public enum HideMode
    {
        DeleteTab = 0,
        HideWindow = 1
    }

    public enum TrayIpcCommand
    {
        None = 0,
        Stop = 1,
        Show = 2,
        Hide = 3,
        Toggle = 4
    }

    [ComImport]
    [Guid("56FDF342-FD6D-11d0-958A-006097C9A090")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface ITaskbarList
    {
        [PreserveSig] int HrInit();
        [PreserveSig] int AddTab(IntPtr hwnd);
        [PreserveSig] int DeleteTab(IntPtr hwnd);
        [PreserveSig] int ActivateTab(IntPtr hwnd);
        [PreserveSig] int SetActiveAlt(IntPtr hwnd);
    }

    [ComImport]
    [Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    internal class TaskbarListComObject
    {
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public bool SameAs(RECT other)
        {
            return Left == other.Left && Top == other.Top && Right == other.Right && Bottom == other.Bottom;
        }

        public bool Contains(int x, int y)
        {
            return x >= Left && x <= Right && y >= Top && y <= Bottom;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    public static class NativeMethods
    {
        public delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

        public const int GWL_STYLE = -16;
        public const int GWL_EXSTYLE = -20;
        public const int WS_MINIMIZEBOX = 0x00020000;
        public const uint GW_OWNER = 4;
        public const uint GA_ROOT = 2;

        public const int SW_HIDE = 0;
        public const int SW_SHOW = 5;
        public const int SW_MINIMIZE = 6;
        public const int SW_SHOWMINNOACTIVE = 7;
        public const int SW_RESTORE = 9;

        public const int WH_MOUSE_LL = 14;
        public const int WM_NCHITTEST = 0x0084;
        public const int WM_LBUTTONDOWN = 0x0201;
        public const int WM_LBUTTONUP = 0x0202;
        public const int HTCLOSE = 20;

        public const uint SMTO_BLOCK = 0x0001;
        public const uint SMTO_ABORTIFHUNG = 0x0002;

        public static readonly IntPtr HWND_BROADCAST = new IntPtr(0xFFFF);
        public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        public static extern bool IsWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool IsIconic(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetParent(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

        [DllImport("user32.dll")]
        public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

        [DllImport("user32.dll")]
        public static extern IntPtr WindowFromPoint(POINT point);

        [DllImport("user32.dll")]
        public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern uint RegisterWindowMessage(string lpString);

        [DllImport("user32.dll")]
        public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam,
            uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnhookWindowsHookEx(IntPtr hhk);

        [DllImport("user32.dll")]
        public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandle(string lpModuleName);

        public static void TryEnablePerMonitorDpi()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)) return;
            }
            catch { }
            try { SetProcessDPIAware(); } catch { }
        }

        public static IntPtr MakeScreenLParam(int x, int y)
        {
            return new IntPtr(unchecked((int)(((y & 0xFFFF) << 16) | (x & 0xFFFF))));
        }
    }

    internal sealed class CachedCloseButton
    {
        public IntPtr Hwnd;
        public RECT WindowRect;
        public RECT ButtonRect;
        public DateTime UpdatedUtc;
    }

    public sealed class CloseButtonInterceptor : IDisposable
    {
        private readonly object _sync = new object();
        private readonly Action<IntPtr> _onCloseIntercepted;
        private readonly NativeMethods.LowLevelMouseProc _hookProc;
        private IntPtr _hookHandle = IntPtr.Zero;
        private bool _enabled = false;
        private bool _swallowNextLeftUp = false;
        private DateTime _swallowUpDeadlineUtc = DateTime.MinValue;

        private HashSet<IntPtr> _trackedWindows = new HashSet<IntPtr>();
        private CachedCloseButton _cachedClose = null;
        private int _uiaProbeInFlight = 0;

        public CloseButtonInterceptor(Action<IntPtr> onCloseIntercepted)
        {
            _onCloseIntercepted = onCloseIntercepted;
            _hookProc = MouseHookCallback;
        }

        public bool IsHookActive
        {
            get { return _hookHandle != IntPtr.Zero; }
        }

        public bool Enabled
        {
            get { return _enabled; }
            set
            {
                if (_enabled == value) return;
                _enabled = value;
                if (_enabled)
                {
                    InstallHook();
                }
                else
                {
                    UninstallHook();
                }
            }
        }

        public void UpdateTrackedWindows(ICollection<IntPtr> liveMainWindows)
        {
            var next = new HashSet<IntPtr>();
            IntPtr singleVisible = IntPtr.Zero;
            int visibleCount = 0;
            if (liveMainWindows != null)
            {
                foreach (var h in liveMainWindows)
                {
                    if (h != IntPtr.Zero && NativeMethods.IsWindow(h))
                    {
                        next.Add(h);
                        if (NativeMethods.IsWindowVisible(h) && !NativeMethods.IsIconic(h))
                        {
                            singleVisible = h;
                            visibleCount++;
                        }
                    }
                }
            }

            bool needUiaRefresh = false;
            RECT singleRect = default(RECT);
            lock (_sync)
            {
                _trackedWindows = next;
                if (_enabled && next.Count == 1 && visibleCount == 1 && NativeMethods.GetWindowRect(singleVisible, out singleRect))
                {
                    if (_cachedClose == null ||
                        _cachedClose.Hwnd != singleVisible ||
                        !_cachedClose.WindowRect.SameAs(singleRect) ||
                        (DateTime.UtcNow - _cachedClose.UpdatedUtc).TotalSeconds >= 5.0)
                    {
                        needUiaRefresh = true;
                    }
                }
                else if (next.Count != 1)
                {
                    _cachedClose = null;
                }
            }

            if (needUiaRefresh)
            {
                ScheduleUiaCloseProbe(singleVisible, singleRect);
            }
        }

        public void TriggerUiaRefreshAsync(IntPtr hwnd)
        {
            RECT wr;
            if (!NativeMethods.GetWindowRect(hwnd, out wr)) return;
            ScheduleUiaCloseProbe(hwnd, wr);
        }

        public bool TryGetCachedCloseRect(IntPtr hwnd, out RECT rect)
        {
            lock (_sync)
            {
                if (_cachedClose != null && _cachedClose.Hwnd == hwnd)
                {
                    rect = _cachedClose.ButtonRect;
                    return true;
                }
            }
            rect = default(RECT);
            return false;
        }

        public void ClearUiaCache()
        {
            lock (_sync)
            {
                _cachedClose = null;
            }
        }

        private void ScheduleUiaCloseProbe(IntPtr hwnd, RECT expectedRect)
        {
            if (Interlocked.CompareExchange(ref _uiaProbeInFlight, 1, 0) != 0) return;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    RECT br;
                    if (TryFindCloseButtonRectViaUia(hwnd, expectedRect, out br))
                    {
                        lock (_sync)
                        {
                            _cachedClose = new CachedCloseButton
                            {
                                Hwnd = hwnd,
                                WindowRect = expectedRect,
                                ButtonRect = br,
                                UpdatedUtc = DateTime.UtcNow
                            };
                        }
                    }
                }
                catch { }
                finally
                {
                    Interlocked.Exchange(ref _uiaProbeInFlight, 0);
                }
            });
        }

        // Bounded UIA tree walk that skips web Document subtrees (< 5 ms) and strictly
        // requires the rightmost top-corner window caption close button so browser tab
        // close buttons (also named "Close" / "\uB2EB\uAE30") are never misidentified.
        public static bool TryFindCloseButtonRectViaUia(IntPtr hwnd, RECT winRect, out RECT buttonRect)
        {
            buttonRect = default(RECT);
            bool foundAny = false;
            int bestRight = int.MinValue;
            try
            {
                var root = AutomationElement.FromHandle(hwnd);
                if (root == null) return false;

                var walker = TreeWalker.ControlViewWalker;
                var queue = new Queue<KeyValuePair<AutomationElement, int>>();
                queue.Enqueue(new KeyValuePair<AutomationElement, int>(root, 0));
                int visited = 0;
                const int maxVisited = 80;
                const int maxDepth = 5;

                int topBandBottom = winRect.Top + 72;
                int rightEdgeMin = winRect.Right - 28;

                while (queue.Count > 0 && visited < maxVisited)
                {
                    var item = queue.Dequeue();
                    var el = item.Key;
                    int depth = item.Value;
                    visited++;

                    ControlType ct = null;
                    try { ct = el.Current.ControlType; } catch { continue; }

                    if (ct == ControlType.Document) continue;

                    if (ct == ControlType.Button)
                    {
                        string name = "";
                        string autoId = "";
                        try { name = el.Current.Name ?? ""; } catch { }
                        try { autoId = el.Current.AutomationId ?? ""; } catch { }

                        bool nameMatch =
                            string.Equals(name, "Close", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(name, "\uB2EB\uAE30", StringComparison.Ordinal) ||
                            string.Equals(autoId, "Close", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(autoId, "CloseButton", StringComparison.OrdinalIgnoreCase);

                        if (nameMatch)
                        {
                            System.Windows.Rect r;
                            try { r = el.Current.BoundingRectangle; } catch { continue; }
                            if (!r.IsEmpty && r.Width >= 24 && r.Width <= 120 && r.Height >= 16 && r.Height <= 90)
                            {
                                int left = (int)Math.Floor(r.Left);
                                int top = (int)Math.Floor(r.Top);
                                int right = (int)Math.Ceiling(r.Right);
                                int bottom = (int)Math.Ceiling(r.Bottom);
                                if (top <= topBandBottom && right >= rightEdgeMin && right <= winRect.Right + 8)
                                {
                                    if (!foundAny || right > bestRight)
                                    {
                                        bestRight = right;
                                        buttonRect = new RECT { Left = left, Top = top, Right = right, Bottom = bottom };
                                        foundAny = true;
                                    }
                                }
                            }
                        }
                    }

                    if (depth >= maxDepth) continue;

                    AutomationElement child = null;
                    try { child = walker.GetFirstChild(el); } catch { child = null; }
                    int siblings = 0;
                    while (child != null && siblings < 25)
                    {
                        queue.Enqueue(new KeyValuePair<AutomationElement, int>(child, depth + 1));
                        siblings++;
                        try { child = walker.GetNextSibling(child); } catch { child = null; }
                    }
                }
            }
            catch { }
            return foundAny;
        }

        private void InstallHook()
        {
            if (_hookHandle != IntPtr.Zero) return;
            IntPtr hMod = NativeMethods.GetModuleHandle(null);
            _hookHandle = NativeMethods.SetWindowsHookEx(NativeMethods.WH_MOUSE_LL, _hookProc, hMod, 0);
        }

        private void UninstallHook()
        {
            _swallowNextLeftUp = false;
            if (_hookHandle != IntPtr.Zero)
            {
                try { NativeMethods.UnhookWindowsHookEx(_hookHandle); } catch { }
                _hookHandle = IntPtr.Zero;
            }
        }

        // Core mouse decision path shared identically by WH_MOUSE_LL and -SelfTest.
        // Returns true when the mouse message must be swallowed.
        public bool ProcessMouseMessage(int msg, POINT pt)
        {
            if (!_enabled) return false;

            if (msg == NativeMethods.WM_LBUTTONUP)
            {
                if (_swallowNextLeftUp)
                {
                    bool withinWindow = DateTime.UtcNow <= _swallowUpDeadlineUtc;
                    _swallowNextLeftUp = false;
                    return withinWindow;
                }
                return false;
            }

            if (msg != NativeMethods.WM_LBUTTONDOWN) return false;

            try
            {
                IntPtr hitWnd = NativeMethods.WindowFromPoint(pt);
                if (hitWnd == IntPtr.Zero) return false;

                IntPtr topWnd = NativeMethods.GetAncestor(hitWnd, NativeMethods.GA_ROOT);
                bool isSingleTracked = false;
                CachedCloseButton cached = null;
                lock (_sync)
                {
                    if (_trackedWindows.Count == 1 && _trackedWindows.Contains(topWnd))
                    {
                        isSingleTracked = true;
                        cached = _cachedClose;
                    }
                }

                if (!isSingleTracked) return false;

                RECT winRect;
                if (!NativeMethods.GetWindowRect(topWnd, out winRect)) return false;

                bool inTopRightCorner =
                    pt.X >= (winRect.Right - 160) &&
                    pt.X <= (winRect.Right + 4) &&
                    pt.Y >= (winRect.Top - 4) &&
                    pt.Y <= (winRect.Top + 140);

                if (inTopRightCorner && IsPointOnCloseButton(topWnd, hitWnd, winRect, pt, cached))
                {
                    _swallowNextLeftUp = true;
                    _swallowUpDeadlineUtc = DateTime.UtcNow.AddMilliseconds(2000);
                    if (_onCloseIntercepted != null)
                    {
                        _onCloseIntercepted(topWnd);
                    }
                    return true;
                }
            }
            catch { }
            return false;
        }

        private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0 && _enabled)
            {
                int msg = wParam.ToInt32();
                if (msg == NativeMethods.WM_LBUTTONDOWN || msg == NativeMethods.WM_LBUTTONUP)
                {
                    var info = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                    if (ProcessMouseMessage(msg, info.pt))
                    {
                        return new IntPtr(1);
                    }
                }
            }
            return NativeMethods.CallNextHookEx(_hookHandle, nCode, wParam, lParam);
        }

        private static bool IsPointOnCloseButton(IntPtr topWnd, IntPtr hitWnd, RECT winRect, POINT pt, CachedCloseButton cached)
        {
            // Fast path: cached UIA Close button rect with matching window position/size (zero cross-process IPC).
            if (cached != null && cached.Hwnd == topWnd && cached.WindowRect.SameAs(winRect))
            {
                if (cached.ButtonRect.Contains(pt.X, pt.Y))
                {
                    return true;
                }
            }

            // Standard Win32 / Chromium NonClientHitTest path (HTCLOSE == 20).
            IntPtr lp = NativeMethods.MakeScreenLParam(pt.X, pt.Y);
            IntPtr hitResult;
            IntPtr ok = NativeMethods.SendMessageTimeout(
                topWnd,
                NativeMethods.WM_NCHITTEST,
                IntPtr.Zero,
                lp,
                NativeMethods.SMTO_ABORTIFHUNG | NativeMethods.SMTO_BLOCK,
                40,
                out hitResult);
            if (ok != IntPtr.Zero && hitResult.ToInt64() == NativeMethods.HTCLOSE)
            {
                return true;
            }
            if (hitWnd != IntPtr.Zero && hitWnd != topWnd)
            {
                ok = NativeMethods.SendMessageTimeout(
                    hitWnd,
                    NativeMethods.WM_NCHITTEST,
                    IntPtr.Zero,
                    lp,
                    NativeMethods.SMTO_ABORTIFHUNG | NativeMethods.SMTO_BLOCK,
                    40,
                    out hitResult);
                if (ok != IntPtr.Zero && hitResult.ToInt64() == NativeMethods.HTCLOSE)
                {
                    return true;
                }
            }
            return false;
        }

        public void Dispose()
        {
            _enabled = false;
            UninstallHook();
        }
    }

    internal sealed class TaskbarBridge : IDisposable
    {
        private object _comObj;
        private ITaskbarList _list;
        private IntPtr _lastTrayWnd = IntPtr.Zero;

        public bool EnsureReady(out bool shellChanged)
        {
            shellChanged = false;
            IntPtr curTray = NativeMethods.FindWindow("Shell_TrayWnd", null);
            if (curTray == IntPtr.Zero)
            {
                ReleaseCom();
                _lastTrayWnd = IntPtr.Zero;
                return false;
            }
            if (_list != null && curTray == _lastTrayWnd)
            {
                return true;
            }
            ReleaseCom();
            _lastTrayWnd = curTray;
            shellChanged = true;
            try
            {
                _comObj = new TaskbarListComObject();
                var tb = (ITaskbarList)_comObj;
                int hr = tb.HrInit();
                if (hr == 0)
                {
                    _list = tb;
                    return true;
                }
            }
            catch
            {
                // Ignore shell initialization errors on non-interactive desktops.
            }
            ReleaseCom();
            return false;
        }

        public bool DeleteTab(IntPtr hwnd)
        {
            bool changed;
            if (!EnsureReady(out changed) || _list == null) return false;
            try { return _list.DeleteTab(hwnd) == 0; } catch { return false; }
        }

        public bool AddTab(IntPtr hwnd)
        {
            bool changed;
            if (!EnsureReady(out changed) || _list == null) return false;
            try { return _list.AddTab(hwnd) == 0; } catch { return false; }
        }

        private void ReleaseCom()
        {
            _list = null;
            if (_comObj != null)
            {
                try { Marshal.ReleaseComObject(_comObj); } catch { }
                _comObj = null;
            }
        }

        public void Dispose()
        {
            ReleaseCom();
        }
    }

    internal sealed class HiddenEntry
    {
        public HideMode AppliedMode;
        public string LastTitle;
        public DateTime LastEnforcedUtc;
    }

    internal sealed class BroadcastListenerWindow : NativeWindow, IDisposable
    {
        private readonly uint _ipcMsg;
        private readonly uint _taskbarCreatedMsg;
        private readonly uint _internalHideMsg;
        private readonly Action<TrayIpcCommand> _onCommand;
        private readonly Action _onTaskbarCreated;
        private readonly Action<IntPtr> _onInternalHide;

        public BroadcastListenerWindow(
            uint ipcMsg,
            uint taskbarCreatedMsg,
            uint internalHideMsg,
            Action<TrayIpcCommand> onCommand,
            Action onTaskbarCreated,
            Action<IntPtr> onInternalHide)
        {
            _ipcMsg = ipcMsg;
            _taskbarCreatedMsg = taskbarCreatedMsg;
            _internalHideMsg = internalHideMsg;
            _onCommand = onCommand;
            _onTaskbarCreated = onTaskbarCreated;
            _onInternalHide = onInternalHide;
            var cp = new CreateParams();
            cp.Caption = "CloseToTrayHelperIpcListener";
            cp.X = 0;
            cp.Y = 0;
            cp.Width = 0;
            cp.Height = 0;
            cp.Style = 0;
            cp.ExStyle = 0x00000080; // WS_EX_TOOLWINDOW
            cp.Parent = IntPtr.Zero; // Top-level invisible window receives HWND_BROADCAST
            CreateHandle(cp);
        }

        protected override void WndProc(ref Message m)
        {
            uint msg = unchecked((uint)m.Msg);
            if (_internalHideMsg != 0 && msg == _internalHideMsg)
            {
                if (_onInternalHide != null) _onInternalHide(m.WParam);
                return;
            }
            if (_ipcMsg != 0 && msg == _ipcMsg)
            {
                int cmdCode = m.WParam.ToInt32();
                if (Enum.IsDefined(typeof(TrayIpcCommand), cmdCode))
                {
                    _onCommand((TrayIpcCommand)cmdCode);
                }
                return;
            }
            if (_taskbarCreatedMsg != 0 && msg == _taskbarCreatedMsg)
            {
                _onTaskbarCreated();
                return;
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero)
            {
                DestroyHandle();
            }
        }
    }

    public static class AsideIpc
    {
        public const string MutexName = @"Local\Close-To-Tray-Helper";
        public const string ListenerWindowCaption = "CloseToTrayHelperIpcListener";
        public const string IpcMessageName = "CloseToTrayHelper_Command_v1";
        public const string InternalHideMessageName = "CloseToTrayHelper_InternalHide_v1";

        public static IntPtr FindListenerWindow()
        {
            return NativeMethods.FindWindow(null, ListenerWindowCaption);
        }

        public static bool IsHelperRunning()
        {
            return FindListenerWindow() != IntPtr.Zero;
        }

        public static bool SendCommand(TrayIpcCommand cmd)
        {
            IntPtr target = FindListenerWindow();
            if (target == IntPtr.Zero) return false;
            uint msg = NativeMethods.RegisterWindowMessage(IpcMessageName);
            if (msg == 0) return false;
            return NativeMethods.PostMessage(target, msg, new IntPtr((int)cmd), IntPtr.Zero);
        }
    }

    public sealed class AsideTrayContext : ApplicationContext
    {
        private const string APP_TITLE = "\ud2b8\ub808\uc774 \ub3c4\uc6b0\ubbf8";
        private const string TIP_HIDDEN = "\ud2b8\ub808\uc774 \ub3c4\uc6b0\ubbf8 (\ube0c\ub77c\uc6b0\uc800 \uc228\uae40 \u00b7 \ud074\ub9ad\ud574 \uc5f4\uae30)";
        private const string TIP_VISIBLE = "\ud2b8\ub808\uc774 \ub3c4\uc6b0\ubbf8 (\ucc3d \uc5f4\ub9bc \u00b7 \ucd5c\uc18c\ud654 \uc2dc \uc228\uae40)";
        private const string TIP_STOPPED = "\ud2b8\ub808\uc774 \ub3c4\uc6b0\ubbf8 (\ube0c\ub77c\uc6b0\uc800 \ubbf8\uc2e4\ud589 \u00b7 \ud074\ub9ad\ud574 \uc2dc\uc791)";
        private const string MENU_SHOW = "\ube0c\ub77c\uc6b0\uc800 \ucc3d \uc5f4\uae30";
        private const string MENU_HIDE = "\uD2B8\uB808\uC774\uB85C \uC989\uC2DC \uC228\uAE30\uAE30";
        private const string MENU_START = "\ube0c\ub77c\uc6b0\uc800 \uc2dc\uc791 (\ud2b8\ub808\uc774\ub85c)";
        private const string MENU_MODE_DEL = "\uC228\uAE40 \uBC29\uC2DD: \uC791\uC5C5 \uD45C\uC2DC\uC904\uB9CC \uC228\uAE30\uAE30 (\uAD8C\uC7A5)";
        private const string MENU_MODE_HIDE = "\uC228\uAE40 \uBC29\uC2DD: \uC644\uC804 \uC228\uAE30\uAE30 (Alt+Tab \uD3EC\uD568)";
        private const string MENU_CLOSE_TO_TRAY = "\uB2EB\uAE30(\u00D7) \uD074\uB9AD \uC2DC \uD2B8\uB808\uC774\uB85C \uC228\uAE30\uAE30";
        private const string MENU_STARTUP = "Windows \uB85C\uADF8\uC778 \uC2DC \uC790\uB3D9 \uC2E4\uD589";
        private const string MENU_AUTOSTART = "\ub3c4\uc6b0\ubbf8 \uc2dc\uc791 \uc2dc \ube0c\ub77c\uc6b0\uc800\ub3c4 \uc790\ub3d9 \uc2dc\uc791";
        private const string MENU_EXIT = "\ud2b8\ub808\uc774 \ub3c4\uc6b0\ubbf8 \uc885\ub8cc (\ube0c\ub77c\uc6b0\uc800 \ucc3d \ubcf5\uc6d0)";

        private readonly string _asideExe;
        private readonly string _asideUpScript;
        private readonly string _prefsPath;
        private readonly string _startupDir;
        private readonly string _launcherVbs;

        private HideMode _mode;
        private bool _autoStartAside;
        private bool _closeToTray;

        private readonly Dictionary<int, bool> _pidCache = new Dictionary<int, bool>();
        private readonly Dictionary<IntPtr, HiddenEntry> _hidden = new Dictionary<IntPtr, HiddenEntry>();
        private readonly TaskbarBridge _taskbar = new TaskbarBridge();
        private readonly uint _internalHideMsg;

        private NotifyIcon _tray;
        private ContextMenuStrip _menu;
        private ToolStripMenuItem _miShow;
        private ToolStripMenuItem _miHide;
        private ToolStripMenuItem _miStart;
        private ToolStripMenuItem _miModeDel;
        private ToolStripMenuItem _miModeHide;
        private ToolStripMenuItem _miCloseToTray;
        private ToolStripMenuItem _miStartup;
        private ToolStripMenuItem _miAutoStart;
        private ToolStripMenuItem _miExit;
        private Font _showBoldFont;
        private System.Windows.Forms.Timer _timer;
        private BroadcastListenerWindow _listener;
        private CloseButtonInterceptor _closeInterceptor;

        private DateTime _suppressHideUntilUtc = DateTime.MinValue;
        private DateTime _lastLeftClickUtc = DateTime.MinValue;
        private bool _launchingAside = false;
        private bool _cleanedUp = false;

        public AsideTrayContext(
            string asideExe,
            string asideUpScript,
            string prefsPath,
            string startupDir,
            string launcherVbs,
            HideMode initialMode,
            bool autoStartAside,
            bool closeToTray,
            bool startAsideNow)
        {
            _asideExe = asideExe ?? "";
            _asideUpScript = asideUpScript ?? "";
            _prefsPath = prefsPath ?? "";
            _startupDir = startupDir ?? "";
            _launcherVbs = launcherVbs ?? "";
            _mode = initialMode;
            _autoStartAside = autoStartAside;
            _closeToTray = closeToTray;

            BuildTrayUi();

            uint ipcMsg = NativeMethods.RegisterWindowMessage(AsideIpc.IpcMessageName);
            uint tbCreated = NativeMethods.RegisterWindowMessage("TaskbarCreated");
            _internalHideMsg = NativeMethods.RegisterWindowMessage(AsideIpc.InternalHideMessageName);
            _listener = new BroadcastListenerWindow(
                ipcMsg,
                tbCreated,
                _internalHideMsg,
                HandleIpcCommand,
                HandleTaskbarCreated,
                HideWindowFromCloseClick);

            _closeInterceptor = new CloseButtonInterceptor(hwnd =>
            {
                if (_listener != null && _listener.Handle != IntPtr.Zero && _internalHideMsg != 0)
                {
                    NativeMethods.PostMessage(_listener.Handle, _internalHideMsg, hwnd, IntPtr.Zero);
                }
            });
            _closeInterceptor.Enabled = _closeToTray;

            SystemEvents.SessionEnding += OnSessionEnding;
            AppDomain.CurrentDomain.ProcessExit += OnProcessExit;
            Application.ApplicationExit += OnApplicationExit;

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 350;
            _timer.Tick += (s, e) => Reconcile();
            _timer.Start();

            // Run one immediate scan so an already-minimized Aside window hides at once.
            Reconcile();

            if (startAsideNow || _autoStartAside)
            {
                if (!IsAsideBrowserRunning())
                {
                    LaunchAsideAsync();
                }
            }
        }

        private void BuildTrayUi()
        {
            _menu = new ContextMenuStrip();
            _menu.Opening += (s, e) => RefreshMenuState();

            _miShow = new ToolStripMenuItem(MENU_SHOW);
            _showBoldFont = new Font(_miShow.Font, FontStyle.Bold);
            _miShow.Font = _showBoldFont;
            _miShow.Click += (s, e) => ShowAllAsideWindows();

            _miHide = new ToolStripMenuItem(MENU_HIDE);
            _miHide.Click += (s, e) => HideAllAsideWindows();

            _miStart = new ToolStripMenuItem(MENU_START);
            _miStart.Click += (s, e) => LaunchAsideAsync();

            _miModeDel = new ToolStripMenuItem(MENU_MODE_DEL);
            _miModeDel.Click += (s, e) => SwitchMode(HideMode.DeleteTab);

            _miModeHide = new ToolStripMenuItem(MENU_MODE_HIDE);
            _miModeHide.Click += (s, e) => SwitchMode(HideMode.HideWindow);

            _miCloseToTray = new ToolStripMenuItem(MENU_CLOSE_TO_TRAY);
            _miCloseToTray.Click += (s, e) => ToggleCloseToTray();

            _miStartup = new ToolStripMenuItem(MENU_STARTUP);
            _miStartup.Click += (s, e) => ToggleStartupShortcut();

            _miAutoStart = new ToolStripMenuItem(MENU_AUTOSTART);
            _miAutoStart.Click += (s, e) => ToggleAutoStartAside();

            _miExit = new ToolStripMenuItem(MENU_EXIT);
            _miExit.Click += (s, e) => RequestExit();

            _menu.Items.Add(_miShow);
            _menu.Items.Add(_miHide);
            _menu.Items.Add(_miStart);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_miModeDel);
            _menu.Items.Add(_miModeHide);
            _menu.Items.Add(_miCloseToTray);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_miStartup);
            _menu.Items.Add(_miAutoStart);
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(_miExit);

            _tray = new NotifyIcon();
            _tray.Text = APP_TITLE;
            _tray.ContextMenuStrip = _menu;
            _tray.Icon = LoadTrayIcon();
            _tray.MouseClick += OnTrayMouseClick;
            _tray.Visible = true;
        }

        private Icon LoadTrayIcon()
        {
            // Neutral Windows icon: the helper does not reuse the browser's own icon or logo.
            return SystemIcons.Application;
        }

        private void OnTrayMouseClick(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            var now = DateTime.UtcNow;
            if ((now - _lastLeftClickUtc).TotalMilliseconds < 400) return;
            _lastLeftClickUtc = now;
            ToggleAsideWindows();
        }

        private void HideWindowFromCloseClick(IntPtr hwnd)
        {
            if (_cleanedUp || hwnd == IntPtr.Zero || !NativeMethods.IsWindow(hwnd)) return;
            _suppressHideUntilUtc = DateTime.MinValue;
            ApplyHide(hwnd, _mode);
            UpdateTooltip(true);
        }

        private void HandleIpcCommand(TrayIpcCommand cmd)
        {
            switch (cmd)
            {
                case TrayIpcCommand.Stop:
                    RequestExit();
                    break;
                case TrayIpcCommand.Show:
                    ShowAllAsideWindows();
                    break;
                case TrayIpcCommand.Hide:
                    HideAllAsideWindows();
                    break;
                case TrayIpcCommand.Toggle:
                    ToggleAsideWindows();
                    break;
            }
        }

        private void HandleTaskbarCreated()
        {
            bool changed;
            _taskbar.EnsureReady(out changed);
            foreach (var kv in _hidden)
            {
                if (kv.Value.AppliedMode == HideMode.DeleteTab && NativeMethods.IsWindow(kv.Key))
                {
                    _taskbar.DeleteTab(kv.Key);
                    kv.Value.LastEnforcedUtc = DateTime.UtcNow;
                }
            }
        }

        private HashSet<int> GetAsideBrowserPids()
        {
            var live = new HashSet<int>();
            Process[] procs;
            try { procs = Process.GetProcessesByName("Aside"); }
            catch { return live; }

            var seen = new HashSet<int>();
            foreach (var p in procs)
            {
                try
                {
                    int pid = p.Id;
                    seen.Add(pid);
                    bool isBrowser;
                    if (!_pidCache.TryGetValue(pid, out isBrowser))
                    {
                        isBrowser = CheckIsAsideBrowserProcess(p);
                        _pidCache[pid] = isBrowser;
                    }
                    if (isBrowser) live.Add(pid);
                }
                catch { }
                finally { p.Dispose(); }
            }

            if (_pidCache.Count > 64)
            {
                var stale = new List<int>();
                foreach (var k in _pidCache.Keys)
                {
                    if (!seen.Contains(k)) stale.Add(k);
                }
                foreach (var k in stale) _pidCache.Remove(k);
            }
            return live;
        }

        private static bool CheckIsAsideBrowserProcess(Process p)
        {
            try
            {
                string path = p.MainModule != null ? p.MainModule.FileName : null;
                if (string.IsNullOrEmpty(path)) return false;
                if (path.EndsWith(@"\Application\Aside.exe", StringComparison.OrdinalIgnoreCase)) return true;
                var info = FileVersionInfo.GetVersionInfo(path);
                return string.Equals(info.ProductName, "Aside", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private bool IsAsideBrowserRunning()
        {
            return GetAsideBrowserPids().Count > 0;
        }

        private static bool IsCandidateAsideWindow(IntPtr hwnd, HashSet<int> asidePids)
        {
            if (!NativeMethods.IsWindow(hwnd)) return false;
            uint pid;
            NativeMethods.GetWindowThreadProcessId(hwnd, out pid);
            if (!asidePids.Contains((int)pid)) return false;
            if (NativeMethods.GetParent(hwnd) != IntPtr.Zero) return false;
            if (NativeMethods.GetWindow(hwnd, NativeMethods.GW_OWNER) != IntPtr.Zero) return false;

            var cls = new StringBuilder(128);
            NativeMethods.GetClassName(hwnd, cls, cls.Capacity);
            string cn = cls.ToString();
            if (cn != "Chrome_WidgetWin_1" && cn != "WinUIDesktopWin32WindowClass") return false;

            int style = NativeMethods.GetWindowLong(hwnd, NativeMethods.GWL_STYLE);
            if ((style & NativeMethods.WS_MINIMIZEBOX) == 0) return false;

            return true;
        }

        private List<IntPtr> EnumAsideMainWindows(HashSet<int> asidePids)
        {
            var found = new List<IntPtr>();
            if (asidePids.Count == 0) return found;
            NativeMethods.EnumWindows((h, l) =>
            {
                if (IsCandidateAsideWindow(h, asidePids))
                {
                    if (NativeMethods.IsWindowVisible(h) || _hidden.ContainsKey(h))
                    {
                        found.Add(h);
                    }
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        private static string GetWindowTitleSafe(IntPtr hwnd)
        {
            var sb = new StringBuilder(256);
            NativeMethods.GetWindowText(hwnd, sb, sb.Capacity);
            return sb.ToString();
        }

        private void ApplyHide(IntPtr hwnd, HideMode targetMode)
        {
            if (targetMode == HideMode.HideWindow)
            {
                NativeMethods.ShowWindow(hwnd, NativeMethods.SW_HIDE);
            }
            else
            {
                if (!NativeMethods.IsWindowVisible(hwnd))
                {
                    NativeMethods.ShowWindow(hwnd, NativeMethods.SW_SHOWMINNOACTIVE);
                }
                else if (!NativeMethods.IsIconic(hwnd))
                {
                    NativeMethods.ShowWindowAsync(hwnd, NativeMethods.SW_MINIMIZE);
                }
                _taskbar.DeleteTab(hwnd);
            }

            _hidden[hwnd] = new HiddenEntry
            {
                AppliedMode = targetMode,
                LastTitle = GetWindowTitleSafe(hwnd),
                LastEnforcedUtc = DateTime.UtcNow
            };
        }

        private void ApplyRestore(IntPtr hwnd, HiddenEntry entry, bool activate)
        {
            if (!NativeMethods.IsWindow(hwnd)) return;
            if (entry != null && entry.AppliedMode == HideMode.HideWindow)
            {
                if (activate)
                {
                    NativeMethods.ShowWindow(hwnd, NativeMethods.SW_SHOW);
                    if (NativeMethods.IsIconic(hwnd))
                    {
                        NativeMethods.ShowWindow(hwnd, NativeMethods.SW_RESTORE);
                    }
                    NativeMethods.SetForegroundWindow(hwnd);
                }
                else
                {
                    NativeMethods.ShowWindow(hwnd, NativeMethods.SW_SHOWMINNOACTIVE);
                }
            }
            else
            {
                _taskbar.AddTab(hwnd);
                if (activate)
                {
                    if (NativeMethods.IsIconic(hwnd))
                    {
                        NativeMethods.ShowWindow(hwnd, NativeMethods.SW_RESTORE);
                    }
                    NativeMethods.SetForegroundWindow(hwnd);
                }
            }
        }

        public void ShowAllAsideWindows()
        {
            _suppressHideUntilUtc = DateTime.UtcNow.AddMilliseconds(1500);
            var pids = GetAsideBrowserPids();
            var wins = EnumAsideMainWindows(pids);
            if (wins.Count == 0 && _hidden.Count == 0)
            {
                LaunchAsideAsync();
                return;
            }

            var toRestore = new List<IntPtr>();
            foreach (var h in _hidden.Keys) toRestore.Add(h);
            foreach (var h in wins)
            {
                if (!toRestore.Contains(h)) toRestore.Add(h);
            }

            foreach (var h in toRestore)
            {
                HiddenEntry entry;
                _hidden.TryGetValue(h, out entry);
                ApplyRestore(h, entry, true);
                _hidden.Remove(h);
            }
            if (_closeInterceptor != null)
            {
                _closeInterceptor.UpdateTrackedWindows(toRestore);
            }
            UpdateTooltip(pids.Count > 0);
        }

        public void HideAllAsideWindows()
        {
            _suppressHideUntilUtc = DateTime.MinValue;
            var pids = GetAsideBrowserPids();
            var wins = EnumAsideMainWindows(pids);
            foreach (var h in wins)
            {
                ApplyHide(h, _mode);
            }
            UpdateTooltip(pids.Count > 0);
        }

        public void ToggleAsideWindows()
        {
            var pids = GetAsideBrowserPids();
            if (pids.Count == 0)
            {
                LaunchAsideAsync();
                return;
            }
            if (_hidden.Count > 0)
            {
                ShowAllAsideWindows();
                return;
            }
            var wins = EnumAsideMainWindows(pids);
            bool anyVisibleOpen = false;
            foreach (var h in wins)
            {
                if (NativeMethods.IsWindowVisible(h) && !NativeMethods.IsIconic(h))
                {
                    anyVisibleOpen = true;
                    break;
                }
            }
            if (anyVisibleOpen)
            {
                HideAllAsideWindows();
            }
            else
            {
                ShowAllAsideWindows();
            }
        }

        private void SwitchMode(HideMode newMode)
        {
            if (_mode == newMode) return;
            _mode = newMode;
            SavePrefs();

            var keys = new List<IntPtr>(_hidden.Keys);
            foreach (var h in keys)
            {
                if (!NativeMethods.IsWindow(h))
                {
                    _hidden.Remove(h);
                    continue;
                }
                ApplyHide(h, _mode);
            }
        }

        private void ToggleCloseToTray()
        {
            _closeToTray = !_closeToTray;
            if (_closeInterceptor != null)
            {
                _closeInterceptor.Enabled = _closeToTray;
            }
            SavePrefs();
        }

        private void Reconcile()
        {
            if (_cleanedUp) return;

            var dead = new List<IntPtr>();
            foreach (var h in _hidden.Keys)
            {
                if (!NativeMethods.IsWindow(h)) dead.Add(h);
            }
            foreach (var h in dead) _hidden.Remove(h);

            bool shellChanged;
            _taskbar.EnsureReady(out shellChanged);

            var pids = GetAsideBrowserPids();
            var wins = EnumAsideMainWindows(pids);
            var now = DateTime.UtcNow;

            var allTracked = new HashSet<IntPtr>(wins);
            foreach (var h in _hidden.Keys) allTracked.Add(h);
            if (_closeInterceptor != null)
            {
                _closeInterceptor.UpdateTrackedWindows(allTracked);
            }

            foreach (var h in wins)
            {
                HiddenEntry entry;
                if (_hidden.TryGetValue(h, out entry))
                {
                    if (entry.AppliedMode == HideMode.DeleteTab)
                    {
                        if (!NativeMethods.IsWindowVisible(h))
                        {
                            _hidden.Remove(h);
                        }
                        else if (!NativeMethods.IsIconic(h))
                        {
                            _taskbar.AddTab(h);
                            _hidden.Remove(h);
                        }
                        else
                        {
                            string curTitle = GetWindowTitleSafe(h);
                            if (shellChanged || curTitle != entry.LastTitle || (now - entry.LastEnforcedUtc).TotalMilliseconds >= 1500)
                            {
                                _taskbar.DeleteTab(h);
                                entry.LastTitle = curTitle;
                                entry.LastEnforcedUtc = now;
                            }
                        }
                    }
                    else
                    {
                        if (NativeMethods.IsWindowVisible(h))
                        {
                            if (!NativeMethods.IsIconic(h))
                            {
                                _hidden.Remove(h);
                            }
                            else
                            {
                                NativeMethods.ShowWindow(h, NativeMethods.SW_HIDE);
                                entry.LastEnforcedUtc = now;
                            }
                        }
                    }
                }
                else
                {
                    if (now >= _suppressHideUntilUtc && NativeMethods.IsWindowVisible(h) && NativeMethods.IsIconic(h))
                    {
                        ApplyHide(h, _mode);
                    }
                }
            }

            UpdateTooltip(pids.Count > 0);
        }

        private void UpdateTooltip(bool asideRunning)
        {
            if (_tray == null) return;
            string tip;
            if (!asideRunning) tip = TIP_STOPPED;
            else if (_hidden.Count > 0) tip = TIP_HIDDEN;
            else tip = TIP_VISIBLE;
            if (_tray.Text != tip) _tray.Text = tip;
        }

        private void RefreshMenuState()
        {
            bool running = IsAsideBrowserRunning();
            _miShow.Enabled = running;
            _miHide.Enabled = running;
            _miStart.Enabled = !running && !_launchingAside;
            _miModeDel.Checked = (_mode == HideMode.DeleteTab);
            _miModeHide.Checked = (_mode == HideMode.HideWindow);
            _miCloseToTray.Checked = _closeToTray;
            _miStartup.Checked = IsStartupInstalled();
            _miAutoStart.Checked = _autoStartAside;
        }

        private string GetStartupShortcutPath()
        {
            return Path.Combine(_startupDir, "Close To Tray Helper.lnk");
        }

        private bool IsStartupInstalled()
        {
            return !string.IsNullOrEmpty(_startupDir) && File.Exists(GetStartupShortcutPath());
        }

        private void ToggleStartupShortcut()
        {
            try
            {
                string lnk = GetStartupShortcutPath();
                if (File.Exists(lnk))
                {
                    File.Delete(lnk);
                }
                else if (!string.IsNullOrEmpty(_launcherVbs) && File.Exists(_launcherVbs))
                {
                    Directory.CreateDirectory(_startupDir);
                    Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                    object shell = Activator.CreateInstance(shellType);
                    try
                    {
                        object sc = shellType.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
                        Type scType = sc.GetType();
                        string wscript = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "wscript.exe");
                        scType.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { wscript });
                        scType.InvokeMember("Arguments", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { string.Format("//B //Nologo \"{0}\"", _launcherVbs) });
                        scType.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { Path.GetDirectoryName(_launcherVbs) });
                        scType.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, sc, new object[] { "Close-to-tray helper (unofficial)" });
                        // No IconLocation: the shortcut keeps the default wscript.exe icon (no browser logo).
                        scType.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, sc, null);
                        Marshal.ReleaseComObject(sc);
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(shell);
                    }
                }
            }
            catch { }
        }

        private void ToggleAutoStartAside()
        {
            _autoStartAside = !_autoStartAside;
            SavePrefs();
        }

        private void SavePrefs()
        {
            if (string.IsNullOrEmpty(_prefsPath)) return;
            try
            {
                string dir = Path.GetDirectoryName(_prefsPath);
                if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
                string json = string.Format(
                    "{{\"mode\":\"{0}\",\"autoStartAside\":{1},\"closeToTray\":{2}}}",
                    _mode == HideMode.HideWindow ? "HideWindow" : "DeleteTab",
                    _autoStartAside ? "true" : "false",
                    _closeToTray ? "true" : "false");
                File.WriteAllText(_prefsPath, json, new UTF8Encoding(false));
            }
            catch { }
        }

        private void LaunchAsideAsync()
        {
            if (_launchingAside) return;
            // Prefer an optional launcher script (for example one that starts Aside minimized
            // and returns focus); otherwise start Aside.exe directly.
            bool useScript = !string.IsNullOrEmpty(_asideUpScript) && File.Exists(_asideUpScript);
            bool useExe = !useScript && !string.IsNullOrEmpty(_asideExe) && File.Exists(_asideExe);
            if (!useScript && !useExe) return;
            _launchingAside = true;
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    var psi = new ProcessStartInfo();
                    if (useScript)
                    {
                        psi.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
                        psi.Arguments = string.Format("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{0}\"", _asideUpScript);
                        psi.UseShellExecute = false;
                        psi.CreateNoWindow = true;
                        using (var proc = Process.Start(psi))
                        {
                            if (proc != null) proc.WaitForExit(35000);
                        }
                    }
                    else
                    {
                        psi.FileName = _asideExe;
                        psi.UseShellExecute = true;
                        psi.WindowStyle = ProcessWindowStyle.Minimized;
                        using (Process.Start(psi)) { }
                    }
                }
                catch { }
                finally
                {
                    _launchingAside = false;
                }
            });
        }

        private void RestoreAllOnExit()
        {
            if (_cleanedUp) return;
            _cleanedUp = true;

            if (_closeInterceptor != null)
            {
                try { _closeInterceptor.Dispose(); } catch { }
                _closeInterceptor = null;
            }

            if (_timer != null)
            {
                try { _timer.Stop(); _timer.Dispose(); } catch { }
                _timer = null;
            }

            foreach (var kv in _hidden)
            {
                try { ApplyRestore(kv.Key, kv.Value, false); } catch { }
            }
            _hidden.Clear();

            if (_tray != null)
            {
                try { _tray.Visible = false; _tray.Dispose(); } catch { }
                _tray = null;
            }
            if (_menu != null)
            {
                try { _menu.Dispose(); } catch { }
                _menu = null;
            }
            if (_showBoldFont != null)
            {
                try { _showBoldFont.Dispose(); } catch { }
                _showBoldFont = null;
            }
            if (_listener != null)
            {
                try { _listener.Dispose(); } catch { }
                _listener = null;
            }
            _taskbar.Dispose();
        }

        private void OnSessionEnding(object sender, SessionEndingEventArgs e)
        {
            RestoreAllOnExit();
        }

        private void OnProcessExit(object sender, EventArgs e)
        {
            RestoreAllOnExit();
        }

        private void OnApplicationExit(object sender, EventArgs e)
        {
            RestoreAllOnExit();
        }

        public void RequestExit()
        {
            RestoreAllOnExit();
            ExitThread();
        }

        private static void PumpEvents(int durationMs)
        {
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < durationMs)
            {
                Application.DoEvents();
                Thread.Sleep(10);
            }
        }

        private static bool WaitForUiaCloseRect(CloseButtonInterceptor interceptor, IntPtr hwnd, out RECT closeRect, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            var lastKick = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (interceptor.TryGetCachedCloseRect(hwnd, out closeRect))
                {
                    return true;
                }
                if (lastKick.ElapsedMilliseconds >= 250)
                {
                    interceptor.TriggerUiaRefreshAsync(hwnd);
                    lastKick.Restart();
                }
                Application.DoEvents();
                Thread.Sleep(15);
            }
            return interceptor.TryGetCachedCloseRect(hwnd, out closeRect);
        }

        private static bool FindCloseRectOffUiThread(IntPtr hwnd, out RECT closeRect, int timeoutMs)
        {
            closeRect = default(RECT);
            RECT wr;
            if (!NativeMethods.GetWindowRect(hwnd, out wr)) return false;
            bool done = false;
            bool found = false;
            RECT result = default(RECT);
            ThreadPool.QueueUserWorkItem(_ =>
            {
                try
                {
                    RECT br;
                    if (CloseButtonInterceptor.TryFindCloseButtonRectViaUia(hwnd, wr, out br))
                    {
                        result = br;
                        found = true;
                    }
                }
                catch { }
                finally { done = true; }
            });
            var sw = Stopwatch.StartNew();
            while (!done && sw.ElapsedMilliseconds < timeoutMs)
            {
                Application.DoEvents();
                Thread.Sleep(15);
            }
            if (found) closeRect = result;
            return found;
        }

        // Pure live verification of WH_MOUSE_LL install/unhook, UIA close-button detection,
        // WM_NCHITTEST(HTCLOSE) fallback, paired LBUTTONUP swallowing, client pass-through,
        // overlapping-window occlusion guard, multi-window pass-through, and disable state.
        // All UIA queries run off the owning STA UI thread while pumping Application.DoEvents().
        // Never moves the user's mouse cursor or calls SendInput.
        public static string RunCloseInterceptTest()
        {
            bool hookInstalled = false;
            bool hookUnhooked = false;
            bool uiaCloseFound = false;
            bool htCloseMatched = false;
            bool singleIntercepted = false;
            bool pairedUpSwallowed = false;
            bool htCloseFallbackIntercepted = false;
            bool clientPassed = false;
            bool occludedPassed = false;
            bool multiPassed = false;
            bool disabledPassed = false;

            int interceptedCount = 0;
            IntPtr lastInterceptedHwnd = IntPtr.Zero;

            using (var interceptor = new CloseButtonInterceptor(h =>
            {
                interceptedCount++;
                lastInterceptedHwnd = h;
            }))
            using (var f1 = new Form())
            {
                f1.Text = "CloseToTraySelfTest_Primary";
                f1.Width = 340;
                f1.Height = 220;
                f1.StartPosition = FormStartPosition.Manual;
                f1.Left = 120;
                f1.Top = 120;
                f1.TopMost = true;
                f1.Show();
                PumpEvents(80);

                interceptor.Enabled = true;
                hookInstalled = interceptor.IsHookActive;
                interceptor.UpdateTrackedWindows(new[] { f1.Handle });

                RECT closeRect;
                uiaCloseFound = WaitForUiaCloseRect(interceptor, f1.Handle, out closeRect, 2500);
                if (uiaCloseFound)
                {
                    var closePt = new POINT
                    {
                        X = (closeRect.Left + closeRect.Right) / 2,
                        Y = (closeRect.Top + closeRect.Bottom) / 2
                    };

                    IntPtr hitRes;
                    IntPtr ok = NativeMethods.SendMessageTimeout(
                        f1.Handle,
                        NativeMethods.WM_NCHITTEST,
                        IntPtr.Zero,
                        NativeMethods.MakeScreenLParam(closePt.X, closePt.Y),
                        NativeMethods.SMTO_ABORTIFHUNG | NativeMethods.SMTO_BLOCK,
                        80,
                        out hitRes);
                    htCloseMatched = (ok != IntPtr.Zero && hitRes.ToInt64() == NativeMethods.HTCLOSE);

                    // 1. Single tracked window + cached UIA rect: LBUTTONDOWN swallowed, paired LBUTTONUP swallowed, stray LBUTTONUP NOT swallowed.
                    bool downSwallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, closePt);
                    bool up1Swallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONUP, closePt);
                    bool up2Swallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONUP, closePt);
                    singleIntercepted = (downSwallowed && interceptedCount == 1 && lastInterceptedHwnd == f1.Handle);
                    pairedUpSwallowed = (up1Swallowed && !up2Swallowed);

                    // 2. Clear UIA cache to force Layer B (WM_NCHITTEST == HTCLOSE) fallback path.
                    interceptor.ClearUiaCache();
                    bool fbDown = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, closePt);
                    bool fbUp = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONUP, closePt);
                    htCloseFallbackIntercepted = (fbDown && fbUp && interceptedCount == 2 && lastInterceptedHwnd == f1.Handle);

                    // Restore UIA cache asynchronously while pumping UI thread.
                    interceptor.TriggerUiaRefreshAsync(f1.Handle);
                    RECT dummyRect;
                    WaitForUiaCloseRect(interceptor, f1.Handle, out dummyRect, 1500);

                    // 3. Click on center client area must pass through untouched.
                    RECT wr1;
                    NativeMethods.GetWindowRect(f1.Handle, out wr1);
                    var clientPt = new POINT { X = (wr1.Left + wr1.Right) / 2, Y = (wr1.Top + wr1.Bottom) / 2 + 20 };
                    bool clientSwallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, clientPt);
                    clientPassed = (!clientSwallowed && interceptedCount == 2);

                    // 4. Overlapping window covering f1's X button: WindowFromPoint hits cover window -> must NOT intercept.
                    using (var fCover = new Form())
                    {
                        fCover.Text = "CloseToTraySelfTest_Cover";
                        fCover.Width = 260;
                        fCover.Height = 180;
                        fCover.StartPosition = FormStartPosition.Manual;
                        fCover.Left = closePt.X - 80;
                        fCover.Top = Math.Max(0, closePt.Y - 40);
                        fCover.TopMost = true;
                        fCover.Show();
                        fCover.BringToFront();
                        PumpEvents(80);

                        bool occSwallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, closePt);
                        occludedPassed = (!occSwallowed && interceptedCount == 2);
                        fCover.Close();
                    }
                    PumpEvents(40);

                    // 5. Multi-window (2 tracked windows): clicking X on window 2 must NOT intercept.
                    using (var f2 = new Form())
                    {
                        f2.Text = "CloseToTraySelfTest_Secondary";
                        f2.Width = 340;
                        f2.Height = 220;
                        f2.StartPosition = FormStartPosition.Manual;
                        f2.Left = 500;
                        f2.Top = 120;
                        f2.TopMost = true;
                        f2.Show();
                        PumpEvents(80);

                        interceptor.UpdateTrackedWindows(new[] { f1.Handle, f2.Handle });
                        RECT cr2;
                        if (FindCloseRectOffUiThread(f2.Handle, out cr2, 2000))
                        {
                            var pt2 = new POINT { X = (cr2.Left + cr2.Right) / 2, Y = (cr2.Top + cr2.Bottom) / 2 };
                            bool mSwallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, pt2);
                            multiPassed = (!mSwallowed && interceptedCount == 2);
                        }
                        f2.Close();
                    }
                    PumpEvents(40);

                    // 6. Disable interceptor: hook cleanly unhooks and X passes through.
                    interceptor.UpdateTrackedWindows(new[] { f1.Handle });
                    interceptor.Enabled = false;
                    hookUnhooked = !interceptor.IsHookActive;
                    bool disSwallowed = interceptor.ProcessMouseMessage(NativeMethods.WM_LBUTTONDOWN, closePt);
                    disabledPassed = (!disSwallowed && interceptedCount == 2);
                }
                else
                {
                    interceptor.Enabled = false;
                    hookUnhooked = !interceptor.IsHookActive;
                }

                if (!f1.IsDisposed) f1.Close();
            }

            return string.Format(
                "hook_installed={0};hook_unhooked={1};uia_close_found={2};htclose_matched={3};single_intercepted={4};paired_up_swallowed={5};htclose_fallback_intercepted={6};client_passed={7};occluded_passed={8};multi_passed={9};disabled_passed={10}",
                hookInstalled, hookUnhooked, uiaCloseFound, htCloseMatched,
                singleIntercepted, pairedUpSwallowed, htCloseFallbackIntercepted,
                clientPassed, occludedPassed, multiPassed, disabledPassed);
        }

        public static string RunSelfTest(string asideExe)
        {
            NativeMethods.TryEnablePerMonitorDpi();
            Icon neutralIcon = SystemIcons.Application;
            bool iconOk = (neutralIcon != null && neutralIcon.Width > 0);
            bool shellTrayPresent = NativeMethods.FindWindow("Shell_TrayWnd", null) != IntPtr.Zero;
            bool tbReady;
            using (var tb = new TaskbarBridge())
            {
                bool changed;
                tbReady = tb.EnsureReady(out changed);
            }
            uint ipcMsg = NativeMethods.RegisterWindowMessage(AsideIpc.IpcMessageName);
            int maxTipLen = Math.Max(TIP_HIDDEN.Length, Math.Max(TIP_VISIBLE.Length, TIP_STOPPED.Length));
            string closeDiag = RunCloseInterceptTest();
            return string.Format(
                "icon_ok={0};shell_tray={1};taskbar_ready={2};ipc_msg={3};tip_len={4};{5}",
                iconOk, shellTrayPresent, tbReady, ipcMsg > 0, maxTipLen, closeDiag);
        }
    }
}
'@

if (-not ('CloseToTrayHelper.AsideTrayContext' -as [type])) {
    Add-Type -TypeDefinition $CSharpSource -ReferencedAssemblies @(
        'System.Windows.Forms', 'System.Drawing',
        'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase'
    )
}

# Handle one-shot IPC control flags (-Stop, -Show, -Hide, -Toggle).
if ($Stop -or $Show -or $Hide -or $Toggle) {
    $cmd = [CloseToTrayHelper.TrayIpcCommand]::None
    $name = 'none'
    if ($Stop) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Stop; $name = 'stop' }
    elseif ($Show) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Show; $name = 'show' }
    elseif ($Hide) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Hide; $name = 'hide' }
    elseif ($Toggle) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Toggle; $name = 'toggle' }
    $running = [CloseToTrayHelper.AsideIpc]::IsHelperRunning()
    $sent = [CloseToTrayHelper.AsideIpc]::SendCommand($cmd)
    $res = [ordered]@{ action = $name; running = $running; sent = $sent }
    Out-Result $res ("[close-to-tray] command=$name running=$running sent=$sent")
    exit 0
}

# Handle offline -SelfTest: compiles the controller, briefly shows three small top-most
# test windows and installs a temporary mouse hook; never touches Aside or holds the mutex.
if ($SelfTest) {
    $prefs = Read-TrayPrefs $PrefsPath
    $prefsDirty = $false
    if ($Mode) { $prefs.mode = $Mode; $prefsDirty = $true }
    if ($CloseToTray) { $prefs.closeToTray = $true; $prefsDirty = $true }
    if ($NoCloseToTray) { $prefs.closeToTray = $false; $prefsDirty = $true }
    if ($prefsDirty) {
        Write-TrayPrefs -Path $PrefsPath -ModeVal $prefs.mode -AutoStartVal ([bool]$prefs.autoStartAside) -CloseToTrayVal ([bool]$prefs.closeToTray)
        $prefs = Read-TrayPrefs $PrefsPath
    }
    $csDiag = [CloseToTrayHelper.AsideTrayContext]::RunSelfTest($ResolvedAsideExe)
    $kv = @{}
    foreach ($pair in ($csDiag -split ';')) {
        $parts = $pair -split '=', 2
        if ($parts.Count -eq 2) { $kv[$parts[0]] = $parts[1] }
    }
    $closeOk = (
        $kv['hook_installed'] -eq 'True' -and
        $kv['hook_unhooked'] -eq 'True' -and
        $kv['uia_close_found'] -eq 'True' -and
        $kv['htclose_matched'] -eq 'True' -and
        $kv['single_intercepted'] -eq 'True' -and
        $kv['paired_up_swallowed'] -eq 'True' -and
        $kv['htclose_fallback_intercepted'] -eq 'True' -and
        $kv['client_passed'] -eq 'True' -and
        $kv['occluded_passed'] -eq 'True' -and
        $kv['multi_passed'] -eq 'True' -and
        $kv['disabled_passed'] -eq 'True'
    )
    $ok = ([bool]($kv['ipc_msg'] -eq 'True') -and [int]$kv['tip_len'] -le 63 -and (Test-Path -LiteralPath $LauncherVbs -PathType Leaf) -and $closeOk)
    $res = [ordered]@{
        self_test_ok = $ok
        mode = $prefs.mode
        auto_start_aside = [bool]$prefs.autoStartAside
        close_to_tray = [bool]$prefs.closeToTray
        aside_exe = $ResolvedAsideExe
        aside_exe_found = ([bool]$ResolvedAsideExe -and (Test-Path -LiteralPath $ResolvedAsideExe -PathType Leaf))
        aside_up_found = (Test-Path -LiteralPath $AsideUpScript -PathType Leaf)
        launcher_found = (Test-Path -LiteralPath $LauncherVbs -PathType Leaf)
        icon_extracted = ($kv['icon_ok'] -eq 'True')
        shell_tray_present = ($kv['shell_tray'] -eq 'True')
        taskbar_ready = ($kv['taskbar_ready'] -eq 'True')
        ipc_msg_registered = ($kv['ipc_msg'] -eq 'True')
        tooltip_max_len = [int]$kv['tip_len']
        apartment_state = [System.Threading.Thread]::CurrentThread.ApartmentState.ToString()
        startup_installed = (Test-Path -LiteralPath (Get-StartupShortcutPath $StartupDir) -PathType Leaf)
        close_intercept = [ordered]@{
            hook_installed = ($kv['hook_installed'] -eq 'True')
            hook_unhooked = ($kv['hook_unhooked'] -eq 'True')
            uia_close_found = ($kv['uia_close_found'] -eq 'True')
            htclose_matched = ($kv['htclose_matched'] -eq 'True')
            single_intercepted = ($kv['single_intercepted'] -eq 'True')
            paired_up_swallowed = ($kv['paired_up_swallowed'] -eq 'True')
            htclose_fallback_intercepted = ($kv['htclose_fallback_intercepted'] -eq 'True')
            client_passed = ($kv['client_passed'] -eq 'True')
            occluded_passed = ($kv['occluded_passed'] -eq 'True')
            multi_passed = ($kv['multi_passed'] -eq 'True')
            disabled_passed = ($kv['disabled_passed'] -eq 'True')
        }
    }
    Out-Result $res ("[close-to-tray] self-test ok=$ok mode=$($prefs.mode) close_to_tray=$($prefs.closeToTray) close_ok=$closeOk")
    if ($ok) { exit 0 } else { exit 1 }
}

# Normal resident tray execution: single-instance mutex.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, [CloseToTrayHelper.AsideIpc]::MutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

try {
    [CloseToTrayHelper.NativeMethods]::TryEnablePerMonitorDpi()
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

    $prefs = Read-TrayPrefs $PrefsPath
    $prefsDirty = $false
    if ($Mode) { $prefs.mode = $Mode; $prefsDirty = $true }
    if ($CloseToTray) { $prefs.closeToTray = $true; $prefsDirty = $true }
    if ($NoCloseToTray) { $prefs.closeToTray = $false; $prefsDirty = $true }
    if ($prefsDirty) {
        Write-TrayPrefs -Path $PrefsPath -ModeVal $prefs.mode -AutoStartVal ([bool]$prefs.autoStartAside) -CloseToTrayVal ([bool]$prefs.closeToTray)
    }
    $hideMode = if ($prefs.mode -eq 'HideWindow') { [CloseToTrayHelper.HideMode]::HideWindow } else { [CloseToTrayHelper.HideMode]::DeleteTab }

    $ctx = New-Object CloseToTrayHelper.AsideTrayContext(
        $ResolvedAsideExe,
        $AsideUpScript,
        $PrefsPath,
        $StartupDir,
        $LauncherVbs,
        $hideMode,
        [bool]$prefs.autoStartAside,
        [bool]$prefs.closeToTray,
        [bool]$StartAside
    )
    [System.Windows.Forms.Application]::Run($ctx)
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
