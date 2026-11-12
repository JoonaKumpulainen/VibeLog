# VibeLog for agents

Read this first. It's loaded by itself in tools that read `AGENTS.md` or `CLAUDE.md`, and it
points to everything else. New additions follow the design rules in [ROADMAP.md](ROADMAP.md).

## What this is

An iPhone camera app that records full-sensor RAW frames, processes them on the GPU and encodes log
video. The goal is the full quality of the sensor, with the best codecs, color spaces and log curves
the phone can sustain. When quality and convenience conflict, quality wins.

- **Repo:** public, GPL-3.0,
  [JoonaKumpulainen/VibeLog](https://github.com/JoonaKumpulainen/VibeLog), branch `main`.
- **Test phone:** iPhone 14 Pro (`iPhone15,2`), iOS 27.2. A second tester sends logs from an iPhone 16
  (`iPhone17,3`). Fit other phones by the rules in
  [docs/decisions/per-phone-fitting.md](docs/decisions/per-phone-fitting.md).

## How we work

- **No Mac:** the owner cannot build locally, and this Linux machine has no Swift or Xcode. Every
  build runs on GitHub Actions (`macos-26`), and pushes to `main` trigger it. `.md` changes don't
  build.
- **Project file:** XcodeGen generates it from `project.yml`. Never hand-write a `.pbxproj`.
- **After each code change:** ask the owner before committing, pushing or starting a build. Once
  they say so, push, wait for CI with `gh run watch`, and read the logs until it's green. Then
  download the artifact with `gh run download` and send the `.ipa` to the owner. If the owner asks
  for several changes before a build, batch them.
- **Reading CI logs:** the test step only keeps its last 60 lines. Use `gh run view <id>
  --log-failed` and look under `Testing failed:`. The `Executed N tests` line shows totals,
  including skips.
- **Install:** the owner sideloads the unsigned `.ipa` with a free Apple ID, now through SideStore.
  Each green build of `main` goes to the `sidestore` release as `VibeLog.ipa`, versioned `0.1.<CI
  run>` so SideStore sees it as an update,
  and `source.json` goes to the `sidestore-source` branch, which SideStore reads at
  `https://raw.githubusercontent.com/JoonaKumpulainen/VibeLog/sidestore-source/source.json`.
  SideStore gives a source about 3 s, which the release download's redirect missed, hence the
  branch. Sideloadly still works with the CI artifact. Don't add anything needing a paid account or
  special entitlements.
- **Test server:** can also run on the owner's Windows PC, with Python 3 from the Microsoft Store,
  the phone's hotspot as the network and the PC at `172.20.10.4`. The results folder is
  `VibeLogTest` in the owner's home folder.
- **Evidence:** camera behavior is only proven by the phone. Results come back as
  `logs/session_*.log`, JSON sidecars, screenshots and the owner's observations. Say exactly what to
  test and what to send. Never claim camera behavior works from CI alone.
- **Screenshots:** taking one during a recording may disturb it, so long tests should run hands-off.
- **Public repo:** keep commits and files free of private details. `tools/check_secrets.py`
  runs as a pre-commit hook and in CI; in a new clone, turn the hook on with `git config
  core.hooksPath .githooks`. Secrets live outside the repo: `~/.vibelog_logs_secrets.json` (the
  log service's invite codes and owner key), `~/.vibelog_logs` (its address and the owner key)
  and the test server's token files. Never paste their values into files, commits or chat
  output.
- **Privacy:** [PRIVACY.md](PRIVACY.md) is the promise to testers. Any change to what the app
  sends, or where, updates it in the same change.
- **Accessibility:** the owner won't test it, so leave it out of test lists. VoiceOver labels,
  announcements, Increase Contrast and Reduce Motion support were added, and none has been tested.

## Where things are written down

| File | What's in it | When to read it |
|---|---|---|
| [docs/status.md](docs/status.md) | Latest build, last session, what's waiting on the phone, what's next | At the start of every session |
| [docs/next-tests.md](docs/next-tests.md) | Step-by-step phone tests waiting to run, and what to send | When asking for tests, and to rewrite for a new round |
| [docs/findings.md](docs/findings.md) | What the phone has proven, and what isn't verified | Before claiming or testing camera behaviour |
| [docs/how-it-works.md](docs/how-it-works.md) | The camera screen, what presets keep, what may change during a take, encoder failures, the test link for test sessions, simulator limits | Before changing those areas |
| [ROADMAP.md](ROADMAP.md) | Phases and the design rules for new additions | Before adding anything |
| [docs/decisions/](docs/decisions/) | Agreed plans and first designs | When working on what they cover |
| [docs/history/](docs/history/) | Every past session and build, by commit hash | When you need why something is the way it is |
| [docs/using.md](docs/using.md) | How to use the app, for people | When the app's behaviour changes |
| [docs/test-link.md](docs/test-link.md) | The test link's privacy, server and removal | When using or changing the test link |

## At the end of a session

- Rewrite [docs/status.md](docs/status.md): the latest build, what's waiting on the phone and
  what's next. Move the finished session's notes to the month's file in
  [docs/history/](docs/history/), newest at the bottom.
- Move anything the phone proved into [docs/findings.md](docs/findings.md), and take it off
  **Not verified**.
- Rewrite [docs/next-tests.md](docs/next-tests.md) for the tests the new build needs, step by
  step, with what to send.
- Put a new plan or design the owner agreed in [docs/decisions/](docs/decisions/), one file each.
- If the app's behaviour changed, update [docs/using.md](docs/using.md) and the README.
- Keep docs plain and short, wrapped at about 100 columns. `.md` changes don't start a build.

## Project layout

| Path | Role |
|---|---|
| `App/` | SwiftUI UI, `AppModel`, `FrameRouter`, camera screen with the look panel and its ADJUST, COLOR and FX pages, format panel, library, export with its grade editor, Settings, Diagnostics, `DesignTokens`, `Haptics` |
| `Modules/VLCore` | Frames, stats, DNG reader, RAW levels, logging, storage, device status, `VideoFrameSink`, `GyroLog`, `SteadyPath` for stabilized export, `AppConfig`, `CaptureSupport`, `GyroflowProfile`, `LookGrade`, `LookStyle`, `LookEffects` |
| `Modules/VLCapture` | Session, photo RAW driver, video driver, manual controls, audio, `MotionLogger`, probe |
| `Modules/VLProcessing` | Log curves, color math, `GamutPairing`, `.cube` parser, Metal pipeline with `LookParams`, `ACES2.swift`, `ACES13.swift`, `BuiltInLook` with the grade and HDR encodings, `LookExporter`, `LookPlayback`, `LookEffects`, `ScopeMeter`, still export, `Shaders.metal` |
| `Modules/VLRecording` | RAW dump writer, `VideoEncoder`, encoder presets, encoder benchmark, `TakeLibrary` |
| `Modules/ObjCGuard` | Catches Objective-C exceptions from AVFoundation, runtime scan |
| `Tests/VLTests` | 189 tests, including real GPU tests on the simulator |
| `tools/inspect_clip.py` | Summarizes a RAW clip and exports a frame |
| `tools/test_server.py` | The test link's server, which sends the phone commands and collects its files, and runs suites and rounds |
| `tools/rounds/*.json` | A round of phone tests that checks its own results and writes `round_*.md` |
| `tools/measure_steady.py` | Fits a take's motion to its gyro log, and measures what a stabilized copy leaves |
| `tools/read_log.py` | Sums up session logs: takes, exports, stalls, heat, returning to the app, slider drags |
| `tools/log_service/` | The Cloudflare Worker that takes testers' opt-in log uploads; `cf dev`, `cf deploy` |
| `tools/pull_logs.py` | Pulls those uploads, sorted by phone model, into `phones/` and writes `phones/report.md` |
| `tools/sidestore_source.py`, `tools/sidestore/icon.png` | Writes the SideStore source from the built IPA, in CI |
| `tools/suites/export_matrix_1.json`, `_2.json` | Record 2 s in every curve and gamut and export each take |
| `tools/suites/fx_baked.json`, `fx_cost.json`, `scope_cost.json` and others | Long takes that measure what FX and tools cost when hot |

Modules are dynamic frameworks. Swift is in Swift 5 mode.
