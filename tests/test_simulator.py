"""Offline simulator tests; all test artifacts stay inside this repository."""

from contextlib import contextmanager, redirect_stderr
from datetime import datetime, timedelta, timezone
import io
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import unittest
from unittest.mock import MagicMock, patch
import uuid

from simulator import send


ROOT = Path(__file__).resolve().parents[1]
STAMP = datetime(2026, 10, 1, 8, 0, 0, 123000, tzinfo=timezone.utc)


@contextmanager
def artifact_directory():
    directory = ROOT / "tests" / (".simulator-test-" + uuid.uuid4().hex)
    directory.mkdir()
    try:
        yield directory
    finally:
        shutil.rmtree(directory)


def cli(manifest, *args):
    return subprocess.run(
        [sys.executable, "-m", "simulator", "--run-id", "test-001", "--manifest", str(manifest), *args],
        cwd=ROOT,
        capture_output=True,
        timeout=10,
        check=False,
    )


class RecordTests(unittest.TestCase):
    def test_syslog_header_json_and_framing(self):
        record = send.build_record("syslog", "demo-001", 8, STAMP)
        self.assertTrue(record.startswith(b"<165>1 2026-10-01T08:00:00.123Z firewall-site02-01 netdemo - DEMO - "))
        self.assertEqual(record.count(b"\n"), 1)
        self.assertTrue(record.endswith(b"\n"))
        self.assertNotIn(b"\r", record)
        body = json.loads(record.decode().split(" ", 7)[7])
        self.assertEqual(list(body), ["runId", "sequence", "noise", "device", "message", "padding"])
        self.assertEqual(body["runId"], "demo-001")
        self.assertEqual(body["sequence"], 8)
        self.assertIs(body["noise"], False)
        self.assertEqual(len(body["padding"]), 512)

    def test_deterministic_for_both_formats(self):
        for format_name in ("syslog", "cef"):
            with self.subTest(format_name=format_name):
                self.assertEqual(send.build_record(format_name, "demo", 12, STAMP), send.build_record(format_name, "demo", 12, STAMP))

    def test_noise_split_and_one_based_sequences(self):
        records = [send.event_payload("noise-check", sequence) for sequence in range(1, 1001)]
        self.assertEqual(sum(record["noise"] for record in records), 700)
        kept = [record["sequence"] for record in records if not record["noise"]]
        self.assertEqual(len(kept), 300)
        self.assertEqual(kept[:6], [8, 9, 10, 18, 19, 20])
        self.assertEqual(kept[-1], 1000)
        self.assertEqual({record["device"] for record in records}, set(send.DEVICES))
        self.assertTrue(all(type(record["noise"]) is bool for record in records))
        self.assertTrue(all(len(record["padding"]) == 512 for record in records))

    def test_cef_header_extensions_timestamp_and_framing(self):
        record = send.build_record("cef", "demo-001", 8, STAMP)
        self.assertTrue(record.startswith(b"<165>Oct  1 08:00:00 firewall-site02-01 CEF:0|PipelineDemo|NetworkDevice|1.0|100|"))
        for field in (b"cs1Label=RunId cs1=demo-001", b"cn1Label=Sequence cn1=8", b"cs2Label=Noise cs2=false", b"dvc=192.0.2.13", b"dvchost=firewall-site02-01", b"cs3Label=Padding cs3=" + b"x" * 512):
            self.assertIn(field, record)
        self.assertIn(f"rt={int(STAMP.timestamp() * 1000)}".encode(), record)
        self.assertEqual(record.count(b"\n"), 1)
        self.assertTrue(record.endswith(b"\n"))
        self.assertNotIn(b"\r", record)
        self.assertLessEqual(len(record) - 1, 1024)

    def test_cef_escaping_uses_distinct_header_and_extension_rules(self):
        text = "a\\b|c=d\r\ne"
        self.assertEqual(send.escape_cef_header(text), r"a\\b\|c=d\r\ne")
        self.assertEqual(send.escape_cef_extension(text), r"a\\b|c\=d\r\ne")
        with patch.object(send, "event_payload", return_value={
            **send.event_payload("test", 1), "message": text,
        }):
            record = send.build_record("cef", "test", 1, STAMP)
        self.assertIn(b"msg=a\\\\b|c\\=d\\r\\ne ", record)
        self.assertEqual(record.count(b"\n"), 1)
        self.assertNotIn(b"\r", record)

    def test_offsets_normalize_to_utc(self):
        local = STAMP.astimezone(timezone(timedelta(hours=2)))
        for format_name in ("syslog", "cef"):
            self.assertEqual(send.build_record(format_name, "test", 10, local), send.build_record(format_name, "test", 10, STAMP))
        self.assertEqual(send.parse_timestamp("2026-10-01T10:00:00.123+02:00"), STAMP)

    def test_utc_rollover_and_legacy_space_padded_date(self):
        stamp = datetime(2026, 1, 1, 0, 30, tzinfo=timezone(timedelta(hours=2)))
        self.assertIn(b"2025-12-31T22:30:00.000Z", send.build_record("syslog", "test", 1, stamp))
        self.assertIn(b"Dec 31 22:30:00", send.build_record("cef", "test", 1, stamp))

    def test_invalid_builder_inputs(self):
        for sequence in (0, -1, True, 1.5, "1"):
            with self.subTest(sequence=sequence), self.assertRaises(ValueError):
                send.event_payload("test", sequence)
        for run_id in ("", "-test", "a b", "test\nx", "tést", "a" * 65, "a_b", None):
            with self.subTest(run_id=run_id), self.assertRaises(ValueError):
                send.event_payload(run_id, 1)
        with self.assertRaises(ValueError):
            send.build_record("unknown", "test", 1, STAMP)
        with self.assertRaises(ValueError):
            send.build_record("syslog", "test", 1, STAMP.replace(tzinfo=None))


class CliTests(unittest.TestCase):
    def test_argument_validation(self):
        base = ["--run-id", "test", "--manifest", "unused.json", "--output-only"]
        for extra in (
            ["--port", "0"], ["--port", "65536"], ["--port", "abc"],
            ["--host", ""], ["--host", "bad\nhost"], ["--count", "0"],
            ["--count", "-1"], ["--count", "1.2"], ["--rate", "0"],
            ["--rate", "-1"], ["--rate", "nan"], ["--rate", "inf"],
            ["--timeout", "0"], ["--timeout", "61"], ["--timeout", "nan"],
            ["--run-id", "unsafe=id"], ["--format", "udp"],
            ["--timestamp", "2026-10-01"], ["--timestamp", "invalid"],
        ):
            with self.subTest(extra=extra), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
                send.parse_args(base + extra)
            self.assertEqual(result.exception.code, 2)
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            send.parse_args(base[:-1])

    def test_output_only_is_reproducible_and_does_not_send(self):
        with artifact_directory() as directory:
            for format_name in ("syslog", "cef"):
                with self.subTest(format_name=format_name):
                    path = directory / f"{format_name}.json"
                    args = ["--output-only", "--format", format_name, "--count", "20", "--timestamp", "2026-10-01T08:00:00.123Z"]
                    first = cli(path, *args)
                    second = cli(path, *args)
                    self.assertEqual(first.returncode, 0, first.stderr)
                    self.assertEqual(second.returncode, 0, second.stderr)
                    self.assertEqual(first.stdout, second.stdout)
                    self.assertEqual(len(first.stdout.splitlines()), 20)
                    self.assertNotIn(b"\r", first.stdout)
                    report = json.loads(path.read_text(encoding="utf-8"))
                    self.assertEqual(report["status"], "generated")
                    self.assertEqual(report["generatedRecords"], 20)
                    self.assertEqual(report["sentRecords"], 0)
                    self.assertEqual(report["attemptedRecords"], 0)
                    self.assertEqual(report["sentBytes"], 0)
                    self.assertEqual(report["expectedSequences"], list(range(1, 21)))
                    self.assertEqual(report["expectedRetainedSequences"], [8, 9, 10, 18, 19, 20])
                    self.assertIs(report["ingestionVerified"], False)
                    self.assertTrue(report["startedAt"].endswith("Z"))
                    self.assertTrue(report["finishedAt"].endswith("Z"))

    def test_local_tcp_receiver_for_both_formats(self):
        for format_name in ("syslog", "cef"):
            with self.subTest(format_name=format_name), artifact_directory() as directory, socket.socket() as server:
                server.bind(("127.0.0.1", 0))
                server.listen(1)
                server.settimeout(5)
                received = bytearray()
                errors = []

                def receive():
                    try:
                        with server.accept()[0] as client:
                            client.settimeout(5)
                            while True:
                                chunk = client.recv(113)
                                if not chunk:
                                    break
                                received.extend(chunk)
                    except OSError as error:
                        errors.append(error)

                thread = threading.Thread(target=receive, daemon=True)
                thread.start()
                manifest = directory / "report.json"
                result = cli(manifest, "--host", "127.0.0.1", "--port", str(server.getsockname()[1]), "--format", format_name, "--count", "20", "--rate", "10000", "--timestamp", "2026-10-01T08:00:00.123Z")
                thread.join(6)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(received, b"".join(send.build_record(format_name, "test-001", seq, STAMP) for seq in range(1, 21)))
                report = json.loads(manifest.read_text(encoding="utf-8"))
                self.assertEqual(report["status"], "sent")
                self.assertEqual(report["attemptedRecords"], 20)
                self.assertEqual(report["sentRecords"], 20)
                self.assertEqual(report["sentBytes"], len(received))
                self.assertIs(report["ingestionVerified"], False)

    def test_explicit_connection_failure(self):
        with artifact_directory() as directory, socket.socket() as unavailable:
            # Reserve an unlistened port so another process cannot claim it.
            unavailable.bind(("127.0.0.1", 0))
            path = directory / "failed.json"
            result = cli(path, "--host", "127.0.0.1", "--port", str(unavailable.getsockname()[1]), "--count", "10", "--timeout", "0.2")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn(b"sentRecords=0", result.stderr)
            self.assertIn(b"No retries performed", result.stderr)
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["sentRecords"], 0)
            self.assertEqual(report["attemptedRecords"], 0)
            self.assertEqual(report["expectedSequences"], list(range(1, 11)))
            self.assertTrue(report["error"])

    def test_failed_send_is_never_retried(self):
        with artifact_directory() as directory:
            path = directory / "failed-send.json"
            client = MagicMock()
            client.__enter__.return_value = client
            client.sendall.side_effect = [None, socket.timeout("write timed out")]
            args = ["--host", "127.0.0.1", "--port", "514", "--run-id", "test", "--count", "10", "--rate", "10000", "--manifest", str(path)]
            with patch.object(send.socket, "create_connection", return_value=client) as connect, redirect_stderr(io.StringIO()):
                result = send.main(args)
            self.assertEqual(result, 1)
            connect.assert_called_once_with(("127.0.0.1", 514), timeout=5)
            client.settimeout.assert_called_once_with(5)
            self.assertEqual(client.sendall.call_count, 2)
            report = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(report["sentRecords"], 1)
            self.assertEqual(report["attemptedRecords"], 2)
            self.assertEqual(report["generatedRecords"], 2)
            self.assertEqual(report["status"], "failed")
            self.assertIn("partially", report["deliveryNote"])

    def test_unwritable_manifest_prevents_network_side_effects(self):
        with artifact_directory() as directory:
            with patch.object(send.socket, "create_connection") as connect, redirect_stderr(io.StringIO()):
                result = send.main(["--host", "127.0.0.1", "--port", "514", "--run-id", "test", "--manifest", str(directory)])
            self.assertEqual(result, 1)
            connect.assert_not_called()

    def test_rate_limits_each_send_without_catchup_bursts(self):
        with artifact_directory() as directory:
            client = MagicMock()
            client.__enter__.return_value = client
            with patch.object(send.socket, "create_connection", return_value=client), patch.object(send.time, "monotonic", return_value=100), patch.object(send.time, "sleep") as sleep, redirect_stderr(io.StringIO()):
                result = send.main(["--host", "127.0.0.1", "--port", "514", "--run-id", "test", "--count", "3", "--rate", "4", "--manifest", str(directory / "report.json")])
            self.assertEqual(result, 0)
            self.assertEqual([call.args[0] for call in sleep.call_args_list], [0, 0.25, 0.25])


if __name__ == "__main__":
    unittest.main()
