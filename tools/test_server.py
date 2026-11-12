#!/usr/bin/env python3
"""A test server for VibeLog on a private network. Standard library only.

    python3 tools/test_server.py serve
    python3 tools/test_server.py send status
    python3 tools/test_server.py send set tools peaking,grid
    python3 tools/test_server.py send record 20 --wait
    python3 tools/test_server.py suite tools/suites/heat_paths.json
    python3 tools/test_server.py round tools/rounds/2026-11-13.json

The phone connects out to `serve`, takes commands and sends files, which land in the results
folder. `send` queues a command from this machine and prints the phone's reply. Traffic is plain
HTTP with a token, so use it on your own network only.

    python3 tools/test_server.py serve --public
    ngrok http 8765

`--public` is for a phone elsewhere, through a tunnel such as ngrok that ends HTTPS on this
machine. It listens on this machine only, gives the tunnel its own long token, refuses commands
and replies that came through a tunnel, and locks out a sender after a few wrong tokens. See
docs/test-link.md before using it.
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
import subprocess
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


# Wrong tokens a sender may give before it's locked out, and for how long.
LOCKOUT_TRIES = 5
LOCKOUT_SECONDS = 15 * 60

# Headers a proxy or tunnel adds. Their presence means the request came from outside, whatever
# address it arrives from: ngrok's agent connects from 127.0.0.1.
FORWARDED_HEADERS = ("X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "Forwarded")


class Link:
    """Commands waiting for the phone, and the phone's replies."""

    def __init__(self, token, folder, public_token=None):
        self.token = token
        # With --public, what a phone through the tunnel must give. The short token then only
        # works for requests made on this machine itself.
        self.public_token = public_token
        self.failures = {}
        self.locked = {}
        self.guard = threading.Lock()
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
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,200}", base) or base in ("token", "public_token", "replies.jsonl"):
        return None
    return base


def make_handler(link):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def forwarded(self):
            return any(self.headers.get(name) for name in FORWARDED_HEADERS)

        def sender(self):
            """Who sent it. For a tunnelled request, the last forwarded address, the one the tunnel
            added itself: earlier ones are whatever the sender wrote, and could dodge a lockout."""
            if self.forwarded():
                chain = self.headers.get("X-Forwarded-For", "") or self.headers.get("Forwarded", "")
                return "via tunnel " + (chain.split(",")[-1].strip() or "unknown")
            return self.client_address[0]

        def local(self):
            """Made on this machine, not through a tunnel that also connects from 127.0.0.1."""
            return self.client_address[0].startswith("127.") and not self.forwarded()

        def allowed(self):
            sender = self.sender()
            now = time.time()
            with link.guard:
                if link.locked.get(sender, 0) > now:
                    locked = True
                else:
                    link.locked.pop(sender, None)
                    locked = False
            if locked:
                self.answer(429, {"error": "locked out"})
                return False
            given = self.headers.get("Authorization", "").encode()
            # Through a tunnel, only the long token works.
            expected = link.public_token if (link.public_token and self.forwarded()) else link.token
            if hmac.compare_digest(given, f"Bearer {expected}".encode()):
                with link.guard:
                    link.failures.pop(sender, None)
                return True
            with link.guard:
                count = link.failures.get(sender, 0) + 1
                link.failures[sender] = count
                if count >= LOCKOUT_TRIES:
                    link.failures.pop(sender, None)
                    link.locked[sender] = now + LOCKOUT_SECONDS
            print(f"refused a wrong token from {sender}"
                  + (f", locked out for {LOCKOUT_SECONDS // 60} minutes" if count >= LOCKOUT_TRIES else ""), flush=True)
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
                if not self.local():
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
                if not self.local():
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


def public_token_for(folder):
    """A long token for a phone through a tunnel, kept beside the short one. Typed once, or pasted."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "public_token"
    if not path.exists():
        path.touch(mode=0o600)
        path.write_text(secrets.token_hex(16))
    return path.read_text().strip()


def serve(options):
    folder = options.folder
    token = token_for(folder)
    if options.public:
        public = public_token_for(folder)
        # The tunnel's agent connects from this machine, so nothing else needs to reach the server.
        bind = "127.0.0.1" if options.bind == "0.0.0.0" else options.bind
        server = ThreadingHTTPServer((bind, options.port), make_handler(Link(token, folder, public)))
        print(f"Public mode: listening on {bind}:{server.server_address[1]} for a tunnel only\n"
              f"Start the tunnel:  ngrok http {server.server_address[1]}\n"
              f"On the phone, enter the tunnel's https:// address and this token:\n"
              f"Token:  {public}\nFiles:  {folder}\n"
              "Anyone with the address and token can run tests and fetch files and stills.\n"
              "Stop the tunnel and this server (Ctrl+C) as soon as testing ends.", flush=True)
    else:
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
        {"take": 600, "gbPerSecond": 0.03}   a take's storage rate, when it isn't ProRes 422 HQ's
        {"wait": 5}     seconds
        {"export": {"look": "ACES 2.0", "target": "sdr", "codec": "hevc420"}, "label": "S-Log3"}
                        bakes the newest take in log, as the export screen would

    A round (`round` instead of `suite`) also takes these, and writes round_*.md with each check:

        {"needs": "0.1.117"}    the oldest app version the round works with
        {"take": 10, "expect": {"lost": "<=2", "written": ">=29.5"}}
        {"export": {...}, "expect": {"result": "saved"}}
        {"fetch": ["take", "take.gcsv", "take.json", "copy", "copy.json"]}
                        fetches the newest take and export, and their files, unless already here
        {"export": {...}, "of": "take"}   exports the round's own take, as a baked take needs
        {"same": ["preset"]}    the copy's sidecar must match the take's in these fields
        {"levels": "no FX"}     the newest copy's dark end, kept under that name, which is then
        {"levels": "grain", "against": "no FX", "expect": {"darkLift": "<=2"}}   compared
        {"measure": {"copy": true}, "expect": {"copy.keeps.x": "<=0.4"}}
                        runs tools/measure_steady.py on the fetched take, and its copy
        {"log": true, "expect": {"flaggedTakes": 0, "pausedAfterReturn": 0}}
                        fetches the session log and sums it up with tools/read_log.py
        {"use": "video_20261112_000714.mov"}   makes a take already on the phone the round's take
        {"pause": "Walk slowly with the phone"}   waits for Enter here, for what needs a person
        {"ask": "Did the shadows stay as dark?"}  a question for a person, listed in the report
        {"status": {"encoderLimits": "~proven by takes"}}   checks the phone's status reply;
                        "~text" means it contains the text

    A round puts back every setting it changed when it ends, even after a failure.

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
        self.round = getattr(options, "round", False)
        self.checks = []        # (label, verdict, detail) for the report
        self.blocks = []        # (title, text) of tool output for the report
        self.questions = []
        self.original = {}      # each setting's value before the round changed it
        self.last_take = ""
        self.last_copy = ""

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

    def set_values(self, values, restoring=False):
        if self.round and not restoring:
            current = self.ask({"action": "status"})["values"]
            for name in values:
                if name not in self.original and name in current:
                    self.original[name] = current[name]
        for name, value in values.items():
            text = str(value).lower() if isinstance(value, bool) else str(value)
            reply = self.ask({"action": "set", "name": name, "value": text})
            if not reply["ok"]:
                if restoring:
                    print(f"  couldn't put back {name} = {text}: {reply['message']}", flush=True)
                    continue
                sys.exit(f"{name}: {reply['message']}")
        time.sleep(1)

    def take(self, seconds, label, expect=None):
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
        self.last_take = values.get("lastTake", "")
        print(f"  {self.last_take} {result[:150]}", flush=True)
        if expect:
            self.expect(label, {k: v for k, v in row.items() if v is not None}, expect)
        time.sleep(3)

    def export(self, choices, label, expect=None, of="newest"):
        """Bakes the newest take and waits for it. A failure is written down, not fatal."""
        if self.export_log is None:
            self.exports = open(self.options.folder / f"exports_{self.stamp}.csv", "w", newline="", encoding="utf-8")
            self.export_log = csv.DictWriter(self.exports, ["label", "result", "seconds", "message"])
            self.export_log.writeheader()
        print(f"export: {label}", flush=True)
        started = time.time()
        before = self.status(label).get("exports", "0")
        value = ";".join(f"{name}={text}" for name, text in choices.items())
        name = self.file_name(of) if of != "newest" else "newest"
        reply = self.ask({"action": "export", "name": name, "value": value})
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
        if message.startswith("Saved as "):
            self.last_copy = message[len("Saved as "):].split()[0]
        if expect:
            self.expect(label, {"result": result, "message": message, "seconds": time.time() - started}, expect)
        # The camera stops for an export and needs a moment to start again.
        time.sleep(3)

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

    def expect(self, label, values, expectations):
        """Judges each expectation, prints it and keeps it for the report."""
        for key, wanted in expectations.items():
            actual = values
            for part in key.split("."):
                actual = actual.get(part) if isinstance(actual, dict) else None
            passed = judge(actual, wanted)
            verdict = "PASS" if passed else "FAIL" if passed is False else "?"
            shown = f"{actual:.3g}" if isinstance(actual, float) else actual
            detail = f"{key} {wanted} : {shown}"
            self.checks.append((label, verdict, detail))
            print(f"  {verdict} {detail}", flush=True)

    LENS_FILES = {"0.5x": "back-ultrawide", "1x": "back-wide", "2x": "back-wide", "3x": "back-tele"}

    def file_name(self, what):
        """take, take.gcsv, take.json, copy, copy.json, lens (the take's lens profile), or a name as
        it is."""
        if what == "lens":
            meta = json.loads((self.options.folder / self.file_name("take.json")).read_text())
            lens = self.LENS_FILES.get(meta.get("metadata", {}).get("lens", ""), "back-wide")
            return f"{lens}-4032x3024.json"
        base, _, kind = what.partition(".")
        name = {"take": self.last_take, "copy": self.last_copy}.get(base)
        if name is None:
            return what
        if not name:
            sys.exit(f"No {base} to fetch yet")
        if kind == "gcsv":
            return str(Path(name).with_suffix(".gcsv"))
        if kind == "json":
            return name + ".json"
        return name

    def fetch(self, names, give_up_minutes=45):
        """Fetches each file unless it's already in the results folder, and waits for it. Over USB
        when the phone is plugged in here, about a hundred times faster, else over the link."""
        for what in names:
            name = self.file_name(what)
            target = self.options.folder / name
            if target.exists():
                print(f"fetch: {name} is already here", flush=True)
                continue
            if usb_pull(self.options.folder, name):
                print(f"fetch: {name}, over USB", flush=True)
                continue
            print(f"fetch: {name}", flush=True)
            reply = self.ask({"action": "sendFile", "name": name})
            if not reply["ok"]:
                self.checks.append((f"fetch {name}", "FAIL", reply["message"]))
                print(f"  {reply['message']}", flush=True)
                continue
            deadline = time.time() + give_up_minutes * 60
            part = self.options.folder / (name + ".part")
            while not target.exists():
                if time.time() > deadline:
                    sys.exit(f"{name} didn't arrive in {give_up_minutes} minutes")
                if part.exists():
                    print(f"  {part.stat().st_size / 1e6:.0f} MB so far", end="\r", flush=True)
                time.sleep(5)
            print(f"  received {name}" + " " * 20, flush=True)

    def tool(self, script, arguments, label):
        """Runs one of the analysis tools, keeps its report and returns its figures."""
        # Letters, digits and dashes only: a label's ':' isn't allowed on every drive.
        safe = re.sub(r"[^A-Za-z0-9-]+", "_", label).strip("_")
        output = self.options.folder / f"{safe}_{self.stamp}.json"
        command = [sys.executable, str(Path(__file__).with_name(script)), *arguments, "--json", str(output)]
        print(f"{script}: {label}", flush=True)
        run = subprocess.run(command, capture_output=True, text=True)
        notes = "\n".join(line for line in run.stderr.splitlines() if not line.startswith("Reading "))
        text = (run.stdout + ("\n" + notes if notes else "")).strip()
        print("\n".join("  " + line for line in text.splitlines()), flush=True)
        self.blocks.append((label, text))
        return json.loads(output.read_text()) if output.exists() else {}

    def measure(self, step):
        take = self.options.folder / self.file_name("take")
        arguments = [str(take), "--lenses", str(self.options.folder)]
        if step["measure"].get("copy"):
            arguments += ["--copy", str(self.options.folder / self.file_name("copy"))]
        label = step.get("label", "measure " + take.stem)
        figures = self.tool("measure_steady.py", arguments, label)
        if "expect" in step:
            self.expect(label, figures, step["expect"])

    def read_session_log(self, step):
        asked = time.time()
        self.ask({"action": "sendLog"})
        deadline = asked + 120
        while True:
            logs = [p for p in self.options.folder.glob("session_*.log") if p.stat().st_mtime >= asked - 2]
            if logs or time.time() > deadline:
                break
            time.sleep(2)
        if not logs:
            self.checks.append(("session log", "FAIL", "it didn't arrive"))
            return
        log = max(logs, key=lambda p: p.stat().st_mtime)
        label = step.get("label", "session log")
        summary = self.tool("read_log.py", [str(log)], label)
        figures = {
            "flaggedTakes": sum(1 for t in summary.get("takes", []) if t.get("flagged")),
            "problems": len(summary.get("problems", [])),
            "pausedAfterReturn": sum(1 for r in summary.get("returns", []) if r.get("pausedAfter") is not None),
            "returns": len(summary.get("returns", [])),
            "drags": len(summary.get("drags", [])),
            "app": summary.get("app"),
        }
        if "expect" in step:
            self.expect(label, figures, step["expect"])

    def levels(self, step):
        """The copy's darkest tenth and darkest pixel, in 8-bit codes, averaged over two frames a
        second, from ffmpeg's signalstats."""
        name = self.file_name("copy")
        self.fetch(["copy"])
        run = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(self.options.folder / name), "-vf",
             "fps=2,format=yuv420p,signalstats,metadata=print:file=-", "-f", "null", "-"],
            capture_output=True, text=True)
        readings = {"YLOW": [], "YMIN": [], "YAVG": []}
        for line in run.stdout.splitlines():
            key, _, value = line.partition("=")
            key = key.rsplit(".", 1)[-1]
            if key in readings:
                readings[key].append(float(value))
        if not readings["YLOW"]:
            self.checks.append((f"levels {step['levels']}", "FAIL", f"ffmpeg read nothing from {name}"))
            return
        figures = {key.lower(): sum(v) / len(v) for key, v in readings.items()}
        if not hasattr(self, "level_sets"):
            self.level_sets = {}
        self.level_sets[step["levels"]] = figures
        print(f"levels {step['levels']}: {name} darkest tenth {figures['ylow']:.1f}, darkest {figures['ymin']:.1f}, "
              f"mean {figures['yavg']:.1f}", flush=True)
        if "against" in step:
            base = self.level_sets.get(step["against"])
            if base:
                figures["darkLift"] = figures["ylow"] - base["ylow"]
                figures["blackLift"] = figures["ymin"] - base["ymin"]
        if "expect" in step:
            self.expect(step.get("label", f"levels {step['levels']}"), figures, step["expect"])

    def same(self, fields, label):
        take = json.loads((self.options.folder / self.file_name("take.json")).read_text())
        copy = json.loads((self.options.folder / self.file_name("copy.json")).read_text())
        for field in fields:
            a, b = take.get(field, take.get("metadata", {}).get(field)), copy.get(field, copy.get("metadata", {}).get(field))
            verdict = "PASS" if a == b else "FAIL"
            self.checks.append((label, verdict, f"{field}: take {a}, copy {b}"))
            print(f"  {verdict} {field}: take {a}, copy {b}", flush=True)

    def needs(self, version):
        have = self.ask({"action": "status"})["values"].get("app", "")
        if not have or version_tuple(have) < version_tuple(version):
            sys.exit(f"This round needs VibeLog {version} or later; the phone has {have or 'an older one'}")
        print(f"app {have}", flush=True)

    def restore(self):
        if self.original:
            print("putting back: " + ", ".join(f"{k} = {v}" for k, v in self.original.items()), flush=True)
            self.set_values(self.original, restoring=True)

    def write_report(self, plan):
        path = self.options.folder / f"round_{self.stamp}.md"
        passed = sum(1 for _, v, _ in self.checks if v == "PASS")
        failed = sum(1 for _, v, _ in self.checks if v == "FAIL")
        lines = [f"# Round {plan}, {self.stamp}", "", f"{passed} passed, {failed} failed.", ""]
        if self.checks:
            lines += ["| Step | Verdict | Detail |", "|---|---|---|"]
            lines += [f"| {label} | {verdict} | {detail} |" for label, verdict, detail in self.checks]
            lines.append("")
        if self.questions:
            lines += ["## For a person", ""] + [f"- {q}" for q in self.questions] + [""]
        for title, text in self.blocks:
            lines += [f"## {title}", "", "```", text, "```", ""]
        path.write_text("\n".join(lines), encoding="utf-8")
        print(f"report: {path}\n{passed} passed, {failed} failed", flush=True)

    def step(self, step):
        if "needs" in step:
            pass
        elif "set" in step:
            self.set_values(step["set"])
        elif "take" in step:
            self.take(step["take"], step.get("label", "take"), step.get("expect"))
        elif "cool" in step:
            self.cool(step["cool"])
        elif "wait" in step:
            time.sleep(step["wait"])
        elif "export" in step:
            self.export(step["export"], step.get("label", "export"), step.get("expect"), step.get("of", "newest"))
        elif "fetch" in step:
            self.fetch(step["fetch"])
        elif "levels" in step:
            self.levels(step)
        elif "same" in step:
            self.same(step["same"], step.get("label", "sidecars"))
        elif "measure" in step:
            self.measure(step)
        elif "log" in step:
            self.read_session_log(step)
        elif "use" in step:
            self.last_take = step["use"]
            print(f"take: {self.last_take}, already on the phone", flush=True)
        elif "pause" in step:
            if getattr(self.options, "go", 0):
                # The person said the phone is ready, so the steps run without waiting for Enter.
                print(f"\n>>> {step['pause']}\n    Going on in {self.options.go} s.", flush=True)
                time.sleep(self.options.go)
            else:
                input(f"\n>>> {step['pause']}\n    Press Enter when done. ")
        elif "status" in step:
            values = self.ask({"action": "status"})["values"]
            for key, wanted in step["status"].items():
                actual = values.get(key)
                if isinstance(wanted, str) and wanted.startswith("~"):
                    passed = actual is not None and wanted[1:] in actual
                    verdict = "PASS" if passed else "FAIL"
                    self.checks.append((step.get("label", "status"), verdict, f"{key} contains {wanted[1:]!r} : {actual}"))
                    print(f"  {verdict} {key} contains {wanted[1:]!r} : {actual}", flush=True)
                else:
                    self.expect(step.get("label", "status"), values, {key: wanted})
        elif "ask" in step:
            self.questions.append(step["ask"])
            print(f"for a person: {step['ask']}", flush=True)
        else:
            sys.exit(f"Unknown step: {step}")

    def check(self, steps):
        """Stops before anything runs, rather than partway through a long plan."""
        values = self.ask({"action": "status"})["values"]
        if values.get("screen") != "camera":
            sys.exit(f"The phone is on {values.get('screen')}. Return it to the camera screen first")
        if values.get("busy"):
            sys.exit(f"The phone is busy: {values['busy']}")
        # ProRes 422 HQ's rate, unless a take says its own, as a baked HEVC take's 0.03 GB a second.
        needed = sum(step.get("take", 0) * step.get("gbPerSecond", GB_PER_SECOND) for step in steps) + PHONE_FLOOR_GB
        if float(values.get("freeGB", 0)) < needed:
            sys.exit(f"The phone needs about {needed:.0f} GB free and has {values.get('freeGB')} GB")

    def run(self, steps, plan=""):
        for step in steps:
            if "needs" in step:
                self.needs(step["needs"])
        self.check(steps)
        try:
            for step in steps:
                self.step(step)
        finally:
            if self.round:
                self.restore()
                self.write_report(plan)
        print(f"results: {self.results.name}\nheat: {self.heat.name}", flush=True)
        if self.exports:
            self.collect()
            counts = self.export_counts
            print(f"exports: {self.exports.name}, {counts['saved']} saved, {counts['failed']} failed", flush=True)


def usb_tool():
    """pymobiledevice3, from its own environment or the PATH, or None."""
    for candidate in (Path.home() / ".venvs/imobile/bin/pymobiledevice3", shutil.which("pymobiledevice3")):
        if candidate and Path(candidate).exists():
            return str(candidate)
    return None


def usb_pull(folder, name):
    """Copies a file from the app's Documents over USB, when the phone is plugged in and trusted.
    The app's bundle ID, which SideStore changes, is read from usb_app_id in the results folder,
    kept out of the repo. Returns whether the file arrived."""
    tool, id_file = usb_tool(), folder / "usb_app_id"
    if not tool or not id_file.exists():
        return False
    bundle = id_file.read_text().strip()
    part = folder / (name + ".usb")
    for where in ("videos", "logs", "probes", "stills", "clips", "lenses", f"lenses/{phone_model(folder)}"):
        result = subprocess.run([tool, "apps", "pull", "--documents", bundle, f"/Documents/{where}/{name}", str(part)],
                                capture_output=True, timeout=1800)
        if result.returncode == 0 and part.exists() and part.stat().st_size > 0:
            part.replace(folder / name)
            return True
        part.unlink(missing_ok=True)
    return False


def phone_model(folder):
    """The phone's model from the newest status reply, for its lens profile folder."""
    try:
        with open(folder / "replies.jsonl", "rb") as log:
            log.seek(max(0, log.seek(0, 2) - 200_000))
            for line in reversed(log.read().decode("utf-8", "replace").splitlines()):
                if '"phone"' in line:
                    return json.loads(line)["values"]["phone"]
    except (OSError, ValueError, KeyError):
        pass
    return "unknown"


def version_tuple(text):
    return tuple(int(part) for part in re.findall(r"\d+", text)[:3])


def judge(actual, wanted):
    """True, False, or None when it can't be judged. wanted is a value, or a string such as
    "<=2", ">=29.5", "<0.4", "==saved" or "!=0"."""
    if actual is None:
        return None
    match = re.fullmatch(r"\s*(<=|>=|==|!=|<|>)\s*(.+)", str(wanted)) if isinstance(wanted, str) else None
    op, target = (match.group(1), match.group(2)) if match else ("==", wanted)
    try:
        a, b = float(actual), float(target)
    except (TypeError, ValueError):
        a, b = str(actual), str(target)
    return {"<=": a <= b, ">=": a >= b, "<": a < b, ">": a > b, "==": a == b, "!=": a != b}[op]


def suite(options):
    Suite(options).run(json.loads(Path(options.plan).read_text()), options.plan.stem)


def round_(options):
    options.round = True
    suite(options)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--folder", type=Path, default=default_folder())
    commands = parser.add_subparsers(dest="mode", required=True)
    serving = commands.add_parser("serve")
    serving.add_argument("--bind", default="0.0.0.0")
    serving.add_argument(
        "--public", action="store_true",
        help="for a phone through a tunnel such as ngrok: this machine only, a long token, lockouts")
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
    rounding = commands.add_parser("round", help="a suite that checks results, puts settings back and writes a report")
    rounding.add_argument("plan", type=Path)
    rounding.add_argument("--timeout", type=float, default=30)
    rounding.add_argument("--go", type=int, nargs="?", const=5, default=0, metavar="SECONDS",
                          help="don't wait for Enter at pauses: the phone is ready; count down instead (5 s)")
    rounding.set_defaults(run=round_)
    options = parser.parse_args()
    options.run(options)


if __name__ == "__main__":
    main()
