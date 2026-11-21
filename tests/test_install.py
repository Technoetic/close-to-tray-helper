"""Exercise the Windows bundle installer in disposable user and package directories."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SKILL_SOURCE = Path(".agents/skills/aside-repl")
APP_FILES = ("close-to-tray.ps1", "close-to-tray-launch.vbs", "LICENSE")
SKILL_FILES = ("SKILL.md", "scripts/run_repl.py", "examples/readme-title.js")


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

    def install(self, *args, error_file=None):
        proc = subprocess.run(
            [self.env["COMSPEC"], "/d", "/c", "call", str(self.package / "install.cmd"), *map(str, args)],
            cwd=self.root,
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
            for f in dest.rglob("*")
            if f.is_file()
        }

    def test_default_cmd_installs_all_hosts_and_updates_managed_files(self):
        self.install()
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

    def test_custom_agent_homes(self):
        self.env["CODEX_HOME"] = str(self.profile / "custom codex")
        self.env["CLAUDE_CONFIG_DIR"] = str(self.profile / "custom claude")
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

    def test_foreign_skill_blocks_install_before_any_other_host_is_changed(self):
        self.skills[-1].mkdir(parents=True)
        upstream = (self.package / SKILL_SOURCE / "SKILL.md").read_bytes()
        for content in (b"user-owned skill", upstream):
            with self.subTest(identical_to_release=content == upstream):
                (self.skills[-1] / "SKILL.md").write_bytes(content)
                before = self.installed_files()
                self.install(error_file="SKILL.md")
                self.assertEqual(self.installed_files(), before)

    def test_modified_managed_file_blocks_entire_upgrade(self):
        self.install()
        (self.skills[-1] / "scripts/run_repl.py").write_bytes(b"local edit")
        (self.package / "LICENSE").write_bytes(b"release update")
        with (self.package / SKILL_SOURCE / "SKILL.md").open("ab") as f:
            f.write(b"\r\nNew release note.\r\n")
        before = self.installed_files()
        self.install(error_file="run_repl.py")
        self.assertEqual(self.installed_files(), before)

    def test_incomplete_release_installs_no_files(self):
        (self.package / SKILL_SOURCE / "examples/readme-title.js").unlink()
        self.install(error_file="readme-title.js")
        self.assertEqual(self.installed_files(), {})


if __name__ == "__main__":
    unittest.main()
