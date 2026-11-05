#!/usr/bin/env python3
"""A test server for VibeLog on a private network. Standard library only.

    python3 tools/test_server.py serve
    python3 tools/test_server.py send status
    python3 tools/test_server.py send set tools peaking,grid
    python3 tools/test_server.py send record 20 --wait
    python3 tools/test_server.py suite tools/suites/heat_paths.json

The phone connects out to `serve`, takes commands and sends files, which land in the results
folder. `send` queues a command from this machine and prints the phone's reply. Traffic is plain
HTTP with a token, so use it on your own network only.
"""
import argparse
import csv
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DEFAULT_PORT = 8765
CHUNK = 1024 * 1024
# Left free on the drive, so a large clip can't fill it.
SPARE_BYTES = 2_000_000_000
# ProRes 422 HQ at full size, with some to spare.
GB_PER_SECOND = 0.18
# Recording stops itself below this.
PHONE_FLOOR_GB = 10


def default_folder():
    """VIBELOG_TEST_FOLDER, then the path in ~/.vibelog_test_folder, then ~/VibeLogTest."""
    chosen = os.environ.get("VIBELOG_TEST_FOLDER")
    saved = Path.home() / ".vibelog_test_folder"
    if not chosen and saved.exists():
        chosen = saved.read_text().strip()
    return Path(chosen) if chosen else Path.home() / "VibeLogTest"


class Link:
    """Commands waiting for the phone, and the phone's replies."""

    def __init__(self, token, folder):
        self.token = token
        self.folder = folder
        self.changed = threading.Condition()
        self.commands = []
        self.replies = {}
        self.next_id = 1
        self.last_seen = 0.0

    def queue(self, command):
        with self.changed:
            command["id"] = self.next_id
            self.next_id += 1
            self.commands.append(command)
            self.changed.notify_all()
            return command["id"]

    def take(self, wait):
        deadline = time.time() + wait
        with self.changed:
            if time.time() - self.last_seen > 60:
                print("phone connected", flush=True)
            self.last_seen = time.time()
            while not self.commands:
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.changed.wait(left)
            return self.commands.pop(0)

    def reply(self, reply):
        with self.changed:
            self.replies[reply["id"]] = reply
            self.changed.notify_all()
        with open(self.folder / "replies.jsonl", "a", encoding="utf-8") as log:
            log.write(json.dumps(reply) + "\n")

    def wait_reply(self, command_id, wait):
        deadline = time.time() + wait
        with self.changed:
            while command_id not in self.replies:
                left = deadline - time.time()
                if left <= 0:
                    return None
                self.changed.wait(left)
            return self.replies.pop(command_id)


def safe_name(name):
    """Keeps an upload inside the results folder."""
    base = os.path.basename(name.replace("\\", "/"))
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,200}", base) or base in ("token", "replies.jsonl"):
        return None
    return base


def make_handler(link):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def allowed(self):
            given = self.headers.get("Authorization", "")
            if hmac.compare_digest(given.encode(), f"Bearer {link.token}".encode()):
                return True
            print(f"refused a wrong token from {self.client_address[0]}", flush=True)
            self.answer(401, {"error": "bad token"})
            return False

        def answer(self, code, body=None):
            data = b"" if body is None else json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            length = int(self.headers.get("Content-Length", 0))
            return self.rfile.read(length)

        def do_GET(self):
            if not self.allowed():
                return
            url = urlparse(self.path)
            query = parse_qs(url.query)
            if url.path == "/next":
                command = link.take(min(float(query.get("wait", ["20"])[0]), 30))
                self.answer(200, command) if command else self.answer(204)
            elif url.path == "/result":
                if not self.client_address[0].startswith("127."):
                    self.answer(403, {"error": "local only"})
                    return
                reply = link.wait_reply(int(query["id"][0]), float(query.get("wait", ["30"])[0]))
                self.answer(200, reply) if reply else self.answer(504, {"error": "no reply from the phone"})
            elif url.path == "/seen":
                self.answer(200, {"seconds_ago": round(time.time() - link.last_seen, 1)})
            else:
                self.answer(404, {"error": "unknown path"})

        def do_POST(self):
            if not self.allowed():
                return
            url = urlparse(self.path)
            if url.path == "/reply":
                link.reply(json.loads(self.body()))
                self.answer(200, {})
            elif url.path == "/upload":
                self.upload(parse_qs(url.query).get("name", [""])[0])
            elif url.path == "/queue":
                if not self.client_address[0].startswith("127."):
                    self.answer(403, {"error": "local only"})
                    return
                self.answer(200, {"id": link.queue(json.loads(self.body()))})
            else:
                self.answer(404, {"error": "unknown path"})

        def upload(self, name):
            length = int(self.headers.get("Content-Length", 0))
            safe = safe_name(name)
            if safe is None:
                self.rfile.read(length)
                self.answer(400, {"error": "bad name"})
                return
            if shutil.disk_usage(link.folder).free < length + SPARE_BYTES:
                print(f"no room for {safe} ({length} bytes) in {link.folder}", flush=True)
                self.close_connection = True
                self.answer(507, {"error": "no room"})
                return
            part = link.folder / (safe + ".part")
            with open(part, "wb") as output:
                left = length
                while left > 0:
                    chunk = self.rfile.read(min(CHUNK, left))
                    if not chunk:
                        break
                    output.write(chunk)
                    left -= len(chunk)
            if left:
                part.unlink(missing_ok=True)
                self.answer(400, {"error": "cut short"})
                return
            part.replace(link.folder / safe)
            print(f"received {safe} ({length} bytes)", flush=True)
            self.answer(200, {})

    return Handler


def local_address():
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        try:
            probe.connect(("10.255.255.255", 1))
            return probe.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def token_for(folder):
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "token"
    if not path.exists():
        path.touch(mode=0o600)
        # Short enough to type on the phone. It only guards a private network.
        path.write_text(f"{secrets.randbelow(10 ** 6):06d}")
    return path.read_text().strip()


def serve(options):
    folder = options.folder
    token = token_for(folder)
    server = ThreadingHTTPServer((options.bind, options.port), make_handler(Link(token, folder)))
    print(f"Server: {local_address()}:{server.server_address[1]}\nToken:  {token}\nFiles:  {folder}", flush=True)
    server.serve_forever()


def call(options, method, path, body=None):
    request = urllib.request.Request(
        f"http://127.0.0.1:{options.port}{path}", method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token_for(options.folder)}"})
    with urllib.request.urlopen(request, timeout=options.timeout + 5) as response:
        return json.loads(response.read() or b"{}")


def command_from(words):
    action, rest = words[0], words[1:]
    if action == "record":
        return {"action": action, "seconds": float(rest[0])}
    if action == "set":
        return {"action": action, "name": rest[0], "value": " ".join(rest[1:])}
    if action in ("sendFile", "applyPreset", "savePreset", "defaultPreset"):
        return {"action": action, "name": " ".join(rest)}
    if action in ("stream", "focusAt"):
        return {"action": action, "value": rest[0]}
    if action == "export":
        # export [file or newest] [look=ACES 2.0;target=sdr;codec=hevc420]
        name = rest[0] if rest and "=" not in rest[0] else "newest"
        value = " ".join(rest[1:] if rest and "=" not in rest[0] else rest)
        return {"action": action, "name": name, "value": value}
    return {"action": action}


def send_once(options, command):
    command_id = call(options, "POST", "/queue", command)["id"]
    return call(options, "GET", f"/result?id={command_id}&wait={options.timeout}")


def send(options):
    command = command_from(options.words)
    try:
        waiting = options.wait and command["action"] == "record"
        previous = send_once(options, {"action": "status"})["values"].get("lastResult") if waiting else None
        reply = send_once(options, command)
        print(json.dumps(reply, indent=2))
        if waiting and reply["ok"]:
            time.sleep(command["seconds"])
            while True:
                reply = send_once(options, {"action": "status"})
                values = reply["values"]
                if values.get("recording") == "false" and values.get("lastResult") != previous:
                    break
                time.sleep(2)
            print(reply["values"].get("lastResult", ""))
    except urllib.error.HTTPError as error:
        sys.exit(f"{error.code}: {error.read().decode()}")
    except urllib.error.URLError as error:
        sys.exit(f"Server not reachable: {error.reason}")


RESULT = re.compile(
    r"(?P<written>[\d.]+) fps written, (?P<frames>\d+) frames, (?P<lost>\d+) lost .*"
    r"capture (?P<capture>[\d.]+) fps fail (?P<failed>\d+) missed (?P<missed>\d+) duplicates (?P<duplicates>\d+)"
    r" .*gpu (?P<gpu>[\d.]+) recent .*copy (?P<copy>[\d.]+) queue (?P<queue>[\d.]+) append (?P<append>[\d.]+)"
    r" draw (?P<draw>[\d.]+) ms, viewfinder yields (?P<yields>\d+)")
HEAT_FIELDS = [
    "time", "label", "thermal", "battery", "fps", "drops", "yields", "gpuMs", "copyMs", "queueMs", "drawMs", "freeGB",
    "distortionCorrection", "efficientWhenHot", "bilinearWhenHot", "appPreview"]
RESULT_FIELDS = ["label", "seconds", "thermal_end", *RESULT.groupindex, "result"]


class Suite:
    """Runs a list of steps from a JSON file. Each step is one of:

        {"set": {"lens": "1x", "tools": "none"}}
        {"take": 20, "label": "ultra wide"}
        {"cool": 30}    stops the stream, waits at least that many minutes and for nominal heat
        {"wait": 5}     seconds
        {"export": {"look": "ACES 2.0", "target": "sdr", "codec": "hevc420"}, "label": "S-Log3"}
                        bakes the newest take in log, as the export screen would

    Results go to suite_*.csv and a reading every 10 seconds to heat_*.csv, in the results folder.
    Exports go to exports_*.csv, and a failed one doesn't stop the suite. At the end the phone
    sends its session log and its own exports.csv, which says which step each failure stopped in.
    """

    GIVE_UP_SECONDS = 300
    EXPORT_GIVE_UP_SECONDS = 900

    def __init__(self, options):
        self.options = options
        stamp = time.strftime("%Y%m%d_%H%M%S")
        self.results = open(options.folder / f"suite_{stamp}.csv", "w", newline="", encoding="utf-8")
        self.heat = open(options.folder / f"heat_{stamp}.csv", "w", newline="", encoding="utf-8")
        self.result_log = csv.DictWriter(self.results, RESULT_FIELDS)
        self.heat_log = csv.DictWriter(self.heat, HEAT_FIELDS, extrasaction="ignore")
        self.result_log.writeheader()
        self.heat_log.writeheader()
        self.stamp = stamp
        self.exports = None
        self.export_log = None
        self.export_counts = {"saved": 0, "failed": 0}

    def ask(self, command):
        """Keeps trying while the phone is away, then stops the suite."""
        deadline = time.time() + self.GIVE_UP_SECONDS
        while True:
            try:
                return send_once(self.options, command)
            except urllib.error.URLError:
                if time.time() > deadline:
                    sys.exit("The phone stopped answering")
                time.sleep(5)

    def status(self, label):
        values = self.ask({"action": "status"})["values"]
        self.heat_log.writerow({**values, "time": time.strftime("%H:%M:%S"), "label": label})
        self.heat.flush()
        return values

    def set_values(self, values):
        for name, value in values.items():
            text = str(value).lower() if isinstance(value, bool) else str(value)
            reply = self.ask({"action": "set", "name": name, "value": text})
            if not reply["ok"]:
                sys.exit(f"{name}: {reply['message']}")
        time.sleep(1)

    def take(self, seconds, label):
        print(f"take: {label}, {seconds} s", flush=True)
        previous = self.status(label).get("lastResult", "")
        reply = self.ask({"action": "record", "seconds": float(seconds)})
        if not reply["ok"]:
            sys.exit(f"{label}: {reply['message']}")
        end = time.time() + seconds
        while time.time() < end:
            time.sleep(min(10, max(end - time.time(), 0.1)))
            self.status(label)
        while True:
            values = self.status(label)
            if values["recording"] == "false" and values.get("lastResult") != previous:
                break
            time.sleep(2)
        result = values.get("lastResult", "")
        parsed = RESULT.search(result)
        row = {"label": label, "seconds": seconds, "thermal_end": values["thermal"], "result": result}
        row.update(parsed.groupdict() if parsed else {})
        self.result_log.writerow(row)
        self.results.flush()
        print(f"  {result[:150]}", flush=True)
        time.sleep(3)

    def export(self, choices, label):
        """Bakes the newest take and waits for it. A failure is written down, not fatal."""
        if self.export_log is None:
            self.exports = open(self.options.folder / f"exports_{self.stamp}.csv", "w", newline="", encoding="utf-8")
            self.export_log = csv.DictWriter(self.exports, ["label", "result", "seconds", "message"])
            self.export_log.writeheader()
        print(f"export: {label}", flush=True)
        started = time.time()
        before = self.status(label).get("exports", "0")
        value = ";".join(f"{name}={text}" for name, text in choices.items())
        reply = self.ask({"action": "export", "name": "newest", "value": value})
        if reply["ok"]:
            deadline = started + self.EXPORT_GIVE_UP_SECONDS
            while True:
                time.sleep(2)
                values = self.status(label)
                if values.get("exports") != before and values.get("exporting") == "false":
                    message = values.get("lastExport", "")
                    result = "saved" if message.startswith("Saved") else "failed"
                    break
                if time.time() > deadline:
                    self.ask({"action": "cancelExport"})
                    message, result = "Gave up waiting, cancelled", "failed"
                    break
        else:
            message, result = reply["message"], "refused"
        self.export_counts["saved" if result == "saved" else "failed"] += 1
        self.export_log.writerow(
            {"label": label, "result": result, "seconds": f"{time.time() - started:.1f}", "message": message})
        self.exports.flush()
        print(f"  {result}: {message[:150]}", flush=True)

    def collect(self):
        """Asks for the phone's own record of the exports, with the reasons for failures."""
        self.ask({"action": "sendLog"})
        reply = self.ask({"action": "sendFile", "name": "exports.csv"})
        if not reply["ok"]:
            print(f"  exports.csv: {reply['message']}", flush=True)
        time.sleep(5)

    def cool(self, minutes):
        print(f"cooling: at least {minutes} minutes and nominal heat", flush=True)
        self.ask({"action": "stream", "value": "off"})
        earliest = time.time() + minutes * 60
        while True:
            values = self.status("cooling")
            if time.time() >= earliest and values["thermal"] == "nominal":
                break
            time.sleep(min(10, max(earliest - time.time(), 10)))
        self.ask({"action": "stream", "value": "on"})
        time.sleep(5)

    def check(self, steps):
        """Stops before anything runs, rather than partway through a long plan."""
        values = self.ask({"action": "status"})["values"]
        if values.get("screen") != "camera":
            sys.exit(f"The phone is on {values.get('screen')}. Return it to the camera screen first")
        if values.get("busy"):
            sys.exit(f"The phone is busy: {values['busy']}")
        needed = sum(step.get("take", 0) for step in steps) * GB_PER_SECOND + PHONE_FLOOR_GB
        if float(values.get("freeGB", 0)) < needed:
            sys.exit(f"The phone needs about {needed:.0f} GB free and has {values.get('freeGB')} GB")

    def run(self, steps):
        self.check(steps)
        for step in steps:
            if "set" in step:
                self.set_values(step["set"])
            elif "take" in step:
                self.take(step["take"], step.get("label", "take"))
            elif "cool" in step:
                self.cool(step["cool"])
            elif "wait" in step:
                time.sleep(step["wait"])
            elif "export" in step:
                self.export(step["export"], step.get("label", "export"))
            else:
                sys.exit(f"Unknown step: {step}")
        print(f"results: {self.results.name}\nheat: {self.heat.name}", flush=True)
        if self.exports:
            self.collect()
            counts = self.export_counts
            print(f"exports: {self.exports.name}, {counts['saved']} saved, {counts['failed']} failed", flush=True)


def suite(options):
    Suite(options).run(json.loads(Path(options.plan).read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--folder", type=Path, default=default_folder())
    commands = parser.add_subparsers(dest="mode", required=True)
    serving = commands.add_parser("serve")
    serving.add_argument("--bind", default="0.0.0.0")
    serving.set_defaults(run=serve)
    sending = commands.add_parser("send")
    sending.add_argument("words", nargs="+")
    sending.add_argument("--wait", action="store_true", help="after record, wait for the take to end")
    sending.add_argument("--timeout", type=float, default=30)
    sending.set_defaults(run=send)
    suiting = commands.add_parser("suite")
    suiting.add_argument("plan", type=Path)
    suiting.add_argument("--timeout", type=float, default=30)
    suiting.set_defaults(run=suite)
    options = parser.parse_args()
    options.run(options)


if __name__ == "__main__":
    main()
