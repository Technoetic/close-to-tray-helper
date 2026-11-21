# Security Policy

> [한국어 요약 아래 포함](#한국어-보안-요약)

## Supported Versions

Only the latest release on `main` receives fixes.

| Version | Supported |
|---|---|
| `v0.2.x` (latest) | Yes |
| `< v0.2.0` | No |

## Threat Model & What This Helper Does (and Does Not Do)

Because `close-to-tray-helper` is a Windows desktop utility that registers a low-level mouse hook and launches PowerShell silently, reviewers and security tools should inspect the exact boundaries below:

- **No network activity:** `close-to-tray.ps1`, `close-to-tray-launch.vbs`, `install.ps1`, and `uninstall.ps1` make zero outbound or inbound network connections.
- **No DLL injection or browser modification:** The helper never patches browser binaries, modifies browser profiles, or injects code into browser processes. It interacts only with top-level windows via standard Win32 APIs (`ITaskbarList`, `ShowWindow`, `UI Automation`, `WM_NCHITTEST`).
- **Low-level mouse hook (`WH_MOUSE_LL`):** Used solely to detect left-clicks on the top-right Close (`×`) button of the last open Aside window when **Close-to-tray** is enabled. It does not install a keyboard hook, does not log mouse coordinates or clicks, and immediately unhooks when disabled or on exit/logoff.
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
- **취약점 제보:** 비공개 보안 제보는 [GitHub Security Advisories](https://github.com/Technoetic/close-to-tray-helper/security/advisories/new)를 이용해 주세요.
