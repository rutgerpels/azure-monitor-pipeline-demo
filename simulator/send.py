"""Generate synthetic device events; never interpret a TCP send as ingestion.

Wire formats: RFC 5424 section 6, RFC 3164 section 4.1, and LF framing
from RFC 6587 section 3.4.2. RFC 3164 has no timezone/year field: this
simulator's device clocks are UTC; CEF rt also supplies epoch milliseconds.
CEF escaping follows the ArcSight CEF Implementation Standard, version 26:
https://www.microfocus.com/documentation/arcsight/arcsight-smartconnectors-8.4/
pdfdoc/cef-implementation-standard/cef-implementation-standard.pdf

Plain TCP is intentionally restricted to synthetic demo traffic. It provides
neither encryption nor an application-level delivery acknowledgement.
"""

import argparse
from contextlib import nullcontext
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import socket
import sys
import time


PADDING = "x" * 512
DEVICES = ("switch-site01-01", "switch-site02-01", "firewall-site01-01", "firewall-site02-01")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
RUN_ID_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,63}", re.ASCII)


def validate_run_id(value):
    """Accept a caller-supplied correlation ID, never silently replace it."""
    if not isinstance(value, str) or RUN_ID_PATTERN.fullmatch(value) is None:
        raise ValueError("run-id must be 1-64 ASCII letters/digits/hyphens, starting with a letter/digit")
    return value


def event_payload(run_id, sequence):
    """Return the exact JSON body schema and deterministic 70/30 noise pattern."""
    validate_run_id(run_id)
    if type(sequence) is not int or sequence < 1:
        raise ValueError("sequence must be a positive integer")
    noise = sequence % 10 in range(1, 8)
    device = DEVICES[(sequence - 1) % len(DEVICES)]
    message = "periodic interface polling" if noise else "interface state changed"
    if device.startswith("firewall"):
        message = "periodic session polling" if noise else "blocked inbound connection"
    return {
        "runId": run_id,
        "sequence": sequence,
        "noise": noise,
        "device": device,
        "message": message,
        "padding": PADDING,
    }


def utc_timestamp(value):
    """Reject ambiguous naive datetimes and normalize aware datetimes to UTC."""
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamp must include a timezone")
    return value.astimezone(timezone.utc)


def iso_timestamp(value):
    return utc_timestamp(value).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def escape_cef_header(value):
    """CEF header delimiters differ from extension delimiters."""
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\r", "\\r").replace("\n", "\\n")


def escape_cef_extension(value):
    return str(value).replace("\\", "\\\\").replace("=", "\\=").replace("\r", "\\r").replace("\n", "\\n")


def build_record(format_name, run_id, sequence, timestamp):
    """Return one UTF-8 record, including exactly one trailing LF byte."""
    event = event_payload(run_id, sequence)
    stamp = utc_timestamp(timestamp)
    priority = 167 if event["noise"] else 165
    if format_name == "syslog":
        body = json.dumps(event, separators=(",", ":"), ensure_ascii=True)
        message = f"<{priority}>1 {iso_timestamp(stamp)} {event['device']} netdemo - DEMO - {body}"
    elif format_name == "cef":
        # English month names are explicit so fixtures do not depend on locale.
        legacy_stamp = f"{MONTHS[stamp.month - 1]} {stamp.day:2d} {stamp:%H:%M:%S}"
        headers = ("PipelineDemo", "NetworkDevice", "1.0", "100", event["message"], "1" if event["noise"] else "5")
        extension = {
            "rt": int(stamp.timestamp() * 1000),
            "cs1Label": "RunId",
            "cs1": run_id,
            "cn1Label": "Sequence",
            "cn1": sequence,
            "cs2Label": "Noise",
            "cs2": str(event["noise"]).lower(),
            "dvc": f"192.0.2.{10 + (sequence - 1) % len(DEVICES)}",
            "dvchost": event["device"],
            "src": "198.51.100.10",
            "dst": "203.0.113.20",
            "act": "observe" if event["noise"] else "alert",
            "msg": event["message"],
            "cs3Label": "Padding",
            "cs3": PADDING,
        }
        cef = "CEF:0|" + "|".join(escape_cef_header(value) for value in headers)
        cef += "|" + " ".join(f"{key}={escape_cef_extension(value)}" for key, value in extension.items())
        message = f"<{priority}>{legacy_stamp} {event['device']} {cef}"
    else:
        raise ValueError("format must be syslog or cef")
    return (message + "\n").encode("utf-8")


def positive_integer(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def positive_float(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be finite and greater than zero")
    return result


def parse_timestamp(value):
    try:
        return utc_timestamp(datetime.fromisoformat(value.replace("Z", "+00:00")))
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("use an ISO 8601 timestamp with timezone, e.g. 2026-10-01T08:00:00Z") from error


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--host", help="TCP receiver hostname or IP (required unless --output-only)")
    parser.add_argument("--port", type=positive_integer, help="TCP receiver port (required unless --output-only)")
    parser.add_argument("--format", choices=("syslog", "cef"), default="syslog")
    parser.add_argument("--run-id", required=True, help="stable correlation ID; use a new ID for each independent run")
    parser.add_argument("--count", type=positive_integer, default=1000)
    parser.add_argument("--rate", type=positive_float, default=100, help="maximum records/second (default: 100)")
    parser.add_argument("--manifest", type=Path, required=True, help="JSON report path; parent directory must exist")
    parser.add_argument("--output-only", action="store_true", help="write LF-framed fixtures to stdout, without sockets or pacing")
    parser.add_argument("--timeout", type=positive_float, default=5, help="connect/send timeout in seconds, maximum 60 (default: 5)")
    parser.add_argument("--timestamp", type=parse_timestamp, help="fixed event timestamp for reproducible fixtures; default: current UTC")
    args = parser.parse_args(argv)
    try:
        validate_run_id(args.run_id)
    except ValueError as error:
        parser.error(str(error))
    if not args.output_only and (args.host is None or args.port is None):
        parser.error("--host and --port are required unless --output-only is set")
    if args.host is not None and (not args.host or any(char.isspace() or ord(char) < 32 for char in args.host)):
        parser.error("--host must be a nonempty hostname or IP without whitespace/control characters")
    if args.port is not None and args.port > 65535:
        parser.error("--port must be between 1 and 65535")
    if args.timeout > 60:
        parser.error("--timeout must not exceed 60 seconds")
    return args


def write_manifest(path, report):
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


def run(args):
    """Send each record at most once and persist honest sender-side counters."""
    report = {
        "schemaVersion": 1,
        "runId": args.run_id,
        "format": args.format,
        "mode": "output-only" if args.output_only else "tcp",
        "host": args.host,
        "port": args.port,
        "requestedRecords": args.count,
        "expectedSequences": list(range(1, args.count + 1)),
        "expectedRetainedSequences": [sequence for sequence in range(1, args.count + 1) if sequence % 10 in (8, 9, 0)],
        "generatedRecords": 0,
        "attemptedRecords": 0,
        "sentRecords": 0,
        "sentBytes": 0,
        "status": "running",
        "ingestionVerified": False,
        "deliveryNote": "sentRecords counts completed socket sendall calls only, not receiver acknowledgement or ingestion; a failing send may have partially transmitted its record. No records are retried.",
        "startedAt": iso_timestamp(datetime.now(timezone.utc)),
        "finishedAt": None,
        "error": None,
    }
    # Check the report destination before any network side effect.
    try:
        write_manifest(args.manifest, report)
    except OSError as error:
        print(f"Manifest unavailable; no records sent: {error}", file=sys.stderr)
        return 1

    exit_code = 0
    try:
        connection = nullcontext(None) if args.output_only else socket.create_connection((args.host, args.port), timeout=args.timeout)
        with connection as client:
            if client is not None:
                client.settimeout(args.timeout)
            next_send = time.monotonic()
            for sequence in range(1, args.count + 1):
                if not args.output_only:
                    time.sleep(max(0, next_send - time.monotonic()))
                stamp = args.timestamp if args.timestamp is not None else datetime.now(timezone.utc)
                record = build_record(args.format, args.run_id, sequence, stamp)
                report["generatedRecords"] += 1
                if args.output_only:
                    sys.stdout.buffer.write(record)
                else:
                    report["attemptedRecords"] += 1
                    client.sendall(record)
                    report["sentRecords"] += 1
                    report["sentBytes"] += len(record)
                    next_send = time.monotonic() + 1 / args.rate
            if args.output_only:
                sys.stdout.buffer.flush()
        report["status"] = "generated" if args.output_only else "sent"
    except (OSError, KeyboardInterrupt) as error:
        exit_code = 130 if isinstance(error, KeyboardInterrupt) else 1
        report["status"] = "failed"
        report["error"] = str(error) or "Interrupted"
    finally:
        report["finishedAt"] = iso_timestamp(datetime.now(timezone.utc))
        try:
            write_manifest(args.manifest, report)
        except OSError as error:
            print(f"Could not persist final manifest: {error}", file=sys.stderr)
            exit_code = 1
        print(
            f"status={report['status']} requestedRecords={args.count} "
            f"generatedRecords={report['generatedRecords']} attemptedRecords={report['attemptedRecords']} "
            f"sentRecords={report['sentRecords']} ingestionVerified=false",
            file=sys.stderr,
        )
        if report["error"]:
            print(f"No retries performed: {report['error']}", file=sys.stderr)
    return exit_code


def main(argv=None):
    return run(parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
