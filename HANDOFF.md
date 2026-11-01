# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of the end of Phase 5's build work: the library, presets, frame rates and auto during a take are written and need their first phone test.

## What this is

An iPhone camera app that records full-sensor RAW frames, processes them on the GPU and encodes log video. The goal is the full quality of the sensor, with the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

- **Repo:** public, GPL-3.0, [JoonaKumpulainen/VibeLog](https://github.com/JoonaKumpulainen/VibeLog), branch `main`.
- **Test phone:** iPhone 14 Pro (`iPhone15,2`), iOS 27.2.

## How we work

- **No Mac:** the owner cannot build locally, and this Linux machine has no Swift or Xcode. Every build runs on GitHub Actions (`macos-26`), and pushes to `main` trigger it. `.md` changes don't build.
- **Project file:** XcodeGen generates it from `project.yml`. Never hand-write a `.pbxproj`.
- **After each code change:** ask the owner before committing, pushing or starting a build. Once they say so, push, wait for CI with `gh run watch`, and read the logs until it's green. Then download the artifact with `gh run download` and send the `.ipa` to the owner.
- **Reading CI logs:** the test step only keeps its last 60 lines. Use `gh run view <id> --log-failed` and look under `Testing failed:`. The `Executed N tests` line shows totals, including skips.
- **Install:** the owner sideloads the unsigned `.ipa` with a free Apple ID, using Sideloadly. Don't add anything needing a paid account or special entitlements.
- **Evidence:** camera behavior is only proven by the phone. Results come back as `logs/session_*.log`, JSON sidecars, screenshots and the owner's observations. Say exactly what to test and what to send. Never claim camera behavior works from CI alone.
- **Screenshots:** taking one during a recording may disturb it, so long tests should run hands-off.
- **Public repo:** keep commits and files free of private details.

## Project layout

| Path | Role |
|---|---|
| `App/` | SwiftUI UI, `AppModel`, `FrameRouter`, camera screen, format panel, library, Settings, Diagnostics, `DesignTokens` |
| `Modules/VLCore` | Frames, stats, DNG reader, RAW levels, logging, storage, device status, `VideoFrameSink` |
| `Modules/VLCapture` | Session, photo RAW driver, video driver, manual controls, audio, probe |
| `Modules/VLProcessing` | Log curves, color math, monitor LUT, `.cube` parser, Metal pipeline, still export, `Shaders.metal` |
| `Modules/VLRecording` | RAW dump writer, `VideoEncoder`, encoder presets, encoder benchmark, `TakeLibrary` |
| `Modules/ObjCGuard` | Catches Objective-C exceptions from AVFoundation, runtime scan |
| `Tests/VLTests` | 61 tests, including real GPU tests on the simulator |
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
- **Redesign:** the owner approved the camera screen after phone testing, apart from the fixes listed under Phase 5. Switching **Full view** five times during a take dropped no frames, and a recording with focus peaking on dropped none.
- **Mic meter:** the bar reacts to sound, and a take with it showing dropped no frames.

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

New additions follow the design rules in [ROADMAP.md](ROADMAP.md). `CameraGeometry.topShare` sets the picture's top and bottom edges, and that share is an estimate of the Camera app's split, not a measurement. The config's `toolbar` and `telemetry` fields are no longer used by the app.

### Waiting on the phone

None of this has run on a phone, so its first build needs these answers:

- **Frame rates:** does a 2-minute take at 24 and at 25 write that rate with no `DROP`? The `Frame timing:` log line shows what the sensor accepted, and the take's **Details** shows the measured rate. Frame timing below 30 is the first use of `activeVideoMinFrameDuration` under the Photo preset, so check that zero shutter lag and RAW still work there. Also confirm 30 still holds, because auto exposure now has a limit of one frame time at every rate.
- **Auto during a take:** with the setting on, record 2 minutes while moving between bright and dark. Does `DROP` stay at 0, does the shutter stay at or above the frame rate, and do the file's exposure and color follow the scene smoothly? `Recording:` log lines carry shutter, ISO and gains. Gains are read as each photo arrives, so color may lag exposure by a frame or more.
- **Library:** browse, play, share and delete. Thumbnails of ProRes at full size may be slow.
- **Presets:** save, apply, overwrite and swipe to delete, then reopen the app to check they persist.
- **Accessibility:** a pass with VoiceOver, Increase Contrast and Reduce Motion on.
- **10-minute test:** 10 minutes in Maximum quality at 30 fps, hands-off. Send the session log and sidecar. It's the last gate before gyro logging.
- **Peaking:** still unanswered: is it as sensitive punched in as at full view, and does noise make it flicker at high ISO? Its threshold of 0.1 on log luma is my own choice.

### How the camera screen works

- **Layout:** monospaced values around the picture. Every control keeps its portrait position in every hold and only its contents turn. The owner's earlier glass panels are gone: only black was ever behind them, so they added cost and no look.
- **Status:** two mirrored three-line blocks beside the Dynamic Island. Each is square so it can turn, and keeps to its outer corner in every hold. Warnings are filled orange chips.
- **Control bar:** ISO, shutter, white balance and focus. Amber means set by the user, an A badge means auto and a lock means frozen for the take.
- **Tray:** above the control bar, it shows the tools and lenses, a dial or the **MON** tools, so the control bar always stays. During a take the mic meter replaces the lenses.
- **Dials:** they have **AUTO** and **FINE**. The white balance dial also sets tint, and the focus dial has **PUNCH** and **PEAK**. Shutter angle shows while the shutter dial is open.
- **Format:** **FORMAT** opens slidable columns for codec, chroma, size, log curve, aspect and frame rate. ProRes has no 4:2:0. Changing frame rate rebuilds the session, unlike the other columns.
- **Clock:** with the drop count, it takes the two columns right of record in every hold. It shows only the digits in use, at the largest size that fits.
- **Notices:** short notices cover the tray and control bar for a few seconds, and a tap clears them. A take that ends early leaves an orange card until dismissed.
- **EV:** an offset stays visible in the tool row, and a tap resets it.
- **Last take:** the thumbnail left of record plays the newest video and stops the stream until the screen closes. Sound follows the silent switch, because audio session settings were left alone to protect recording.
- **Library:** back from that player is every take in `videos/`, newest first, with drops marked. Each has **Details** from its sidecar, **Share** and **Delete**, which also removes the sidecar. RAW dumps stay in the Files app.
- **Full view:** at 16:9 the tool row offers a 699x393 picture that leaves the 4:3 frame with only a strip beneath it. A take that stops early leaves it.
- **Punch-in:** it moves where the existing monitor draw samples, so it adds no GPU work. It shows a third of the picture, close to one sensor pixel per drawable pixel in Maximum quality and half that in Efficient. It opens on the last focus point and drags, including during a take.
- **Focus peaking:** a `Tool` that marks fine detail in cyan on the monitor, with four extra texture reads per drawable pixel while it's on. Its neighbors are fixed at about three sensor pixels, so punching in doesn't weaken it.
- **Mic meter:** the bar moves about twelve times a second by writing to Core Animation layers from the audio queue, so it skips the main thread. Its dB number updates once a second. Green runs to -12 dB, yellow to -3 dB, then red.
- **Settings:** one searchable page ordered by use, shown as a sheet. Format changes link to the panel. Presets save every format column plus pipeline, debayer and exposure offset, inside `VibeLog.config.json`. The volume buttons toggle recording on iOS 18 and later.

### Still to do

Only the phone tests above. Gyro logging to a Gyroflow `.gcsv` follows as its own change once the 10-minute test passes.

`VLCapture` gained focus and exposure points, exposure compensation, live values and audio peak measurement. `VLProcessing` gained the monitor view and peaking. Other module code is unchanged.

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

- **Allowed during a take:** ISO, shutter, white balance and tint dials, monitor tools, punch-in and Full view. With **Auto exposure and white balance during a take** on, **AUTO** on those dials also works.
- **Blocked during a take:** every focus change, and exposure drag, because bias was cut short by the writer failure.
- **Must stay locked:** lens, frame rate and capture settings, because any change rebuilds the session. Curve, exposure offset, debayer, crop and pipeline, because they're baked in and the clip's metadata is written at the start.
- **Holds during a take:** focus always freezes as a take starts and resumes when it ends. Exposure and white balance do the same unless **Auto exposure and white balance during a take** is on, which is off by default until its control test passes; values set by hand stay either way. The sidecar records which happened. The cost of those mode changes hasn't been measured on the phone. If reduced load starts during a take, only the log and the popup show it; the clip's metadata records the state at the start.
- **Not settled:** Per-frame ISO, shutter and white balance values are read when a photo arrives, so they can lag the frame. White balance gains are baked into the debayer. The RAW frames have no focus breathing correction.

The ISP monitor removes the Metal view, so it stays in Settings. Keep SwiftUI updates to about once a second while recording, and avoid continuous animations, because main-thread load has cost frames before. A faster reading draws on its own layers from its own queue, as the mic bar does.

## Encoder failures

Two takes ended with `-11800`, underlying `-16364`, after 92 and 820 frames, both at serious heat. It appeared after the move to Xcode 26 and is unconfirmed. Community reports link `-16364` to timestamps that don't advance. The encoder now drops any frame that doesn't advance and logs it, and a failure logs timestamps, rotation, heat and free space. If it returns with no out-of-order frames logged, timestamps are ruled out.

## Known simulator limits

- Linear textures on shared buffers crash the simulator, so the RAW copy path can only be tested on the phone.
- `blit.synchronize(resource:)` isn't available on iOS.
- There's no camera or microphone, so capture and audio are phone-only.
