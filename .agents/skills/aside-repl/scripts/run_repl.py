"""Pass a UTF-8 JavaScript file to Aside REPL and capture both output streams."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def describe(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(65536), b""):
            digest.update(block)
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest.hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("script", type=Path, help="UTF-8 JavaScript file")
    args = parser.parse_args()
    try:
        code = args.script.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeError) as error:
        parser.exit(2, f"Cannot read script: {error}\n")
    if not code.strip():
        parser.exit(2, "The JavaScript file is empty.\n")
    executable = shutil.which("aside")
    if executable is None:
        parser.exit(127, "Aside CLI was not found on PATH.\n")

    directory = Path(tempfile.mkdtemp(prefix="aside-repl-"))
    stdout = directory / "stdout.txt"
    stderr = directory / "stderr.txt"
    with stdout.open("wb") as out, stderr.open("wb") as err:
        try:
            result = subprocess.run(
                [executable, "repl", code], stdin=subprocess.DEVNULL, stdout=out, stderr=err
            )
            exit_code = result.returncode
        except OSError as error:
            err.write(f"Cannot launch Aside CLI: {error}\n".encode("utf-8"))
            exit_code = 1

    print(json.dumps({"exit_code": exit_code, "stdout": describe(stdout), "stderr": describe(stderr)}))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
