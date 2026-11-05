#!/usr/bin/env python3
"""Writes the SideStore source for one build, read from the IPA itself. Standard library only.

    python3 tools/sidestore_source.py dist/VibeLog.ipa --download URL --source URL --notes TEXT > source.json

CI runs it after each build of main and puts the source and the IPA on the `sidestore` release, so
SideStore on the phone sees each new build as an update. The privacy list comes from the app's
Info.plist, because SideStore refuses an app that asks for more than its source declares.
"""
import argparse
import json
import plistlib
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ICON = "https://raw.githubusercontent.com/JoonaKumpulainen/VibeLog/main/tools/sidestore/icon.png"


def app_info(ipa):
    with zipfile.ZipFile(ipa) as archive:
        name = next(n for n in archive.namelist() if n.count("/") == 2 and n.endswith(".app/Info.plist"))
        return plistlib.loads(archive.read(name))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--download", required=True, help="where the phone downloads the IPA")
    parser.add_argument("--source", required=True, help="where this source is served")
    parser.add_argument("--notes", default="")
    options = parser.parse_args()

    info = app_info(options.ipa)
    privacy = {key: value for key, value in info.items() if key.startswith("NS") and key.endswith("UsageDescription")}
    version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info["CFBundleVersion"],
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": options.notes,
        "downloadURL": options.download,
        "size": options.ipa.stat().st_size,
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    source = {
        "name": "VibeLog",
        "identifier": info["CFBundleIdentifier"] + ".source",
        "sourceURL": options.source,
        "iconURL": ICON,
        "apps": [{
            "name": info.get("CFBundleDisplayName", "VibeLog"),
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "JoonaKumpulainen",
            "subtitle": "RAW log video for iPhone 14 Pro",
            "localizedDescription": "Records 12 MP RAW frames as log video in ProRes or HEVC, built by CI from main.",
            "iconURL": ICON,
            "tintColor": "#F2A900",
            "category": "photo-video",
            "versions": [version],
            "appPermissions": {"entitlements": [], "privacy": privacy},
        }],
        "news": [],
    }
    json.dump(source, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
