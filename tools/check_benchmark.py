#!/usr/bin/env python3
"""Checks a phone's encoder figures against what its real takes did. Standard library only.

    python3 tools/check_benchmark.py                 every phone under <results folder>/phones
    python3 tools/check_benchmark.py FOLDER ...      folders holding encoder_support.json and takes

The app times each codec and size once per phone (`encoder_support.json`) and warns before a take
whose codec read under 30 fps. A take's sidecar says how it really went: frames written a second,
and frames the encoder refused. This lists each codec and size with both, and flags:

- FALSE ALARM: the figures say under 30 fps, but takes held 30 with the encoder refusing nothing.
- MISSED: the figures say 30 or more, but takes lost frames at the encoder.
- UNTESTED: under 30 fps by the figures, and no take to say otherwise.

A take counts as held when it wrote at least 29.5 fps over at least 5 seconds with no frames
refused by the encoder; frames lost at the camera or the GPU don't count against the encoder.
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from test_server import default_folder  # noqa: E402

REAL_TIME = 30.0
HELD = 29.5
LABEL_TO_ID = {
    "HEVC 10-bit 4:2:0": "hevc420", "HEVC 10-bit 4:2:2": "hevc422", "HEVC 10-bit 4:4:4": "hevc444",
    "ProRes 422 LT": "prores422lt", "ProRes 422": "prores422", "ProRes 422 HQ": "prores422hq",
    "ProRes 4444": "prores4444", "HEVC 4:4:4 from 16-bit": "hevc444-16",
}


RESULT = re.compile(
    r"VIDEO RESULT (?P<file>\S+): (?P<label>.+?) (?P<size>\d+x\d+): (?P<fps>[\d.]+) fps written, (?P<frames>\d+) frames, "
    r"\d+ lost \((?P<gpu>\d+) gpu, (?P<encoder>\d+) encoder")
ENCODING = re.compile(r"Encoding (?P<file>\S+?): lens \S+, (?P<label>.+?) (?P<bits>\d+)-bit (?P<size>\d+x\d+)")


def add(evidence, codec, size, fps, seconds, refused):
    if not codec or seconds < 5:
        return
    entry = evidence[(codec, size)]
    entry["takes"] += 1
    if fps >= HELD and refused == 0:
        entry["held"] += 1
    if refused:
        entry["encoderLost"] += 1
    if entry["worst"] is None or fps < entry["worst"]:
        entry["worst"] = fps


def log_evidence(folder, evidence, seen):
    """Every take in the session logs, which outlive the takes themselves."""
    for log in folder.rglob("session_*.log"):
        bits = {}
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            if m := ENCODING.search(line):
                bits[m["file"]] = m["bits"]
            elif m := RESULT.search(line):
                name = Path(m["file"]).stem
                if name in seen:
                    continue
                seen.add(name)
                codec = LABEL_TO_ID.get(m["label"])
                if codec == "prores4444" and bits.get(name) == "12":
                    codec = "prores4444-12"
                fps, frames = float(m["fps"]), int(m["frames"])
                add(evidence, codec, m["size"], fps, frames / max(fps, 1), int(m["encoder"]))


def take_evidence(folder, extra=()):
    """By (codec ID, size): how many takes held 30 fps and how many lost frames at the encoder,
    from the session logs, and from sidecars of takes the logs don't cover."""
    evidence = defaultdict(lambda: {"held": 0, "encoderLost": 0, "takes": 0, "worst": None})
    seen = set()
    for where in (folder, *extra):
        log_evidence(where, evidence, seen)
    for sidecar in [p for where in (folder, *extra) for p in where.rglob("*.mov.json")]:
        if sidecar.name[:-len(".mov.json")] in seen:
            continue
        if "_look" in sidecar.name:   # exports and stabilized copies aren't real-time takes
            continue
        try:
            data = json.loads(sidecar.read_text())
        except (OSError, ValueError):
            continue
        meta = data.get("metadata", {})
        codec = LABEL_TO_ID.get(data.get("preset", ""))
        if codec == "prores4444" and meta.get("bitDepth") == "12":
            codec = "prores4444-12"
        refused = data.get("droppedNoBuffer", 0) + data.get("droppedNotReady", 0)
        add(evidence, codec, f"{data.get('width')}x{data.get('height')}", data.get("fps", 0),
            data.get("seconds") or 0, refused)
    return evidence


def check(folder, extra=()):
    support_files = list(folder.rglob("encoder_support.json"))
    if not support_files:
        return None
    support = json.loads(max(support_files, key=lambda p: p.stat().st_mtime).read_text())
    evidence = take_evidence(folder, extra)
    rows, flags = [], []
    for codec, sizes in sorted(support.get("fps", {}).items()):
        for size, rate in sorted(sizes.items(), key=lambda kv: -int(kv[0].split("x")[0])):
            seen = evidence.get((codec, size))
            held = seen["held"] if seen else 0
            lost = seen["encoderLost"] if seen else 0
            verdict = ""
            if rate < REAL_TIME and held and not lost:
                verdict = "FALSE ALARM"
            elif rate >= REAL_TIME and lost:
                verdict = "MISSED"
            elif rate < REAL_TIME and not seen:
                verdict = "UNTESTED"
            takes = f"{seen['takes']} takes, {held} held 30, {lost} lost at encoder, worst {seen['worst']:.2f} fps" if seen else "no takes"
            rows.append(f"  {codec:14} {size:10} {rate:6.1f} fps   {takes:58} {verdict}")
            if verdict:
                flags.append(verdict)
    header = f"{folder}: {support.get('device')}, {support.get('system')}"
    return header, rows, flags


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("folders", nargs="*", type=Path)
    parser.add_argument("--takes", type=Path, action="append", default=[],
                        help="another folder of that phone's logs and sidecars, such as the results folder")
    options = parser.parse_args()
    folders = options.folders or sorted(
        {p.parent for p in (default_folder() / "phones").glob("*/*/*/*/encoder_support.json")})
    if not folders:
        sys.exit("No encoder_support.json found")
    for folder in folders:
        result = check(folder, options.takes)
        if result is None:
            continue
        header, rows, flags = result
        print(header)
        print("\n".join(rows))
        counts = {f: flags.count(f) for f in sorted(set(flags))}
        print("  " + (", ".join(f"{n} {f.lower()}" for f, n in counts.items()) if counts else "figures agree with the takes"))
        print()


if __name__ == "__main__":
    main()
