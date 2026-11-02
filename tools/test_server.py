#!/usr/bin/env python3
"""A test server for VibeLog on a private network. Standard library only.

    python3 tools/test_server.py serve
    python3 tools/test_server.py send status
    python3 tools/test_server.py send set tools peaking,grid
    python3 tools/test_server.py send record 20 --wait

The phone connects out to `serve`, takes commands and sends files, which land in the results
folder. `send` queues a command from this machine and prints the phone's reply. Traffic is plain
HTTP with a token, so use it on your own network only.
"""
import argparse
import hmac
import json
import os
import re
import secrets
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
DEFAULT_FOLDER = Path.home() / "VibeLogTest"
CHUNK = 1024 * 1024


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
        path.write_text(secrets.token_urlsafe(16))
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
    if action == "sendFile":
        return {"action": action, "name": rest[0]}
    return {"action": action}


def send_once(options, command):
    command_id = call(options, "POST", "/queue", command)["id"]
    return call(options, "GET", f"/result?id={command_id}&wait={options.timeout}")


def send(options):
    command = command_from(options.words)
    try:
        reply = send_once(options, command)
        print(json.dumps(reply, indent=2))
        if options.wait and reply["ok"] and command["action"] == "record":
            time.sleep(command["seconds"])
            while True:
                reply = send_once(options, {"action": "status"})
                if reply["values"].get("recording") == "false":
                    break
                time.sleep(2)
            print(reply["values"].get("lastResult", ""))
    except urllib.error.HTTPError as error:
        sys.exit(f"{error.code}: {error.read().decode()}")
    except urllib.error.URLError as error:
        sys.exit(f"Server not reachable: {error.reason}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--folder", type=Path, default=DEFAULT_FOLDER)
    commands = parser.add_subparsers(dest="mode", required=True)
    serving = commands.add_parser("serve")
    serving.add_argument("--bind", default="0.0.0.0")
    serving.set_defaults(run=serve)
    sending = commands.add_parser("send")
    sending.add_argument("words", nargs="+")
    sending.add_argument("--wait", action="store_true", help="after record, wait for the take to end")
    sending.add_argument("--timeout", type=float, default=30)
    sending.set_defaults(run=send)
    options = parser.parse_args()
    options.run(options)


if __name__ == "__main__":
    main()
