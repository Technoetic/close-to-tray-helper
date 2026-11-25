"""Unit tests for close-to-tray.ps1, close-to-tray-launch.vbs, and installer scripts (Windows only).

The self-test shows three small top-most test windows for a moment and installs a
temporary global mouse hook, so it runs only when CLOSE_TO_TRAY_SELFTEST=1 is set.
"""
from __future__ import annotations

import ctypes
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parents[1]
TRAY_PS1 = SCRIPTS_DIR / "close-to-tray.ps1"
LAUNCHER_VBS = SCRIPTS_DIR / "close-to-tray-launch.vbs"
INSTALL_PS1 = SCRIPTS_DIR / "install.ps1"
INSTALL_CMD = SCRIPTS_DIR / "install.cmd"
UNINSTALL_PS1 = SCRIPTS_DIR / "uninstall.ps1"
UNINSTALL_CMD = SCRIPTS_DIR / "uninstall.cmd"
PS_EXE = str(pathlib.Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe")
RUN_SELFTEST = os.environ.get("CLOSE_TO_TRAY_SELFTEST") == "1"


def _run_ps(args: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [PS_EXE, "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )


@unittest.skipUnless(sys.platform == "win32", "Windows only")
class TestCloseToTray(unittest.TestCase):
    def test_files_exist_and_are_pure_ascii(self) -> None:
        for path in (TRAY_PS1, LAUNCHER_VBS, INSTALL_PS1, INSTALL_CMD, UNINSTALL_PS1, UNINSTALL_CMD):
            self.assertTrue(path.is_file(), f"Missing {path}")
            raw = path.read_bytes()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), f"Unexpected BOM in {path.name}")
            non_ascii = [b for b in raw if b >= 128]
            self.assertEqual(non_ascii, [], f"Non-ASCII bytes found in {path.name}")

    def test_launcher_vbs_has_hidden_sta_invocation(self) -> None:
        text = LAUNCHER_VBS.read_text(encoding="ascii")
        self.assertIn("close-to-tray.ps1", text)
        self.assertIn("-STA", text)
        self.assertIn("-WindowStyle Hidden", text)
        self.assertIn("shell.Run cmd, 0, False", text)

    def test_powershell_syntax_valid(self) -> None:
        for script in (TRAY_PS1, INSTALL_PS1, UNINSTALL_PS1):
            with self.subTest(script=script.name):
                cmd = (
                    "$t=$null; $e=$null; "
                    f"[void][System.Management.Automation.Language.Parser]::ParseFile('{script}', [ref]$t, [ref]$e); "
                    "if ($e.Count -gt 0) { $e | ForEach-Object { Write-Error $_.Message }; exit 1 } "
                    "Write-Output 'PARSE_OK'"
                )
                proc = _run_ps(["-Command", cmd])
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertIn("PARSE_OK", proc.stdout)

    def test_ipc_reports_not_running_when_no_listener_exists(self) -> None:
        hwnd = ctypes.windll.user32.FindWindowW(None, "CloseToTrayHelperIpcListener")
        if hwnd:
            self.skipTest("A live CloseToTrayHelperIpcListener window is active on this desktop")
        proc = _run_ps(["-File", str(TRAY_PS1), "-Show", "-Json"])
        self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)
        data = json.loads(proc.stdout.strip())
        self.assertEqual(data["action"], "show")
        self.assertFalse(data["running"])
        self.assertFalse(data["sent"])

    @unittest.skipUnless(RUN_SELFTEST, "set CLOSE_TO_TRAY_SELFTEST=1 to run the desktop self-test")
    def test_self_test_close_intercept_and_prefs_roundtrip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            prefs = pathlib.Path(td) / "prefs.json"
            proc1 = _run_ps([
                "-File", str(TRAY_PS1),
                "-SelfTest", "-Json",
                "-PrefsPath", str(prefs),
                "-StartupDir", td,
                "-Mode", "HideWindow",
                "-NoCloseToTray",
            ])
            self.assertEqual(proc1.returncode, 0, proc1.stderr or proc1.stdout)
            data1 = json.loads(proc1.stdout.strip())
            self.assertTrue(data1["self_test_ok"])
            self.assertEqual(data1["mode"], "HideWindow")
            self.assertFalse(data1["close_to_tray"])
            self.assertTrue(data1["launcher_found"])
            self.assertIn("aside_up_found", data1)
            self.assertTrue(data1["ipc_msg_registered"])
            self.assertGreaterEqual(data1["tooltip_max_len"], 27)
            self.assertLessEqual(data1["tooltip_max_len"], 63)
            self.assertEqual(data1["apartment_state"], "STA")
            self.assertTrue(prefs.is_file())

            ci = data1["close_intercept"]
            self.assertTrue(ci["hook_installed"])
            self.assertTrue(ci["hook_unhooked"])
            self.assertTrue(ci["uia_close_found"])
            self.assertTrue(ci["htclose_matched"])
            self.assertTrue(ci["single_intercepted"])
            self.assertTrue(ci["paired_up_swallowed"])
            self.assertTrue(ci["htclose_fallback_intercepted"])
            self.assertTrue(ci["client_passed"])
            self.assertTrue(ci["occluded_passed"])
            self.assertTrue(ci["multi_passed"])
            self.assertTrue(ci["disabled_passed"])

            # Second call without override flags should reload persisted prefs.
            proc2 = _run_ps([
                "-File", str(TRAY_PS1),
                "-SelfTest", "-Json",
                "-PrefsPath", str(prefs),
                "-StartupDir", td,
            ])
            self.assertEqual(proc2.returncode, 0, proc2.stderr or proc2.stdout)
            data2 = json.loads(proc2.stdout.strip())
            self.assertEqual(data2["mode"], "HideWindow")
            self.assertFalse(data2["close_to_tray"])

            # Third call with -CloseToTray restores true and persists it.
            proc3 = _run_ps([
                "-File", str(TRAY_PS1),
                "-SelfTest", "-Json",
                "-PrefsPath", str(prefs),
                "-StartupDir", td,
                "-CloseToTray",
            ])
            self.assertEqual(proc3.returncode, 0, proc3.stderr or proc3.stdout)
            data3 = json.loads(proc3.stdout.strip())
            self.assertTrue(data3["close_to_tray"])

    def test_restart_browser_ipc_reports_not_running_when_no_listener_exists(self) -> None:
        hwnd = ctypes.windll.user32.FindWindowW(None, "CloseToTrayHelperIpcListener")
        if hwnd:
            self.skipTest("A live CloseToTrayHelperIpcListener window is active on this desktop")
        proc = _run_ps(["-File", str(TRAY_PS1), "-RestartBrowser", "-Json"])
        self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)
        data = json.loads(proc.stdout.strip())
        self.assertEqual(data["action"], "restart-browser")
        self.assertFalse(data["running"])
        self.assertFalse(data["sent"])

    def test_restart_policy_table_passes(self) -> None:
        # Pure decision table and prefs reading: no window is shown and no other process is touched.
        with tempfile.TemporaryDirectory() as td:
            proc = _run_ps([
                "-File", str(TRAY_PS1),
                "-PolicyTest", "-Json",
                "-PrefsPath", str(pathlib.Path(td) / "prefs.json"),
            ], timeout=90)
            self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)
            data = json.loads(proc.stdout.strip())
            self.assertEqual(data["action"], "policy-test")
            self.assertTrue(data["ok"], data["failed"])
            self.assertEqual(data["failed"], "")
            self.assertGreaterEqual(data["cases"], 37)
            prefs = data["prefs"]
            self.assertEqual(
                (prefs["auto_restart"], float(prefs["restart_at_gb"]), float(prefs["restart_after_hours"]), int(prefs["restart_idle_minutes"])),
                (True, 4.0, 0.0, 10),
            )

    def test_restart_prefs_are_validated(self) -> None:
        # (name, prefs file body, expected (autoRestart, restartAtGB, restartAfterHours, restartIdleMinutes))
        cases = [
            ("custom", '{"mode":"DeleteTab","autoRestart":false,"restartAtGB":8,"restartAfterHours":24,"restartIdleMinutes":30}',
             (False, 8.0, 24.0, 30)),
            ("out-of-range", '{"mode":"DeleteTab","restartAtGB":0.1,"restartAfterHours":5000,"restartIdleMinutes":0}',
             (True, 4.0, 0.0, 10)),
            ("zero-turns-a-trigger-off", '{"mode":"DeleteTab","restartAtGB":0,"restartAfterHours":0}', (True, 0.0, 0.0, 10)),
            ("numeric-strings", '{"mode":"DeleteTab","restartAtGB":"6.5","restartIdleMinutes":"15"}', (True, 6.5, 0.0, 15)),
            ("string-false-is-not-false", '{"mode":"DeleteTab","autoRestart":"false"}', (True, 4.0, 0.0, 10)),
            ("junk-does-not-drop-a-valid-neighbor", '{"mode":"DeleteTab","restartAtGB":"abc","restartAfterHours":null,"restartIdleMinutes":20}',
             (True, 4.0, 0.0, 20)),
            ("bools-are-not-numbers", '{"mode":"DeleteTab","restartAtGB":true,"restartIdleMinutes":false}', (True, 4.0, 0.0, 10)),
            ("negative", '{"mode":"DeleteTab","restartAtGB":-3,"restartIdleMinutes":-5}', (True, 4.0, 0.0, 10)),
            # Regression: without a "mode" key, StrictMode used to throw and drop every setting in the file.
            ("no-mode-key", '{"autoRestart":false,"restartAtGB":12}', (False, 12.0, 0.0, 10)),
            ("v0.2.1-file", '{"mode":"HideWindow","autoStartAside":true,"closeToTray":false}', (True, 4.0, 0.0, 10)),
            ("malformed", '{not json', (True, 4.0, 0.0, 10)),
        ]
        with tempfile.TemporaryDirectory() as td:
            for name, body, expected in cases:
                with self.subTest(case=name):
                    path = pathlib.Path(td) / f"{name}.json"
                    path.write_text(body, encoding="utf-8")
                    proc = _run_ps(["-File", str(TRAY_PS1), "-PolicyTest", "-Json", "-PrefsPath", str(path)], timeout=90)
                    self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)
                    prefs = json.loads(proc.stdout.strip())["prefs"]
                    got = (
                        prefs["auto_restart"],
                        float(prefs["restart_at_gb"]),
                        float(prefs["restart_after_hours"]),
                        int(prefs["restart_idle_minutes"]),
                    )
                    self.assertEqual(got, expected)

    def test_restart_feature_never_kills_the_browser(self) -> None:
        # The restart only asks windows to close; it must not end any process by force.
        text = TRAY_PS1.read_text(encoding="ascii")
        for banned in (".Kill(", "TerminateProcess", "taskkill", "Stop-Process"):
            self.assertNotIn(banned, text, banned)
        self.assertIn("NativeMethods.WM_CLOSE", text)
        self.assertIn("--restore-last-session", text)

    def test_processes_are_opened_with_least_privilege(self) -> None:
        # Static source check: every OpenProcess call asks for PROCESS_QUERY_LIMITED_INFORMATION, plus SYNCHRONIZE
        # only where the restart waits for the browser to exit; nothing reads another process's memory or modules.
        text = TRAY_PS1.read_text(encoding="ascii")
        for banned in (".MainModule", "PROCESS_VM_READ", "ReadProcessMemory", "DuplicateHandle", ".HasExited", "p.StartTime"):
            self.assertNotIn(banned, text, banned)
        self.assertIn("QueryFullProcessImageName", text)
        self.assertIn("public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;", text)
        self.assertIn("public const uint SYNCHRONIZE = 0x00100000;", text)
        calls = [a.replace("NativeMethods.", "").strip()
                 for a in re.findall(r"(?<!extern IntPtr )\bOpenProcess\(([^,]+),", text)]
        self.assertGreaterEqual(len(calls), 4, calls)
        for access in calls:
            self.assertIn(access, ("PROCESS_QUERY_LIMITED_INFORMATION", "SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION"))
        self.assertEqual(calls.count("SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION"), 1)

    def test_reopened_window_gives_the_foreground_back(self) -> None:
        # Static source check (the hand-back itself needs a live desktop): a reopened window that took the foreground
        # is minimized with SW_MINIMIZE, which hands the foreground to the window behind it; any other reopened window
        # is minimized without touching the foreground.
        text = TRAY_PS1.read_text(encoding="ascii")
        self.assertIn("public static extern IntPtr GetForegroundWindow();", text)
        self.assertRegex(
            text,
            r"GetWindowThreadProcessId\(NativeMethods\.GetForegroundWindow\(\), out fgPid\);\s+"
            r"int cmd = fgPid != 0 && fgPid == winPid \? NativeMethods\.SW_MINIMIZE : NativeMethods\.SW_SHOWMINNOACTIVE;\s+"
            r"NativeMethods\.ShowWindowAsync\(h, cmd\);",
        )

    def test_third_review_guards_are_wired(self) -> None:
        # Static source check of the restart guards added after the second review.
        text = TRAY_PS1.read_text(encoding="ascii")
        # Sound is asked for only when everything else says restart, off the UI thread; its answer re-runs the check.
        self.assertIn("StartAudioProbe(pids);", text)
        self.assertIn("inputs.MediaPlaying = _audioResultPlaying;", text)
        self.assertIn("if ((signals & SIGNAL_AUDIO_DONE) != 0) _lastPolicyCheckUtc = DateTime.MinValue;", text)
        self.assertIn("probe.SetApartmentState(ApartmentState.MTA);", text)
        self.assertNotIn("AudioActivity.AnyActive(pids)", text)
        # The restart thread counts every window of the main process, visible or hidden (also one opened during
        # the wait), and the policy refuses a restart while more than one exists.
        self.assertIn("if (!exited && CountBrowserWindows(mainOnly) > 0)", text)
        self.assertIn("if (CountBrowserWindows(mainOnly) == 0)", text)
        # Exactly one call into Core Audio, inside the probe thread; the copy comes before the one-probe flag; the
        # probe is asked for only after Decide has said restart; nothing waits for the probe thread.
        self.assertEqual(text.count("AudioActivity.AnyActive("), 1)
        self.assertIn("try { playing = AudioActivity.AnyActive(copy); }", text)
        self.assertRegex(text, r"var copy = new HashSet<int>\(pids\);[^\n]*\n\s+"
                               r"if \(Interlocked\.CompareExchange\(ref _audioProbeRunning, 1, 0\) != 0\) return;")
        self.assertRegex(text, r"string decision = RestartPolicy\.Decide\(inputs\);\s+"
                               r"if \(decision == RestartPolicy\.Restart && !manual\)")
        self.assertNotIn("probe.Join(", text)
        self.assertIn("if (i.MediaPlaying) return \"media-playing\";", text)
        self.assertIn("inputs.WindowCount = wins.Count == 0 ? 0 : Math.Max(wins.Count, CountBrowserWindows(pids));", text)
        self.assertIn("if (c.cb < size) return -1;", text)
        # The helper's own start counts as CLI activity: in the constructor, not only where a CLI process is seen.
        self.assertRegex(
            text,
            r"_restartIdleMinutes = restartIdleMinutes < 1 \? 1 : restartIdleMinutes;\s+(?://[^\n]*\n\s+)*"
            r"_lastCliSeenUtc = DateTime\.UtcNow;",
        )
        self.assertIn("SystemEvents.SessionEnded += OnSessionEnded;", text)
        self.assertIn("_miExit.Enabled = !_restartCritical && !_exitPending;", text)
        self.assertNotIn("_sessionEnding = true", text)

    def test_restart_is_not_read_as_restart_browser(self) -> None:
        # PowerShell accepts a unique prefix of a parameter name; -Restart must not close the browser. The parameter
        # list is read without running the script, and the script run below stays offline.
        keys = _run_ps(["-Command", f"(Get-Command -Name '{TRAY_PS1}').Parameters.Keys -join ','"])
        self.assertEqual(keys.returncode, 0, keys.stderr)
        names = keys.stdout.strip().split(",")
        self.assertIn("Restart", names)
        self.assertIn("RestartBrowser", names)
        # With -PolicyTest and a temporary settings file the run stays offline even if the -Restart guard were
        # removed (the script would then pass the policy test and exit 0, which fails below), so no skip is needed.
        with tempfile.TemporaryDirectory() as td:
            proc = _run_ps(["-File", str(TRAY_PS1), "-Restart", "-PolicyTest", "-Json",
                            "-PrefsPath", str(pathlib.Path(td) / "prefs.json")], timeout=90)
        self.assertEqual(proc.returncode, 2, proc.stderr or proc.stdout)
        data = json.loads(proc.stdout.strip())
        self.assertEqual(data["action"], "none")
        self.assertEqual(data["browser"], "-RestartBrowser")

    def test_install_and_uninstall_startup_in_temp_dir(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            inst = _run_ps([
                "-File", str(TRAY_PS1),
                "-InstallStartup", "-Json",
                "-StartupDir", td,
            ])
            self.assertEqual(inst.returncode, 0, inst.stderr or inst.stdout)
            inst_data = json.loads(inst.stdout.strip())
            self.assertTrue(inst_data["ok"])
            self.assertEqual(inst_data["icon_exe"], "")
            lnk = pathlib.Path(inst_data["shortcut"])
            self.assertTrue(lnk.is_file())
            self.assertEqual(lnk.name, "Close To Tray Helper.lnk")

            verify_cmd = (
                "$w = New-Object -ComObject WScript.Shell; "
                f"$s = $w.CreateShortcut('{lnk}'); "
                "Write-Output ($s.TargetPath + '|' + $s.Arguments + '|' + $s.IconLocation)"
            )
            chk = _run_ps(["-Command", verify_cmd])
            self.assertEqual(chk.returncode, 0, chk.stderr)
            self.assertIn("wscript.exe", chk.stdout.lower())
            self.assertIn("close-to-tray-launch.vbs", chk.stdout.lower())
            self.assertTrue(chk.stdout.strip().endswith("|,0"), chk.stdout)

            uninst = _run_ps([
                "-File", str(TRAY_PS1),
                "-UninstallStartup", "-Json",
                "-StartupDir", td,
            ])
            self.assertEqual(uninst.returncode, 0, uninst.stderr or uninst.stdout)
            uninst_data = json.loads(uninst.stdout.strip())
            self.assertTrue(uninst_data["ok"])
            self.assertTrue(uninst_data["removed"])
            self.assertFalse(lnk.exists())


if __name__ == "__main__":
    unittest.main()
