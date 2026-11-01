# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of the end of Phase 4.

## What this is

An iPhone camera app that records full-sensor RAW frames, processes them on the GPU and encodes log video. The goal is the full quality of the sensor, with the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

- **Repo:** public, GPL-3.0, [JoonaKumpulainen/VibeLog](https://github.com/JoonaKumpulainen/VibeLog), branch `main`.
- **Test phone:** iPhone 14 Pro (`iPhone15,2`), iOS 27.2.

## How we work

- **No Mac:** the owner cannot build locally, and this Linux machine has no Swift or Xcode. Every build runs on GitHub Actions (`macos-15`, Xcode 16.4), and pushes to `main` trigger it. `.md` changes don't build.
- **Project file:** XcodeGen generates it from `project.yml`. Never hand-write a `.pbxproj`.
- **After each code change:** push, wait for CI with `gh run watch`, and read the logs until it's green. Then download the artifact with `gh run download` and send the `.ipa` to the owner.
- **Reading CI logs:** the test step only keeps its last 60 lines. Use `gh run view <id> --log-failed` and look under `Testing failed:`. The `Executed N tests` line shows totals, including skips.
- **Install:** the owner sideloads the unsigned `.ipa` with a free Apple ID, using Sideloadly. Don't add anything needing a paid account or special entitlements.
- **Evidence:** camera behavior is only proven by the phone. Results come back as `logs/session_*.log`, JSON sidecars, screenshots and the owner's observations. Say exactly what to test and what to send. Never claim camera behavior works from CI alone.
- **Screenshots:** taking one during a recording may disturb it, so long tests should run hands-off.
- **Public repo:** keep commits and files free of private details.

## Project layout

| Path | Role |
|---|---|
| `App/` | SwiftUI UI, `AppModel`, `FrameRouter`, overlay, control panel |
| `Modules/VLCore` | Frames, stats, DNG reader, RAW levels, logging, storage, device status, `VideoFrameSink` |
| `Modules/VLCapture` | Session, photo RAW driver, video driver, manual controls, audio, probe |
| `Modules/VLProcessing` | Log curves, color math, monitor LUT, `.cube` parser, Metal pipeline, still export, `Shaders.metal` |
| `Modules/VLRecording` | RAW dump writer, `VideoEncoder`, encoder presets, encoder benchmark |
| `Modules/ObjCGuard` | Catches Objective-C exceptions from AVFoundation, runtime scan |
| `Tests/VLTests` | 47 tests, including real GPU tests on the simulator |
| `tools/inspect_clip.py` | Summarizes a RAW clip and exports a frame |

Modules are dynamic frameworks. Swift is in Swift 5 mode.

## What's proven on the phone

- **RAW source:** `AVCapturePhotoOutput` with the readiness coordinator, zero shutter lag and responsive capture gives 12 MP Bayer (`bgg4`, 14-bit in 16-bit words) at 30 fps. The app fires requests from camera events as well as the coordinator, with a 30 ms minimum gap.
- **Preset:** RAW is listed only under the `.photo` session preset, never `.inputPriority`. That mode is capped at 30 fps, so RAW at 60 fps is not available this way.
- **Video output:** offers no Bayer format under either preset.
- **Levels:** use the photo metadata's `{DNG}` values for the pixel buffer: black 2112, white 16383. The DNG file's tags are a quarter of that scale, so don't apply them to buffers. Highlights really clip at 14271 at ISO 100 and 3000.
- **Exposure:** default is -0.5 stops, from a single measurement.
- **Frame copy:** RAW frames must be copied to GPU memory. Holding camera buffers through a GPU pass correlated with `-12686` photo failures, so zero-copy input is off the table.
- **Main thread:** keep capture timing independent of it. The old overlay timer cost exactly 2 frames per second.
- **Encoding:** ProRes 422 HQ at 4032x3024 is the default, at about 160 MB/s or 9.5 GB per minute. ProRes 4444 held 30 fps for 30 seconds at 240 MB/s. HEVC only just reaches 30 fps at full size.
- **Long run:** 10 minutes at 29.81 fps with 0 encoder drops, with **Reduce load when hot** on. Thermal state reached serious but not critical, and no throttling happened. Without reduced load, the GPU throttled at 5 minutes.
- **Battery:** recording near 1% stalled the encoder, and the same test at 70% was clean. That is strong evidence, from one comparison.
- **Storage:** full RAW dumps need 732 MB/s, but the phone sustains about 420 MB/s after about 8 GB. Encoder drops began at about 8 GB free, so recording stops at 10 GB free. Free space must use `volumeAvailableCapacityKey`; the important-usage figure counts purgeable data.
- **Pipelines:** **Maximum quality** is the default. **Efficient** matches it within one 10-bit code in tests and looked identical to the owner, but one run showed no clear gain, plus more failed photos and memory. It isn't proven better.
- **Features confirmed:** synced audio, 16:9 crop, zebras, false color and `.cube` import with **LUT input**.

## Not verified

- Recording past 10 minutes, or a full 10 minutes in Maximum quality.
- Whether the 8-minute clip played to the end.
- Color accuracy against a chart.
- Whether the exposure default holds across scenes.
- Recording on the ultra wide and tele.
- Crash recovery from the 10-second file fragments.
- What `-12686` and `-16800` mean.
- False color ranges, which are my own choice.
- S-Log3 and LogC3 use Rec.2020, not their native gamuts.

## Next: Phase 5

Redesign the interface to first-party Apple camera standard, as described in the roadmap. The owner agreed to this phase but hasn't yet said to start it. Leave room for the tools in Phases 6 and 7, and keep the capture, processing and encoding code unchanged. The debug overlay, logs and benchmarks must stay reachable in a hidden diagnostics screen, because phone testing depends on them.

Gyro logging to a Gyroflow `.gcsv` is small and cheap, so it's worth adding early.

## Known simulator limits

- Linear textures on shared buffers crash the simulator, so the RAW copy path can only be tested on the phone.
- `blit.synchronize(resource:)` isn't available on iOS.
- There's no camera or microphone, so capture and audio are phone-only.
