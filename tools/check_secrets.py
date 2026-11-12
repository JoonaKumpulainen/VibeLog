#!/usr/bin/env python3
"""Stops secrets and private details from reaching the public repo. Standard library only.

    python3 tools/check_secrets.py            the files staged for commit (the pre-commit hook)
    python3 tools/check_secrets.py --all      every tracked file (CI, and a check by hand)
    python3 tools/check_secrets.py FILE ...   just these

It refuses:

- Files that only ever hold secrets: `.dev.vars`, the test server's `token` and `public_token`,
  `~/.vibelog_logs`-style files, signing keys and profiles.
- Text that looks like a secret: bearer tokens, private keys, Cloudflare API tokens, assignments
  to INVITE_CODES, ADMIN_TOKEN, testToken and the like, ngrok and other tunnel addresses, and
  Cloudflare account IDs in dashboard links.
- On this machine, also the exact values of the real secrets, read from where they're kept:
  ~/.vibelog_logs_secrets.json, ~/.vibelog_logs, the test server's token files, and the Apple
  team ID in the USB fetch's usb_app_id. CI doesn't
  have them, so it relies on the patterns.

A line can be let through with `check-secrets: allow` on it, for an example that only looks like
a secret. Exits 1 with each finding, 0 when clean.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_NAMES = re.compile(
    r"(^|/)(\.dev\.vars|\.env|token|public_token|\.vibelog_logs[^/]*|[^/]*secrets?\.json|"
    r"[^/]*\.(p12|pem|key|mobileprovision|cer))$")
# .dev.vars.example and .env.example are meant to be shared.
ALLOWED_NAMES = re.compile(r"\.example$")

PATTERNS = [
    ("a bearer token", re.compile(r"Bearer\s+[A-Za-z0-9._~+/=-]{20,}")),
    ("a private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("a secret written as a literal", re.compile(
        r"(INVITE_CODES|ADMIN_TOKEN|CLOUDFLARE_API_TOKEN|testToken|public_token|api[_-]?key|token)\"?\s*[=:]\s*"
        r"[\"'](?!local-|test-)[A-Za-z0-9._~+/-]{8,}[\"']", re.IGNORECASE)),
    ("a secret in an env file", re.compile(
        r"^\s*(export\s+)?[A-Z][A-Z0-9_]*(TOKEN|SECRET|KEY|CODES|PASSWORD)\s*=\s*(?!local-|test-|<|\$)[^\s#]{8,}")),
    ("a tunnel address", re.compile(
        r"[A-Za-z0-9-]{6,}\.(ngrok-free\.app|ngrok\.app|ngrok\.io|ngrok-free\.dev|trycloudflare\.com)")),
    ("a Cloudflare account ID in a link", re.compile(r"dash\.cloudflare\.com/[0-9a-f]{32}")),
    ("a GitHub token", re.compile(r"\b(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}")),
]

EXAMPLES = {"abc-123.ngrok-free.app", "5991-2001-f00.ngrok-free.app"}


def default_folder():
    chosen = os.environ.get("VIBELOG_TEST_FOLDER")
    saved = Path.home() / ".vibelog_test_folder"
    if not chosen and saved.exists():
        chosen = saved.read_text().strip()
    return Path(chosen) if chosen else Path.home() / "VibeLogTest"


def local_secrets():
    """The real secrets' values, where this machine keeps them. Short values are skipped, since
    six digits would match too much by chance; the patterns cover how they're written."""
    values = set()

    def take(value):
        for part in str(value).split(","):
            part = part.strip()
            if len(part) >= 8:
                values.add(part)

    for path in (Path.home() / ".vibelog_logs_secrets.json", Path.home() / ".vibelog_logs"):
        try:
            data = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for key, value in data.items():
            if key != "url":
                take(value)
    # SideStore's bundle ID for the USB fetch ends in the owner's Apple team ID.
    try:
        bundle = (default_folder() / "usb_app_id").read_text().strip()
        take(bundle.rsplit(".", 1)[-1])
    except OSError:
        pass
    for name in ("token", "public_token"):
        try:
            take((default_folder() / name).read_text())
        except OSError:
            pass
    return values


def staged_files():
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


def staged_text(path):
    result = subprocess.run(["git", "show", f":{path}"], cwd=ROOT, capture_output=True)
    return result.stdout.decode("utf-8", errors="replace") if result.returncode == 0 else ""


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


def check(path, text, secrets):
    findings = []
    if FORBIDDEN_NAMES.search(path) and not ALLOWED_NAMES.search(path):
        findings.append(f"{path}: a file that holds secrets")
    for number, line in enumerate(text.splitlines(), 1):
        if "check-secrets: allow" in line:
            continue
        for label, pattern in PATTERNS:
            match = pattern.search(line)
            if match and match.group(0) not in EXAMPLES:
                findings.append(f"{path}:{number}: {label}: {match.group(0)[:12]}…")
        for value in secrets:
            if value in line:
                findings.append(f"{path}:{number}: the value of a real secret on this machine")
    return findings


def main():
    arguments = sys.argv[1:]
    if arguments == ["--all"]:
        paths, read = tracked_files(), lambda p: (ROOT / p).read_text(encoding="utf-8", errors="replace")
    elif arguments:
        paths, read = arguments, lambda p: Path(p).read_text(encoding="utf-8", errors="replace")
    else:
        paths, read = staged_files(), staged_text
    secrets = local_secrets()
    findings = []
    for path in paths:
        if path.endswith(("package-lock.json", ".png", ".jpg", ".ipa")):
            continue
        try:
            text = read(path)
        except OSError:
            continue
        findings += check(path, text, secrets)
    if findings:
        print("Secrets or private details would reach the public repo:", file=sys.stderr)
        for finding in findings:
            print("  " + finding, file=sys.stderr)
        print("Remove them, or mark a harmless example line with `check-secrets: allow`.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
