# Security Policy

> [한국어 요약 아래 포함](#한국어-보안-요약)

## Supported Versions

Only the latest release on `main` receives fixes.

| Version | Supported |
|---|---|
| `v0.3.x` (latest) | Yes |
| `< v0.3.0` | No |

## Threat Model & What This Helper Does (and Does Not Do)

Because `close-to-tray-helper` is a Windows desktop utility that registers a low-level mouse hook and launches PowerShell silently, reviewers and security tools should inspect the exact boundaries below:

- **No network activity:** `close-to-tray.ps1`, `close-to-tray-launch.vbs`, `install.ps1`, and `uninstall.ps1` make zero outbound or inbound network connections.
- **No DLL injection or browser modification:** The helper never patches browser binaries, modifies browser profiles, or injects code into browser processes. It interacts only with top-level windows via standard Win32 APIs (`ITaskbarList`, `ShowWindow`, `UI Automation`, `WM_NCHITTEST`, and `WM_CLOSE` for the memory restart).
- **Low-level mouse hook (`WH_MOUSE_LL`):** Used solely to detect left-clicks on the top-right Close (`×`) button of the last open Aside window when **Close-to-tray** is enabled. It does not install a keyboard hook, does not log mouse coordinates or clicks, and immediately unhooks when disabled or on exit/logoff.
- **Memory restart (on by default):** Every 60 s the helper reads the memory counters (`GetProcessMemoryInfo`, `SharedCommitUsage`) of the browser's processes and the image path of the browser's main process (to start the same executable again); it never reads another process's memory. Processes are opened with `PROCESS_QUERY_LIMITED_INFORMATION` only: for those counters and paths, for the image path (`QueryFullProcessImageName`) and product name of each newly seen process named Aside (the browser and the Aside CLI; a process whose path cannot be read is tried again on the next 350 ms scan), and for start times (`GetProcessTimes`) of the browser's main process (of all its processes when `restartAfterHours` is set). While automatic restart is on and every other condition says restart, it asks Windows' audio session API (Core Audio), on a background thread, whether the browser's processes are playing or recording. When the browser's leaked shared memory reaches the threshold (or, when set, its uptime reaches `restartAfterHours`), its one window is in the tray, it plays no sound and the user has been idle, the helper posts `WM_CLOSE` to the browser's top-level windows, waits for the main browser process to exit (opened with `SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION` for that wait), starts the same executable with `--restore-last-session`, and minimizes the reopened window back to the tray. The tray menu's restart item and the `-RestartBrowser` command restart at once, even with the window on screen; like the other IPC commands, any process in the same session can send that command to the helper's listener window. It never terminates a process. Turn automatic restarts off from the tray menu or with `"autoRestart": false` in `prefs.json`.
- **Hidden PowerShell launcher (`-ExecutionPolicy Bypass`):** `close-to-tray-launch.vbs` starts `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden` so no console window flashes on startup. Enterprise AV/EDR tools may flag unsigned scripts using `WH_MOUSE_LL`, hidden PowerShell, or Startup shortcuts — inspect `close-to-tray.ps1` and check organization policy before running.
- **Optional `aside-up.ps1` trust boundary:** If a user places `aside-up.ps1` next to `close-to-tray.ps1` (or passes `-AsideUpScript <path>`), choosing **Start browser** executes that local script with `-ExecutionPolicy Bypass`. Keep the installation directory writable only by your user account (`%LOCALAPPDATA%\CloseToTrayHelper\app`).
- **Installer safety (`install.ps1` / `uninstall.ps1`):** Tracks SHA-256 digests in `.close-to-tray-bundle.json`, stages temporary files atomically (`File.Replace`), blocks reparse points inside managed install targets, and refuses to overwrite or delete locally modified files without explicit review (`-Force` on uninstall).
- **Bundled `aside-repl` skill:** `scripts/run_repl.py` invokes local `aside repl` with no shell interpolation (`subprocess.run` list argv) and enforces a default 120-second timeout. Review any JavaScript file before running it against authenticated or private pages.

## Reporting a Vulnerability

Please report security issues privately using [GitHub Security Advisories](https://github.com/Technoetic/close-to-tray-helper/security/advisories/new) (or open an issue only for non-sensitive hardening suggestions). Include reproduction steps, Windows version, and affected file/line.

---

## 한국어 보안 요약

- **네트워크 통신·DLL 주입·키 입력 로깅 없음:** `close-to-tray.ps1`과 설치/제거 스크립트는 네트워크에 연결하지 않으며 브라우저 파일을 수정하거나 코드를 주입하지 않습니다.
- **전역 마우스 훅(`WH_MOUSE_LL`) 및 숨김 PowerShell:** 마지막 창의 오른쪽 위 닫기(`×`) 버튼 감지용으로만 마우스 왼쪽 클릭을 확인하며, 기능 해제·종료·로그오프 시 훅을 즉시 해제합니다. 서명 없는 PowerShell·마우스 훅·시작프로그램 바로 가기는 보안 프로그램(AV/EDR)이 경고할 수 있으므로 실행 전 스크립트와 사내 정책을 확인하세요.
- **메모리 기준 다시 시작(기본 켬):** 60초마다 브라우저 프로세스의 메모리 계수기와, 같은 실행 파일을 다시 띄우려고 주 브라우저 프로세스의 실행 파일 경로를 읽습니다(다른 프로세스의 메모리는 읽지 않음). 프로세스는 계수기 읽기 권한(`PROCESS_QUERY_LIMITED_INFORMATION`)으로만 엽니다: 그 계수기와 경로, 처음 보는 Aside 이름 프로세스(브라우저와 Aside CLI)의 실행 파일 경로와 제품 이름(경로를 읽지 못한 프로세스는 다음 350ms 검사에서 다시 읽음), 주 브라우저 프로세스의 시작 시각(`restartAfterHours`를 켰을 때는 브라우저의 모든 프로세스의 시작 시각)을 읽을 때입니다. 자동 다시 시작이 켜져 있고 다른 조건이 모두 맞을 때만, 별도 스레드에서 Windows 오디오 세션 API(Core Audio)로 브라우저 프로세스가 소리를 내거나 녹음하는지 확인합니다. 쌓인 공유 메모리가 기준에 이르고(켰다면 가동 시간이 기준에 이르고) 창 하나가 트레이에 있으며 소리가 나지 않고 입력이 없을 때 브라우저 창에 정상 종료 요청(`WM_CLOSE`)을 보냅니다. 주 브라우저 프로세스가 끝나기를 기다린 뒤(이때만 `SYNCHRONIZE` 권한을 더함) 같은 실행 파일을 `--restore-last-session`으로 다시 열고 창을 트레이로 내립니다. 트레이 메뉴의 다시 시작 항목과 `-RestartBrowser` 명령은 창이 화면에 있어도 바로 다시 시작하며, 다른 IPC 명령처럼 같은 세션의 어느 프로세스든 도우미의 수신 창에 이 명령을 보낼 수 있습니다. 프로세스를 강제 종료하지 않으며, 자동 다시 시작은 트레이 메뉴나 `prefs.json`의 `"autoRestart": false`로 끌 수 있습니다.
- **취약점 제보:** 비공개 보안 제보는 [GitHub Security Advisories](https://github.com/Technoetic/close-to-tray-helper/security/advisories/new)를 이용해 주세요.
