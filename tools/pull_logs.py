#!/usr/bin/env python3
"""Pulls what testers' phones uploaded to the log service, sorts it by phone, and sums it up.
Standard library only.

    python3 tools/pull_logs.py            fetch new uploads, then write the report
    python3 tools/pull_logs.py --delete   also delete each upload from the service once saved
    python3 tools/pull_logs.py --report   only write the report from what's already here
    python3 tools/pull_logs.py --forget 1a2b3c4d   delete everything from the install whose ID
                                                   starts so, on the service and here

The service's address and the owner's key are read from ~/.vibelog_logs, kept out of the repo:

    {"url": "https://vibelog-logs.<account>.workers.dev", "token": "<the ADMIN_TOKEN secret>"}

Files land in <results folder>/phones/<model>/<iOS>/<app version>/<install>/, and the report in
phones/report.md, grouped by phone model. An install is a random ID from one phone's app, so
several installs of one model are several phones, or one phone given a new ID.
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
import zlib
import re
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import read_log  # noqa: E402
from test_server import default_folder  # noqa: E402

SETTINGS = Path(os.environ.get("VIBELOG_LOGS_SETTINGS", Path.home() / ".vibelog_logs"))


def settings():
    if not SETTINGS.exists():
        sys.exit(f"Put the service's url and token in {SETTINGS}, as this file's help shows")
    data = json.loads(SETTINGS.read_text())
    return data["url"].rstrip("/"), data["token"]


def call(base, token, path, method="GET"):
    request = urllib.request.Request(base + path, method=method, headers={
        "Authorization": f"Bearer {token}", "User-Agent": "vibelog-pull"})
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read()
        # Uploads the phone sent packed are kept packed, as raw DEFLATE.
        if response.headers.get("x-body-encoding") == "deflate-raw":
            body = zlib.decompress(body, -15)
        return json.loads(body)


def keys(base, token):
    cursor = None
    while True:
        page = call(base, token, "/list" + (f"?cursor={urllib.parse.quote(cursor)}" if cursor else ""))
        yield from page["keys"]
        cursor = page.get("cursor")
        if not cursor:
            return


def folder_for(root, key):
    # u/<model>/<ios>/<app>/<install>/<order>
    _, model, ios, app, install, _ = key.split("/")
    return root / model / ios / app / install


def save(folder, files):
    """A file uploaded again, such as a session log that grew, keeps its longest copy."""
    folder.mkdir(parents=True, exist_ok=True)
    saved = 0
    for item in files:
        name = Path(item["name"]).name
        target = folder / name
        if target.exists() and len(target.read_text(encoding="utf-8", errors="replace")) >= len(item["text"]):
            continue
        target.write_text(item["text"], encoding="utf-8")
        saved += 1
    return saved


def pull(root, delete):
    base, token = settings()
    seen = root / ".pulled"
    pulled = set(seen.read_text().split()) if seen.exists() else set()
    new = 0
    for entry in keys(base, token):
        key = entry["key"]
        if key in pulled and not delete:
            continue
        if key not in pulled:
            upload = call(base, token, "/get?key=" + urllib.parse.quote(key, safe=""))
            saved = save(folder_for(root, key), upload["files"])
            pulled.add(key)
            with open(seen, "a", encoding="utf-8") as log:
                log.write(key + "\n")
            new += 1
            print(f"{key}: {saved} of {len(upload['files'])} files new", flush=True)
        if delete:
            call(base, token, "/delete?key=" + urllib.parse.quote(key, safe=""), method="POST")
    print(f"{new} new uploads", flush=True)


def forget(root, prefix):
    """A tester's request to delete their uploads, by the start of the ID Diagnostics shows."""
    import shutil
    if len(prefix) < 8:
        sys.exit("Give at least the 8 characters Diagnostics shows")
    base, token = settings()
    gone = 0
    for entry in list(keys(base, token)):
        if entry["key"].split("/")[4].startswith(prefix):
            call(base, token, "/delete?key=" + urllib.parse.quote(entry["key"], safe=""), method="POST")
            gone += 1
    for folder in root.glob(f"*/*/*/{prefix}*"):
        shutil.rmtree(folder)
        gone += 1
    print(f"forgot {prefix}: {gone} uploads and folders deleted", flush=True)


def report(root):
    """One section per phone model: its installs, versions, takes and problems."""
    by_model = defaultdict(list)
    for log in sorted(root.glob("*/*/*/*/session_*.log")):
        model, ios, app, install = log.parts[-5:-1]
        by_model[model].append((ios, app, install, read_log.read(str(log))))
    lines = ["# Phones", ""]
    for model in sorted(by_model):
        entries = by_model[model]
        installs = {install for _, _, install, _ in entries}
        takes = [t for *_, s in entries for t in s["takes"] if "frames" in t]
        flagged = [t for *_, s in entries for t in s["takes"] if t["flagged"]]
        # The app only logs a capture setup that left the standard one.
        setups = {s["captureSetup"] or "standard" for *_, s in entries}
        lines += [f"## {model}", "",
                  f"- {len(installs)} install(s), {len(entries)} session(s), "
                  f"iOS {', '.join(sorted({i for i, *_ in entries}))}, app {', '.join(sorted({a for _, a, *_ in entries}))}",
                  f"- Capture setup: {', '.join(sorted(setups))}",
                  f"- Takes: {len(takes)}, of which {len(flagged)} lost frames or failed"]
        codecs = defaultdict(list)
        for t in takes:
            codecs[t.get("format", "?")].append(t)
        for codec, group in sorted(codecs.items()):
            lost = sum(t["lost"] for t in group)
            frames = sum(t["frames"] for t in group)
            lines.append(f"  - {codec}: {len(group)} takes, {lost} of {frames + lost} frames lost")
        kinds = Counter()
        for *_, s in entries:
            for _, text in s["problems"]:
                # Grouped by what happened, without the numbers that differ each time.
                kind = re.sub(r"\b\w+_[0-9a-f]{8}\S*", "<file>", text.split(":")[0])
                kinds[re.sub(r"[0-9][0-9.]*", "#", kind)[:70]] += 1
        if kinds:
            lines.append(f"- Problems: {sum(kinds.values())}")
            lines += [f"  - {kind}: {count}" for kind, count in kinds.most_common()]
        lines.append("")
        for ios, app, install, s in entries:
            lines += ["```", read_log.report(s), "```", ""]
    path = root / "report.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    print(f"report: {path}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--folder", type=Path, default=default_folder())
    parser.add_argument("--delete", action="store_true", help="delete each upload from the service once saved")
    parser.add_argument("--report", action="store_true", help="only write the report")
    parser.add_argument("--forget", metavar="ID", help="delete an install's uploads, on the service and here")
    options = parser.parse_args()
    root = options.folder / "phones"
    root.mkdir(parents=True, exist_ok=True)
    if options.forget:
        forget(root, options.forget)
    elif not options.report:
        pull(root, options.delete)
    report(root)


if __name__ == "__main__":
    main()
