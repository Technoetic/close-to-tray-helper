"""Offline unit tests for .agents/skills/aside-repl/scripts/run_repl.py."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
RUN_REPL = REPO / ".agents/skills/aside-repl/scripts/run_repl.py"


class TestRunRepl(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory()
        self.addCleanup(td.cleanup)
        self.root = Path(td.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.created_dirs: list[Path] = []

    def tearDown(self):
        for d in self.created_dirs:
            shutil.rmtree(d, ignore_errors=True)

    def _make_stub(self, py_body: str) -> dict[str, str]:
        stub_py = self.bin_dir / "fake_aside.py"
        stub_py.write_text(py_body, encoding="utf-8")
        if sys.platform == "win32":
            shim = self.bin_dir / "aside.cmd"
            shim.write_text(
                f'@echo off\r\n"{sys.executable}" "{stub_py}" %*\r\n',
                encoding="ascii",
            )
        else:
            shim = self.bin_dir / "aside"
            shim.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{stub_py}" "$@"\n', encoding="utf-8")
            shim.chmod(0o755)
        env = os.environ.copy()
        env["PATH"] = str(self.bin_dir) + os.pathsep + env.get("PATH", "")
        return env

    def _run(self, args: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(RUN_REPL), *args],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=env,
            timeout=20,
        )

    def test_captures_stdout_stderr_and_sha256(self):
        env = self._make_stub(
            "import json, sys\n"
            "assert sys.argv[1] == 'repl'\n"
            "print(json.dumps({'received_len': len(sys.argv[2])}))\n"
            "sys.stderr.write('warn-line\\n')\n"
        )
        script = self.root / "ok.js"
        script.write_text("console.log('hi');\n", encoding="utf-8")
        proc = self._run([str(script)], env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        data = json.loads(proc.stdout.strip())
        out_path = Path(data["stdout"]["path"])
        err_path = Path(data["stderr"]["path"])
        self.created_dirs.append(out_path.parent)
        self.assertEqual(data["exit_code"], 0)
        self.assertFalse(data["timed_out"])
        self.assertEqual(data["stdout"]["sha256"], hashlib.sha256(out_path.read_bytes()).hexdigest())
        self.assertEqual(data["stderr"]["sha256"], hashlib.sha256(err_path.read_bytes()).hexdigest())
        self.assertIn("received_len", out_path.read_text(encoding="utf-8"))
        self.assertIn("warn-line", err_path.read_text(encoding="utf-8"))

    def test_empty_and_missing_script_return_exit_2(self):
        empty = self.root / "empty.js"
        empty.write_text("  \r\n\t ", encoding="utf-8")
        p1 = self._run([str(empty)])
        self.assertEqual(p1.returncode, 2)
        self.assertIn("empty", p1.stderr.lower())

        p2 = self._run([str(self.root / "missing.js")])
        self.assertEqual(p2.returncode, 2)
        self.assertIn("cannot read", p2.stderr.lower())

    def test_missing_aside_on_path_returns_127(self):
        script = self.root / "ok.js"
        script.write_text("console.log(1);", encoding="utf-8")
        env = os.environ.copy()
        env["PATH"] = str(self.root / "empty_bin")
        proc = self._run([str(script)], env=env)
        self.assertEqual(proc.returncode, 127)
        self.assertIn("PATH", proc.stderr)

    def test_timeout_enforced_with_exit_124(self):
        env = self._make_stub("import time\ntime.sleep(5)\n")
        script = self.root / "slow.js"
        script.write_text("await new Promise(r => setTimeout(r, 5000));", encoding="utf-8")
        proc = self._run(["--timeout", "0.5", str(script)], env=env)
        self.assertEqual(proc.returncode, 124, proc.stderr)
        data = json.loads(proc.stdout.strip())
        err_path = Path(data["stderr"]["path"])
        self.created_dirs.append(err_path.parent)
        self.assertEqual(data["exit_code"], 124)
        self.assertTrue(data["timed_out"])
        self.assertIn("timed out", err_path.read_text(encoding="utf-8").lower())

    @unittest.skipUnless(sys.platform == "win32", "Windows command-line limit guard")
    def test_oversize_script_guard_on_windows(self):
        big = self.root / "big.js"
        big.write_text("//" + ("a" * 31000), encoding="utf-8")
        proc = self._run([str(big)])
        self.assertEqual(proc.returncode, 2)
        self.assertIn("limit", proc.stderr.lower())


if __name__ == "__main__":
    unittest.main()
