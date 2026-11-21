"""Build a deterministic slim Windows release ZIP and SHA256SUMS.txt."""
from __future__ import annotations

import argparse
import datetime
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import zipfile

REPO_ROOT = Path(__file__).resolve().parents[1]

RELEASE_FILES = (
    "install.cmd",
    "install.ps1",
    "uninstall.cmd",
    "uninstall.ps1",
    "close-to-tray.ps1",
    "close-to-tray-launch.vbs",
    "LICENSE",
    "README.md",
    "README.ko.md",
    "SECURITY.md",
    ".agents/skills/aside-repl/SKILL.md",
    ".agents/skills/aside-repl/scripts/run_repl.py",
    ".agents/skills/aside-repl/examples/readme-title.js",
)


def resolve_source_date_epoch(repo: Path) -> int:
    env_val = os.environ.get("SOURCE_DATE_EPOCH")
    if env_val:
        return int(env_val)
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%ct"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if out:
            return int(out)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return 1700000000


def build_release_bundle(version: str, out_dir: Path, repo: Path = REPO_ROOT) -> tuple[Path, Path, str]:
    clean_ver = version.lstrip("v")
    prefix = f"close-to-tray-helper-{clean_ver}"
    zip_name = f"{prefix}-windows.zip"
    out_dir.mkdir(parents=True, exist_ok=True)
    zip_path = out_dir / zip_name
    sums_path = out_dir / "SHA256SUMS.txt"

    epoch = resolve_source_date_epoch(repo)
    dt = datetime.datetime.fromtimestamp(epoch, tz=datetime.timezone.utc)
    zip_date = (max(dt.year, 1980), dt.month, dt.day, dt.hour, dt.minute, dt.second)

    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel in sorted(RELEASE_FILES):
            src = repo / rel
            if not src.is_file():
                raise FileNotFoundError(f"Missing release file: {rel}")
            data = src.read_bytes()
            info = zipfile.ZipInfo(filename=f"{prefix}/{rel}", date_time=zip_date)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix permissions metadata for deterministic builds
            info.external_attr = (0o644 << 16)
            zf.writestr(info, data)

    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    sums_path.write_text(f"{digest}  {zip_name}\n", encoding="utf-8", newline="\n")
    return zip_path, sums_path, digest


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version (e.g. v0.2.1)")
    parser.add_argument("--out", type=Path, required=True, help="Output directory")
    args = parser.parse_args(argv)
    zip_path, sums_path, digest = build_release_bundle(args.version, args.out)
    print(f"Built {zip_path.name} ({zip_path.stat().st_size} bytes, sha256={digest})")
    print(f"Wrote {sums_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
