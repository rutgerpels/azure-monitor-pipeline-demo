"""Exercise managed-identity subscription discovery without Azure calls."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("bash"), "bash is required")
class ArcTests(unittest.TestCase):
    def test_login_is_refreshed_until_temporary_role_is_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_path = root.as_posix()
            if os.name == "nt":
                bin_path = "/" + bin_path[0].lower() + bin_path[2:]
            source = (Path(__file__).parents[1] / "scripts/linux/connect-arc.sh").read_text()
            script = root / "connect.sh"
            script.write_text(f'export PATH="{bin_path}:$PATH"\n' + source, newline="\n")
            commands = {
                "sleep": "exit 0",
                "az": """
printf '%s\\n' "$*" >> "$TEST_ROOT/calls"
case "$1 $2" in
    "login --identity") echo login >> "$TEST_ROOT/logins";;
    "group show") test "$(/usr/bin/wc -l < "$TEST_ROOT/logins")" -ge 2;;
    "extension add"|"connectedk8s connect"|"connectedk8s enable-features"|"account clear") exit 0;;
    *) exit 2;;
esac
""",
            }
            for name, content in commands.items():
                path = root / name
                path.write_text("#!/bin/bash\nset -eu\n" + content + "\n", newline="\n")
                path.chmod(0o755)
            env = dict(os.environ, TEST_ROOT=root.as_posix())
            result = subprocess.run(
                [shutil.which("bash"), script.as_posix(), "subscription", "group", "cluster", "oid"],
                env=env, capture_output=True, text=True, timeout=20, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = (root / "calls").read_text().splitlines()
            logins = [i for i, call in enumerate(calls) if call.startswith("login ")]
            groups = [i for i, call in enumerate(calls) if call.startswith("group show")]
            self.assertEqual(len(logins), 2)
            self.assertLess(logins[0], groups[0])
            self.assertLess(groups[0], logins[1])
            self.assertLess(logins[1], groups[1])
            self.assertEqual(calls[-1], "account clear")


if __name__ == "__main__":
    unittest.main()
