"""Unit tests for close-to-tray.ps1, close-to-tray-launch.vbs, and installer scripts (Windows only).

The self-test shows three small top-most test windows for a moment and installs a
temporary global mouse hook, so it runs only when CLOSE_TO_TRAY_SELFTEST=1 is set.
"""
from __future__ import annotations

import ctypes
import json
import os
import pathlib
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
