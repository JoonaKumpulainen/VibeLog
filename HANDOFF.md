# VibeLog handoff

For the next working session. Read this and [ROADMAP.md](ROADMAP.md) first. As of early Phase 6. Phase 5 is built, and only a few phone checks remain. The latest build is `b86f6bd`, which passed CI with 99 tests and hasn't been tested on the phone. The changes under **New since `b86f6bd`** aren't committed or built yet. The latest phone results came from `021248e`. The last logged session came from `9f9a456`.

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
| `Tests/VLTests` | 106 tests, including real GPU tests on the simulator |
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
- **Encoding:** ProRes 422 HQ at 4032x3024 is the default, at about 160 MB/s or 9.5 GB per minute. ProRes 4444 held 30 fps for 30 seconds at 240 MB/s. HEVC only just reaches 30 fps at full size. On `b86f6bd`, take `185616`, 1x, ProRes 4444, Maximum quality and Apple Log 2 in a dark scene at ISO 9799, ran 60 seconds at 29.91 fps written, 1796 frames, 259.8 MB/s, with 0 lost at the GPU or encoder and heat nominal throughout. The only loss was the start: 17.5 fps over the first 0.4 seconds, `missed 5` and a 200 ms gap. GPU time sat near 26 ms. HEVC 4:4:4 is real 4:4:4: take `185048` reads as the HEVC Range Extensions profile, `yuv444p10le`, and its chroma holds detail past half resolution. That 3.9-second take wrote 28.94 fps at 38.7 MB/s, with 0 lost at the GPU or encoder, but 2 failed photos and `missed 4`. Its time base of 1/600 confirms the decimal-rate cause.
- **Long run:** 10 minutes at 29.81 fps with 0 encoder drops, with **Keep recording when hot** on. Thermal state reached serious but not critical, and no throttling happened. Without reduced load, the GPU throttled at 5 minutes.
- **Battery:** recording near 1% stalled the encoder, and the same test at 70% was clean. That is strong evidence, from one comparison.
- **Storage:** full RAW dumps need 732 MB/s, but the phone sustains about 420 MB/s after about 8 GB. Encoder drops began at about 8 GB free, so recording stops at 10 GB free. Free space must use `volumeAvailableCapacityKey`; the important-usage figure counts purgeable data.
- **Pipelines:** **Maximum quality** is the app's default, but the owner's phone is saved on **Efficient**, so every take in the last session used it. **Efficient** matches it within one 10-bit code in tests and looked identical to the owner, but one run showed no clear gain, plus more failed photos and memory. It isn't proven better.
- **Features confirmed:** synced audio, 16:9 crop, zebras, false color and `.cube` import with **LUT made for**.
- **Redesign:** the owner approved the camera screen after phone testing, apart from the fixes listed under Phase 5. Switching **Full view** five times during a take dropped no frames, and a recording with focus peaking on dropped none.
- **Mic meter:** the bar reacts to sound, and a take with it showing dropped no frames.
- **Frame rates:** no dropped frames at 24, 25 and 30 fps. One take each at 24 and 25 wrote 23.90 fps over 10 seconds and 24.97 fps over 42 seconds. The owner reported no drops at 23.98 and 29.97, with no logs seen yet. DaVinci Resolve reports 24 for the 23.98 file and 30 for the 29.97 file, which is wrong. A fix is listed under **New since `b86f6bd`**.
- **Decimal timing:** the `Frame timing:` log confirms the sensor accepted 0.033367 s for 29.97 and 0.041708 s for 23.98. A 31-second take at 29.97 lost 3 frames at the GPU in its first second, started 1.2 seconds after the session rebuild, then held. A 30-second take at 23.98 lost nothing, with `missed 0`.
- **Duplicate frames:** that 23.98 take logged 4 encoder drops, though 738 frames arrived in 30.6 seconds, more than 23.98 fps gives. The first was exactly 0.0 ms behind the last frame, so the camera delivered the same frame twice, probably because the 0.9 frame gap lets a request reach the same frame. The others weren't logged. The encoder rightly skips these, but they count as `DROP`, so the number overstates the loss.
- **Uncompressed audio:** the owner reported that sound in the 10-minute take is crisp and in sync.
- **Color space:** the owner reported that S-Gamut3 with S-Log3 works. LogC3 takes recorded, but ARRI Wide Gamut 3 hasn't been graded. The owner reported that Apple Log 2 grades well.
- **Ultra wide falls short of 30 fps:** every take on it missed frames, while the main camera held 30.00 fps after a start hitch of 133 to 200 ms. Locked 20-second ProRes 422 HQ takes wrote 18.94 fps at 1/30 s, 20.45 at 1/60 and 20.37 at 1/120. HEVC and ProRes 4444 gave 20.0 fps at 1/120, and auto at 1/33 gave 24.7. So neither shutter nor codec sets the limit. GPU time stayed near 14 ms at the start of those takes with no drops, so nor does the GPU. The camera delivers the frames late, and `PhotoRawDriver` has no per-lens logic. The cause is unproven. See **Variable frame timing**. `missed` understates this lens, because it compares gaps with the take's median: take `190710` lost about a third of its frames and logged `missed 2`.
- **Ultra wide long run:** 10:08 of ProRes 4444 in LogC3 and Maximum quality at 23.29 fps written, 14173 frames and 190.7 MB/s. Encoder drops were 0, but 441 frames dropped at the GPU and 33 photos failed. Heat reached serious after 65 seconds. From about 2 minutes in, GPU time jumped from 28 ms to about 65 ms for long stretches with a return to 28 ms in between, which looks like GPU throttling, and every loss came during the slow stretches. An earlier 7:42 take ran serious for 2:40 at 20 fps with no drops. This doesn't test 30 fps.
- **Monitoring cost:** none measurable, and earlier notes blaming tools were wrong. At serious heat, 40-second 1x takes showed GPU 28.1 ms with all tools except zebras and 28.4 ms with none, and at fair heat 25.2 ms with none. GPU time climbs from about 13 ms to about 25 ms within 10 seconds of any take, with or without tools, for a reason not yet known. The figure only times the compute pass, not the viewfinder draw, so the tools' full cost needs a long take. All three takes lost 0 frames with the test link connected.
- **Gyro cost:** none seen. Two 40-second 1x takes, gyro on and off, both wrote 1200 frames with 0 lost.
- **Main camera, Maximum quality, 10 minutes:** take `192944`, 1x, ProRes 422 HQ, uncompressed audio and all tools except zebras, ran 10:01. The camera delivered 29.99 fps with `missed 5`, and the encoder dropped nothing, but the file wrote 28.11 fps because 1128 frames (6%) dropped at the GPU. The first 6:20 lost none. Heat reached fair at 38 seconds and serious at 1:48. At 6:20, GPU time jumped from about 27 ms to 52 ms, then to about 70 ms by 8:30, with no other change, which looks like GPU throttling. Tools were first blamed for this, but a later comparison showed no measurable difference, so the slowdown itself is the problem. `a2d2cab` has the viewfinder yield in that case, which still needs a long take.
- **Viewfinder yields didn't save a long take:** take `210133` on `a2d2cab`, 1x, ProRes 422 HQ, Maximum quality, uncompressed audio and all tools except zebras, began at nominal heat but only about 2 minutes after leaving fair, following a run of short takes. The camera delivered 29.99 fps with `missed 8`, but 1982 frames (12%) dropped at the GPU and the file wrote 26.35 fps. Heat reached serious at 1:30 and critical at 9:05, the first critical seen, so the app ended the take. GPU time left about 30 ms at about 3 minutes and settled near 78 ms. The viewfinder gave up 11909 draws and losses still grew, so the compute work itself is what slows. Starting heat differs from `192944`, so it isn't a direct comparison, and that take's lower loss may only reflect a cooler phone.
- **Efficient path when hot held a full take:** take `222321` on `021248e`, 1x, ProRes 422 HQ, Maximum quality with **Efficient path when hot** on, uncompressed audio, correction off and all tools except zebras, after a 30-minute rest with the stream off. It ran the full 10:00 at 29.96 fps written, 17975 frames at 169.4 MB/s, with 9 lost, all in the first 5 minutes before the phone was hot, and `missed 17`. Heat reached serious at 4:41 and never critical. GPU time stayed near 26 ms for the 5 minutes at serious, where `210133` and `192944` climbed to 70 ms or more. Both the longer rest and the hot path differ from those takes, so it doesn't yet separate them. `viewfinder yields` was 1897, but Settings was open over the camera, which likely inflated it: 20-second takes with Settings open gave 184 to 491 yields, against 0 to 52 in 40-second takes on the camera screen. Heat also differed between those runs. Run linked takes from the camera screen.
- **The picture changes when hot:** What was **Keep recording when hot**, now **Bilinear when hot**, changes the debayer as well as the path. Two 10-second takes at ISO 800, matching each half of `222321`, kept the same brightness and color (mean 0.366 and 0.365), but the Efficient Bilinear frame had about 4% of the fine detail energy of Maximum Malvar-He-Cutler. Most of that is noise at this ISO: side by side it's clearly less grainy and slightly softer, with lettering intact. A low ISO scene with fine detail hasn't been compared. The next step is a long take with the hot path on and **Keep recording when hot** off, which should keep Malvar-He-Cutler if the heat allows.
- **Tele:** take `194057` delivered 29.86 fps. It started at serious heat, and GPU time reached 66 ms once tools were on, so 68 frames dropped at the GPU over 21 seconds. Take `194232`, in the same conditions, logged 664 frames at 29.98 fps, but 151 were duplicates with the same timestamp as the frame before, so the file wrote 23.13 fps. `missed` showed 0.
- **Frame time doesn't set the lens limit:** on `a2d2cab`, 20-second takes at 1/120 s wrote 21.33 fps fixed and 21.50 variable on the ultra wide, and 29.91 both ways on the tele. Fixed stays the default until the 1x long run says otherwise, and the Diagnostics switch can go once it does.
- **Why the ultra wide was slow:** distortion correction. On `021248e`, 20-second takes at 1/120 s wrote 22.89 fps with it on and 29.85 fps with it off, and the camera's not-ready time fell from 40.5 ms to 31.9 ms. With it on, previews came out 704x504 with black edges, and with it off 672x504 with none, so correction reshapes the frame the app receives. Off gives the sensor's plain 4032x3024, which suits the app's goal, but the lens's distortion then stays in the picture. The switch is on by default, so the ultra wide stays slow until that changes. Whether colors and levels stay right with it off hasn't been checked on footage.
- **Correction on the 1x and tele:** 20-second takes were the same with it on and off: 1x 29.71 and 29.30 fps, tele 29.71 and 29.81, all with the same 672x504 previews. The phone heated through this run, so the small losses of 1 to 10 frames at the GPU follow the order of the takes more than the setting. Off is fine as the default on every lens.
- **Slow focus move still costs frames:** in the 56-second control test, 16 small focus changes at two a second over 8 seconds delivered 210 of 240 frames. A rack lost 30 of 60 in 2 seconds, and tap focus lost about 4 to 7 frames, as before. ISO and exposure bias steps stayed clean. Focus stays blocked during takes.
- **Shutter priority:** at 1x and 1/60 s, a 20-second take frozen at the start and a 30-second take with ISO live both lost 0 frames, at 29.75 and 29.84 fps. ISO moved from 926 to 1114 between them, but no take has followed a real change of light.
- **Frame steps:** in a 20-second 1x take, copy took about 7 ms, queue 0.3 ms, append 0 ms and draw 6 ms, with the compute pass at 26 ms. The viewfinder is small next to compute. A long take should show which step grows when hot.
- **Tele:** two 20-second takes at 1/120 s kept every frame at 29.91 fps with no duplicates. The earlier 23 fps duplicates take hasn't repeated.
- **Auto during a take:** the owner reported that auto exposure and white balance work. It hasn't been in a logged test, so its cost isn't measured.
- **Long run in Efficient:** 10:12 of ProRes 422 HQ at full size with 0 `DROP`, 18338 frames and 172 MB/s, in a dark scene at 1/31 s and ISO 8710. Heat reached serious at 5 minutes, with **Keep recording when hot** on and no failure. The file wrote 29.97 fps, about 16 frames fewer than 30 fps gives, and the rolling rate dipped to 29.49 in 8 of 122 samples. `DROP` doesn't count frames the camera never delivered, so result lines now log `missed` and `gap`.
- **Library and peaking:** the owner reported both working. Delete removes a take with its metadata.
- **Format panel:** the owner reported that the wheels open on the current choice, and that the ProRes names, **OPEN GATE** and the sizes read correctly.
- **180° button:** the owner reported it working.
- **Gyroflow:** the owner reported that it works with the saved `.gcsv`. A 5-second sample also had the right header, even 100 Hz spacing and 1.00 g at rest.

## Not verified

- Recording well past 10 minutes, or 10 minutes with no dropped frames at all.
- Why the long run was about 16 frames short of 30 fps: skipped frames or the sensor's real rate. The new `missed` and `gap` figures should show which.
- Whether **Auto exposure and white balance during a take** costs frames.
- Why a take at 00:24:03 in the last session stopped after 76 ms with no frames. It may have been a double tap or record firing twice.
- Whether the 8-minute clip played to the end.
- Color accuracy against a chart.
- Whether the exposure default holds across scenes.
- Whether footage with distortion correction off keeps correct color and levels.
- Crash recovery from the 10-second file fragments.
- What `-12686` and `-16800` mean. Nearly every one is the single failure right after a session rebuild. The exception is the ultra wide long run, where 33 came mid-take while the GPU ran slow.
- Why `-11819` session runtime errors appear. Three came with the camera idle, and each stream recovered within a second.
- False color ranges, which are my own choice.
- Whether the **Color space** choices match real S-Gamut3 and AWG3 footage. Its matrices come from published primaries.

## Now: end of Phase 5, start of Phase 6

New additions follow the design rules in [ROADMAP.md](ROADMAP.md). `CameraGeometry.topShare` sets the picture's top and bottom edges, and that share is an estimate of the Camera app's split, not a measurement. The config's `toolbar` and `telemetry` fields are no longer used by the app.

### New in `a2d2cab`, untested on the phone

- **Presets:** a default preset.
- **Fixed frame time at 30 fps:** on by default, with a Diagnostics switch.
- **Viewfinder yields:** `MonitorPacer` drops to every 8th draw for 30 frames once two frames are waiting during a take. It's meant to stop the 6% loss in `192944`, which is untested. The result line reports `viewfinder yields`.
- **Loss counts:** `FrameRouter` stops duplicate frames, within 1 ms of the last, before the GPU, so they no longer count or cost anything. `missed` now compares with the real frame rate during a take. The result line gives `lost (gpu, encoder)`, and the sidecar and library include GPU losses, which they used to leave out.
- **Setup in the log:** the `Encoding` line and sidecar record lens, tools, audio, gyro and frame time.
- **Record settles:** a take starts at least 1.5 seconds after the stream does. After a format change, record is delayed by up to that long.
- **Test link:** see below.
- **From other sessions:** the 48mm RAW probe and **Log capture timing**.

### New in `021248e`, untested on the phone

- **Efficient path when hot:** a Diagnostics switch, on by default since after `021248e`, at the owner's request and before any long take has proven it. While the phone is hot, frames use the Efficient path whichever pipeline is chosen. `tools/suites/heat_paths.json` tests it.
- **Frame steps:** `Recording` and result lines log `steps copy, queue, append, draw` in ms, to show where GPU time goes as heat rises.
- **Lens distortion correction:** a Diagnostics switch, on by default, because the ultra wide's 45 ms wait may come from it. `tools/suites/ultra_wide.json` tests it.
- **Suites:** `tools/test_server.py suite <plan.json>` runs takes and cooling breaks, stopping the stream to cool, and writes `suite_*.csv` and `heat_*.csv`. A cooling step waits for a minimum time as well as nominal heat, because `210133` showed nominal alone isn't cool.
- **Slow focus move:** the control test is now 56 seconds, with 16 small focus changes over its last stretch, to see if a gentler move keeps its frames. A long-standing focus block during takes stays until that passes.
- **Shutter priority:** with a set shutter, ISO's **AUTO** makes ISO follow the meter, using `ShutterPriority.nextISO` four times a second. Like other auto exposure, it freezes at the start of a take unless **Auto exposure and white balance during a take** is on. Its frame cost is unmeasured.
- **EV dial:** an **EV** button on the ISO dial, shown while the camera picks ISO, outside takes. In shutter priority it depends on the camera's meter including the bias, which is unproven.
- **Frame guides:** the **GUIDE** tool marks 2.39, 2.00, 1.85 or 1.00:1, chosen in Settings. The existing **LEVEL** tool is the horizon indicator.
- **Anamorphic desqueeze:** viewfinder only, in Settings, and it adds no texture reads.
- **File tag:** Settings under Image offers Rec.2020 (the old behavior), Rec.709 or Rec.2020 HLG. It changes tags only, and which one suits an editor is unchecked.

- **Test link:** stream control, the settings and actions above, a preview still, RAW clip fetching, and a report of the open screen. The `sendPreview` still works without any sign on the phone, which `TEST_LINK.md` states.
- **Fixes:** the timing file now sends once it's written, and `record` works for RAW dumps.

### New in `b86f6bd`, untested on the phone

- **Presets:** every setting except the link, plus **Reset all settings** in place of Stock.
- **Status blocks:** centered sideways and slightly wider.
- **Debayer text:** Settings says what each debayer does to detail and grain.
- **Apple Log 2:** Apple Log's curve with Apple Wide Gamut, from the primaries in OpenColorIO's source, which credits Apple's white paper. Red 0.725, 0.301, green 0.221, 0.814, blue 0.068, -0.076, D65. The Apple paper itself wasn't read. It's a software encoding, so it isn't limited to newer iPhones. The file tag stays nominal. The owner reported that it grades well.
- **Library and player turn:** `AppOrientation` allows landscape only while they're open, and the camera screen stays portrait. The sheet and share views turn with them. Turning hasn't been seen on the phone.

- **Advanced page:** Settings has an **Advanced** page with **Pipeline** and **Efficient when hot**, **Debayer** and **Bilinear when hot**, **Lens distortion correction** and **Diagnostics**. The long press on **Version** is gone. A search still shows these rows on the main page. **Keep recording when hot** is split: the debayer switch moved here, and the viewfinder part stayed as **Slow viewfinder when hot**.

- **Heat changes:** the sidecar's `heatChanges` and **Details** give the time of each hot and cool change in a take, with what changed. **Details** also shows debayer, hot switches, lens correction and file tag.
- **Idle camera pause:** after 2 minutes with no touch on the camera screen, the stream stops and a tap resumes it. Change or turn it off under Viewfinder. It doesn't run while a dial or panel is open, or while the test link is on. A dial drag only counts through that open dial, so a very long hold on a closed screen can still pause.
- **Warm note:** starting a take within 20 minutes of the phone leaving serious heat shows a notice, because nominal doesn't mean cool.
- **Server:** the default results folder can be set in `~/.vibelog_test_folder`, the server refuses uploads that would leave under 2 GB free, suites check the screen and storage first, and the heat log records `yields`.

### Test link

**Test link** in Diagnostics connects the phone to `tools/test_server.py` on the owner's computer, so a session can run tests itself. [TEST_LINK.md](TEST_LINK.md) covers privacy, running the server and removing it. It's off at every launch, and can't be switched on from the server.

- **Setup:** run `python3 tools/test_server.py serve`, which prints the address and token, and keeps files in `~/VibeLogTest`. `/home` on this machine has no room for clips, so `~/.vibelog_test_folder` points it at the larger drive. Enter both in Diagnostics and turn on **Connect**. iOS asks for Local Network permission the first time. The computer's firewall must allow port 8765.
- **Commands:** `python3 tools/test_server.py send status`, `send set <name> <value>`, `send record <seconds> --wait` and the rest in [TEST_LINK.md](TEST_LINK.md). `set` takes lens, frameRate, codec, size, aspect, curve, gamut, pipeline, debayer, peaking, exposureOffset, shutter, iso, uncompressedAudio, saveGyro, captureTiming, fixedFrameTime, slowViewfinderWhenHot, bilinearWhenHot, autoDuringTake, distortionCorrection, efficientWhenHot, isoAuto, frameGuide, fileTag, desqueeze, tools, method, encodeVideo, writeFrames, look, lut, lutMadeFor, freezeViewfinder, disconnectAppPreview, pairsGamut, punch, stopAfter, whiteBalance, tint, focus and exposureBias. A wrong value replies with the choices.
- **Limits:** the app only acts on the fixed list in `App/TestCommands.swift`. Nothing there deletes a take. Only tools, look and punch-in change during a take. Files wait until a take ends, and videos only go by `sendFile`. It's plain HTTP with a token, so it suits a private network only. The phone must be awake, with VibeLog open, and someone must point it at the scene.
- **Cost:** one idle request stays open during a take, on its own queue. 40-second takes lost nothing with it connected, but no take has compared it with the link off.
- **Proven:** it connected on the phone, ran these tests, and delivered logs, sidecars, gyro and timing files.

### New since `b86f6bd`, not built

- **Decimal rates:** `VideoEncoder` never set `videoInput.mediaTimeScale`, so the track probably got the default of 600. At that scale a 23.98 frame lasts 25.025 ticks and a 29.97 frame 20.02, so both rounded to whole rates, which matches what Resolve showed. `FrameRates.mediaTimeScale` now gives 1000 ticks per whole frame per second, 24000 for 23.98 and 30000 for 29.97, so a decimal frame lasts exactly 1001 ticks. A test writes 23.98 and 29.97 files on the simulator and reads back the track's timescale and rate. Timestamps are still each frame's real capture time, so Resolve may show a rate that isn't exactly 23.976 if capture jitters.
- **Presets:** the save button reads **Save current settings**. **Reset all settings** asks in a centered alert instead of a sheet from the bottom. A row's menu has **Update to current settings**, which keeps the name, place and default, and is disabled when the preset already matches.
- **Curve names:** short names follow each brand's spelling in capitals: S-LOG3, S-LOG2, LOGC3, LOGC4, C-LOG3. Apple has no short name, so ALOG and ALOG2 stay. The owner asked for "S-LOG 3" as the example, but Sony writes S-Log3 without a space.
- **New curves:** S-Log2 with S-Gamut, LogC4 with ARRI Wide Gamut 4, and Canon Log 3 (v1.2) with Cinema Gamut. Formulas and primaries come from colour-science's `develop` branch, and the tests check colour-science's own examples: middle gray 0.3395 for S-Log2, 0.2784 for LogC4 and 0.3434 for Canon Log 3. S-Gamut has the same primaries as S-Gamut3. Cinema Gamut's green has y 1.14, as Canon publishes. The shader switches on raw values 4, 5 and 6, and settings save the label. Lists are grouped by brand. Grading any of them hasn't been checked.
- **Pair curve and color space:** a switch in Settings under Image, on by default and kept in presets. While on, every curve records its own gamut: choosing a curve chooses its gamut, choosing a gamut chooses its curve, and Rec.2020 chooses Apple Log. Off, it behaves as before, where any curve but Apple Log 2 can record Rec.2020, and turning it off keeps the current pair. The link sets it with `set pairsGamut`. An older saved setup with S-Log3 or LogC3 in Rec.2020 now opens in S-Gamut3 or ARRI Wide Gamut 3 unless the switch is turned off.
- **ProRes 4444 at 12 bits:** it replaces the 10-bit 4444 under the same id and label, so saved settings and presets keep it. The encoder now gets 16-bit AYCbCr (`kCVPixelFormatType_4444AYpCbCr16`) in one plane, with opaque alpha, so ProRes keeps its 12 bits of color instead of 10. The 10-bit version gave nothing over ProRes 422 HQ but chroma, at about 60% more data. New kernels `encodePacked` (Maximum) and `processDirectPacked` (Efficient and the hot path) write it with the same math, keeping each code's fraction. `EncoderPreset.bitDepth` gives 12 for it, and the `Encoding` line and sidecar's `bitDepth` record it. The encoder benchmark now fills packed buffers. Tests check that both paths agree, that a code of 400.25 comes out as 12-bit 1601, and that a ProRes 4444 file on the simulator keeps steps finer than 10 bits. Whether the phone's encoder accepts this format at 4032x3024 and 30 fps is unknown: there's no fallback, so a refusal would show as a writer failure. The frame buffer grows from 6 to 8 bytes a pixel, so watch copy, GPU and memory figures against take `185616`.
- **Apple's preview hidden:** `SessionPreview` is hidden whenever the Metal monitor shows, so the bright Apple picture no longer flashes at launch. It stays connected, so it saves no load. With the **ISP preview** look, it shows as before, including during a take.
- **Disconnect Apple's preview:** a Diagnostics switch, off at every launch and kept out of presets. While VibeLog's own viewfinder shows, it takes the hidden preview off the session. It can't change during a take, and the connection holds until the take ends. The sidecar's `appPreview`, the link's status and the heat log record whether it was connected. Whether photo capture or auto exposure depends on it is unknown, so it needs a short take before a long one. If it saves heat, the end goal is to make this the normal behavior and drop the switch: **ISP preview** stays under **Look**, the preview connects only while that look is chosen, and any other look disconnects it.
- **Suites:** `tools/suites/hot_switches.json` runs the two long tests below, and `tools/suites/app_preview.json` runs a long take with Apple's preview disconnected. Both match `222321`'s setup: 1x, Maximum quality, uncompressed audio, correction off and all tools except zebras.

### Waiting on the phone

Run these in order. The owner has limited time, so short tests come first, and the session log and sidecars should come back with the results.

1. **Launch and curves:** the screen should stay black at launch until VibeLog's picture appears, with no bright Apple picture first. Check the LOG wheel's new names and curves, and that **ISP preview** still shows a picture. Then turn on **Disconnect Apple's preview** and record a 20-second take: does it record, and do auto exposure and photos still work?
2. **Screens:** check the status blocks in all four holds with a long setup. Check that the library, player, details and share turn with the phone, and that the camera screen is unchanged after closing them sideways. Check **Advanced**, and **Pause camera when idle**.
3. **ProRes 4444 at 12 bits:** a 60-second 1x take in Maximum quality, as `185616` was, through the link. The `Encoding` line should say `12-bit`. Compare lost frames, GPU time and MB/s, and check the file with `ffprobe`, which should report `yuva444p12le`. If it records cleanly, run 10 minutes.
4. **Presets:** save, apply and update one with **Update to current settings**, including tools and audio. Check that **Reset all settings** asks in a centered popup. **Set as default** from a row's menu, change something, then reopen the app: it should open on that preset. Delete by menu and by swipe; deleting the default returns to the last choices used. **Reset all settings** should keep presets and the test link. Do saved presets persist?
5. **Decimal rates:** record a 23.98 and a 29.97 take and check what Resolve shows.
6. **ARRI Wide Gamut 3:** left for later at the owner's choice. Record it and grade it. Does the file read correctly when graded that way?
7. **Long tests:** run from the camera screen, with Settings closed, after a 30-minute rest and with about 100 GB free. First, **Bilinear when hot** off, to see if Malvar-He-Cutler survives the heat. If it does, it should become the default. Second, **Efficient when hot** off, to separate it from the rest that `222321` had. These also decide whether the viewfinder yield stays. `python3 tools/test_server.py suite tools/suites/hot_switches.json` runs both, with a 30-minute cool before each. Then `app_preview.json`, if the short disconnected take worked.
8. **48mm RAW probe:** prop the phone on a still, detailed scene and tap **Run 48mm RAW probe** in Diagnostics. Each `48mm probe:` log line gives the real frame size, `35mm=` focal length, and `field=`. `cropped` at 2x with 4032x3024 frames would mean true 48mm RAW is available. `same` means RAW ignores the zoom, and `gaps` shows how fast 8064x6048 is if it works. If neither works, 2x falls back to a digital crop limited to about 1080p.

For vignette correction, also ask for a short RAW clip's `reference.dng` and `reference_metadata.json`. Turn off **Encode video** in Diagnostics to record one.

### Phase 6 so far

- **Built:** frame rates, gyro logging, the 180° button, PCM audio and native gamuts.
- **Color space:** a picker in Settings under Image, always shown. Each choice names what it pairs with, so Apple Log's lack of a gamut of its own shows by omission. Choosing a gamut other than Rec.2020 sets its curve. The saved `nativeGamut` setting then follows the curve: Apple Log falls back to Rec.2020, and S-Log3 or LogC3 return to their own gamut. `Gamut.fromRec2020` builds each matrix from published primaries, and the pipeline multiplies it after the DNG matrix, which adds no GPU work. The Rec.709 monitor LUT and still export follow the setting. Sidecars and `still.json` name the gamut, and the file's own tag stays nominal Rec.2020 because it can't name these gamuts. The `.cube` conversion LUTs receive the recorded gamut, and stills keep the file name `log_rec2020.png` either way.
- **Needs samples first:** vignette correction needs a real `reference.dng` to find the `FixVignetteRadial` values, and highlight reconstruction needs clips with clipped highlights. Color accuracy needs a chart. Any real-time GPU work then needs a frame-cost test.
- **Needs the phone:** lens tests, the stabilization check and focus while recording.
- **Focus peaking sensitivity:** Low keeps the old threshold of 0.1 and High uses 0.05, set in Settings under Viewfinder. It's a `MonitorParams` field, so it adds no GPU work. Untested on the phone.
- **Settings pauses the stream:** opening Settings stops the stream, unless a take is running, and closing it resumes. Opening Diagnostics resumes it for good, because its tools need it. Looks and LUTs therefore can't be previewed behind the sheet. Untested on the phone.
- **Not started:** shutter priority, which needs an ISO loop during capture and its own frame-cost test, auto exposure with an EV slider, external microphones and file tagging options.

### How the camera screen works

- **Layout:** monospaced values around the picture. Every control keeps its portrait position in every hold and only its contents turn. The owner's earlier glass panels are gone: only black was ever behind them, so they added cost and no look.
- **Status:** two mirrored three-line blocks beside the Dynamic Island. Each is square so it can turn. Upright, its lines keep to the outer edge. Sideways, they center in the square, away from the screen's rounded corners. The owner reported text clipping before this change, and the fix hasn't been seen on the phone. Warnings are filled orange chips.
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
- **Settings:** one searchable page ordered by use, shown as a sheet. Format changes link to the panel. Presets hold a copy of every setting in `AppConfig` except the test link, inside `VibeLog.config.json`, and older presets convert when read. They don't hold lens, exposure, white balance or focus, which aren't saved settings. **Reset all settings** returns to `AppConfig`'s defaults. A row's menu sets the default, which replaces the saved format at launch, and deletes saved presets. With no default, the app opens on the last choices used. **Uncompressed audio** records 24-bit PCM instead of AAC, which stays the default until it's tested. The volume buttons toggle recording on iOS 18 and later.

Diagnostics is under **Advanced** in Settings.

## What presets keep

Every new setting needs a decision here, in the same change that adds it. Ask whether it describes how the owner works, or the shot in front of the camera. The first goes in a preset. The second stays out, so a preset never brings back a choice made for another scene.

- **Adding a setting to a preset:** put it in `AppConfig`, with `AppModel.config` writing it and `adoptSettings` reading it. `presetValues` then includes it, and **Reset all settings** returns it to its default. A setting missing from `adoptSettings` saves but never applies, and nothing fails to warn about it.
- **Keeping a setting out:** leave it out of `AppConfig`, or add it to what `presetValues` and `use` keep apart, as the test link does.
- **Last choices:** everything in `AppConfig` also carries over between launches, except `overlay`, which only comes back from a preset.

| Group | Settings | In presets |
|---|---|---|
| Format | Codec, size, aspect, frame rate, log curve, color space, **Pair curve and color space**, file tag, exposure offset | Yes |
| Processing | Pipeline, **Efficient when hot**, debayer, **Bilinear when hot**, fixed frame time, lens distortion correction | Yes |
| Recording | **Stop after**, auto during a take, uncompressed audio, gyro data, flicker-free shutter, **Slow viewfinder when hot** | Yes |
| Viewfinder | Look, LUT and **LUT made for**, freeze during a take, peaking sensitivity, frame guide, desqueeze, **Pause camera when idle** | Yes |
| Tools | Monitoring tools, zebras and false color | Yes |
| The shot | Lens, shutter, ISO, shutter priority, white balance, tint, focus, exposure bias, punch-in position | No, these belong to the scene |
| Test link | Server, token, connection, send switches | No, private to the device |
| Diagnostics | Capture method, RAW and photo formats, **Encode video**, **Write frames to disk**, **Log capture timing**, **Disconnect Apple's preview** | No, they're for test runs and reset at launch |
| Interface | **FINE** on the dials, debug overlay | No, they're saved on the device apart from settings |
| Presets | The presets and the default | No |

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
