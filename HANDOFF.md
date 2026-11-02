# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of early Phase 6. Phase 5 is built, and only a few phone checks remain. The latest build is `fc8fc51`, which passed CI with 73 tests, and the owner is partway through testing it on the phone. Everything listed under **Unbuilt changes** is not yet built, and none of it has been compiled. The last logged session came from `9f9a456`.

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
| `Tests/VLTests` | 93 tests, including real GPU tests on the simulator |
| `tools/inspect_clip.py` | Summarizes a RAW clip and exports a frame |
| `tools/test_server.py` | The test link's server, which sends the phone commands and collects its files |

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
- **Frame rates:** no dropped frames at 24, 25 and 30 fps. One take each at 24 and 25 wrote 23.90 fps over 10 seconds and 24.97 fps over 42 seconds. The owner reported no drops at 23.98 and 29.97, with no logs seen yet. What an editor reports for those files is unchecked.
- **Decimal timing:** the `Frame timing:` log confirms the sensor accepted 0.033367 s for 29.97 and 0.041708 s for 23.98. A 31-second take at 29.97 lost 3 frames at the GPU in its first second, started 1.2 seconds after the session rebuild, then held. A 30-second take at 23.98 lost nothing, with `missed 0`.
- **Duplicate frames:** that 23.98 take logged 4 encoder drops, though 738 frames arrived in 30.6 seconds, more than 23.98 fps gives. The first was exactly 0.0 ms behind the last frame, so the camera delivered the same frame twice, probably because the 0.9 frame gap lets a request reach the same frame. The others weren't logged. The encoder rightly skips these, but they count as `DROP`, so the number overstates the loss.
- **Uncompressed audio:** the owner reported that sound in the 10-minute take is crisp and in sync.
- **Color space:** the owner reported that S-Gamut3 with S-Log3 works. LogC3 takes recorded, but ARRI Wide Gamut 3 hasn't been graded.
- **Ultra wide falls short of 30 fps:** every take on it missed frames, while the main camera held 30.00 fps after a start hitch of 133 to 200 ms. Locked 20-second ProRes 422 HQ takes wrote 18.94 fps at 1/30 s, 20.45 at 1/60 and 20.37 at 1/120. HEVC and ProRes 4444 gave 20.0 fps at 1/120, and auto at 1/33 gave 24.7. So neither shutter nor codec sets the limit. GPU time stayed near 14 ms at the start of those takes with no drops, so nor does the GPU. The camera delivers the frames late, and `PhotoRawDriver` has no per-lens logic. The cause is unproven. See **Variable frame timing**. `missed` understates this lens, because it compares gaps with the take's median: take `190710` lost about a third of its frames and logged `missed 2`.
- **Ultra wide long run:** 10:08 of ProRes 4444 in LogC3 and Maximum quality at 23.29 fps written, 14173 frames and 190.7 MB/s. Encoder drops were 0, but 441 frames dropped at the GPU and 33 photos failed. Heat reached serious after 65 seconds. From about 2 minutes in, GPU time jumped from 28 ms to about 65 ms for long stretches with a return to 28 ms in between, which looks like GPU throttling, and every loss came during the slow stretches. An earlier 7:42 take ran serious for 2:40 at 20 fps with no drops. This doesn't test 30 fps.
- **Monitoring cost:** in the 10-minute take, all tools except zebras took GPU time from 13.5 ms to about 29 ms, which fits within 33.3 ms while the GPU runs at full speed.
- **Main camera, Maximum quality, 10 minutes:** take `192944`, 1x, ProRes 422 HQ, uncompressed audio and all tools except zebras, ran 10:01. The camera delivered 29.99 fps with `missed 5`, and the encoder dropped nothing, but the file wrote 28.11 fps because 1128 frames (6%) dropped at the GPU. The first 6:20 lost none. Heat reached fair at 38 seconds and serious at 1:48. At 6:20, GPU time jumped from about 27 ms to 52 ms, then to about 70 ms by 8:30, with no other change, which looks like GPU throttling. Tools are the likely reason it can't absorb that, but no 10-minute take with tools off has run in Maximum quality. Recording frames should outrank monitoring, so a viewfinder that gives way before the file does is worth building.
- **Tele:** take `194057` delivered 29.86 fps. It started at serious heat, and GPU time reached 66 ms once tools were on, so 68 frames dropped at the GPU over 21 seconds. Take `194232`, in the same conditions, logged 664 frames at 29.98 fps, but 151 were duplicates with the same timestamp as the frame before, so the file wrote 23.13 fps. `missed` showed 0.
- **Variable frame timing:** in builds up to `fc8fc51`, 30 fps left the sensor's frame time at 1/30 to 1/15 s, while every other rate was fixed. The sensor may have been slowing down on the ultra wide and tele, which would explain both the late frames and the duplicates. `applyFrameRate` now fixes 30 fps too, unbuilt and untested, and **Fixed frame time at 30 fps** in Diagnostics switches it back. All the long runs above used the old timing, so the main camera at 30 fps needs checking again. Another session's reading of the sensor timestamps disagrees with this theory for locked takes, so don't count on it.
- **Auto during a take:** the owner reported that auto exposure and white balance work. It hasn't been in a logged test, so its cost isn't measured.
- **Long run in Efficient:** 10:12 of ProRes 422 HQ at full size with 0 `DROP`, 18338 frames and 172 MB/s, in a dark scene at 1/31 s and ISO 8710. Heat reached serious at 5 minutes, with **Keep recording when hot** on and no failure. The file wrote 29.97 fps, about 16 frames fewer than 30 fps gives, and the rolling rate dipped to 29.49 in 8 of 122 samples. `DROP` doesn't count frames the camera never delivered, so result lines now log `missed` and `gap`.
- **Library and peaking:** the owner reported both working. Delete removes a take with its metadata.
- **Format panel:** the owner reported that the wheels open on the current choice, and that the ProRes names, **OPEN GATE** and the sizes read correctly.
- **180° button:** the owner reported it working.
- **Gyroflow:** the owner reported that it works with the saved `.gcsv`. A 5-second sample also had the right header, even 100 Hz spacing and 1.00 g at rest.

## Not verified

- Recording well past 10 minutes, or 10 minutes in Maximum quality with no dropped frames.
- Why the long run was about 16 frames short of 30 fps: skipped frames or the sensor's real rate. The new `missed` and `gap` figures should show which.
- Whether **Auto exposure and white balance during a take** costs frames.
- Why a take at 00:24:03 in the last session stopped after 76 ms with no frames. It may have been a double tap or record firing twice.
- Whether the 8-minute clip played to the end.
- Color accuracy against a chart.
- Whether the exposure default holds across scenes.
- Why the ultra wide and tele fall short of 30 fps.
- Crash recovery from the 10-second file fragments.
- What `-12686` and `-16800` mean. Nearly every one is the single failure right after a session rebuild. The exception is the ultra wide long run, where 33 came mid-take while the GPU ran slow.
- Why `-11819` session runtime errors appear. Three came with the camera idle, and each stream recovered within a second.
- False color ranges, which are my own choice.
- Whether the **Color space** choices match real S-Gamut3 and AWG3 footage. Its matrices come from published primaries.

## Now: end of Phase 5, start of Phase 6

New additions follow the design rules in [ROADMAP.md](ROADMAP.md). `CameraGeometry.topShare` sets the picture's top and bottom edges, and that share is an estimate of the Camera app's split, not a measurement. The config's `toolbar` and `telemetry` fields are no longer used by the app.

### Unbuilt changes

- **Presets:** a default preset and a built-in Stock.
- **Fixed frame time at 30 fps:** on by default, with a Diagnostics switch.
- **Viewfinder yields:** `MonitorPacer` drops to every 8th draw for 30 frames once two frames are waiting during a take. It's meant to stop the 6% loss in `192944`, which is untested. The result line reports `viewfinder yields`.
- **Loss counts:** `FrameRouter` stops duplicate frames, within 1 ms of the last, before the GPU, so they no longer count or cost anything. `missed` now compares with the real frame rate during a take. The result line gives `lost (gpu, encoder)`, and the sidecar and library include GPU losses, which they used to leave out.
- **Setup in the log:** the `Encoding` line and sidecar record lens, tools, audio, gyro and frame time.
- **Record settles:** a take starts at least 1.5 seconds after the stream does. After a format change, record is delayed by up to that long.
- **Test link:** see below.
- **From other sessions:** the 48mm RAW probe and **Log capture timing**.

### Test link

**Test link** in Diagnostics connects the phone to `tools/test_server.py` on the owner's computer, so a session can run tests itself. It's off at every launch, and can't be switched on from the server.

- **Setup:** run `python3 tools/test_server.py serve`, which prints the address and token, and keeps files in `~/VibeLogTest`. Enter both in Diagnostics and turn on **Connect**. iOS asks for Local Network permission the first time. The computer's firewall must allow port 8765.
- **Commands:** `python3 tools/test_server.py send status`, `send set <name> <value>`, `send record <seconds> --wait`, `send stop`, `send controlTest`, `send zoomProbe`, `send sendLog`, `send listFiles` and `send sendFile <name>`. `set` takes lens, frameRate, codec, size, aspect, curve, gamut, pipeline, debayer, peaking, exposureOffset, shutter, iso, uncompressedAudio, saveGyro, captureTiming, fixedFrameTime, keepRecordingWhenHot, autoDuringTake and tools. A wrong value replies with the choices.
- **Limits:** the app only acts on the fixed list in `App/TestCommands.swift`. Nothing there deletes a take. Only tools change during a take. Files wait until a take ends, and videos only go by `sendFile`. It's plain HTTP with a token, so it suits a private network only. The phone must be awake, with VibeLog open, and someone must point it at the scene.
- **Cost:** one idle request stays open during a take, on its own queue. That's untested, so turn the link off for takes that prove frame counts until it has its own comparison.

### Waiting on the phone

Run these in order. The owner has limited time, so short tests come first, and the session log and sidecars should come back with the results.

1. **Test link, once built:** connect it, then run `send status` and a 20-second `send record`. Do the log and sidecar arrive?
2. **Presets, once built:** save, apply and overwrite one. **Stock** stays at the top with no **Delete**, and the name **Stock** can't be saved. **Set as default** from a row's menu, change the format, then reopen the app: it should open on that preset. Delete it by menu and by swipe; deleting the default returns to the last choices used. Do saved presets persist?
3. **Gyro cost:** Does a 2-minute take with **Save gyro data** on show the same `DROP` as one with it off?
4. **Decimal frame rates:** what does an editor report for a 23.98 and a 29.97 file? Files use each frame's real capture time, not a fixed grid. The `Frame timing:` log line shows what the sensor accepted.
5. **ARRI Wide Gamut 3:** does the viewfinder look unchanged, and does the file read correctly when graded that way?
6. **Fixed frame timing:** record 20 seconds each at 29.97 on the ultra wide and the tele, on a cool phone, with tools off. On `fc8fc51`, near 29.97 fps written with no duplicates means the fixed frame time should solve both lenses. On the next build, repeat this at 30 fps: `Frame timing:` should read 0.0333 to 0.0333. Also check that a 1-minute 1x take at 30 fps still holds in dim light, because the sensor can no longer stretch a frame.
7. **Long test with tools off:** repeat `192944` with every monitoring tool off, starting cool, at 1x. It needs about 100 GB free. Does it keep all its frames once the GPU slows?
8. **48mm RAW probe:** prop the phone on a still, detailed scene and tap **Run 48mm RAW probe** in Diagnostics. Each `48mm probe:` log line gives the real frame size, `35mm=` focal length, and `field=`. `cropped` at 2x with 4032x3024 frames would mean true 48mm RAW is available. `same` means RAW ignores the zoom, and `gaps` shows how fast 8064x6048 is if it works. If neither works, 2x falls back to a digital crop limited to about 1080p.
9. **Ultra wide capture timing:** turn on **Log capture timing** in Diagnostics and record 20 seconds on the ultra wide at 1/120 s. The `Capture timing:` log line shows frame gaps, how long requests took and how long the camera wasn't ready. Many `held` counts mean the app's requests are waiting on the camera. Few `held` with gaps of 33 and 67 ms mean the camera skips frames it was asked for. Send the `.timing.csv` too.

For vignette correction, also ask for a short RAW clip's `reference.dng` and `reference_metadata.json`. Turn off **Encode video** in Diagnostics to record one.

### Phase 6 so far

- **Built:** frame rates, gyro logging, the 180° button, PCM audio and native gamuts.
- **Color space:** a picker in Settings under Image, always shown. Each choice names what it pairs with, so Apple Log's lack of a gamut of its own shows by omission. Choosing a gamut other than Rec.2020 sets its curve. The saved `nativeGamut` setting then follows the curve: Apple Log falls back to Rec.2020, and S-Log3 or LogC3 return to their own gamut. `Gamut.fromRec2020` builds each matrix from published primaries, and the pipeline multiplies it after the DNG matrix, which adds no GPU work. The Rec.709 monitor LUT and still export follow the setting. Sidecars and `still.json` name the gamut, and the file's own tag stays nominal Rec.2020 because it can't name these gamuts. The `.cube` conversion LUTs receive the recorded gamut, and stills keep the file name `log_rec2020.png` either way.
- **Needs samples first:** vignette correction needs a real `reference.dng` to find the `FixVignetteRadial` values, and highlight reconstruction needs clips with clipped highlights. Color accuracy needs a chart. Any real-time GPU work then needs a frame-cost test.
- **Needs the phone:** lens tests, the stabilization check and focus while recording.
- **Focus peaking sensitivity:** Low keeps the old threshold of 0.1 and High uses 0.05, set in Settings under Viewfinder. It's a `MonitorParams` field, so it adds no GPU work. Unbuilt and untested.
- **Settings pauses the stream:** opening Settings stops the stream, unless a take is running, and closing it resumes. Opening Diagnostics resumes it for good, because its tools need it. Looks and LUTs therefore can't be previewed behind the sheet. Unbuilt and untested.
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
- **Settings:** one searchable page ordered by use, shown as a sheet. Format changes link to the panel. Presets save every format column plus pipeline, debayer, exposure offset and color space, inside `VibeLog.config.json`. **Stock** is built in from `AppConfig`'s defaults, so it can't be replaced or deleted. A row's menu sets the default, which replaces the saved format at launch, and deletes saved presets. With no default, the app opens on the last choices used. **Uncompressed audio** records 24-bit PCM instead of AAC, which stays the default until it's tested. The volume buttons toggle recording on iOS 18 and later.

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
