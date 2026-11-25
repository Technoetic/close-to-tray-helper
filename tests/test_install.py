"""Exercise the Windows bundle installer and uninstaller in disposable directories."""
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
SKILL_SOURCE = Path(".agents/skills/aside-repl")
APP_FILES = ("close-to-tray.ps1", "close-to-tray-launch.vbs", "uninstall.ps1", "uninstall.cmd", "LICENSE")
SKILL_FILES = ("SKILL.md", "scripts/run_repl.py", "examples/readme-title.js")


def _live_helper_running() -> bool:
    """A Close to Tray Helper runs in this session (its listener window or its session-wide mutex exists).

    The installer and uninstaller stop a running helper through that mutex and window, which a temporary profile
    does not isolate, so tests that run them must not run next to a live helper."""
    if sys.platform != "win32":
        return False
    import ctypes
    if ctypes.windll.user32.FindWindowW(None, "CloseToTrayHelperIpcListener"):
        return True
    handle = ctypes.windll.kernel32.OpenMutexW(0x00100000, False, "Local\\Close-To-Tray-Helper")
    if handle:
        ctypes.windll.kernel32.CloseHandle(handle)
        return True
    return False


LIVE_HELPER = _live_helper_running()


@unittest.skipUnless(sys.platform == "win32", "Windows bundle installer")
class TestBundleInstall(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.package = self.root / "release [bundle]"
        self.profile = self.root / "test user [1]"
        self.profile.mkdir()
        self.local = self.profile / "AppData/Local"
        self.app = self.local / "CloseToTrayHelper/app"
        self.startup = self.root / "startup [1]"
        self.startup.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            CI="1",
            USERPROFILE=str(self.profile),
            HOME=str(self.profile),
            HOMEDRIVE=self.profile.drive,
            HOMEPATH=str(self.profile)[len(self.profile.drive):],
            APPDATA=str(self.profile / "AppData/Roaming"),
            LOCALAPPDATA=str(self.local),
        )
        for name in ("CODEX_HOME", "CLAUDE_CONFIG_DIR"):
            self.env.pop(name, None)
        self.skills = [
            self.profile / ".agents/skills/aside-repl",
            self.profile / ".claude/skills/aside-repl",
            self.profile / ".gemini/config/skills/aside-repl",
        ]
        release_files = [Path(name) for name in ("install.cmd", "install.ps1", *APP_FILES)]
        release_files.extend(SKILL_SOURCE / name for name in SKILL_FILES)
        for rel in release_files:
            self.assertTrue((REPO / rel).is_file(), f"Missing release file: {rel}")
            dest = self.package / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / rel, dest)

    def _run_cmd(self, batch_path: Path, *args, error_file=None, cwd=None) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(
            [self.env["COMSPEC"], "/d", "/c", "call", str(batch_path), *map(str, args)],
            cwd=cwd or self.root,
            env=self.env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=30,
        )
        if error_file is None:
            self.assertEqual(proc.returncode, 0, proc.stdout)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn(error_file, proc.stdout)
        return proc

    def install(self, *args, error_file=None, cwd=None):
        return self._run_cmd(self.package / "install.cmd", *args, error_file=error_file, cwd=cwd)

    def uninstall(self, *args, batch_path=None, error_file=None, cwd=None):
        return self._run_cmd(batch_path or (self.package / "uninstall.cmd"), *args, error_file=error_file, cwd=cwd)

    def assert_payloads(self, app, skills):
        for name in APP_FILES:
            self.assertEqual((app / name).read_bytes(), (self.package / name).read_bytes())
        for dest in skills:
            for name in SKILL_FILES:
                with self.subTest(dest=dest, name=name):
                    self.assertEqual(
                        (dest / name).read_bytes(),
                        (self.package / SKILL_SOURCE / name).read_bytes(),
                    )

    def installed_files(self):
        return {
            f.relative_to(self.profile): f.read_bytes()
            for dest in [self.app, *self.skills]
            if dest.exists()
            for f in dest.rglob("*")
            if f.is_file()
        }

    def test_clean_profile_does_not_create_unused_agent_dirs(self):
        proc = self.install()
        self.assert_payloads(self.app, [])
        for agent_dir in (".agents", ".claude", ".gemini"):
            self.assertFalse((self.profile / agent_dir).exists(), agent_dir)
        self.assertIn("-AllHosts", proc.stdout)

    def test_detected_single_agent_installs_only_that_agent(self):
        (self.profile / ".claude").mkdir()
        self.install()
        self.assert_payloads(self.app, [self.skills[1]])
        self.assertFalse((self.profile / ".agents").exists())
        self.assertFalse((self.profile / ".gemini").exists())

    def test_all_hosts_installs_and_updates_managed_files(self):
        self.install("-AllHosts")
        self.assert_payloads(self.app, self.skills)
        extra = self.skills[1] / "my-notes.txt"
        extra.write_bytes(b"keep my file")
        # Model a subsequent release with both runtime and skill updates.
        (self.package / "LICENSE").write_bytes(b"new license\r\n")
        with (self.package / SKILL_SOURCE / "SKILL.md").open("ab") as f:
            f.write(b"\r\nNew release note.\r\n")
        self.install()
        self.install()
        self.assert_payloads(self.app, self.skills)
        self.assertEqual(extra.read_bytes(), b"keep my file")

    def test_app_only_skips_skills_even_when_foreign_skill_exists(self):
        self.skills[1].mkdir(parents=True)
        (self.skills[1] / "SKILL.md").write_bytes(b"user-owned skill")
        self.install("-AppOnly")
        self.assert_payloads(self.app, [])
        self.assertEqual((self.skills[1] / "SKILL.md").read_bytes(), b"user-owned skill")

    def test_custom_agent_homes(self):
        self.env["CODEX_HOME"] = str(self.profile / "custom codex")
        self.env["CLAUDE_CONFIG_DIR"] = str(self.profile / "custom claude")
        (self.profile / ".gemini").mkdir()
        self.install()
        self.assert_payloads(self.app, [
            self.profile / "custom codex/skills/aside-repl",
            self.profile / "custom claude/skills/aside-repl",
            self.skills[2],
        ])
        for default in self.skills[:2]:
            self.assertFalse(default.exists(), default)

    def test_explicit_app_and_skills_directories(self):
        app = self.profile / "my app [2]"
        skills_dir = self.profile / "shared skills [3]"
        self.install("-AppDir", app, "-SkillsDir", skills_dir)
        self.assert_payloads(app, [skills_dir / "aside-repl"])
        for default in [self.app, *self.skills]:
            self.assertFalse(default.exists(), default)

    @unittest.skipIf(LIVE_HELPER, "a live Close to Tray Helper runs here; the uninstaller would stop it")
    def test_ancestor_junction_on_dot_claude_succeeds_while_target_junction_blocks(self):
        real_claude = self.root / "dotfiles_claude"
        real_claude.mkdir()
        junc_claude = self.profile / ".claude"
        mk = subprocess.run(["cmd", "/c", "mklink", "/J", str(junc_claude), str(real_claude)], capture_output=True, text=True)
        self.assertEqual(mk.returncode, 0, mk.stderr)
        # Installing into a symlinked/junctioned .claude dotfiles folder should work cleanly.
        self.install()
        self.assert_payloads(self.app, [self.skills[1]])
        # Uninstall through the junctioned .claude folder should also succeed cleanly.
        self.uninstall("-StartupDir", self.startup)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.skills[1].exists())
        self.assertTrue(real_claude.exists())

        # A junction directly at the managed target (aside-repl itself) MUST still be blocked.
        escape_dir = self.root / "escape_target"
        escape_dir.mkdir()
        (junc_claude / "skills").mkdir(parents=True, exist_ok=True)
        mk2 = subprocess.run(["cmd", "/c", "mklink", "/J", str(self.skills[1]), str(escape_dir)], capture_output=True, text=True)
        self.assertEqual(mk2.returncode, 0, mk2.stderr)
        self.install(error_file="Linked path requires manual review")

    def test_v020_manifest_upgrades_cleanly_to_v021(self):
        # Simulate an existing v0.2.0 installation whose app manifest only tracked 3 files.
        self.app.mkdir(parents=True)
        v020_files = ("close-to-tray.ps1", "close-to-tray-launch.vbs", "LICENSE")
        manifest_files = {}
        for name in v020_files:
            dest = self.app / name
            shutil.copyfile(self.package / name, dest)
            manifest_files[name] = [hashlib.sha256(dest.read_bytes()).hexdigest().upper()]
        manifest = {"format": "close-to-tray-helper/app/1", "files": manifest_files}
        (self.app / ".close-to-tray-bundle.json").write_text(json.dumps(manifest), encoding="utf-8")

        self.install("-AppOnly")
        self.assert_payloads(self.app, [])
        self.assertTrue((self.app / "uninstall.cmd").is_file())
        self.assertTrue((self.app / "uninstall.ps1").is_file())

    @unittest.skipIf(LIVE_HELPER, "a live Close to Tray Helper runs here; the uninstaller would stop it")
    def test_uninstall_self_deletes_preserves_user_files_and_guards_edits(self):
        self.install("-AllHosts")
        prefs = self.app.parent / "prefs.json"
        prefs.write_text('{"mode":"DeleteTab"}', encoding="utf-8")
        shortcut = self.startup / "Close To Tray Helper.lnk"
        shortcut.write_bytes(b"stub-lnk")
        extra = self.skills[1] / "my-notes.txt"
        extra.write_bytes(b"keep my file")

        # Locally edited file blocks uninstall unless -Force is passed.
        (self.skills[0] / "SKILL.md").write_bytes(b"local user tweak")
        self.uninstall("-StartupDir", self.startup, error_file="SKILL.md")
        self.assertTrue(self.app.exists())
        self.assertTrue(shortcut.exists())

        # Running the installed app/uninstall.cmd FROM cwd=self.app (as Explorer double-click does)
        # with -Force cleans everything cleanly while keeping extra user files.
        self.uninstall("-StartupDir", self.startup, "-Force", batch_path=self.app / "uninstall.cmd", cwd=self.app)
        self.assertFalse(self.app.exists())
        self.assertFalse(self.app.parent.exists())
        self.assertFalse(prefs.exists())
        self.assertFalse(shortcut.exists())
        self.assertFalse((self.skills[0] / "SKILL.md").exists())
        self.assertEqual(extra.read_bytes(), b"keep my file")
        self.assertFalse((self.skills[1] / "SKILL.md").exists())
        self.assertFalse((self.skills[2]).exists())

    def test_foreign_skill_blocks_install_before_any_other_host_is_changed(self):
        self.skills[-1].mkdir(parents=True)
        upstream = (self.package / SKILL_SOURCE / "SKILL.md").read_bytes()
        for content in (b"user-owned skill", upstream):
            with self.subTest(identical_to_release=content == upstream):
                (self.skills[-1] / "SKILL.md").write_bytes(content)
                before = self.installed_files()
                self.install("-AllHosts", error_file="SKILL.md")
                self.assertEqual(self.installed_files(), before)

    def test_modified_managed_file_blocks_entire_upgrade(self):
        self.install("-AllHosts")
        (self.skills[-1] / "scripts/run_repl.py").write_bytes(b"local edit")
        (self.package / "LICENSE").write_bytes(b"release update")
        with (self.package / SKILL_SOURCE / "SKILL.md").open("ab") as f:
            f.write(b"\r\nNew release note.\r\n")
        before = self.installed_files()
        self.install("-AllHosts", error_file="run_repl.py")
        self.assertEqual(self.installed_files(), before)

    def test_incomplete_release_installs_no_files(self):
        (self.package / SKILL_SOURCE / "examples/readme-title.js").unlink()
        self.install("-AllHosts", error_file="readme-title.js")
        self.assertEqual(self.installed_files(), {})


if __name__ == "__main__":
    unittest.main()
