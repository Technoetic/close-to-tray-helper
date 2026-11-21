# close-to-tray-helper

A small Windows helper that keeps a browser running in the system tray. Minimized browser windows leave the taskbar and sit behind a tray icon, and clicking × on the last browser window hides it instead of quitting.

It currently supports the Aside AI browser. This is an unofficial project: it is not affiliated with, endorsed by or supported by the makers of that browser, and it contains none of their logos or other branding.

Status: v0.1.0, first public release (2026-11-21). The known issues below are planned for later versions.

## Why

- We found no "minimize to tray" or "close to tray" option in the browser's official documentation or changelog (checked 2026-11-21), and on our test PC (browser version 1.0.1116.2) the browser never showed a tray icon of its own.
- On that PC, closing the browser's last window also ended its background daemon, which stopped its command-line automation until the browser was started again.
- This helper keeps the browser alive but out of the way.

## Features

- **Two hide modes**, switchable from the tray menu:
  - `DeleteTab` (default, recommended): the browser stays in its normal minimized state and only its taskbar button is removed (`ITaskbarList::DeleteTab`).
  - `HideWindow` (experimental): minimized browser windows are hidden with `SW_HIDE`, so they also disappear from Alt+Tab. See the known issues before you use it.
- **Close to tray** (on by default): a left click on the × of the *last* browser window hides it to the tray. Extra windows close normally, and Alt+F4 still quits the browser. It uses a low-level mouse hook (`WH_MOUSE_LL`) with `WM_NCHITTEST` (`HTCLOSE`) and a small UI Automation cache of the close button.
- **Tray icon**: a left click opens or hides the browser. The right-click menu is listed below.
- **Clean exit**: on exit, `-Stop` or Windows sign-out, the mouse hook is removed and every hidden browser window is put back on the taskbar. The helper never closes or kills the browser.
- **Single instance** through the named mutex `Local\Close-To-Tray-Helper`.
- **Settings** are saved in `%LOCALAPPDATA%\CloseToTrayHelper\prefs.json`: the hide mode, close to tray, and whether to start the browser when the helper starts. Start-up at Windows sign-in is not stored there; it is the Startup shortcut itself.

## What it does and does not do

- It watches left mouse clicks system-wide only to tell whether the click hit the close button of the last browser window. It does not record or send input. The one click that hits that close button (and its button-up) is swallowed, so the window is hidden instead of closed.
- It has no keyboard hook and makes no network connections.
- It does not inject code into the browser or change the browser's files. It only minimizes, hides and restores the browser's own top-level windows and removes or restores their taskbar buttons.
- Windows sign-in start-up is opt-in (`-InstallStartup`).

## Requirements

- Windows 10 or 11 with the built-in **64-bit** Windows PowerShell 5.1, .NET Framework 4.x and Windows Script Host. A 32-bit PowerShell cannot inspect the 64-bit browser process.
- The supported browser installed. If `-AsideExe` or the `ASIDE_EXE` environment variable is given, that path is used as is, with no fallback. Otherwise the helper looks in the default install folders under `%ProgramFiles%`, `%ProgramFiles(x86)%` and `%LOCALAPPDATA%`.
- Tested with browser version 1.0.1116.2 on Windows 11.

## Run

```powershell
git clone https://github.com/Technoetic/close-to-tray-helper
cd close-to-tray-helper

# start the helper without a console window
wscript .\close-to-tray-launch.vbs

# or run it directly (it needs an STA thread)
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\close-to-tray.ps1
```

Start it at Windows sign-in (this creates `Close To Tray Helper.lnk` in your Startup folder):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\close-to-tray.ps1 -InstallStartup
```

The shortcut stores the folder's full path, so run `-InstallStartup` again if you move the folder.

## Tray menu

The menu labels are in Korean.

| Label | Meaning |
|---|---|
| 브라우저 창 열기 | Open the browser window |
| 트레이로 즉시 숨기기 | Hide to the tray now |
| 브라우저 시작 (트레이로) | Start the browser (into the tray) |
| 숨김 방식: 작업 표시줄만 숨기기 (권장) | Hide mode: taskbar button only (recommended) |
| 숨김 방식: 완전 숨기기 (Alt+Tab 포함) | Hide mode: hide completely, also from Alt+Tab (experimental) |
| 닫기(×) 클릭 시 트레이로 숨기기 | Hide to the tray when × is clicked |
| Windows 로그인 시 자동 실행 | Run at Windows sign-in |
| 도우미 시작 시 브라우저도 자동 시작 | Also start the browser when the helper starts |
| 트레이 도우미 종료 (브라우저 창 복원) | Exit the helper (restores browser windows) |

## Command-line switches

| Switch | Effect |
|---|---|
| `-Mode DeleteTab` or `-Mode HideWindow` | Set the hide mode (saved) |
| `-CloseToTray` or `-NoCloseToTray` | Turn close to tray on or off (saved) |
| `-StartAside` | Start the browser when the helper starts |
| `-Show`, `-Hide`, `-Toggle` | Send a command to the running helper |
| `-Stop` | Stop the running helper and restore the browser windows |
| `-InstallStartup`, `-UninstallStartup` | Add or remove the sign-in shortcut |
| `-AsideExe <path>` | Path to the browser executable |
| `-AsideUpScript <path>` | Optional launcher script for "start the browser", for example one that starts it minimized and gives focus back. The default is `aside-up.ps1` next to this script. If that file does not exist, the browser executable is started directly. |
| `-PrefsPath <file>`, `-StartupDir <dir>` | Use another settings file or Startup folder |
| `-SelfTest` | Run the offline self-test |
| `-Json` | Print results as JSON |

Switches that change settings (`-Mode`, `-CloseToTray`, `-NoCloseToTray`) apply when the helper starts. If a helper is already running, a second start exits without changing anything, so use the tray menu or run `-Stop` first. If neither a launcher script nor the browser executable can be found, "start the browser" does nothing.

## Uninstall

1. `powershell -NoProfile -ExecutionPolicy Bypass -File .\close-to-tray.ps1 -Stop` (restores the browser windows).
2. `powershell -NoProfile -ExecutionPolicy Bypass -File .\close-to-tray.ps1 -UninstallStartup`.
3. Delete `%LOCALAPPDATA%\CloseToTrayHelper` and this folder.

## Known issues

- **HideWindow and a forced kill.** If the helper is killed (Task Manager, a crash, power loss) while windows are hidden in `HideWindow` mode, those windows stay hidden, and a restarted helper cannot find them. Recover by ending the browser in Task Manager and starting it again. `DeleteTab`, the default, does not have this problem: its windows stay minimized, and a restarted helper finds them again.
- **Mouse hook on the UI thread.** The hook callback runs on the helper's UI thread, which also talks to the browser windows. If the browser stops responding, mouse input can lag until Windows times the hook out. Turn off "hide to the tray when × is clicked" in the menu to remove the hook.
- **Security software.** A hidden PowerShell process with a global mouse hook and a Startup shortcut can be flagged by antivirus or EDR heuristics. Read the script before you run it.
- **Browser updates.** An update that changes the browser's window structure can break close-button detection. If × stops behaving as expected, turn the close-to-tray option off.
- **Animations pause while hidden.** A minimized Chromium window draws very few frames. Pages keep working for automation, but animations cannot be watched while the browser is hidden.
- **Pinned taskbar icon.** If the browser is pinned to the taskbar, the pinned icon stays visible.
- **Windows 11 tray overflow.** New tray icons start in the overflow area (the ^ arrow). Pin the icon there if you want it always visible.

## Tests

```powershell
python -m unittest discover -s tests -v
```

Windows only. The default run checks the files, the PowerShell syntax and the Startup shortcut in a temporary folder. The desktop self-test compiles the embedded C# controller and checks the hook, the close-button detection and the multi-window rules on its own test windows. It shows three small top-most windows for a moment, so it runs only when you ask for it:

```powershell
$env:CLOSE_TO_TRAY_SELFTEST = '1'; python -m unittest discover -s tests -v
```

## License

[MIT](LICENSE)

## 한국어 요약

브라우저를 작업 표시줄 없이 시스템 트레이에 두는 작은 Windows 도우미입니다. 최소화한 창은 작업 표시줄에서 빠져 트레이 아이콘으로 들어가고, 마지막 창의 닫기(×)를 누르면 종료하지 않고 트레이로 숨깁니다. 도우미를 끄면 숨긴 창을 모두 되돌려 놓고, 브라우저를 끄지는 않습니다. 지원하는 브라우저는 Aside AI 브라우저이며, 그 제작사와 관계없는 비공식 프로젝트입니다. 알려진 문제는 위 Known issues에 있습니다.
