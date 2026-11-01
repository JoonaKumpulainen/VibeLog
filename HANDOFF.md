# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of early Phase 6. Phase 5 is built, and only a few phone checks remain. The latest build is `fc8fc51`, which passed CI with 73 tests. It hasn't been tested on the phone, and the last logged session came from `9f9a456`.

## What this is

An iPhone camera app that records full-sensor RAW frames, processes them on the GPU and encodes log video. The goal is the full quality of the sensor, with the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

- **Repo:** public, GPL-3.0, [JoonaKumpulainen/VibeLog](https://github.com/JoonaKumpulainen/VibeLog), branch `main`.
- **Test phone:** iPhone 14 Pro (`iPhone15,2`), iOS 27.2.

## How we work

- **No Mac:** the owner cannot build locally, and this Linux machine has no Swift or Xcode. Every build runs on GitHub Actions (`macos-26`), and pushes to `main` trigger it. `.md` changes don't build.
- **Project file:** XcodeGen generates it from `project.yml`. Never hand-write a `.pbxproj`.
- **After each code change:** ask the owner before committing, pushing or starting a build. Once they say so, push, wait for CI with `gh run watch`, and read the logs until it's green. Then download the artifact with `gh run download` and send the `.ipa` to the owner. If the owner asks for several changes before a build, batch them.
- **Reading CI logs:** the test step only keeps its last 60 lines. Use `gh run view <id> --log-failed` and look under `Testing failed:`. The `Executed N tests` line shows totals, including skips.
- **Install:** the owner sideloads the unsigned `.ipa` with a free Apple ID, using Sideloadly. Don't add anything needing a paid account or special entitlements.
- **Evidence:** camera behavior is only proven by the phone. Results come back as `logs/session_*.log`, JSON sidecars, screenshots and the owner's observations. Say exactly what to test and what to send. Never claim camera behavior works from CI alone.
- **Screenshots:** taking one during a recording may disturb it, so long tests should run hands-off.
- **Public repo:** keep commits and files free of private details.
- **Accessibility:** the owner won't test it, so leave it out of test lists. VoiceOver labels, announcements, Increase Contrast and Reduce Motion support were added, and none has been tested.

## Project layout

| Path | Role |
|---|---|
| `App/` | SwiftUI UI, `AppModel`, `FrameRouter`, camera screen, format panel, library, Settings, Diagnostics, `DesignTokens` |
| `Modules/VLCore` | Frames, stats, DNG reader, RAW levels, logging, storage, device status, `VideoFrameSink`, `GyroLog` |
| `Modules/VLCapture` | Session, photo RAW driver, video driver, manual controls, audio, `MotionLogger`, probe |
| `Modules/VLProcessing` | Log curves, color math, monitor LUT, `.cube` parser, Metal pipeline, still export, `Shaders.metal` |
| `Modules/VLRecording` | RAW dump writer, `VideoEncoder`, encoder presets, encoder benchmark, `TakeLibrary` |
| `Modules/ObjCGuard` | Catches Objective-C exceptions from AVFoundation, runtime scan |
| `Tests/VLTests` | 73 tests, including real GPU tests on the simulator |
| `tools/inspect_clip.py` | Summarizes a RAW clip and exports a frame |

Modules are dynamic frameworks. Swift is in Swift 5 mode.

## What's proven on the phone

- **RAW source:** `AVCapturePhotoOutput` with the readiness coordinator, zero shutter lag and responsive capture gives 12 MP Bayer (`bgg4`, 14-bit in 16-bit words) at 30 fps. The app fires requests from camera events as well as the coordinator, with a minimum gap of 0.9 frame times, which is 30 ms at 30 fps.
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
- **Pipelines:** **Maximum quality** is the app's default, but the owner's phone is saved on **Efficient**, so every take in the last session used it. **Efficient** matches it within one 10-bit code in tests and looked identical to the owner, but one run showed no clear gain, plus more failed photos and memory. It isn't proven better.
- **Features confirmed:** synced audio, 16:9 crop, zebras, false color and `.cube` import with **LUT made for**.
- **Redesign:** the owner approved the camera screen after phone testing, apart from the fixes listed under Phase 5. Switching **Full view** five times during a take dropped no frames, and a recording with focus peaking on dropped none.
- **Mic meter:** the bar reacts to sound, and a take with it showing dropped no frames.
- **Frame rates:** no dropped frames at 24, 25 and 30 fps. One take each at 24 and 25 wrote 23.90 fps over 10 seconds and 24.97 fps over 42 seconds. 23.98 and 29.97 are newer and untested.
- **Auto during a take:** the owner reported that auto exposure and white balance work. It hasn't been in a logged test, so its cost isn't measured.
- **Long run in Efficient:** 10:12 of ProRes 422 HQ at full size with 0 `DROP`, 18338 frames and 172 MB/s, in a dark scene at 1/31 s and ISO 8710. Heat reached serious at 5 minutes, with **Keep recording when hot** on and no failure. The file wrote 29.97 fps, about 16 frames fewer than 30 fps gives, and the rolling rate dipped to 29.49 in 8 of 122 samples. `DROP` doesn't count frames the camera never delivered, so result lines now log `missed` and `gap`.
- **Library and peaking:** the owner reported both working.
- **Gyro file format:** a 5-second sample had the right header, even 100 Hz spacing and 1.00 g at rest, pointing up. Its axes haven't been checked against a picture.

## Not verified

- Recording well past 10 minutes, or a full 10 minutes in Maximum quality.
- Why the long run was about 16 frames short of 30 fps: skipped frames or the sensor's real rate. The new `missed` and `gap` figures should show which.
- Whether **Auto exposure and white balance during a take** costs frames.
- Why a take at 00:24:03 in the last session stopped after 76 ms with no frames. It may have been a double tap or record firing twice.
- Whether the 8-minute clip played to the end.
- Color accuracy against a chart.
- Whether the exposure default holds across scenes.
- Recording on the ultra wide and tele.
- Crash recovery from the 10-second file fragments.
- What `-12686` and `-16800` mean. In one session, nearly every one was the single failure right after a session rebuild, and none came mid-take after the first seconds.
- False color ranges, which are my own choice.
- Whether the **Color space** choices match real S-Gamut3 and AWG3 footage. Its matrices come from published primaries.

## Now: end of Phase 5, start of Phase 6

New additions follow the design rules in [ROADMAP.md](ROADMAP.md). `CameraGeometry.topShare` sets the picture's top and bottom edges, and that share is an estimate of the Camera app's split, not a measurement. The config's `toolbar` and `telemetry` fields are no longer used by the app.

### Waiting on the phone

Run these in order. The owner has limited time, so short tests come first, and the session log and sidecars should come back with the results.

1. **Format wheels:** do they open on the current choice? They used to open at the top, and the fix was never seen working. It calls `scrollTo` as each wheel appears.
2. **ProRes names and labels:** check **PROFILE**, **OPEN GATE** and the sizes are readable in all four holds, and that the format panel stops just short of the picture.
3. **Library delete:** try **Select**, a long press on a take and the player's **Delete**. Each removes the video, sidecar and gyro log.
4. **Presets:** save, apply, overwrite and swipe to delete, then reopen the app to check they persist.
5. **Gyroflow:** load a handheld clip with its `.gcsv` and check the picture steadies instead of shaking more. The orientation `yXZ` is derived from the sensor's layout, because Gyroflow's docs only define it in a figure, and my reading of its axes is from memory. If it shakes more, Gyroflow's **IMU Orientation** field tries others without a new build. Report which works, so `GyroLog.orientation` can change.
6. **Gyro cost:** does a 2-minute take with **Save gyro data** on show the same `DROP` as one with it off?
7. **Decimal frame rates:** does a 2-minute take at 23.98 and at 29.97 show no `DROP`? The `Frame timing:` log line shows what the sensor accepted, and the take's **Details** shows the measured rate. Files use each frame's real capture time, not a fixed grid, so check what an editor reports for them.
8. **180° button:** on the shutter dial. It sets twice the frame rate and locks exposure. Change **FPS** afterward and the shutter should follow.
9. **Uncompressed audio:** does a 2-minute take have clean sound and no `DROP`? The writer converts the microphone to 24-bit, 48 kHz.
10. **Color space:** in Settings under Image, pick S-Gamut3 or ARRI Wide Gamut 3. Does the curve change to match, does the viewfinder look unchanged, and does the file read correctly when graded that way? Choosing Apple Log in the format panel should show Rec.2020 here.
11. **10-minute test:** switch **Pipeline** to **Maximum quality**, then record 10 minutes at 30 fps, hands-off. Check `missed` and `gap` on the result line.

For vignette correction, also ask for a short RAW clip's `reference.dng` and `reference_metadata.json`. Turn off **Encode video** in Diagnostics to record one.

### Phase 6 so far

- **Built:** frame rates, gyro logging, the 180° button, PCM audio and native gamuts.
- **Color space:** a picker in Settings under Image, always shown. Each choice names what it pairs with, so Apple Log's lack of a gamut of its own shows by omission. Choosing a gamut other than Rec.2020 sets its curve. The saved `nativeGamut` setting then follows the curve: Apple Log falls back to Rec.2020, and S-Log3 or LogC3 return to their own gamut. `Gamut.fromRec2020` builds each matrix from published primaries, and the pipeline multiplies it after the DNG matrix, which adds no GPU work. The Rec.709 monitor LUT and still export follow the setting. Sidecars and `still.json` name the gamut, and the file's own tag stays nominal Rec.2020 because it can't name these gamuts. The `.cube` conversion LUTs receive the recorded gamut, and stills keep the file name `log_rec2020.png` either way.
- **Needs samples first:** vignette correction needs a real `reference.dng` to find the `FixVignetteRadial` values, and highlight reconstruction needs clips with clipped highlights. Color accuracy needs a chart. Any real-time GPU work then needs a frame-cost test.
- **Needs the phone:** lens tests, the stabilization check and focus while recording.
- **Requested, not built:** a low and high focus peaking switch in Settings, kept out of the way on purpose rather than on the **PEAK** button. Today's threshold is the fixed 0.1 in `monitorFragment`, so it needs a `MonitorParams` field. Only the threshold changes, so it adds no GPU work.
- **Not started:** shutter priority, which needs an ISO loop during capture and its own frame-cost test, auto exposure with an EV slider, external microphones and file tagging options.

### How the camera screen works

- **Layout:** monospaced values around the picture. Every control keeps its portrait position in every hold and only its contents turn. The owner's earlier glass panels are gone: only black was ever behind them, so they added cost and no look.
- **Status:** two mirrored three-line blocks beside the Dynamic Island. Each is square so it can turn, and keeps to its outer corner in every hold. Warnings are filled orange chips.
- **Control bar:** ISO, shutter, white balance and focus. Amber means set by the user, an A badge means auto and a lock means frozen for the take.
- **Tray:** above the control bar, it shows the tools and lenses, a dial or the **MON** tools, so the control bar always stays. During a take the mic meter replaces the lenses.
- **Dials:** they have **AUTO** and **FINE**. The white balance dial also sets tint, the shutter dial has **180°**, and the focus dial has **PUNCH** and **PEAK**. Shutter angle shows while the shutter dial is open.
- **Format:** **FORMAT** opens slidable columns for codec, chroma or ProRes profile, size, log curve, aspect and frame rate. **ASPECT** calls 4:3 **OPEN GATE**, and **SIZE** shows the full recorded size for the chosen aspect. It's square-cornered and reaches from the screen's edge to `CameraGeometry.formatGap` short of the picture, with its rows sharing the depth. ProRes has no 4:2:0. Changing frame rate rebuilds the session 0.3 seconds after the column settles, unlike the other columns, and record waits for it.
- **Clock:** with the drop count, it takes the two columns right of record in every hold. It shows only the digits in use, at the largest size that fits.
- **Notices:** short notices cover the tray and control bar for a few seconds, and a tap clears them. A take that ends early leaves an orange card until dismissed.
- **EV:** an offset stays visible in the tool row, and a tap resets it.
- **Last take:** the thumbnail left of record plays the newest video and stops the stream until the screen closes. Sound follows the silent switch, because audio session settings were left alone to protect recording.
- **Library:** back from that player is every take in `videos/`, newest first, with drops marked. Each has **Details** from its sidecar, **Share**, which includes the gyro log, and **Delete**, which also removes the sidecar and gyro log. **Select** or a long press deletes from the grid. RAW dumps stay in the Files app.
- **Full view:** at 16:9 the tool row offers a 699x393 picture that leaves the 4:3 frame with only a strip beneath it. A take that stops early leaves it.
- **Punch-in:** it moves where the existing monitor draw samples, so it adds no GPU work. It shows a third of the picture, close to one sensor pixel per drawable pixel in Maximum quality and half that in Efficient. It opens on the last focus point and drags, including during a take.
- **Focus peaking:** a `Tool` that marks fine detail in cyan on the monitor, with four extra texture reads per drawable pixel while it's on. Its neighbors are fixed at about three sensor pixels, so punching in doesn't weaken it.
- **Mic meter:** the bar moves about twelve times a second by writing to Core Animation layers from the audio queue, so it skips the main thread. Its dB number updates once a second. Green runs to -12 dB, yellow to -3 dB, then red.
- **Gyro log:** with **Save gyro data** on, which is the default, each encoded take gets a `.gcsv` of the same name in `videos/`, from `CMDeviceMotion` at 100 Hz, the most the phone delivered when asked for 200, on its own utility queue. A 5-second sample was evenly spaced with sensible units, but began 0.14 seconds after the first frame, because motion updates take that long to start, so a take's first frames have no gyro data. Time zero is the first frame, on the same clock as frame timestamps, and the file is flushed once a second. Rotation is CoreMotion's bias-corrected rate. RAW dumps get none. Share sends it with the video, and delete removes it.
- **Settings:** one searchable page ordered by use, shown as a sheet. Format changes link to the panel. Presets save every format column plus pipeline, debayer, exposure offset and color space, inside `VibeLog.config.json`. **Uncompressed audio** records 24-bit PCM instead of AAC, which stays the default until it's tested. The volume buttons toggle recording on iOS 18 and later.

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

Two takes ended with `-11800`, underlying `-16364`, after 92 and 820 frames, both at serious heat. It appeared after the move to Xcode 26 and is unconfirmed. Community reports link `-16364` to timestamps that don't advance. The encoder now drops any frame that doesn't advance and logs it, and a failure logs timestamps, rotation, heat and free space. If it returns with no out-of-order frames logged, timestamps are ruled out. It didn't return during the 10:12 run, which spent 5 minutes at serious heat, but that was in Efficient.

## Known simulator limits

- Linear textures on shared buffers crash the simulator, so the RAW copy path can only be tested on the phone.
- `blit.synchronize(resource:)` isn't available on iOS.
- There's no camera or microphone, so capture and audio are phone-only.
