# How it works

How the app behaves and the rules that keep it that way. For how to use it, see
[using.md](using.md).

## Code notes

New additions follow the design rules in [ROADMAP.md](../ROADMAP.md). `CameraGeometry.topShare` sets
the picture's top and bottom edges, and that share is an estimate of the Camera app's split, not a
measurement. The config's `toolbar` and `telemetry` fields are no longer used by the app.

## The camera screen

- **Layout:** monospaced values around the picture. Every control keeps its portrait position in
  every hold and only its contents turn. The owner's earlier glass panels are gone: only black was
  ever behind them, so they added cost and no look.
- **Status:** two mirrored blocks beside the Dynamic Island, the format lines on the left and the
  gauges and settings gear on the right, since batch 5. Each is square so it can turn. Upright, its
  lines keep to the outer edge. Sideways, they center in the square, away from the screen's rounded
  corners. The owner reported text clipping before this change, and the fix hasn't been seen on the
  phone. Warnings are filled orange chips.
- **Control bar:** ISO, shutter, white balance and focus. Amber means set by the user, an A badge
  means auto and a lock means frozen for the take.
- **Tray:** above the control bar, it shows the tools and lenses, a dial or the **MON** tools, so
  the control bar always stays. During a take the mic meter replaces the lenses.
- **Dials:** they have **AUTO** and **FINE**. The white balance dial also sets tint, the shutter
  dial has **180°**, and the focus dial has **PUNCH** and **PEAK**. Shutter angle shows while the
  shutter dial is open.
- **Format:** **FORMAT** opens slidable columns for codec, chroma or ProRes profile, size, log
  curve, aspect and frame rate. **ASPECT** calls 4:3 **OPEN GATE**, and **SIZE** shows the full
  recorded size for the chosen aspect. It's square-cornered and reaches from the screen's edge to
  the picture, with its rows sharing the depth. ProRes has no 4:2:0. Changing frame rate rebuilds
  the session 0.3 seconds after the column settles, unlike the other columns, and record waits for
  it.
- **Clock:** with the drop count, it takes the two columns right of record in every hold. It shows
  only the digits in use, at the largest size that fits.
- **Notices:** short notices cover the tray and control bar for a few seconds, and a tap clears
  them. A take that ends early leaves an orange card until dismissed.
- **EV:** an offset stays visible in the tool row, and a tap resets it.
- **Last take:** the thumbnail left of record plays the newest video and stops the stream until the
  screen closes. Sound follows the silent switch, because audio session settings were left alone to
  protect recording.
- **Library:** back from that player is every take in `videos/`, newest first, with drops marked.
  Each has **Details** from its sidecar, **Share**, which includes the gyro log, and **Delete**,
  which also removes the sidecar and gyro log. **Select** or a long press deletes from the grid. RAW
  dumps stay in the Files app.
- **Full view:** at 16:9 the tool row offers a 699x393 picture that leaves the 4:3 frame with only a
  strip beneath it. A take that stops early leaves it.
- **Punch-in:** it moves where the existing monitor draw samples, so it adds no GPU work. It shows a
  third of the picture, close to one sensor pixel per drawable pixel in Maximum quality and half
  that in Efficient. It opens on the last focus point and drags, including during a take.
- **Focus peaking:** a `Tool` that marks fine detail in cyan on the monitor, with four extra texture
  reads per drawable pixel while it's on. Its neighbors are fixed at about three sensor pixels, so
  punching in doesn't weaken it.
- **Mic meter:** the bar moves about twelve times a second by writing to Core Animation layers from
  the audio queue, so it skips the main thread. Its dB number updates once a second. Green runs to
  -12 dB, yellow to -3 dB, then red.
- **Gyro log:** with **Save gyro data** on, which is the default, each encoded take gets a `.gcsv`
  of the same name in `videos/`, from `CMDeviceMotion` at 100 Hz, the most the phone delivered when
  asked for 200, on its own utility queue. A 5-second sample was evenly spaced with sensible units,
  but began 0.14 seconds after the first frame, because motion updates take that long to start, so a
  take's first frames have no gyro data. Time zero is the first frame, on the same clock as frame
  timestamps, and the file is flushed once a second. Rotation is CoreMotion's bias-corrected rate.
  RAW dumps get none. Share sends it with the video, and delete removes it.
- **Settings:** one searchable page ordered by use, shown as a sheet. Format changes link to the
  panel. Presets hold a copy of every setting in `AppConfig` except the test link, inside
  `VibeLog.config.json`, and older presets convert when read. They don't hold lens, exposure, white
  balance or focus, which aren't saved settings. **Reset all settings** returns to `AppConfig`'s
  defaults. A row's menu sets the default, which replaces the saved format at launch, and deletes
  saved presets. With no default, the app opens on the last choices used. **Uncompressed audio**
  records 24-bit PCM instead of AAC, which stays the default until it's tested. The volume buttons
  toggle recording on iOS 18 and later.

Diagnostics is under **Advanced** in Settings.

## What presets keep

Every new setting needs a decision here, in the same change that adds it. Ask whether it describes
how the owner works, or the shot in front of the camera. The first goes in a preset. The second
stays out, so a preset never brings back a choice made for another scene.

- **Adding a setting to a preset:** put it in `AppConfig`, with `AppModel.config` writing it and
  `adoptSettings` reading it. `presetValues` then includes it, and **Reset all settings** returns it
  to its default. A setting missing from `adoptSettings` saves but never applies, and nothing fails
  to warn about it.
- **Keeping a setting out:** leave it out of `AppConfig`, or add it to what `presetValues` and `use`
  keep apart, as the test link does.
- **Last choices:** everything in `AppConfig` also carries over between launches, except `overlay`,
  which only comes back from a preset.

| Group | Settings | In presets |
|---|---|---|
| Format | Codec, size, aspect, frame rate, log curve, color space, **Pair curve and color space**, the pairs and LUTs under **Color spaces and LUTs**, file tag, exposure offset, **Bake**, **Bake to ProRes**, **Bake as** | Yes |
| Processing | Pipeline, **Efficient when hot**, debayer, **Bilinear when hot**, fixed frame time, lens distortion correction, **12-bit ProRes 4444** | Yes |
| Recording | **Stop after**, auto during a take, uncompressed audio, stereo audio, gyro data, flicker-free shutter, **Slow viewfinder when hot** | Yes |
| Viewfinder | ISP preview, look and **LUT made for**, the look's grade, COLOR and FX, **Overlay scope channels**, freeze during a take, peaking sensitivity, frame guide, desqueeze, **Pause camera when idle** | Yes |
| Tools | Monitoring tools, zebras and false color | Yes |
| The shot | Lens, shutter, ISO, shutter priority, white balance, tint, focus, exposure bias, punch-in position | No, these belong to the scene |
| Test link | Server, token, connection, **Over the internet**, send switches | No, private to the device |
| Diagnostics | Capture method, RAW and photo formats, **Encode video**, **Write frames to disk**, **Log capture timing** | No, they're for test runs and reset at launch |
| Interface | **FINE** on the dials, debug overlay | No, they're saved on the device apart from settings |
| Presets | The presets and the default, and saved styles | No, they're libraries kept beside the settings |

## Adjusting the camera while recording

From two 46-second control tests at 30 fps. The first ran at nominal heat, the second at serious
heat and 16:9, so they aren't direct comparisons. Windows should hold 30 frames per second.

| Change during the take | Frames | Expected | Result |
|---|---|---|---|
| Lens position jump | 119, 120 | 120 | Clean |
| Tap focus, center and corner | 116, 113 | 120 | Lost 4 and 7, with a 233 ms gap |
| Focus rack at dial speed, 10 changes a second | 32 | 61 | **Lost 29 frames** |
| Switch to continuous autofocus | 112 | 120 | Lost 8, with a 267 ms gap |
| ISO ramp at dial speed, 200 to 400 | 61 | 61 | Clean |
| Exposure steps and return to auto | 120, 120, 120, 60, 119 | 120, 120, 120, 60, 120 | Clean |
| White balance steps and return to auto | 120, 120, 120 | 120 | Clean |

- **Allowed during a take:** ISO, shutter, white balance and tint dials, monitor tools, punch-in and
  Full view. With **Auto exposure and white balance during a take** on, **AUTO** on those dials also
  works.
- **Blocked during a take:** every focus change, and exposure drag, because bias was cut short by
  the writer failure.
- **Must stay locked:** lens, frame rate and capture settings, because any change rebuilds the
  session. Curve, exposure offset, debayer, crop and pipeline, because they're baked in and the
  clip's metadata is written at the start.
- **Holds during a take:** focus always freezes as a take starts and resumes when it ends. Exposure
  and white balance do the same unless **Auto exposure and white balance during a take** is on,
  which is off by default until its control test passes; values set by hand stay either way. The
  sidecar records which happened. The cost of those mode changes hasn't been measured on the phone.
  If reduced load starts during a take, only the log and the popup show it; the clip's metadata
  records the state at the start.
- **Not settled:** Per-frame ISO, shutter and white balance values are read when a photo arrives, so
  they can lag the frame. White balance gains are baked into the debayer. The RAW frames have no
  focus breathing correction.

The ISP monitor removes the Metal view, so it stays in Settings. Keep SwiftUI updates to about once
a second while recording, and avoid continuous animations, because main-thread load has cost frames
before. A faster reading draws on its own layers from its own queue, as the mic bar does.

## Fitting each phone

The rules are in [decisions/per-phone-fitting.md](decisions/per-phone-fitting.md). A phone only
leaves the standard setup on its own evidence, so a workaround for one never reaches another.

- **Capture:** `CaptureSupport` holds the step of `CaptureSetup.ladder` this phone streams on, in
  `capture_support.json`, per phone model and iOS version. `PhotoRawDriver` retries one stall in
  place. After two with no frame between, or four in 20 seconds, it stops and `CameraController`
  calls `onCaptureStalled`, unless the session is interrupted or the method was picked in
  Diagnostics. `AppModel.captureStalled` moves to the next step and rebuilds. 90 frames on a new
  step save it. When every step stalls, the stream stops with a card and a tap tries again from
  the standard setup.
- **Encoders:** `EncoderSupport` times each codec once per phone and iOS version. `bestDefault`
  picks the first launch's codec and size: the wanted codec if it holds full size at 36 fps or
  more, otherwise the most pixels, then room to spare, then the same chroma. Only an untouched
  default moves. The first launch's check is quick, with the camera running and 20 frames, and
  under-reads: on the 14 Pro, HEVC at full size read 27.5 fps against 30.5 with the camera
  stopped, ProRes 422 HQ 81 against 194. **Measure this phone again** in Diagnostics measures with
  the camera stopped, 45 frames, at nominal heat when it can, and records the method and heat.
- **Takes outrank trials:** a log take in the chosen size, five seconds or more, fed 29 fps or
  more with the encoder refusing nothing goes into `proven`; frames lost at the camera or the GPU
  don't count against the encoder, and that codec and size never warns
  again; one whose encoder refused frames goes into `strained` and always warns.
  `tools/check_benchmark.py` lists where a phone's figures disagree with its takes.
- **GPU:** `GPUSupport` keeps the GPU cost test's median per recording setup, by path, work (log,
  baked look, baked FX) and debayer, in `gpu_support.json`. **Measure this phone again** runs it
  after the encoders. Its time alone can't say whether a take will hold, since a take's GPU time
  reads two to three times it and heat decides over minutes, so takes decide: a take of 150 s or
  more that lost under 0.2% of its frames on the GPU proves its setup, and one that lost over 1%
  strains it. A setup warns only when strained, or when it costs more than a tenth over the
  heaviest proven one. With no takes yet, nothing warns. A take whose path or debayer changed for
  heat proves nothing.
- **Adding a fallback:** give it a step on the ladder or a measured trial, never a model name, and
  put the costlier change later.

## Encoder failures

Two takes ended with `-11800`, underlying `-16364`, after 92 and 820 frames, both at serious heat.
It appeared after the move to Xcode 26 and is unconfirmed. Community reports link `-16364` to
timestamps that don't advance. The encoder now drops any frame that doesn't advance and logs it, and
a failure logs timestamps, rotation, heat and free space. If it returns with no out-of-order frames
logged, timestamps are ruled out. It didn't return during the 10:12 run, which spent 5 minutes at
serious heat, but that was in Efficient.

## Test link, for test sessions

**Test link** in Diagnostics connects the phone to `tools/test_server.py` on the owner's computer,
so a session can run tests itself. [test-link.md](test-link.md) covers privacy, running the server
and removing it. It's off at every launch, and can't be switched on from the server.

- **Setup:** run `python3 tools/test_server.py serve`, which prints the address and token, and keeps
  files in `~/VibeLogTest`. `/home` on this machine has no room for clips, so
  `~/.vibelog_test_folder` points it at the larger drive. Enter both in Diagnostics and turn on
  **Connect**. iOS asks for Local Network permission the first time. The computer's firewall must
  allow port 8765.
- **Commands:** `python3 tools/test_server.py send status`, `send set <name> <value>`, `send record
  <seconds> --wait` and the rest in [test-link.md](test-link.md). `set` takes lens, frameRate,
  codec, size, aspect, curve, gamut, pipeline, debayer, peaking, exposureOffset, shutter, iso,
  uncompressedAudio, saveGyro, captureTiming, fixedFrameTime, slowViewfinderWhenHot,
  bilinearWhenHot, autoDuringTake, distortionCorrection, efficientWhenHot, isoAuto, frameGuide,
  fileTag, desqueeze, tools, method, encodeVideo, writeFrames, look, lut, lutMadeFor,
  freezeViewfinder, pairsGamut, twelveBitProRes, bakeLook, bakeToProRes, bakeTarget, grade, style,
  effects, scopeOverlaid, stereoAudio, idlePauseMinutes, punch, stopAfter, whiteBalance, tint, focus
  and exposureBias. A wrong value replies with the choices. `lut` also takes `ACES 2.0` and `ACES
  1.3`, and `frameRate` matches by label.
- **Limits:** the app only acts on the fixed list in `App/TestCommands.swift`. Nothing there deletes
  a take. Only tools, look and punch-in change during a take. Files wait until a take ends, and
  videos only go by `sendFile`. It's plain HTTP with a token, so it suits a private network only,
  apart from `serve --public` behind an ngrok tunnel, with its long token and lockouts, which the
  app reaches only with **Over the internet** on.
  The phone must be awake, with VibeLog open, and someone must point it at the scene.
- **Cost:** one idle request stays open during a take, on its own queue. 40-second takes lost
  nothing with it connected, but no take has compared it with the link off.
- **Proven:** it connected on the phone, ran these tests, and delivered logs, sidecars, gyro and
  timing files.

## Known simulator limits

- Linear textures on shared buffers crash the simulator, so the RAW copy path can only be tested on
  the phone.
- `blit.synchronize(resource:)` isn't available on iOS.
- There's no camera or microphone, so capture and audio are phone-only.
