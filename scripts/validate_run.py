#!/usr/bin/env python3
"""Validate GPS-SDR-Receiver run logs for PRN acquisition."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PRN_PATTERN = re.compile(r"PRN\s+(\d+)\s+Corr:([0-9.]+)\s+f=([+\-0-9.]+)")
NAV_PATTERNS = [
    re.compile(r"subframe", re.IGNORECASE),
    re.compile(r"gpsframe", re.IGNORECASE),
    re.compile(r"frame\s+lock", re.IGNORECASE),
]
EPHEMERIS_PATTERNS = [
    re.compile(r"ephem", re.IGNORECASE),
    re.compile(r"ephemeris", re.IGNORECASE),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate GPS-SDR-Receiver run log")
    parser.add_argument("--log", required=True, help="Path to run log (tee output)")
    parser.add_argument("--min-prn", type=int, default=1, help="Minimum distinct PRNs expected")
    parser.add_argument("--require-task-finish", action="store_true", help="Fail if Task1/Task2 finished markers missing")
    parser.add_argument("--min-subframes", type=int, default=0, help="Minimum navigation-frame hits expected")
    parser.add_argument("--min-ephemeris", type=int, default=0, help="Minimum ephemeris-related log hits expected")
    parser.add_argument("--json", action="store_true", help="Emit JSON summary")
    return parser.parse_args()


def analyze(log_path: Path) -> dict:
    prns: dict[int, dict[str, float]] = {}
    task1 = False
    task2 = False
    subframes = 0
    ephemeris = 0
    if not log_path.exists():
        raise FileNotFoundError(log_path)
    with log_path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            match = PRN_PATTERN.search(line)
            if match:
                prn = int(match.group(1))
                corr = float(match.group(2))
                freq = float(match.group(3))
                prns[prn] = {"corr": corr, "doppler_hz": freq}
            if "Task1 finished" in line:
                task1 = True
            if "Task2 finished" in line:
                task2 = True
            if any(p.search(line) for p in NAV_PATTERNS):
                subframes += 1
            if any(p.search(line) for p in EPHEMERIS_PATTERNS):
                ephemeris += 1
    return {"prns": prns, "task1": task1, "task2": task2, "subframes": subframes, "ephemeris": ephemeris}


def main() -> None:
    args = parse_args()
    summary = analyze(Path(args.log))
    prn_count = len(summary["prns"])
    ok = prn_count >= args.min_prn
    if args.require_task_finish:
        ok = ok and summary["task1"] and summary["task2"]
    if summary["subframes"] < args.min_subframes:
        ok = False
    if summary["ephemeris"] < args.min_ephemeris:
        ok = False
    payload = {
        "log": args.log,
        "unique_prns": prn_count,
        "min_required": args.min_prn,
        "task1_finished": summary["task1"],
        "task2_finished": summary["task2"],
        "prn_details": summary["prns"],
        "subframes": summary["subframes"],
        "min_subframes": args.min_subframes,
        "ephemeris_hits": summary["ephemeris"],
        "min_ephemeris": args.min_ephemeris,
        "status": "ok" if ok else "failed",
    }
    if args.json:
        print(json.dumps(payload, indent=2))
    else:
        print(f"[validate] {payload['status'].upper()} - {prn_count} PRNs detected")
        if summary["prns"]:
            rows = ", ".join(f"PRN{prn}:corr={info['corr']:.1f}" for prn, info in sorted(summary["prns"].items()))
            print(f"[validate] {rows}")
        print(f"[validate] subframes={summary['subframes']} (min {args.min_subframes}), ephemeris_hits={summary['ephemeris']} (min {args.min_ephemeris})")
    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
