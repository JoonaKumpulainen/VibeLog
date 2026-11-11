# VibeLog

iPhone 14 Pro camera app that captures 12 MP RAW Bayer frames at up to 30 fps, processes them on the
GPU and records log video in ProRes or HEVC, or a look baked in. The goal is the full quality of the
sensor, and where quality and convenience conflict, quality wins.
[docs/findings.md](docs/findings.md) records what's been proven on the phone.

See [ROADMAP.md](ROADMAP.md) for the plan. Working on it with an AI agent? Start with
[AGENTS.md](AGENTS.md).

## Install on the phone

### With SideStore

Each build of `main` that passes CI goes to the `sidestore` release, with a SideStore source beside
it.

1. Set up SideStore on the phone, following its own guide.
2. In SideStore, open **Sources**, tap **+**, and add
   `https://raw.githubusercontent.com/JoonaKumpulainen/VibeLog/sidestore-source/source.json`.
3. Open VibeLog in that source and tap **Free** to install it.
4. Trust your Apple ID and turn on Developer Mode as in step 4 below, then open VibeLog and allow
   camera access.

New builds then show under **My Apps** as updates, versioned `0.1.<CI run>`. SideStore refreshes
the 7-day signature by itself while its own connection works.

### By hand

1. Open the repo's **Actions** tab, then the latest green **Build unsigned IPA** run.
2. Under **Artifacts**, download `VibeLog-unsigned-ipa` and unzip it to get `VibeLog-unsigned.ipa`.
3. Install it with one of these:
   - **Sideloadly** (Windows/macOS): connect the iPhone by USB, drag in the `.ipa`, enter your Apple
     ID, click **Start**.
   - **AltStore**: install AltServer and AltStore, then in AltStore open **My Apps**, tap **+**, and
     pick the `.ipa`.
4. On the phone, enable **Settings > Privacy & Security > Developer Mode** and restart if iOS asks.
   Then trust your Apple ID under **Settings > General > VPN & Device Management**.
5. Open VibeLog and allow camera access.

A free Apple ID signature lasts 7 days, so repeat step 3 when the app stops opening. Reinstalling
keeps Documents as long as the bundle ID stays the same.

## Using it

Turn the ring/silent switch to silent first, then open VibeLog: the camera starts live.
[docs/using.md](docs/using.md) walks through the camera screen, looks, export, settings,
recording limits and where files go.

## Project layout

| Target | Role |
|---|---|
| `Modules/VLCore` | Frames, stats, DNG tag reader, logging, device status |
| `Modules/VLCapture` | Session, capture methods, manual controls, audio, probe |
| `Modules/VLProcessing` | Log curves, color math, Metal pipeline, looks and the ACES ports, export with look, still export |
| `Modules/VLRecording` | RAW dump writer, video encoder, encoder benchmark |
| `Modules/ObjCGuard` | Catches AVFoundation's Objective-C exceptions, runtime scan |
| `App` | SwiftUI UI, overlay and wiring |

`project.yml` is the XcodeGen spec. CI generates the Xcode project, runs the unit tests on a
simulator, builds the unsigned app, and packages the `.ipa`.

## Limits

CI proves the code compiles and the file, stats and DNG parsing logic works. Nothing touching the
camera has run until it runs on a phone.

## License

Copyright (C) 2026 JoonaKumpulainen

VibeLog is free software under the [GNU General Public License v3.0](LICENSE). You can use, change
and share it, and anyone who distributes a modified version must share its source under the same
license. It comes with no warranty, to the extent the law allows, as the license sets out in
sections 15 and 16. Check important footage before relying on it.

### Third-party code

VibeLog carries two ports of other projects' code. Their licenses are in [LICENSES](LICENSES),
[NOTICE](NOTICE) lists what was changed, and the app shows the same texts under **Settings > About >
Legal**, since these licenses ask for their notices to travel with the app.

| Part | Ported from | License |
|---|---|---|
| ACES 2.0 look, `Modules/VLProcessing/ACES2.swift` | OpenColorIO's ACES 2.0 output transform, `src/OpenColorIO/ops/fixedfunction/ACES2` at commit `22dd9c4faa`. Copyright Contributors to the OpenColorIO Project. | [BSD 3-Clause](LICENSES/OpenColorIO-BSD-3-Clause.txt) |
| The ACES 2.0 algorithm it implements | The Academy Color Encoding System 2.0 output transform, `ampas/aces-core`. | [Apache License 2.0](LICENSES/ACES-Apache-2.0.txt) |
| ACES 1.3 look, `Modules/VLProcessing/ACES13.swift` | The Academy's ACES 1.3 reference CTL, `ampas/aces-dev` tag `v1.3.1`. Copyright © 2015 Academy of Motion Picture Arts and Sciences (A.M.P.A.S.). Portions contributed by others as indicated. All rights reserved. | [License Terms for ACES Components](LICENSES/ACES-1.3-AMPAS.txt) |

These licenses are permissive. The BSD 3-Clause and Apache 2.0 licenses are compatible with GPLv3,
and the Academy's license is a BSD-style license that allows copying, changing and redistributing
with its notice, conditions and disclaimer kept. None of them lets VibeLog use the names of the
Academy, the OpenColorIO Project or their contributors to endorse or promote it. This is the
project's reading of the terms, not legal advice.

`tools/make_aces_reference.py` writes the reference values the tests compare against, using
OpenColorIO 2.6's built-in ACES configs. OpenColorIO isn't part of the app.

### Data and formulas

Log curves and color spaces follow their makers' published formulas and primaries. The constants
were checked against colour-science, whose code isn't included. LUTs you import stay under their own
licenses, and VibeLog doesn't ship any camera maker's LUTs.

### Trademarks and affiliation

Apple, iPhone, Apple Log and ProRes are trademarks of Apple Inc. ACES is a trademark of the Academy
of Motion Picture Arts and Sciences. Sony, ARRI and Canon, and the names of their log curves and
color spaces, such as S-Log2, S-Log3, S-Gamut3.Cine, LogC3, LogC4, ARRI Wide Gamut, Canon Log 3 and
Cinema Gamut, may be trademarks of their owners. Gyroflow belongs to the Gyroflow project, DaVinci
Resolve to Blackmagic Design, and other names to their owners. They're used only to say what
VibeLog works with.

VibeLog is an independent project. It isn't affiliated with, endorsed by or certified by Apple,
Sony, ARRI, Canon, the Academy of Motion Picture Arts and Sciences, the Academy Software Foundation,
the OpenColorIO Project, the Gyroflow project or Blackmagic Design. Its ACES looks are its own
implementation, checked against OpenColorIO's output, and it isn't an ACES Logo product. Its
stabilization is its own too, and carries none of Gyroflow's code: the gyro logs and lens profiles
it writes only follow the file formats Gyroflow reads.
