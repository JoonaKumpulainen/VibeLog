#!/usr/bin/env python3
"""Sums up VibeLog session logs: the phone, each take and export, and anything that went wrong.
Standard library only.

    python3 tools/read_log.py session_20261112_134734.log
    python3 tools/read_log.py ~/VibeLogTest/session_2026111*.log
    python3 tools/read_log.py session.log --json summary.json

Each log gets a short report: the phone and iOS, the capture setup, every take with its frames
lost and heat, every export, and the problems: stalls, failed takes, interruptions, idle pauses,
main-thread stalls, heat and reduced GPU load. A take that lost more than half a percent of its
frames, or failed, is marked with `!`.
"""
import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

LINE = re.compile(r"^(?P<time>\d\d:\d\d:\d\d\.\d+) (?P<level>[IWE]) (?P<text>.*)$")
RESULT = re.compile(
    r"VIDEO RESULT (?P<file>\S+): (?P<format>.+?): (?P<fps>[\d.]+) fps written, (?P<frames>\d+) frames, "
    r"(?P<lost>\d+) lost .*?capture (?P<capture>[\d.]+) fps fail (?P<fail>\d+) missed (?P<missed>\d+) "
    r"duplicates (?P<duplicates>\d+)(?: gap (?P<gap>\d+) ms)?, gpu (?P<gpu>[\d.]+) recent (?P<gpuMax>[\d.]+) max ms"
    r"(?:.*?viewfinder yields (?P<yields>\d+))?")
ENCODING = re.compile(r"Encoding (?P<file>video_\S+?): lens (?P<lens>\S+), (?P<rest>.*)")
EXPORTED = re.compile(r"Exported (?P<take>\S+) as (?P<copy>\S+) in (?P<seconds>[\d.]+) s, (?P<mb>[\d.]+) MB: (?P<look>.*)")
STARTED = re.compile(r"VibeLog started on (?P<model>\S+), Version (?P<ios>\S+)(?: \(Build (?P<build>[^)]+)\))?(?P<rest>.*)")
PHOTO_FAILED = re.compile(r"Photo failed: \S+ (?P<code>-?\d+), underlying (?P<underlying>-?\d+), count (?P<count>\d+)")
LATE = re.compile(r"Main thread answered (?P<ms>\d+) ms late on (?P<screen>\S+)")
THERMAL = re.compile(r"Thermal state changed to (?P<state>\w+)")
VERSION = re.compile(r"\bapp (?P<version>\d+\.\d+\.\d+)")
RETURNED = re.compile(r"Returned to the app after (?P<away>\d+) s away(?P<restart>, restarting the camera)?")
DRAG = re.compile(r"Slider (?P<title>.+) dragged (?P<seconds>[\d.]+) s, from (?P<start>-?[\d.]+) to (?P<end>-?[\d.]+)")

LOST_LIMIT = 0.005
IDLE_TOO_SOON = 10


def seconds(stamp):
    h, m, s = stamp.split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def read(path):
    summary = {
        "log": Path(path).name, "phone": None, "ios": None, "app": None, "captureSetup": None,
        "start": None, "end": None, "takes": [], "exports": [], "problems": [], "photoFailures": Counter(),
        "thermal": [], "mainThread": [], "idlePauses": [], "reducedLoad": 0, "returns": [], "drags": [],
    }
    takes = {}
    with open(path, encoding="utf-8", errors="replace") as log:
        for raw in log:
            match = LINE.match(raw.rstrip("\n"))
            if not match:
                continue
            time, level, text = match["time"], match["level"], match["text"]
            summary["start"] = summary["start"] or time
            summary["end"] = time

            if m := STARTED.match(text):
                summary["phone"], summary["ios"] = m["model"], m["ios"]
                if v := VERSION.search(m["rest"]):
                    summary["app"] = v["version"]
            elif text.startswith("Capture setup"):
                summary["captureSetup"] = text.split(": ", 1)[-1]
            elif text.startswith("Capture stalled") or text.startswith("The camera stalled"):
                summary["problems"].append((time, text))
            elif m := ENCODING.match(text):
                take = takes.setdefault(m["file"], {"file": m["file"]})
                take.update(start=time, lens=m["lens"], settings=m["rest"][:160])
            elif m := RESULT.search(text):
                name = Path(m["file"]).stem
                take = takes.setdefault(name, {"file": name})
                values = {k: v for k, v in m.groupdict().items() if v is not None}
                for key in ("fps", "capture", "gpu", "gpuMax"):
                    values[key] = float(values[key])
                for key in ("frames", "lost", "fail", "missed", "duplicates", "gap", "yields"):
                    if key in values:
                        values[key] = int(values[key])
                take.update(values, end=time, thermal=summary["thermal"][-1][1] if summary["thermal"] else "heat unchanged")
            elif text.startswith("VIDEO FAILED"):
                name = Path(text.split()[2].rstrip(":")).stem
                takes.setdefault(name, {"file": name})["failed"] = text.split(": ", 1)[-1]
            elif text.startswith("Recording stopped") or text.startswith("Stopping at"):
                summary["problems"].append((time, text))
            elif m := EXPORTED.match(text):
                summary["exports"].append({"time": time, **m.groupdict(), "seconds": float(m["seconds"]), "mb": float(m["mb"])})
            elif text.startswith("Export of") and (level == "E" or " cancelled " in text or "failed" in text):
                summary["exports"].append({"time": time, "failed": text})
                summary["problems"].append((time, text))
            elif m := PHOTO_FAILED.search(text):
                summary["photoFailures"][f"{m['code']}/{m['underlying']}"] += 1
            elif m := LATE.match(text):
                summary["mainThread"].append((time, int(m["ms"]), m["screen"]))
            elif m := THERMAL.match(text):
                summary["thermal"].append((time, m["state"].lower()))
            elif text.startswith("Reduced GPU load on"):
                summary["reducedLoad"] += 1
            elif m := RETURNED.match(text):
                summary["returns"].append({"time": time, "away": int(m["away"]), "restart": bool(m["restart"]), "pausedAfter": None})
            elif m := DRAG.match(text):
                summary["drags"].append({"time": time, "title": m["title"], "seconds": float(m["seconds"]),
                                         "moved": abs(float(m["end"]) - float(m["start"]))})
            elif text.startswith("Streaming with"):
                summary["streamStarted"] = time
            elif text.startswith("Camera paused after"):
                started = summary.get("streamStarted")
                after = (seconds(time) - seconds(started)) % 86400 if started else None
                summary["idlePauses"].append((time, after))
                for ret in summary["returns"]:
                    if ret["pausedAfter"] is None and 0 <= (seconds(time) - seconds(ret["time"])) % 86400 < 30:
                        ret["pausedAfter"] = round((seconds(time) - seconds(ret["time"])) % 86400, 1)
            elif level in "WE" and any(text.startswith(p) for p in (
                    "Photo loop stalled", "Session interrupted", "Session did not start", "Cannot start",
                    "Configure failed", "Gyro log stopped", "Pipeline shader setup failed")):
                summary["problems"].append((time, text))

    summary["takes"] = sorted(takes.values(), key=lambda t: t.get("start") or t.get("end") or "")
    for take in summary["takes"]:
        frames, lost = take.get("frames"), take.get("lost", 0)
        take["flagged"] = bool(take.get("failed")) or (frames is not None and lost > LOST_LIMIT * (frames + lost))
    summary.pop("streamStarted", None)
    return summary


def duration(start, end):
    if not start or not end:
        return ""
    total = (seconds(end) - seconds(start)) % 86400
    return f"{int(total // 60)} min {int(total % 60)} s"


def report(s):
    out = [f"{s['log']}: {s['phone'] or 'unknown phone'}, iOS {s['ios'] or '?'}"
           + (f", app {s['app']}" if s["app"] else "")
           + f", {s['start']} to {s['end']} ({duration(s['start'], s['end'])})"]
    if s["captureSetup"]:
        out.append(f"  Capture setup: {s['captureSetup']}")
    if s["takes"]:
        out.append(f"  Takes ({len(s['takes'])}):")
        for t in s["takes"]:
            mark = "!" if t["flagged"] else " "
            if "frames" in t:
                seconds_long = t["frames"] / t["fps"] if t.get("fps") else 0
                out.append(
                    f"   {mark} {t['file']}  {t.get('lens', '?'):4} {t.get('format', '')[:34]:34} "
                    f"{seconds_long:6.1f} s  {t['frames']} frames, {t['lost']} lost, missed {t.get('missed', 0)}, "
                    f"gpu {t['gpu']:.0f}/{t['gpuMax']:.0f} ms, {t['thermal']}"
                    + (f"  FAILED: {t['failed']}" if t.get("failed") else ""))
            else:
                out.append(f"   {mark} {t['file']}  no result" + (f"  FAILED: {t['failed']}" if t.get("failed") else ""))
    if s["exports"]:
        out.append(f"  Exports ({len(s['exports'])}):")
        for e in s["exports"]:
            if "failed" in e:
                out.append(f"   ! {e['time']} {e['failed']}")
            else:
                out.append(f"     {e['copy']}  {e['seconds']:.0f} s, {e['mb']:.0f} MB, {e['look'][:60]}")
    problems = list(s["problems"])
    for time, after in s["idlePauses"]:
        # Paused within seconds of the stream starting means the idle clock counted time spent
        # outside the app, the bug fixed in `eed6df9`. A pause long after is the setting working.
        if after is not None and after < IDLE_TOO_SOON:
            problems.append((time, f"Camera paused for idle {after:.1f} s after the stream started"))
        else:
            problems.append((time, "Camera paused for idle, as set"))
    if problems:
        out.append("  Problems:")
        for time, text in problems:
            out.append(f"     {time} {text[:150]}")
    if s["returns"]:
        out.append("  Returning to the app:")
        for r in s["returns"]:
            verdict = (f"! the camera paused for idle {r['pausedAfter']} s later" if r["pausedAfter"] is not None
                       else "the camera kept running" if r["restart"] else "the camera wasn't running before")
            out.append(f"     {r['time']} after {r['away']} s away: {verdict}")
    if s["drags"]:
        counts = Counter(d["title"] for d in s["drags"])
        still = Counter(d["title"] for d in s["drags"] if d["moved"] == 0)
        out.append("  Slider drags the slider took: " + ", ".join(
            f"{title} {n}" + (f" ({still[title]} without moving)" if still[title] else "") for title, n in counts.most_common()))
    if s["photoFailures"]:
        out.append("  Photo failures: " + ", ".join(f"{code} x{n}" for code, n in s["photoFailures"].most_common()))
    if s["thermal"]:
        states = " -> ".join(f"{state} {time[:5]}" for time, state in s["thermal"])
        out.append(f"  Heat: {states}" + (f"; reduced GPU load {s['reducedLoad']} times" if s["reducedLoad"] else ""))
    if s["mainThread"]:
        worst = max(s["mainThread"], key=lambda x: x[1])
        screens = Counter(screen for _, _, screen in s["mainThread"])
        out.append(f"  Main thread late {len(s['mainThread'])} times, worst {worst[1]} ms on {worst[2]}; "
                   + ", ".join(f"{k} {v}" for k, v in screens.most_common()))
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("logs", nargs="+")
    parser.add_argument("--json", help="also write the summaries to this file")
    parser.add_argument("--flagged", action="store_true", help="only print logs with a flagged take or a problem")
    options = parser.parse_args()
    summaries = []
    for path in options.logs:
        summary = read(path)
        summaries.append(summary)
        if options.flagged and not (summary["problems"] or any(t["flagged"] for t in summary["takes"])):
            continue
        print(report(summary))
        print()
    if options.json:
        for s in summaries:
            s["photoFailures"] = dict(s["photoFailures"])
        Path(options.json).write_text(json.dumps(summaries if len(summaries) > 1 else summaries[0], indent=2))


if __name__ == "__main__":
    sys.exit(main())
