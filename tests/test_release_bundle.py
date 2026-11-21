"""Verify deterministic slim release ZIP packaging, repository hygiene, and ZIP install round-trip."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import zipfile

REPO = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = REPO / "tools/build_release_zip.py"
INVISIBLE_RE = re.compile(r"[\u00ad\u034f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff\u3164\uffa0]")
TEXT_SUFFIXES = {".ps1", ".vbs", ".cmd", ".py", ".js", ".md", ".yml", ".yaml", ".txt", ".json"}


class TestReleaseBundleAndHygiene(unittest.TestCase):
    def test_repo_text_files_have_no_bom_or_invisible_unicode(self):
        for p in sorted(REPO.rglob("*")):
            if ".git" in p.parts or "__pycache__" in p.parts or "dist" in p.parts or not p.is_file():
                continue
            if p.suffix.lower() not in TEXT_SUFFIXES and p.name not in ("LICENSE", ".gitignore", ".gitattributes"):
                continue
            raw = p.read_bytes()
            rel = p.relative_to(REPO).as_posix()
            self.assertFalse(raw.startswith(b"\xef\xbb\xbf"), f"UTF-8 BOM in {rel}")
            text = raw.decode("utf-8")
            self.assertEqual(INVISIBLE_RE.findall(text), [], f"Invisible Unicode in {rel}")

    def test_deterministic_slim_release_zip_and_sha256sums(self):
        with tempfile.TemporaryDirectory() as td:
            out1 = Path(td) / "out1"
            out2 = Path(td) / "out2"
            env = os.environ.copy()
            env["SOURCE_DATE_EPOCH"] = "1763732889"
            for out_dir in (out1, out2):
                proc = subprocess.run(
                    [sys.executable, str(BUILD_SCRIPT), "--version", "v0.2.1", "--out", str(out_dir)],
                    capture_output=True, text=True, env=env, timeout=30,
                )
                self.assertEqual(proc.returncode, 0, proc.stderr or proc.stdout)

            z1 = out1 / "close-to-tray-helper-0.2.1-windows.zip"
            z2 = out2 / "close-to-tray-helper-0.2.1-windows.zip"
            self.assertEqual(z1.read_bytes(), z2.read_bytes(), "Release ZIP must be byte-deterministic")
            self.assertLess(z1.stat().st_size, 150_000, "Slim release ZIP should exclude docs/visuals bloat")

            digest = hashlib.sha256(z1.read_bytes()).hexdigest()
            sums = (out1 / "SHA256SUMS.txt").read_text(encoding="utf-8").strip()
            self.assertEqual(sums, f"{digest}  {z1.name}")

            with zipfile.ZipFile(z1, "r") as zf:
                names = zf.namelist()
                self.assertFalse(any("docs/visuals/" in n for n in names))
                self.assertIn("close-to-tray-helper-0.2.1/install.cmd", names)
                self.assertIn("close-to-tray-helper-0.2.1/uninstall.cmd", names)
                self.assertIn("close-to-tray-helper-0.2.1/SECURITY.md", names)
                self.assertIn("close-to-tray-helper-0.2.1/.agents/skills/aside-repl/SKILL.md", names)

            if sys.platform == "win32":
                extract_dir = Path(td) / "extracted"
                with zipfile.ZipFile(z1, "r") as zf:
                    zf.extractall(extract_dir)
                pkg = extract_dir / "close-to-tray-helper-0.2.1"
                prof = Path(td) / "zip_user"
                prof.mkdir()
                startup = Path(td) / "zip_startup"
                startup.mkdir()
                inst_env = os.environ.copy()
                inst_env.update(
                    CI="1",
                    USERPROFILE=str(prof),
                    LOCALAPPDATA=str(prof / "AppData/Local"),
                )
                inst_env.pop("CODEX_HOME", None)
                inst_env.pop("CLAUDE_CONFIG_DIR", None)
                p_inst = subprocess.run(
                    [inst_env["COMSPEC"], "/d", "/c", "call", str(pkg / "install.cmd"), "-AllHosts"],
                    env=inst_env, capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(p_inst.returncode, 0, p_inst.stdout + p_inst.stderr)
                app_dir = prof / "AppData/Local/CloseToTrayHelper/app"
                self.assertTrue((app_dir / "close-to-tray.ps1").is_file())
                self.assertTrue((app_dir / "uninstall.cmd").is_file())
                p_uninst = subprocess.run(
                    [inst_env["COMSPEC"], "/d", "/c", "call", str(app_dir / "uninstall.cmd"), "-StartupDir", str(startup)],
                    cwd=app_dir, env=inst_env, capture_output=True, text=True, timeout=30,
                )
                self.assertEqual(p_uninst.returncode, 0, p_uninst.stdout + p_uninst.stderr)
                self.assertFalse(app_dir.exists())


if __name__ == "__main__":
    unittest.main()
