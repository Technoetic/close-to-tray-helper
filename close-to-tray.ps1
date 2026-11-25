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
      hook is unhooked and every hidden Aside window is restored to the taskbar.
      The helper never kills Aside; the only time it closes Aside's windows is
      the memory restart below.
    - Memory restart (default ON, toggleable in tray menu): some Aside builds
      (for example 1.0.1116.2) keep shared memory in the main process that is
      released only when Aside exits; it counts toward system commit but not
      toward any process's private bytes. Every 60 s the helper reads the
      largest shared commit of a browser process. When it reaches restartAtGB
      (default 4), or the uptime reaches restartAfterHours (default 0 = off),
      it restarts the browser only if the browser has exactly one window
      (hidden ones count) and that window is in the tray, no Aside CLI process
      has run for 15 minutes, nothing is full-screen, the browser has no active
      audio session, and there has been no keyboard or mouse input for
      restartIdleMinutes (default 10). A restart posts WM_CLOSE (never a forced
      kill), waits 60 s (60 s more for a slow exit, up to 30 min for a page
      prompt), starts the same executable with --restore-last-session, and puts
      the window back in the tray. It pauses 1 h after a restart and 6 h after
      a failure. The tray menu shows the measured memory and offers an
      immediate restart (-RestartBrowser does the same).
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
    [switch]$Restart,
    [switch]$RestartBrowser,
    [switch]$SelfTest,
    [switch]$PolicyTest,
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

function ConvertTo-PrefNumber($Value, [double]$Min, [double]$Max, [double]$Default, [bool]$AllowZero) {
    # A JSON number (or a numeric string) inside [Min, Max], or 0 when AllowZero; anything else gives Default.
    if ($null -eq $Value -or $Value -is [bool]) { return $Default }
    $n = 0.0
    if ($Value -is [string]) {
        if (-not [double]::TryParse($Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $Default }
    } elseif ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $n = [double]$Value
    } else {
        return $Default
    }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $Default }
    if ($AllowZero -and $n -eq 0) { return 0.0 }
    if ($n -lt $Min -or $n -gt $Max) { return $Default }
    return $n
}

function Read-TrayPrefs([string]$Path) {
    $prefs = [ordered]@{
        mode = 'DeleteTab'
        autoStartAside = $false
        closeToTray = $true
        autoRestart = $true
        restartAtGB = 4.0
        restartAfterHours = 0.0
        restartIdleMinutes = 10
    }
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            $obj = $raw | ConvertFrom-Json
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'mode') -and ($obj.mode -eq 'DeleteTab' -or $obj.mode -eq 'HideWindow')) {
                $prefs.mode = [string]$obj.mode
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'autoStartAside') -and $null -ne $obj.autoStartAside) {
                $prefs.autoStartAside = [bool]$obj.autoStartAside
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'closeToTray') -and $null -ne $obj.closeToTray) {
                $prefs.closeToTray = [bool]$obj.closeToTray
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'autoRestart') -and $obj.autoRestart -is [bool]) {
                $prefs.autoRestart = [bool]$obj.autoRestart
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'restartAtGB')) {
                $prefs.restartAtGB = ConvertTo-PrefNumber $obj.restartAtGB 0.5 1024 4.0 $true
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'restartAfterHours')) {
                $prefs.restartAfterHours = ConvertTo-PrefNumber $obj.restartAfterHours 1 720 0.0 $true
            }
            if ($obj -and ($obj.PSObject.Properties.Name -contains 'restartIdleMinutes')) {
                $prefs.restartIdleMinutes = [int](ConvertTo-PrefNumber $obj.restartIdleMinutes 1 1440 10 $false)
            }
        } catch {
            # Ignore malformed prefs and keep safe defaults.
        }
    }
    return $prefs
}

function Write-TrayPrefs([string]$Path, $Prefs) {
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $dir -Force)
    }
    $payload = ([ordered]@{
        mode = [string]$Prefs.mode
        autoStartAside = [bool]$Prefs.autoStartAside
        closeToTray = [bool]$Prefs.closeToTray
        autoRestart = [bool]$Prefs.autoRestart
        restartAtGB = [double]$Prefs.restartAtGB
        restartAfterHours = [double]$Prefs.restartAfterHours
        restartIdleMinutes = [int]$Prefs.restartIdleMinutes
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
        Toggle = 4,
        RestartBrowser = 5
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

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    // PROCESS_MEMORY_COUNTERS_EX2 (psapi.h). SharedCommitUsage is the commit of shared sections the process
    // references. Documented for Windows 10 and 11 22H2 with the September 2023 update and later. An older build
    // accepts this size but fills only the part it knows and writes that size back into cb (MemoryProbe checks).
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_MEMORY_COUNTERS_EX2
    {
        public uint cb;
        public uint PageFaultCount;
        public UIntPtr PeakWorkingSetSize;
        public UIntPtr WorkingSetSize;
        public UIntPtr QuotaPeakPagedPoolUsage;
        public UIntPtr QuotaPagedPoolUsage;
        public UIntPtr QuotaPeakNonPagedPoolUsage;
        public UIntPtr QuotaNonPagedPoolUsage;
        public UIntPtr PagefileUsage;
        public UIntPtr PeakPagefileUsage;
        public UIntPtr PrivateUsage;
        public UIntPtr PrivateWorkingSetSize;
        public ulong SharedCommitUsage;
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
        public static extern IntPtr GetForegroundWindow();

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

        public const uint WM_CLOSE = 0x0010;
        public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "K32GetProcessMemoryInfo")]
        public static extern bool GetProcessMemoryInfoEx2(IntPtr process, ref PROCESS_MEMORY_COUNTERS_EX2 counters, uint cb);

        public const uint SYNCHRONIZE = 0x00100000;
        public const uint WAIT_OBJECT_0 = 0;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

        [DllImport("shell32.dll")]
        public static extern int SHQueryUserNotificationState(out int pquns);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetProcessTimes(IntPtr hProcess, out long creation, out long exit, out long kernel, out long user);

        // Start time (UTC) of a process, read with PROCESS_QUERY_LIMITED_INFORMATION only; MinValue when unknown.
        public static DateTime ProcessStartUtc(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return DateTime.MinValue;
            try
            {
                long creation, exit, kernel, user;
                if (!GetProcessTimes(h, out creation, out exit, out kernel, out user)) return DateTime.MinValue;
                return DateTime.FromFileTimeUtc(creation);
            }
            catch
            {
                return DateTime.MinValue;
            }
            finally
            {
                CloseHandle(h);
            }
        }

        // Full image path of a process, read with PROCESS_QUERY_LIMITED_INFORMATION only (no memory access).
        public static string ImagePath(int pid)
        {
            IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                uint size = (uint)sb.Capacity;
                if (!QueryFullProcessImageName(h, 0, sb, ref size)) return null;
                return sb.ToString(0, (int)size);
            }
            catch
            {
                return null;
            }
            finally
            {
                CloseHandle(h);
            }
        }

        // True while a full-screen program or a presentation is running (QUNS_BUSY, QUNS_RUNNING_D3D_FULL_SCREEN,
        // QUNS_PRESENTATION_MODE, QUNS_APP).
        public static bool UserIsBusyFullScreen()
        {
            try
            {
                int state;
                if (SHQueryUserNotificationState(out state) != 0) return false;
                return state == 2 || state == 3 || state == 4 || state == 7;
            }
            catch
            {
                return false;
            }
        }

        // Seconds since the last keyboard or mouse input in this session; 0 when Windows cannot say.
        public static int IdleSeconds()
        {
            var info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref info)) return 0;
            uint idleMs = unchecked((uint)Environment.TickCount - info.dwTime);
            return (int)(idleMs / 1000);
        }

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

    public sealed class RestartInputs
    {
        public bool Enabled;
        public bool Manual;
        public bool BrowserRunning;
        public int WindowCount;
        public bool AnyWindowShown;
        public bool CanRelaunch;
        public bool Busy;
        public bool CliRunning;
        public int CliQuietSeconds = int.MaxValue;
        public int CliQuietRequiredSeconds;
        public bool FullScreenBusy;
        public bool MediaPlaying;
        public bool NoExitSameProcess;
        public double SharedGB = -1;
        public double ThresholdGB;
        public double UptimeHours = -1;
        public double AfterHours;
        public int IdleSeconds;
        public int IdleRequiredSeconds;
        public DateTime NowUtc;
        public DateTime BackoffUntilUtc = DateTime.MinValue;
    }

    // Decides whether the browser may be restarted now. Pure: no window, process or clock access.
    public static class RestartPolicy
    {
        public const string Restart = "restart";

        public static string Decide(RestartInputs i)
        {
            if (i == null) return "invalid";
            if (!i.BrowserRunning) return "not-running";
            if (i.WindowCount <= 0) return "no-windows";
            // Windows closed one at a time come back only as the last one, so several windows are never restarted.
            if (i.WindowCount > 1) return "multi-window";
            if (!i.CanRelaunch) return "no-relaunch-path";
            if (i.Busy) return "busy";
            if (i.CliRunning) return "cli-running";
            if (i.Manual) return Restart;
            if (!i.Enabled) return "off";
            if (i.NowUtc < i.BackoffUntilUtc) return "backoff";
            if (i.NoExitSameProcess) return "no-exit-earlier";
            bool byMemory = i.ThresholdGB > 0 && i.SharedGB >= i.ThresholdGB;
            bool byTime = i.AfterHours > 0 && i.UptimeHours >= i.AfterHours;
            if (!byMemory && !byTime)
            {
                if (i.ThresholdGB > 0 && i.SharedGB < 0 && i.AfterHours <= 0) return "unmeasurable";
                return "below-threshold";
            }
            if (i.CliQuietSeconds < i.CliQuietRequiredSeconds) return "cli-recent";
            if (i.AnyWindowShown) return "window-open";
            if (i.FullScreenBusy) return "full-screen";
            // Sound from the browser (music, a video, a call) means it is in use without keyboard or mouse input.
            if (i.MediaPlaying) return "media-playing";
            if (i.IdleSeconds < i.IdleRequiredSeconds) return "not-idle";
            return Restart;
        }

        // A balloon is worth showing when memory is twice the threshold (twice 4 GB when the memory trigger is off)
        // and no restart is starting. It also appears while automatic restart is turned off.
        public static bool ShouldWarn(RestartInputs i, string decision)
        {
            if (i == null || i.Manual) return false;
            // "audio-check" is a restart waiting only for the sound probe's answer (a fraction of a second).
            if (decision == Restart || decision == "audio-check" || decision == "not-running" || decision == "busy") return false;
            double basis = i.ThresholdGB > 0 ? i.ThresholdGB : 4.0;
            return i.SharedGB >= 2 * basis;
        }

        // Table of fixed cases for -PolicyTest and -SelfTest: "ok=<bool>;cases=<n>;failed=<names>".
        public static string RunTable()
        {
            var failed = new List<string>();
            int count = 0;
            DateTime now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
            Func<RestartInputs> baseCase = () =>
            {
                var b = new RestartInputs();
                b.Enabled = true;
                b.BrowserRunning = true;
                b.WindowCount = 1;
                b.CanRelaunch = true;
                b.SharedGB = 5;
                b.ThresholdGB = 4;
                b.UptimeHours = 10;
                b.AfterHours = 0;
                b.IdleSeconds = 900;
                b.IdleRequiredSeconds = 600;
                b.CliQuietSeconds = int.MaxValue;
                b.CliQuietRequiredSeconds = 900;
                b.NowUtc = now;
                return b;
            };
            Action<string, RestartInputs, string> check = (name, input, expected) =>
            {
                count++;
                string got = Decide(input);
                if (got != expected) failed.Add(name + ":" + got);
            };
            Action<string, RestartInputs, bool> warn = (name, input, expected) =>
            {
                count++;
                if (ShouldWarn(input, Decide(input)) != expected) failed.Add(name);
            };
            RestartInputs c;
            c = baseCase(); check("memory-idle-in-tray-restarts", c, Restart);
            c = baseCase(); c.SharedGB = 4; check("equal-threshold-restarts", c, Restart);
            c = baseCase(); c.SharedGB = 1; check("below-threshold", c, "below-threshold");
            c = baseCase(); c.IdleSeconds = 60; check("not-idle", c, "not-idle");
            c = baseCase(); c.IdleSeconds = 600; check("idle-boundary-restarts", c, Restart);
            c = baseCase(); c.CliRunning = true; check("cli-running", c, "cli-running");
            c = baseCase(); c.CliQuietSeconds = 60; check("cli-recent", c, "cli-recent");
            c = baseCase(); c.CliQuietSeconds = 900; check("cli-quiet-boundary-restarts", c, Restart);
            c = baseCase(); c.AnyWindowShown = true; check("window-open", c, "window-open");
            c = baseCase(); c.FullScreenBusy = true; check("full-screen", c, "full-screen");
            c = baseCase(); c.MediaPlaying = true; check("media-playing", c, "media-playing");
            c = baseCase(); c.WindowCount = 2; check("multi-window", c, "multi-window");
            c = baseCase(); c.Enabled = false; check("off", c, "off");
            c = baseCase(); c.BackoffUntilUtc = now.AddHours(1); check("backoff", c, "backoff");
            c = baseCase(); c.BackoffUntilUtc = now.AddHours(-1); check("backoff-over", c, Restart);
            c = baseCase(); c.NoExitSameProcess = true; check("no-exit-earlier", c, "no-exit-earlier");
            c = baseCase(); c.BrowserRunning = false; check("not-running", c, "not-running");
            c = baseCase(); c.WindowCount = 0; check("no-windows", c, "no-windows");
            c = baseCase(); c.CanRelaunch = false; check("no-relaunch-path", c, "no-relaunch-path");
            c = baseCase(); c.Busy = true; check("busy", c, "busy");
            c = baseCase(); c.Manual = true; c.Enabled = false; c.SharedGB = 0.1; c.IdleSeconds = 0; c.AnyWindowShown = true;
            c.CliQuietSeconds = 0; c.FullScreenBusy = true; c.BackoffUntilUtc = now.AddHours(1); c.NoExitSameProcess = true;
            c.MediaPlaying = true;
            check("manual-overrides-the-automatic-conditions", c, Restart);
            c = baseCase(); c.Manual = true; c.Busy = true; check("manual-waits-when-busy", c, "busy");
            c = baseCase(); c.Manual = true; c.CliRunning = true; check("manual-respects-a-running-cli", c, "cli-running");
            c = baseCase(); c.Manual = true; c.CanRelaunch = false; check("manual-needs-relaunch-path", c, "no-relaunch-path");
            c = baseCase(); c.Manual = true; c.WindowCount = 2; check("manual-needs-one-window", c, "multi-window");
            c = baseCase(); c.Manual = true; c.WindowCount = 0; check("manual-needs-a-window", c, "no-windows");
            c = baseCase(); c.SharedGB = -1; check("unmeasurable", c, "unmeasurable");
            c = baseCase(); c.SharedGB = -1; c.AfterHours = 24; c.UptimeHours = 30; check("uptime-restarts", c, Restart);
            c = baseCase(); c.SharedGB = -1; c.AfterHours = 24; c.UptimeHours = 5; check("uptime-below", c, "below-threshold");
            c = baseCase(); c.ThresholdGB = 0; c.SharedGB = 100; check("memory-trigger-off", c, "below-threshold");
            c = baseCase(); c.SharedGB = 9; c.IdleSeconds = 60; warn("warn-when-high-and-user-active", c, true);
            c = baseCase(); c.SharedGB = 9; warn("no-warn-when-restarting", c, false);
            c = baseCase(); c.SharedGB = 9; c.IdleSeconds = 60; c.Enabled = false; warn("warn-even-when-off", c, true);
            c = baseCase(); c.SharedGB = 7; c.IdleSeconds = 60; warn("no-warn-below-twice", c, false);
            c = baseCase(); c.SharedGB = 9; c.MediaPlaying = true; warn("warn-when-high-and-media-playing", c, true);
            c = baseCase(); c.SharedGB = 9; count++; if (ShouldWarn(c, "audio-check")) failed.Add("no-warn-while-checking-sound");
            c = baseCase(); c.ThresholdGB = 0; c.SharedGB = 9; warn("warn-with-memory-trigger-off", c, true);
            c = baseCase(); c.SharedGB = 9; c.Manual = true; c.CliRunning = true; warn("no-warn-for-manual", c, false);
            return string.Format("ok={0};cases={1};failed={2}", failed.Count == 0, count, string.Join(",", failed.ToArray()));
        }
    }

    // Whether a process has an audio session that is playing or recording now (Core Audio session API). An automatic
    // restart would cut off music, a video or a call that runs without keyboard or mouse input. Any failure reads as
    // "nothing playing", so a broken audio stack never blocks restarts for good.
    public static class AudioActivity
    {
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        private class MMDeviceEnumeratorComObject { }

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        }

        [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDeviceCollection
        {
            [PreserveSig] int GetCount(out int count);
            [PreserveSig] int Item(int index, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        }

        [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionManager2
        {
            [PreserveSig] int GetAudioSessionControl(IntPtr sessionGuid, int streamFlags, out IntPtr sessionControl);
            [PreserveSig] int GetSimpleAudioVolume(IntPtr sessionGuid, int streamFlags, out IntPtr audioVolume);
            [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
        }

        [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionEnumerator
        {
            [PreserveSig] int GetCount(out int count);
            [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
        }

        [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IAudioSessionControl2
        {
            [PreserveSig] int GetState(out int state);
            [PreserveSig] int GetDisplayName(out IntPtr name);
            [PreserveSig] int SetDisplayName(IntPtr name, IntPtr eventContext);
            [PreserveSig] int GetIconPath(out IntPtr path);
            [PreserveSig] int SetIconPath(IntPtr path, IntPtr eventContext);
            [PreserveSig] int GetGroupingParam(out Guid groupingId);
            [PreserveSig] int SetGroupingParam(IntPtr groupingId, IntPtr eventContext);
            [PreserveSig] int RegisterAudioSessionNotification(IntPtr client);
            [PreserveSig] int UnregisterAudioSessionNotification(IntPtr client);
            [PreserveSig] int GetSessionIdentifier(out IntPtr id);
            [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr id);
            [PreserveSig] int GetProcessId(out uint pid);
        }

        private const int EDataFlowAll = 2;            // render and capture endpoints
        private const int DeviceStateActive = 1;
        private const int ClsctxAll = 23;
        private const int AudioSessionStateActive = 1;

        // True when one of the given processes has an active audio session on any active endpoint.
        public static bool AnyActive(HashSet<int> pids)
        {
            string error;
            return Probe(pids, out error);
        }

        // Same, and says why the check could not run ("" when it ran).
        public static bool Probe(HashSet<int> pids, out string error)
        {
            error = "";
            if (pids == null || pids.Count == 0) return false;
            var held = new List<object>();
            try
            {
                var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                held.Add(enumerator);
                IMMDeviceCollection devices;
                if (enumerator.EnumAudioEndpoints(EDataFlowAll, DeviceStateActive, out devices) != 0 || devices == null) return false;
                held.Add(devices);
                int deviceCount;
                if (devices.GetCount(out deviceCount) != 0) return false;
                Guid managerId = typeof(IAudioSessionManager2).GUID;
                for (int d = 0; d < deviceCount; d++)
                {
                    IMMDevice device;
                    if (devices.Item(d, out device) != 0 || device == null) continue;
                    held.Add(device);
                    object managerObject;
                    if (device.Activate(ref managerId, ClsctxAll, IntPtr.Zero, out managerObject) != 0 || managerObject == null) continue;
                    held.Add(managerObject);
                    IAudioSessionEnumerator sessions;
                    if (((IAudioSessionManager2)managerObject).GetSessionEnumerator(out sessions) != 0 || sessions == null) continue;
                    held.Add(sessions);
                    int sessionCount;
                    if (sessions.GetCount(out sessionCount) != 0) continue;
                    for (int s = 0; s < sessionCount; s++)
                    {
                        IAudioSessionControl2 session;
                        if (sessions.GetSession(s, out session) != 0 || session == null) continue;
                        held.Add(session);
                        int state;
                        uint pid;
                        if (session.GetState(out state) != 0 || state != AudioSessionStateActive) continue;
                        if (session.GetProcessId(out pid) != 0) continue;
                        if (pids.Contains((int)pid)) return true;
                    }
                }
                return false;
            }
            catch (Exception ex)
            {
                error = ex.GetType().Name;
                return false;
            }
            finally
            {
                for (int n = held.Count - 1; n >= 0; n--)
                {
                    try { Marshal.ReleaseComObject(held[n]); } catch { }
                }
            }
        }
    }

    public static class MemoryProbe
    {
        // Largest shared commit, in bytes, over the given processes; -1 when none could be read.
        public static long MaxSharedCommit(IEnumerable<int> pids)
        {
            long best = -1;
            foreach (int pid in pids)
            {
                long v = SharedCommit(pid);
                if (v > best) best = v;
            }
            return best;
        }

        // Opens the process only with PROCESS_QUERY_LIMITED_INFORMATION (the right Task Manager uses).
        public static long SharedCommit(int pid)
        {
            IntPtr h = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (h == IntPtr.Zero) return -1;
            try
            {
                var c = new PROCESS_MEMORY_COUNTERS_EX2();
                uint size = (uint)Marshal.SizeOf(typeof(PROCESS_MEMORY_COUNTERS_EX2));
                c.cb = size;
                if (!NativeMethods.GetProcessMemoryInfoEx2(h, ref c, size)) return -1;
                // Without the EX2 structure the call still succeeds but writes a smaller cb back: no value then.
                if (c.cb < size) return -1;
                if (c.SharedCommitUsage > (ulong)long.MaxValue) return long.MaxValue;
                return (long)c.SharedCommitUsage;
            }
            catch
            {
                return -1;
            }
            finally
            {
                NativeMethods.CloseHandle(h);
            }
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

        private const string MENU_RESTART_NOW = "\ube0c\ub77c\uc6b0\uc800 \ub2e4\uc2dc \uc2dc\uc791 (\uba54\ubaa8\ub9ac \uc815\ub9ac)";
        private const string MENU_AUTO_RESTART = "\uba54\ubaa8\ub9ac\uac00 \ub9ce\uc73c\uba74 \uc790\ub9ac \ube44\uc6b4 \uc0ac\uc774 \uc790\ub3d9 \ub2e4\uc2dc \uc2dc\uc791";
        private const string MEM_INFO_PREFIX = "\ube0c\ub77c\uc6b0\uc800\uac00 \ubd99\uc7a1\uc740 \uba54\ubaa8\ub9ac: ";
        private const string MEM_INFO_UNKNOWN = "\ube0c\ub77c\uc6b0\uc800\uac00 \ubd99\uc7a1\uc740 \uba54\ubaa8\ub9ac: \uce21\uc815 \ubd88\uac00";
        private const string BALLOON_HIGH = "\ube0c\ub77c\uc6b0\uc800\uac00 \ubd99\uc7a1\uc740 \uba54\ubaa8\ub9ac\uac00 \ub9ce\uc2b5\ub2c8\ub2e4. \ud2b8\ub808\uc774 \uba54\ub274\uc5d0\uc11c \ub2e4\uc2dc \uc2dc\uc791\ud558\uba74 \ud480\ub9bd\ub2c8\ub2e4.";

        private const string BALLOON_PROMPT = "\ube0c\ub77c\uc6b0\uc800\uc758 \ud398\uc774\uc9c0\uac00 \ub2eb\uae30 \uc804\uc5d0 \ud655\uc778\uc744 \ubb3b\uace0 \uc788\uc2b5\ub2c8\ub2e4. 30\ubd84 \uc548\uc5d0 \ube0c\ub77c\uc6b0\uc800\uac00 \ub2eb\ud788\uba74(\ub098\uac00\uae30) \ub2e4\uc2dc \uc5fd\ub2c8\ub2e4. \ucde8\uc18c\ud558\uba74 \ube0c\ub77c\uc6b0\uc800\ub294 \uadf8\ub300\ub85c \ub450\uc9c0\ub9cc, \uadf8 30\ubd84 \ub3d9\uc548\uc740 \ube0c\ub77c\uc6b0\uc800\ub97c \ub2eb\uc73c\uba74 \ub2e4\uc2dc \uc5f4\ub9ac\uace0 \uba54\ub274\uc758 \ub2e4\uc2dc \uc2dc\uc791\uc740 \uc4f8 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.";
        private const string BALLOON_NO_EXIT = "\ube0c\ub77c\uc6b0\uc800\uac00 \ucc3d\uc744 \ub2eb\uc544\ub3c4 \ub05d\ub098\uc9c0 \uc54a\uc544 \uba54\ubaa8\ub9ac\ub97c \ud480\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4. \ube0c\ub77c\uc6b0\uc800\ub97c \uc9c1\uc811 \ub05d\ub0b4 \uc8fc\uc138\uc694.";
        private const string BALLOON_FAILED = "\ube0c\ub77c\uc6b0\uc800\ub97c \ub2e4\uc2dc \uc5f4\uc9c0 \ubabb\ud588\uc2b5\ub2c8\ub2e4. \ud2b8\ub808\uc774 \uba54\ub274\uc758 \ube0c\ub77c\uc6b0\uc800 \uc2dc\uc791\uc744 \ub20c\ub7ec \uc8fc\uc138\uc694.";
        private const string BALLOON_MULTI = "\ucc3d\uc774 \ub458 \uc774\uc0c1\uc774\uba74 \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc2b5\ub2c8\ub2e4(\ub9c8\uc9c0\ub9c9 \ucc3d\ub9cc \ub418\uc0b4\uc544\ub098\uae30 \ub54c\ubb38). \ucc3d\uc744 \ud558\ub098\ub9cc \ub0a8\uae30\uace0 \ub2e4\uc2dc \uc2dc\ub3c4\ud558\uc138\uc694.";
        private const string BALLOON_CLI = "Aside CLI\uac00 \uc791\uc5c5 \uc911\uc774\ub77c \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4.";
        private const string BALLOON_NO_PATH = "\ube0c\ub77c\uc6b0\uc800\ub97c \ub2e4\uc2dc \ub744\uc6b8 \uc2e4\ud589 \ud30c\uc77c\uc744 \ucc3e\uc9c0 \ubabb\ud574 \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4. \uc544\ubb34\uac83\ub3c4 \ub2eb\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4.";
        private const string BALLOON_NO_WINDOWS = "\uc5f4\ub9b0 \ube0c\ub77c\uc6b0\uc800 \ucc3d\uc774 \uc5c6\uc5b4 \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4.";
        private const string BALLOON_BUSY = "\ube0c\ub77c\uc6b0\uc800\ub97c \uc2dc\uc791\ud558\uac70\ub098 \ub2e4\uc2dc \uc2dc\uc791\ud558\ub294 \uc911\uc785\ub2c8\ub2e4(\ud398\uc774\uc9c0 \ud655\uc778 \ucc3d\uc758 \ub2f5\uc744 \uae30\ub2e4\ub9ac\ub294 \uc911\uc774\uba74 \ucd5c\ub300 30\ubd84). \ub05d\ub09c \ub4a4\uc5d0 \ub2e4\uc2dc \uc2dc\ub3c4\ud558\uc138\uc694.";
        private const string BALLOON_HIDDEN_WINDOW = "\ubcf4\uc774\uc9c0 \uc54a\ub294 \ube0c\ub77c\uc6b0\uc800 \ucc3d\uc774 \uc788\uc5b4 \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4. \uba54\ubaa8\ub9ac\ub97c \ud480\ub824\uba74 \ube0c\ub77c\uc6b0\uc800\ub97c \uc9c1\uc811 \ub05d\ub0b8 \ub4a4 \ub2e4\uc2dc \uc5ec\uc138\uc694.";
        private const string BALLOON_NOT_RUNNING = "\ube0c\ub77c\uc6b0\uc800\uac00 \uc2e4\ud589 \uc911\uc774 \uc544\ub2c8\uc5b4\uc11c \ub2e4\uc2dc \uc2dc\uc791\ud558\uc9c0 \uc54a\uc558\uc2b5\ub2c8\ub2e4.";

        private const int POLICY_INTERVAL_MS = 60000;
        private const int CLOSE_WAIT_MS = 60000;
        private const int REHIDE_GRACE_MS = 60000;
        private const int SLOW_EXIT_WAIT_MS = 60000;
        private const int PROMPT_WAIT_MS = 1800000;
        private const int CLI_QUIET_SECONDS = 900;
        private const int RELAUNCH_SETTLE_MS = 30000;
        private const int SESSION_END_CONFIRM_MS = 5000;
        private const int AUDIO_RESULT_FRESH_MS = 5000;
        private const int KIND_OTHER = 0;
        private const int KIND_BROWSER = 1;
        private const int KIND_CLI = 2;
        private const int KIND_UNKNOWN = -1;   // the process could not be read; not cached
        private const int SIGNAL_SHOW_FOR_PROMPT = 1;
        private const int SIGNAL_BALLOON_PROMPT = 2;
        private const int SIGNAL_BALLOON_NO_EXIT = 4;
        private const int SIGNAL_BALLOON_FAILED = 8;
        private const int SIGNAL_AUDIO_DONE = 16;
        private static readonly TimeSpan BACKOFF_FAILED = TimeSpan.FromHours(6);
        private static readonly TimeSpan COOLDOWN_AFTER_RESTART = TimeSpan.FromHours(1);

        private readonly string _asideExe;
        private readonly string _asideUpScript;
        private readonly string _prefsPath;
        private readonly string _startupDir;
        private readonly string _launcherVbs;

        private HideMode _mode;
        private bool _autoStartAside;
        private bool _closeToTray;
        private bool _autoRestart;
        private double _restartAtGB;
        private double _restartAfterHours;
        private int _restartIdleMinutes;

        private readonly Dictionary<int, int> _pidCache = new Dictionary<int, int>();
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
        private ToolStripMenuItem _miMemInfo;
        private ToolStripMenuItem _miRestartNow;
        private ToolStripMenuItem _miAutoRestart;
        private ToolStripMenuItem _miExit;
        private Font _showBoldFont;
        private System.Windows.Forms.Timer _timer;
        private BroadcastListenerWindow _listener;
        private CloseButtonInterceptor _closeInterceptor;

        private DateTime _suppressHideUntilUtc = DateTime.MinValue;
        private DateTime _lastLeftClickUtc = DateTime.MinValue;
        private bool _launchingAside = false;
        private bool _cleanedUp = false;

        private volatile bool _restarting = false;
        private DateTime _lastPolicyCheckUtc = DateTime.MinValue;
        private DateTime _lastBalloonUtc = DateTime.MinValue;
        private long _backoffUntilTicks = 0;
        private long _rehideUntilTicks = 0;
        private long _relaunchedTicks = 0;
        private double _lastSharedGB = -1;
        private string _lastDecision = "";
        private string _lastRestartResult = "";
        private readonly Dictionary<IntPtr, int> _rehideCounts = new Dictionary<IntPtr, int>();
        private bool _cliAlive = false;
        private DateTime _lastCliSeenUtc = DateTime.MinValue;
        private bool _exitPending = false;
        private volatile bool _restartCritical = false;
        private volatile bool _sessionEnded = false;   // WM_ENDSESSION: Windows is really signing out or shutting down
        private long _sessionEndingTicks = 0;          // WM_QUERYENDSESSION: asked, and may still be cancelled
        private volatile bool _showAfterRestart = false;
        private volatile int _noExitMainPid = 0;
        private long _noExitMainStartTicks = 0;
        private int _audioProbeRunning = 0;
        private long _audioResultTicks = 0;
        private volatile bool _audioResultPlaying = false;
        private int _uiSignals = 0;

        public AsideTrayContext(
            string asideExe,
            string asideUpScript,
            string prefsPath,
            string startupDir,
            string launcherVbs,
            HideMode initialMode,
            bool autoStartAside,
            bool closeToTray,
            bool autoRestart,
            double restartAtGB,
            double restartAfterHours,
            int restartIdleMinutes,
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
            _autoRestart = autoRestart;
            _restartAtGB = restartAtGB < 0 ? 0 : restartAtGB;
            _restartAfterHours = restartAfterHours < 0 ? 0 : restartAfterHours;
            _restartIdleMinutes = restartIdleMinutes < 1 ? 1 : restartIdleMinutes;
            // The helper cannot see CLI runs from before it started: its start counts as CLI activity, so the first
            // automatic restart needs 15 minutes of CLI quiet that this instance has watched.
            _lastCliSeenUtc = DateTime.UtcNow;

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
            SystemEvents.SessionEnded += OnSessionEnded;
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

            _miMemInfo = new ToolStripMenuItem(MEM_INFO_UNKNOWN);
            _miMemInfo.Enabled = false;

            _miRestartNow = new ToolStripMenuItem(MENU_RESTART_NOW);
            _miRestartNow.Click += (s, e) => RequestRestart(true);

            _miAutoRestart = new ToolStripMenuItem(MENU_AUTO_RESTART);
            _miAutoRestart.Click += (s, e) => ToggleAutoRestart();

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
            _menu.Items.Add(_miMemInfo);
            _menu.Items.Add(_miRestartNow);
            _menu.Items.Add(_miAutoRestart);
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
                case TrayIpcCommand.RestartBrowser:
                    RequestRestart(true);
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
            bool cli = false;
            foreach (var p in procs)
            {
                try
                {
                    int pid = p.Id;
                    seen.Add(pid);
                    int kind;
                    if (!_pidCache.TryGetValue(pid, out kind))
                    {
                        kind = ClassifyAsideProcess(pid);
                        if (kind != KIND_UNKNOWN) _pidCache[pid] = kind;
                    }
                    if (kind == KIND_BROWSER) live.Add(pid);
                    else if (kind == KIND_CLI) cli = true;
                }
                catch { }
                finally { p.Dispose(); }
            }
            // The Aside CLI drives the browser; remember when it was last seen (checked every tick, not only
            // at the once-a-minute restart check, so the gaps between CLI calls count as activity).
            _cliAlive = cli;
            if (cli) _lastCliSeenUtc = DateTime.UtcNow;

            // Forget processes that are gone on every pass, so a reused process id is classified again.
            if (_pidCache.Count > 0)
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
            return ClassifyAsideProcess(p.Id) == KIND_BROWSER;
        }

        // Classifies a process named Aside by its image path, read with PROCESS_QUERY_LIMITED_INFORMATION only:
        // the browser (Aside.exe under \Application\ or product name "Aside"), the Aside CLI, or something else.
        private static int ClassifyAsideProcess(int pid)
        {
            try
            {
                string path = NativeMethods.ImagePath(pid);
                if (string.IsNullOrEmpty(path)) return KIND_UNKNOWN;
                if (path.EndsWith(@"\Application\Aside.exe", StringComparison.OrdinalIgnoreCase)) return KIND_BROWSER;
                var info = FileVersionInfo.GetVersionInfo(path);
                if (string.Equals(info.ProductName, "Aside", StringComparison.OrdinalIgnoreCase)) return KIND_BROWSER;
                if (string.Equals(info.ProductName, "Aside CLI", StringComparison.OrdinalIgnoreCase)) return KIND_CLI;
                return KIND_OTHER;
            }
            catch
            {
                return KIND_UNKNOWN;
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
            Interlocked.Exchange(ref _rehideUntilTicks, 0);
            // During a restart a Show also means: leave the reopened window on screen.
            if (_restarting || RelaunchSettling()) _showAfterRestart = true;
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

            // Requests from the other threads first, so a prompt window is shown before a pending exit. Balloons are
            // dropped when the helper is about to exit: the icon goes with it, and they would promise a reopen that an
            // exiting helper cannot do.
            int signals = Interlocked.Exchange(ref _uiSignals, 0);
            if (signals != 0)
            {
                if (_exitPending && !_restartCritical) signals &= SIGNAL_SHOW_FOR_PROMPT;
                HandleRestartSignals(signals);
            }
            // An exit asked for while the browser was closed for a restart happens once it is open again.
            if (_exitPending && !_restartCritical)
            {
                _exitPending = false;
                RequestExit();
                return;
            }

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

            // After a memory restart of a browser that was in the tray, put its new windows back for a short
            // while: the browser restores them at normal size. Opening the browser from the tray (Show) ends this
            // early; input in other programs does not.
            bool rehiding = now.Ticks < Interlocked.Read(ref _rehideUntilTicks);

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
                    else if (rehiding && NativeMethods.IsWindowVisible(h) && !NativeMethods.IsIconic(h))
                    {
                        // Minimize the reopened window; the next tick hides it like any minimized window. At most
                        // twice per window, so a window the user brings back (taskbar pin, Alt+Tab) stays open. If
                        // the browser took the foreground as it opened, minimize it the way the close button does
                        // (SW_MINIMIZE gives the foreground to the window behind it); otherwise leave the foreground
                        // alone (SW_SHOWMINNOACTIVE).
                        int done;
                        _rehideCounts.TryGetValue(h, out done);
                        if (done < 2)
                        {
                            _rehideCounts[h] = done + 1;
                            uint winPid, fgPid;
                            NativeMethods.GetWindowThreadProcessId(h, out winPid);
                            NativeMethods.GetWindowThreadProcessId(NativeMethods.GetForegroundWindow(), out fgPid);
                            int cmd = fgPid != 0 && fgPid == winPid ? NativeMethods.SW_MINIMIZE : NativeMethods.SW_SHOWMINNOACTIVE;
                            NativeMethods.ShowWindowAsync(h, cmd);
                        }
                    }
                }
            }

            if ((now - _lastPolicyCheckUtc).TotalMilliseconds >= POLICY_INTERVAL_MS)
            {
                _lastPolicyCheckUtc = now;
                try { CheckRestartPolicy(pids, wins, false); } catch { }
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
            _miAutoRestart.Checked = _autoRestart;
            _miRestartNow.Enabled = running && !_restarting && !_launchingAside;
            // While the browser is closed for a restart the helper finishes that first, so exiting is not offered.
            _miExit.Enabled = !_restartCritical && !_exitPending;
            UpdateMemoryInfoItem(GetAsideBrowserPids());
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
                var inv = System.Globalization.CultureInfo.InvariantCulture;
                string json = string.Format(
                    inv,
                    "{{\"mode\":\"{0}\",\"autoStartAside\":{1},\"closeToTray\":{2},\"autoRestart\":{3},\"restartAtGB\":{4},\"restartAfterHours\":{5},\"restartIdleMinutes\":{6}}}",
                    _mode == HideMode.HideWindow ? "HideWindow" : "DeleteTab",
                    _autoStartAside ? "true" : "false",
                    _closeToTray ? "true" : "false",
                    _autoRestart ? "true" : "false",
                    _restartAtGB.ToString("0.###", inv),
                    _restartAfterHours.ToString("0.###", inv),
                    _restartIdleMinutes);
                File.WriteAllText(_prefsPath, json, new UTF8Encoding(false));
            }
            catch { }
        }

        private void ToggleAutoRestart()
        {
            _autoRestart = !_autoRestart;
            SavePrefs();
        }

        private void RequestRestart(bool manual)
        {
            if (_cleanedUp) return;
            var pids = GetAsideBrowserPids();
            var wins = EnumAsideMainWindows(pids);
            CheckRestartPolicy(pids, wins, manual);
        }

        // Measures the browser, asks RestartPolicy, then starts a restart or shows a balloon.
        private string CheckRestartPolicy(HashSet<int> pids, List<IntPtr> wins, bool manual)
        {
            var now = DateTime.UtcNow;
            long shared = pids.Count > 0 ? MemoryProbe.MaxSharedCommit(pids) : -1;
            _lastSharedGB = shared < 0 ? -1 : shared / 1073741824.0;

            bool anyShown = false;
            foreach (var h in wins)
            {
                if (NativeMethods.IsWindowVisible(h) && !NativeMethods.IsIconic(h)) { anyShown = true; break; }
            }
            int mainPid = MainPidOf(wins);
            double quiet = _lastCliSeenUtc == DateTime.MinValue ? double.MaxValue : (now - _lastCliSeenUtc).TotalSeconds;

            var inputs = new RestartInputs();
            inputs.Enabled = _autoRestart;
            inputs.Manual = manual;
            inputs.BrowserRunning = pids.Count > 0;
            // Every browser window counts, also one hidden by something other than this helper: it would keep the
            // browser running after the visible one closes. No visible or tracked window means none.
            inputs.WindowCount = wins.Count == 0 ? 0 : Math.Max(wins.Count, CountBrowserWindows(pids));
            inputs.AnyWindowShown = anyShown;
            inputs.CanRelaunch = !string.IsNullOrEmpty(RelaunchExe(mainPid));
            inputs.Busy = _launchingAside || _restarting;
            inputs.CliRunning = _cliAlive;
            inputs.CliQuietSeconds = quiet >= int.MaxValue ? int.MaxValue : (int)Math.Max(0, quiet);
            inputs.CliQuietRequiredSeconds = CLI_QUIET_SECONDS;
            inputs.FullScreenBusy = NativeMethods.UserIsBusyFullScreen();
            inputs.NoExitSameProcess = mainPid != 0 && mainPid == _noExitMainPid
                && NativeMethods.ProcessStartUtc(mainPid).Ticks == Interlocked.Read(ref _noExitMainStartTicks);
            inputs.SharedGB = _lastSharedGB;
            inputs.ThresholdGB = _restartAtGB;
            inputs.AfterHours = _restartAfterHours;
            inputs.UptimeHours = _restartAfterHours > 0 ? GetBrowserUptimeHours(pids) : -1;
            inputs.IdleSeconds = NativeMethods.IdleSeconds();
            inputs.IdleRequiredSeconds = Math.Max(60, _restartIdleMinutes * 60);
            inputs.NowUtc = now;
            inputs.BackoffUntilUtc = new DateTime(Interlocked.Read(ref _backoffUntilTicks), DateTimeKind.Utc);

            string decision = RestartPolicy.Decide(inputs);
            if (decision == RestartPolicy.Restart && !manual)
            {
                // Sound from the browser is asked for only now, when it can change the decision, and on another
                // thread (this one also serves the mouse hook). A fresh answer decides; otherwise the probe starts
                // and its answer runs this check again.
                long age = now.Ticks - Interlocked.Read(ref _audioResultTicks);
                if (age >= 0 && age < TimeSpan.FromMilliseconds(AUDIO_RESULT_FRESH_MS).Ticks)
                {
                    inputs.MediaPlaying = _audioResultPlaying;
                    decision = RestartPolicy.Decide(inputs);
                }
                else
                {
                    StartAudioProbe(pids);
                    decision = "audio-check";
                }
            }
            _lastDecision = decision;
            if (decision == RestartPolicy.Restart)
            {
                StartRestart(wins, mainPid, !anyShown);
            }
            else if (manual)
            {
                // A hidden extra window cannot be closed from the desktop: say so instead of "keep one window".
                if (decision == "multi-window") ShowBalloon(CountBrowserWindows(pids) > wins.Count ? BALLOON_HIDDEN_WINDOW : BALLOON_MULTI);
                else if (decision == "not-running") ShowBalloon(BALLOON_NOT_RUNNING);
                else if (decision == "cli-running") ShowBalloon(BALLOON_CLI);
                else if (decision == "no-relaunch-path") ShowBalloon(BALLOON_NO_PATH);
                else if (decision == "no-windows") ShowBalloon(BALLOON_NO_WINDOWS);
                else if (decision == "busy") ShowBalloon(BALLOON_BUSY);
            }
            else if (RestartPolicy.ShouldWarn(inputs, decision) && (now - _lastBalloonUtc).TotalHours >= 1)
            {
                _lastBalloonUtc = now;
                ShowBalloon(BALLOON_HIGH);
            }
            return decision;
        }

        // Asks Core Audio on a background thread whether the browser plays or records sound, one probe at a time.
        // The answer is kept with its time and announced to the UI thread, which then runs the policy check again.
        private void StartAudioProbe(HashSet<int> pids)
        {
            var copy = new HashSet<int>(pids);   // before the flag: a failure here must not leave it set
            if (Interlocked.CompareExchange(ref _audioProbeRunning, 1, 0) != 0) return;
            try
            {
                var probe = new Thread(() =>
                {
                    bool playing = false;
                    try { playing = AudioActivity.AnyActive(copy); }
                    catch { playing = false; }
                    finally
                    {
                        _audioResultPlaying = playing;
                        Interlocked.Exchange(ref _audioResultTicks, DateTime.UtcNow.Ticks);
                        Interlocked.Exchange(ref _audioProbeRunning, 0);
                        AddSignal(SIGNAL_AUDIO_DONE);
                    }
                });
                probe.IsBackground = true;
                probe.Name = "AudioProbe";
                probe.SetApartmentState(ApartmentState.MTA);
                probe.Start();
            }
            catch
            {
                Interlocked.Exchange(ref _audioProbeRunning, 0);
            }
        }

        private void ShowBalloon(string message)
        {
            try { if (_tray != null) _tray.ShowBalloonTip(10000, APP_TITLE, message, ToolTipIcon.Warning); } catch { }
        }

        private void AddSignal(int bits)
        {
            int seen, next;
            do
            {
                seen = _uiSignals;
                next = seen | bits;
            } while (Interlocked.CompareExchange(ref _uiSignals, next, seen) != seen);
        }

        // Runs on the UI thread (Reconcile) for requests the restart thread cannot carry out itself.
        private void HandleRestartSignals(int signals)
        {
            // The sound probe answered: check the policy again in this pass.
            if ((signals & SIGNAL_AUDIO_DONE) != 0) _lastPolicyCheckUtc = DateTime.MinValue;
            if ((signals & SIGNAL_SHOW_FOR_PROMPT) != 0) ShowAllAsideWindows();
            if ((signals & SIGNAL_BALLOON_PROMPT) != 0) ShowBalloon(BALLOON_PROMPT);
            else if ((signals & SIGNAL_BALLOON_NO_EXIT) != 0) ShowBalloon(BALLOON_NO_EXIT);
            else if ((signals & SIGNAL_BALLOON_FAILED) != 0) ShowBalloon(BALLOON_FAILED);
        }

        // The browser process that owns the given window(s); 0 when unknown.
        private static int MainPidOf(List<IntPtr> wins)
        {
            foreach (var h in wins)
            {
                uint pid;
                NativeMethods.GetWindowThreadProcessId(h, out pid);
                if (pid != 0) return (int)pid;
            }
            return 0;
        }

        // The executable that starts the browser again: the running browser's own image, so the same install comes
        // back; when that cannot be read, the configured or detected Aside.exe.
        private string RelaunchExe(int mainPid)
        {
            if (mainPid != 0)
            {
                string path = NativeMethods.ImagePath(mainPid);
                if (!string.IsNullOrEmpty(path) && File.Exists(path)) return path;
            }
            if (!string.IsNullOrEmpty(_asideExe) && File.Exists(_asideExe)) return _asideExe;
            return null;
        }

        private void UpdateMemoryInfoItem(HashSet<int> pids)
        {
            if (_miMemInfo == null) return;
            long shared = pids.Count > 0 ? MemoryProbe.MaxSharedCommit(pids) : -1;
            _lastSharedGB = shared < 0 ? -1 : shared / 1073741824.0;
            _miMemInfo.Text = _lastSharedGB < 0
                ? MEM_INFO_UNKNOWN
                : MEM_INFO_PREFIX + _lastSharedGB.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " GB";
        }

        private static double GetBrowserUptimeHours(HashSet<int> pids)
        {
            DateTime earliest = DateTime.MaxValue;
            foreach (int pid in pids)
            {
                DateTime started = NativeMethods.ProcessStartUtc(pid);
                if (started != DateTime.MinValue && started < earliest) earliest = started;
            }
            if (earliest == DateTime.MaxValue) return -1;
            return (DateTime.UtcNow - earliest).TotalHours;
        }

        private void StartRestart(List<IntPtr> wins, int mainPid, bool rehideAfter)
        {
            if (_restarting || _launchingAside || _cleanedUp || mainPid == 0) return;
            string exe = RelaunchExe(mainPid);
            if (string.IsNullOrEmpty(exe)) return;
            // Keep the main process open (SYNCHRONIZE) so the wait is about this process even if its id is reused.
            IntPtr mainHandle = NativeMethods.OpenProcess(NativeMethods.SYNCHRONIZE | NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, mainPid);
            if (mainHandle == IntPtr.Zero) return;
            long mainStartTicks = NativeMethods.ProcessStartUtc(mainPid).Ticks;
            var targets = new List<IntPtr>(wins);
            foreach (var h in _hidden.Keys)
            {
                if (!targets.Contains(h)) targets.Add(h);
            }
            // The restart thread counts the main process's windows, visible or hidden: a window this helper hides
            // during the wait, or one the user opens, still counts as open.
            var mainOnly = new HashSet<int>();
            mainOnly.Add(mainPid);
            _restarting = true;
            _restartCritical = true;
            _showAfterRestart = false;
            _rehideCounts.Clear();
            // Start the waiting thread first: if that fails, nothing has been closed yet.
            try
            {
                var worker = new Thread(() => RunRestart(exe, mainPid, mainStartTicks, mainHandle, mainOnly, rehideAfter));
                worker.IsBackground = true;
                worker.Name = "BrowserRestart";
                worker.Start();
            }
            catch
            {
                NativeMethods.CloseHandle(mainHandle);
                _restartCritical = false;
                _restarting = false;
                return;
            }
            // Ask the window to close the normal way (a posted WM_CLOSE does not pass through the close-button mouse
            // hook), so the browser saves its session and exits on its own.
            foreach (var h in targets)
            {
                if (NativeMethods.IsWindow(h)) NativeMethods.PostMessage(h, NativeMethods.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            }
        }

        // Runs on its own background thread: waits for the browser to exit, then starts it again. Never kills a
        // process. While _restartCritical is set the browser may be closed and not open again yet, so RequestExit
        // waits for it to clear.
        private void RunRestart(string exe, int mainPid, long mainStartTicks, IntPtr mainHandle, HashSet<int> mainOnly,
            bool rehideAfter)
        {
            string result = "unknown";
            try
            {
                bool exited = WaitExit(mainHandle, CLOSE_WAIT_MS);
                if (!exited && CountBrowserWindows(mainOnly) > 0)
                {
                    // A window is still open, so a page asks something (for example "Leave site?"). The browser is
                    // open, so this part is not critical: show the window, tell the user, and wait for the answer.
                    AddSignal(SIGNAL_SHOW_FOR_PROMPT | SIGNAL_BALLOON_PROMPT);
                    _restartCritical = false;
                    int answer = WaitForPromptAnswer(mainHandle, mainOnly);
                    if (answer == PROMPT_EXITED)
                    {
                        if (SessionIsEnding()) { result = "session-ending"; return; }
                        result = Relaunch(exe, false) ? "restarted-after-prompt" : "relaunch-failed";
                        SetBackoff(result == "restarted-after-prompt" ? COOLDOWN_AFTER_RESTART : BACKOFF_FAILED);
                        return;
                    }
                    if (answer == PROMPT_STILL_OPEN)
                    {
                        // No answer in time, or the user chose to stay: leave the browser as it is.
                        result = "blocked";
                        SetBackoff(BACKOFF_FAILED);
                        return;
                    }
                    // PROMPT_WINDOWS_GONE: the windows closed but the process stays; handled below like any other.
                }
                else if (!exited)
                {
                    // No window is left but the process lives on: give a slow shutdown a little more time.
                    exited = WaitExit(mainHandle, SLOW_EXIT_WAIT_MS);
                }
                if (SessionIsEnding())
                {
                    result = "session-ending";
                    return;
                }
                if (exited)
                {
                    result = Relaunch(exe, rehideAfter && !_showAfterRestart) ? "restarted" : "relaunch-failed";
                    SetBackoff(result == "restarted" ? COOLDOWN_AFTER_RESTART : BACKOFF_FAILED);
                }
                else
                {
                    // The browser keeps running without windows (for example a "keep running in the background"
                    // setting): bring its window back. Its memory is not released, so this process (same id and start
                    // time) is not restarted automatically again while it lives.
                    Interlocked.Exchange(ref _noExitMainStartTicks, mainStartTicks);
                    _noExitMainPid = mainPid;
                    result = Relaunch(exe, false) ? "no-exit" : "relaunch-failed";
                    AddSignal(SIGNAL_BALLOON_NO_EXIT);
                    SetBackoff(BACKOFF_FAILED);
                }
            }
            catch (Exception ex)
            {
                result = "error:" + ex.GetType().Name;
                SetBackoff(BACKOFF_FAILED);
                AddSignal(SIGNAL_BALLOON_FAILED);
            }
            finally
            {
                NativeMethods.CloseHandle(mainHandle);
                _lastRestartResult = result;
                _restartCritical = false;
                _restarting = false;
            }
        }

        private const int PROMPT_EXITED = 0;
        private const int PROMPT_WINDOWS_GONE = 1;
        private const int PROMPT_STILL_OPEN = 2;

        // Waits up to PROMPT_WAIT_MS for the user's answer. When the windows go away (the user chose to leave, or
        // closed the browser), the browser is closing: from then on an exit request waits for the relaunch again,
        // and the browser gets SLOW_EXIT_WAIT_MS more to finish.
        private int WaitForPromptAnswer(IntPtr mainHandle, HashSet<int> mainOnly)
        {
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < PROMPT_WAIT_MS)
            {
                if (WaitExit(mainHandle, 1000)) return PROMPT_EXITED;
                if (CountBrowserWindows(mainOnly) == 0)
                {
                    _restartCritical = true;
                    return WaitExit(mainHandle, SLOW_EXIT_WAIT_MS) ? PROMPT_EXITED : PROMPT_WINDOWS_GONE;
                }
            }
            return WaitExit(mainHandle, 0) ? PROMPT_EXITED : PROMPT_STILL_OPEN;
        }

        // True when Windows is signing out or shutting down. A query to end the session can still be cancelled, so
        // after a query in the last minute this waits up to SESSION_END_CONFIRM_MS (timed on this thread) for
        // Windows to confirm with SessionEnded; without that confirmation the session goes on.
        private bool SessionIsEnding()
        {
            if (_sessionEnded) return true;
            long asked = Interlocked.Read(ref _sessionEndingTicks);
            if (asked == 0) return false;
            long since = DateTime.UtcNow.Ticks - asked;
            if (since < 0 || since > TimeSpan.FromMinutes(1).Ticks) return false;
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < SESSION_END_CONFIRM_MS)
            {
                if (_sessionEnded) return true;
                Thread.Sleep(250);
            }
            return _sessionEnded;
        }

        private static bool WaitExit(IntPtr process, int ms)
        {
            return NativeMethods.WaitForSingleObject(process, (uint)ms) == NativeMethods.WAIT_OBJECT_0;
        }

        private void SetBackoff(TimeSpan span)
        {
            Interlocked.Exchange(ref _backoffUntilTicks, DateTime.UtcNow.Add(span).Ticks);
        }

        // Starts the browser again with its last session. Returns false, and asks for a balloon, when it cannot.
        private bool Relaunch(string exe, bool rehideAfter)
        {
            if (string.IsNullOrEmpty(exe) || !File.Exists(exe))
            {
                AddSignal(SIGNAL_BALLOON_FAILED);
                return false;
            }
            for (int attempt = 0; attempt < 2; attempt++)
            {
                try
                {
                    var psi = new ProcessStartInfo();
                    psi.FileName = exe;
                    psi.Arguments = "--restore-last-session";
                    psi.UseShellExecute = true;
                    psi.WindowStyle = rehideAfter ? ProcessWindowStyle.Minimized : ProcessWindowStyle.Normal;
                    // Mark the relaunch before starting (settle time, rehide grace), so even a fast window is caught,
                    // and undo the mark when starting fails, so the Start item works again at once.
                    long startTicks = DateTime.UtcNow.Ticks;
                    Interlocked.Exchange(ref _relaunchedTicks, startTicks);
                    Interlocked.Exchange(ref _rehideUntilTicks, rehideAfter ? startTicks + TimeSpan.FromMilliseconds(REHIDE_GRACE_MS).Ticks : 0);
                    using (Process.Start(psi)) { }
                    return true;
                }
                catch
                {
                    Interlocked.Exchange(ref _relaunchedTicks, 0);
                    Interlocked.Exchange(ref _rehideUntilTicks, 0);
                    Thread.Sleep(2000);
                }
            }
            AddSignal(SIGNAL_BALLOON_FAILED);
            return false;
        }

        private static int CountBrowserWindows(HashSet<int> pids)
        {
            int n = 0;
            NativeMethods.EnumWindows((h, l) =>
            {
                if (IsCandidateAsideWindow(h, pids)) n++;
                return true;
            }, IntPtr.Zero);
            return n;
        }

        // For RELAUNCH_SETTLE_MS after a restart started the browser again, the new process may have no window yet: a
        // request to show or start the browser then waits for that window instead of starting a second browser.
        private bool RelaunchSettling()
        {
            long t = Interlocked.Read(ref _relaunchedTicks);
            return t != 0 && DateTime.UtcNow.Ticks - t < TimeSpan.FromMilliseconds(RELAUNCH_SETTLE_MS).Ticks;
        }

        private void LaunchAsideAsync()
        {
            if (_restarting || RelaunchSettling())
            {
                // A restart is opening the browser again: show it when it comes back instead of starting another one.
                _showAfterRestart = true;
                Interlocked.Exchange(ref _rehideUntilTicks, 0);
                return;
            }
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

        // Windows asks whether the session may end; another program can still cancel that. Restoring windows and
        // stopping happen in OnSessionEnded, once Windows confirms, so a cancelled sign-out leaves a working helper.
        private void OnSessionEnding(object sender, SessionEndingEventArgs e)
        {
            Interlocked.Exchange(ref _sessionEndingTicks, DateTime.UtcNow.Ticks);
        }

        private void OnSessionEnded(object sender, SessionEndedEventArgs e)
        {
            _sessionEnded = true;
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
            if (_restartCritical)
            {
                // The browser is closed and not open again yet: finish that first; Reconcile exits afterwards.
                _exitPending = true;
                if (_miExit != null) _miExit.Enabled = false;
                return;
            }
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

# -Restart is not an option of this script. Declaring it keeps PowerShell from reading it as a prefix of
# -RestartBrowser, which would close and reopen the browser.
if ($Restart) {
    Out-Result ([ordered]@{ action = 'none'; error = 'unknown option -Restart'; browser = '-RestartBrowser'; helper = '-Stop, wait until the helper has exited (up to about 2 minutes while it finishes a browser restart), then start it again' }) '[close-to-tray] -Restart is not an option. To restart the browser use -RestartBrowser; to restart this helper use -Stop, wait until it has exited, then start it again.'
    exit 2
}

# Handle one-shot IPC control flags (-Stop, -Show, -Hide, -Toggle).
if ($Stop -or $Show -or $Hide -or $Toggle -or $RestartBrowser) {
    $cmd = [CloseToTrayHelper.TrayIpcCommand]::None
    $name = 'none'
    if ($Stop) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Stop; $name = 'stop' }
    elseif ($Show) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Show; $name = 'show' }
    elseif ($Hide) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Hide; $name = 'hide' }
    elseif ($Toggle) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::Toggle; $name = 'toggle' }
    elseif ($RestartBrowser) { $cmd = [CloseToTrayHelper.TrayIpcCommand]::RestartBrowser; $name = 'restart-browser' }
    $running = [CloseToTrayHelper.AsideIpc]::IsHelperRunning()
    $sent = [CloseToTrayHelper.AsideIpc]::SendCommand($cmd)
    $res = [ordered]@{ action = $name; running = $running; sent = $sent }
    Out-Result $res ("[close-to-tray] command=$name running=$running sent=$sent")
    exit 0
}

# Handle offline -PolicyTest: checks the restart decision table and how the saved preferences
# are read. Opens no window and touches no other process.
if ($PolicyTest) {
    $diag = [CloseToTrayHelper.RestartPolicy]::RunTable()
    $kv = @{}
    foreach ($pair in ($diag -split ';')) {
        $parts = $pair -split '=', 2
        if ($parts.Count -eq 2) { $kv[$parts[0]] = $parts[1] }
    }
    $prefs = Read-TrayPrefs $PrefsPath
    $ok = ($kv['ok'] -eq 'True')
    $res = [ordered]@{
        action = 'policy-test'
        ok = $ok
        cases = [int]$kv['cases']
        failed = [string]$kv['failed']
        prefs = [ordered]@{
            auto_restart = [bool]$prefs.autoRestart
            restart_at_gb = [double]$prefs.restartAtGB
            restart_after_hours = [double]$prefs.restartAfterHours
            restart_idle_minutes = [int]$prefs.restartIdleMinutes
        }
    }
    Out-Result $res ("[close-to-tray] policy-test ok=$ok cases=$($kv['cases']) failed=$($kv['failed'])")
    if ($ok) { exit 0 } else { exit 1 }
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
        Write-TrayPrefs -Path $PrefsPath -Prefs $prefs
        $prefs = Read-TrayPrefs $PrefsPath
    }
    $csDiag = [CloseToTrayHelper.AsideTrayContext]::RunSelfTest($ResolvedAsideExe)
    $policyOk = ([CloseToTrayHelper.RestartPolicy]::RunTable()).StartsWith('ok=True;')
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
    $ok = ([bool]($kv['ipc_msg'] -eq 'True') -and [int]$kv['tip_len'] -le 63 -and (Test-Path -LiteralPath $LauncherVbs -PathType Leaf) -and $closeOk -and $policyOk)
    $res = [ordered]@{
        self_test_ok = $ok
        mode = $prefs.mode
        auto_start_aside = [bool]$prefs.autoStartAside
        close_to_tray = [bool]$prefs.closeToTray
        auto_restart = [bool]$prefs.autoRestart
        restart_at_gb = [double]$prefs.restartAtGB
        restart_after_hours = [double]$prefs.restartAfterHours
        restart_idle_minutes = [int]$prefs.restartIdleMinutes
        restart_policy_ok = $policyOk
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
        Write-TrayPrefs -Path $PrefsPath -Prefs $prefs
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
        [bool]$prefs.autoRestart,
        [double]$prefs.restartAtGB,
        [double]$prefs.restartAfterHours,
        [int]$prefs.restartIdleMinutes,
        [bool]$StartAside
    )
    [System.Windows.Forms.Application]::Run($ctx)
} finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
