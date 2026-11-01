# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of the end of Phase 4.

## What this is

An iPhone camera app that records full-sensor RAW frames, processes them on the GPU and encodes log video. The goal is the full quality of the sensor, with the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

- **Repo:** public, GPL-3.0, [JoonaKumpulainen/VibeLog](https://github.com/JoonaKumpulainen/VibeLog), branch `main`.
- **Test phone:** iPhone 14 Pro (`iPhone15,2`), iOS 27.2.

## How we work

- **No Mac:** the owner cannot build locally, and this Linux machine has no Swift or Xcode. Every build runs on GitHub Actions (`macos-26`), and pushes to `main` trigger it. `.md` changes don't build.
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
- **Long run:** 10 minutes at 29.81 fps with 0 encoder drops, with **Keep recording when hot** on. Thermal state reached serious but not critical, and no throttling happened. Without reduced load, the GPU throttled at 5 minutes.
- **Battery:** recording near 1% stalled the encoder, and the same test at 70% was clean. That is strong evidence, from one comparison.
- **Storage:** full RAW dumps need 732 MB/s, but the phone sustains about 420 MB/s after about 8 GB. Encoder drops began at about 8 GB free, so recording stops at 10 GB free. Free space must use `volumeAvailableCapacityKey`; the important-usage figure counts purgeable data.
- **Pipelines:** **Maximum quality** is the default. **Efficient** matches it within one 10-bit code in tests and looked identical to the owner, but one run showed no clear gain, plus more failed photos and memory. It isn't proven better.
- **Features confirmed:** synced audio, 16:9 crop, zebras, false color and `.cube` import with **LUT made for**.

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

## Now: Phase 5

The owner chose the precision instrument layout from `7f836af` as the base: monospaced values around the picture. Every control keeps its portrait position in every hold and only its contents turn, so nothing covers the picture, and 16:9 narrows the picture inside the 4:3 frame unless **Full view** is on. Controls no longer sit in panels or glass: nothing was ever behind the glass except black, so it added cost and no look. Done so far: layout, orientation tagging, snapping dials with a fine mode, and a saved config. The tray above the control bar shows the tools and lenses, a dial or the **MON** tools, so the control bar always stays. **FORMAT** opens a panel of slidable columns over the control zone, for codec, chroma, size, log curve and aspect, and the slider button opens Settings. The config's `toolbar` and `telemetry` fields are no longer used by the app. Takes freeze focus, and exposure and white balance unless **Freeze exposure at start** is off. Status sits in two mirrored three-line blocks beside the Dynamic Island, each square so it can turn, keeping to its outer corner in every hold. Warnings are filled orange chips. In the control bar, amber means set by the user, an A badge means auto and a lock means frozen for the take. Short notices cover the tool row and control bar for a few seconds, and a take that ends early leaves an orange card until dismissed. The clock and drop count take the two columns right of record in every hold, and the clock shows only the digits in use at the largest size that fits. A persistent EV reading shows beside the tools and taps to reset. The thumbnail left of record plays the newest video and stops the stream while it plays. At 16:9 the tool row offers **Full view**, a 699x393 picture that leaves the 4:3 frame with only a strip beneath it; a stopped take leaves it. Switching it five times during a take dropped no frames on the phone. The WB dial also sets tint, and the focus dial has a punch-in button. Punch-in moves where the existing monitor draw samples, so it adds no GPU work: a third of the picture from the full-size image, close to one sensor pixel per drawable pixel in Maximum quality and half that in Efficient. It opens on the last focus point and drags, including during a take. Focus peaking is a `Tool` that marks fine detail in cyan on the monitor, from four extra texture reads per drawable pixel while it's on. Its threshold of 0.1 on log luma is my own choice and its cost during a take isn't measured. Settings is one searchable page ordered by use, with format changes linking to the panel. New additions follow the design rules in [ROADMAP.md](ROADMAP.md). The tray shows a microphone level during a take, once a second as the peak of that second. The volume buttons toggle recording on iOS 18 and later. `CameraGeometry.topShare` sets the picture's top and bottom edges. That share is an estimate of the Camera app's split, not a measurement. Still to do: 24 and 25 fps, library, accessibility and a 10-minute test. Gyro logging to a Gyroflow `.gcsv` follows as its own change once that test passes. Stage 1 is confirmed on the phone. `VLCapture` gained focus and exposure points, exposure compensation and live values for direct control. Other module code is unchanged.

Diagnostics opens with a long press on **Version** in Settings.

## Adjusting the camera while recording

From two 46-second control tests at 30 fps. The first ran at nominal heat, the second at serious heat and 16:9, so they aren't direct comparisons. Windows should hold 30 frames per second.

| Change during the take | Frames | Expected | Result |
|---|---|---|---|
| Lens position jump | 119, 120 | 120 | Clean |
| Tap focus, center and corner | 116, 113 | 120 | Lost 4 and 7, with a 233 ms gap |
| Focus rack at dial speed, 10 changes a second | 32 | 61 | **Lost 29 frames** |
| Switch to continuous autofocus | 112 | 120 | Lost 8, with a 267 ms gap |
| ISO ramp at dial speed, 200 to 400 | 61 | 61 | Clean |
| Exposure steps and return to auto | 120, 120, 120, 60, 119 | 120, 120, 120, 60, 120 | Clean |
| White balance steps and return to auto | 120, 120, 120 | 120 | Clean |

- **Allowed during a take:** ISO, shutter and white balance dials, and monitor tools.
- **Blocked during a take:** every focus change, and exposure drag, because bias was cut short by the writer failure.
- **Must stay locked:** lens and capture settings, because any change rebuilds the session. Curve, exposure offset, debayer, crop and pipeline, because they're baked in and the clip's metadata is written at the start.
- **Holds during a take:** focus, exposure and white balance freeze where they are as a take starts and resume when it ends. The cost of those mode changes hasn't been measured on the phone. If reduced load starts during a take, only the log and the popup show it; the clip's metadata records the state at the start.
- **Not settled:** Per-frame ISO, shutter and white balance values are read when a photo arrives, so they can lag the frame. White balance gains are baked into the debayer. The RAW frames have no focus breathing correction.

The ISP monitor removes the Metal view, so it stays in Settings. Keep SwiftUI updates to about once a second while recording, and avoid continuous animations, because main-thread load has cost frames before.

## Encoder failures

Two takes ended with `-11800`, underlying `-16364`, after 92 and 820 frames, both at serious heat. It appeared after the move to Xcode 26 and is unconfirmed. Community reports link `-16364` to timestamps that don't advance. The encoder now drops any frame that doesn't advance and logs it, and a failure logs timestamps, rotation, heat and free space. If it returns with no out-of-order frames logged, timestamps are ruled out.

## Known simulator limits

- Linear textures on shared buffers crash the simulator, so the RAW copy path can only be tested on the phone.
- `blit.synchronize(resource:)` isn't available on iOS.
- There's no camera or microphone, so capture and audio are phone-only.
