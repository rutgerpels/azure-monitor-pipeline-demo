"""Exercise the real outage control flow with fake host commands, never a firewall."""

import os
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which("bash"), "bash is required")
class OutageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        source = (Path(__file__).parents[1] / "scripts/linux/outage.sh").read_text()
        bin_path = self.bin.as_posix()
        if os.name == "nt":
            bin_path = "/" + bin_path[0].lower() + bin_path[2:]
        source = f'export PATH="{bin_path}:$PATH"\n' + source
        source = source.replace("/run/pipeline-demo-outage", (self.root / "outage").as_posix())
        self.script = self.root / "outage.sh"
        self.script.write_text(source, newline="\n")
        commands = {
            "flock": "exit 0",
            "cat": 'if [[ "$1" == /proc/sys/kernel/random/uuid ]]; then echo "$GENERATION"; else /usr/bin/cat "$@"; fi',
            "systemd-run": 'printf "%s\\n" "$*" >> "$TEST_ROOT/timers"',
            "systemctl": 'printf "%s\\n" "$*" >> "$TEST_ROOT/stopped"',
            "nft": """
case "$1" in
    list) test -f "$TEST_ROOT/active";;
    delete) rm "$TEST_ROOT/active";;
    -f) /usr/bin/cat >/dev/null; touch "$TEST_ROOT/active";;
    *) exit 2;;
esac
""",
        }
        for name, content in commands.items():
            path = self.bin / name
            path.write_text("#!/bin/bash\nset -eu\n" + content + "\n", newline="\n")
            path.chmod(0o755)
        self.environment = os.environ.copy()
        self.environment.update(TEST_ROOT=self.root.as_posix(), GENERATION="first-generation")
        self.environment["PATH"] = str(self.bin) + os.pathsep + self.environment["PATH"]

    def run_outage(self, *arguments, success=True):
        result = subprocess.run(
            [shutil.which("bash"), self.script.as_posix(), *arguments],
            env=self.environment, text=True, capture_output=True, timeout=10, check=False,
        )
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_stale_timer_cannot_restore_new_outage(self):
        self.run_outage("start", "90")
        self.run_outage("stop")
        self.assertIn("first-generation.timer", (self.root / "stopped").read_text())
        self.environment["GENERATION"] = "second-generation"
        self.run_outage("start", "90")
        self.run_outage("stop", "first-generation")
        self.assertTrue((self.root / "active").exists())
        self.run_outage("status", "second-generation")
        self.run_outage("status", "first-generation", success=False)
        self.run_outage("stop", "second-generation")
        self.assertFalse((self.root / "active").exists())

    def test_duplicate_start_and_invalid_duration_are_rejected(self):
        self.run_outage("start", "181", success=False)
        self.assertFalse((self.root / "timers").exists())
        self.run_outage("start", "90")
        self.run_outage("start", "90", success=False)
        self.run_outage("stop")


@unittest.skipUnless(shutil.which("bash") and shutil.which("jq"), "bash and jq are required")
class CollectorSandboxTests(unittest.TestCase):
    def test_only_current_ready_sandbox_is_inspected(self):
        source = (Path(__file__).parents[1] / "scripts/linux/backfill.sh").read_text()
        function = re.search(r"(?ms)^collector_pid\(\) \{.*?^\}", source).group()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bin_path = root.as_posix()
            if os.name == "nt":
                bin_path = "/" + bin_path[0].lower() + bin_path[2:]
            script = root / "select.sh"
            script.write_text(
                f'#!/bin/bash\nset -euo pipefail\nexport PATH="{bin_path}:$PATH"\n'
                'pod=collector\nkc() { k3s kubectl "$@"; }\n' + function + "\ncollector_pid\n",
                newline="\n",
            )
            fake = root / "k3s"
            fake.write_text("""#!/bin/bash
set -eu
case "$1 $2" in
    "kubectl get") echo current-uid;;
    "crictl pods") cat "$TEST_ROOT/sandboxes.json";;
    "crictl inspectp")
        test "$3" = new-sandbox
        echo inspected > "$TEST_ROOT/inspected"
        echo '{"info":{"pid":12345}}';;
    *) exit 2;;
esac
""", newline="\n")
            fake.chmod(0o755)
            old = {"id": "old-sandbox", "state": "SANDBOX_NOTREADY",
                   "metadata": {"uid": "old-uid", "namespace": "pipeline-demo"}}
            current = {"id": "new-sandbox", "state": "SANDBOX_READY",
                       "metadata": {"uid": "current-uid", "namespace": "pipeline-demo"}}
            wrong_uid = dict(current, id="unrelated", metadata={"uid": "other", "namespace": "pipeline-demo"})
            for items, succeeds in (([old, wrong_uid, current], True), ([old, wrong_uid], False),
                                    ([current, current], False)):
                with self.subTest(items=items):
                    (root / "sandboxes.json").write_text(json.dumps({"items": items}))
                    (root / "inspected").unlink(missing_ok=True)
                    result = subprocess.run(
                        [shutil.which("bash"), script.as_posix()],
                        env=dict(os.environ, TEST_ROOT=root.as_posix()),
                        capture_output=True, text=True, timeout=10, check=False,
                    )
                    self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                    self.assertEqual((root / "inspected").exists(), succeeds)
                    if succeeds:
                        self.assertEqual(result.stdout.strip(), "12345")


if __name__ == "__main__":
    unittest.main()
