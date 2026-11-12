# Status

Where things stand now. Rewrite this at the end of each session: move the finished session's
notes to [history](history/), anything proven to [findings.md](findings.md), and keep this file
short.

## Latest build

The latest build is `db879ba`, CI run 117, version 0.1.117, which passed with 194 tests and one
skip. It adds what automated testing needs from the app: the version and newest take in the test
link's status, leaving and returning to the app and each Export slider drag in the log. It also
adds **Log sharing** in Diagnostics, off until turned on with an invite code, sending anonymized
logs to the log service at `https://vibelog-logs.vibelog-testing.workers.dev`, with **Use mobile
data** as an option. See [decisions/automated-testing.md](decisions/automated-testing.md) and
[decisions/log-service.md](decisions/log-service.md). The service was checked live: refusals,
upload, pull and `--forget`. Nothing from 0.1.113 on has run on the 14 Pro yet.

On this computer: `tools/test_server.py round tools/rounds/2026-11-13.json` runs Tests 1, 2, 3,
5 and 6 on the 14 Pro and writes `round_*.md`; `tools/pull_logs.py` pulls shared logs into
`phones/`; `tools/check_secrets.py` runs as the pre-commit hook and in CI.

The builds before it, all from the sessions of 2026-11-11 and 12:

| Build | Run | What it added | On the phone |
|---|---|---|---|
| `b1cc9a8` | 116 | **Over the internet** as its own switch, main-thread stall logging | Proven on the base 16 |
| `d232d7e` | 115 | The test link reaches a phone elsewhere through ngrok, `serve --public` | Proven on the base 16, with 0.1.116's switch |
| `8c7f7d5` | 114 | A baked take's stabilized copy keeps its own codec | Not yet |
| `eed6df9` | 113 | FX keep light below zero; returning to the app no longer idle-pauses the camera | Not yet |
| `2368f1d` | 112 | Stabilize's timing fixed, its limit eased at 130%, a Stabilize screen for baked takes | Not yet |
| `652ba7a` | 111 | Ultra wide corrects every speed, maker note probe, legal and Gyroflow wording | Probe ran; stabilized copies measured |
| `7e2b514` | 110 | Stabilized export, its preview, stabilized copies of baked takes, stabilizer names in the probe | Probe ran |
| `35d43dc` | 108 | Baked-FX takes make the monitor image and glow every other frame | Proven: 20 minutes back to back |
| `907287d` | 107 | GPU cost test | Ran |
| `b740eab` | 106 | Baked-FX takes on the Efficient path, probe crash fix | Proven |

Run 109 never started and can be ignored. Every session is in
[history/2026-11.md](history/2026-11.md); the last is **Session on 2026-11-12, iPhone 16 logs**,
which ends with the base 16 over the internet link.

## Start here next session

1. **If 0.1.118 isn't built yet:** the owner redeploys the log service (`cf deploy` in
   `tools/log_service`, as in [decisions/log-service.md](decisions/log-service.md)), then push
   `a533f05` and later commits and build.
2. **Ask for [next-tests.md](next-tests.md)'s results** on 0.1.118: Tests 1 to 3 on both phones,
   Tests 4 to 6 from the base 16's tester. Then run `tools/pull_logs.py` and
   `tools/check_benchmark.py`.
3. **Then the benchmark batch** in [decisions/benchmark.md](decisions/benchmark.md): one batch,
   then fixes batched from what log sharing brings in.

## Waiting on the phone

Step-by-step instructions, with what to send, are in [next-tests.md](next-tests.md). In short:
**Run benchmark** and a take proving a codec, on both phones; log sharing's batching; the
base 16's ultra wide questions, slider drags and a 5-minute cold take.

The 14 Pro fetches over USB when plugged in: see **Before you start** in next-tests.md. The test
server is `python3 tools/test_server.py serve`; the phone then needs **Connect** on in
Diagnostics.

**Unanalysed:** Test 5's take B (`video_20261112_192135`), fast pans at 1/1000 s past vertical
lines, for the sensor's readout time, which rolling-shutter correction needs.

## Still to build

In rough order of what's most useful next:

- **The ultra wide's stabilization, proposed:** the 16's take showed no per-phone timing or
  direction fix is needed, and that the field of view's focal length reads short at the centre.
  Build Measure stabilizer below, saving each lens's timing offset, direction and optics share, with fast
  correction off for a lens whose fit is poor; then lens distortion in the warp, from a Gyroflow
  calibration import for the ultra wide, which Apple gives no table for in RAW; then rolling
  shutter, once the readout time is measured.
- **Notices, internal limits, fitted defaults and a rerun button from the first-launch
  benchmark, proposed:** the app already
  times every codec and size once per phone and iOS version (`EncoderSupport`), picks the first
  launch's default from it, and warns before a take whose codec encoded under 30 fps. The owner
  asked on 2026-11-12 to show the results:
  - **In the format panel,** each codec and size marked by its measured rate: holds 30 fps with
    room, at the limit (under 36 fps, the margin `bestDefault` uses), or too slow, with the
    figure. On the base iPhone 16, ProRes 422 HQ at full size would read too slow, 17.7 fps.
  - **A one-time notice after the benchmark,** in plain words: what this phone records best, and
    what it can't, such as "ProRes is encoded in software here, so it can't hold 30 fps at full
    size; HEVC 4:2:2 at 2880x2160 is the best fit". Kept in the take's details and Diagnostics.
  - **Other measured limits in the same notice:** a capture setup off the standard one, such as
    "fast capture off", and the lenses with RAW.
  - **Nothing visible is locked:** every codec, size and setting the screens offer stays
    pickable, whatever the benchmark says. A choice at or over the limit is marked and warned
    about, nothing more. Presets and the test link apply what they hold, with the same warning.
  - **What isn't in Settings is limited from it:** choices the app makes by itself follow the
    measurement, such as the path a baked-FX take runs on, how often the monitor image and glow
    are made during a take, the viewfinder's LUT size, the scope's rate, the export preview's
    size and the capture setup, so a phone with less room gets the lighter internal setting
    without anyone choosing it. A phone with room keeps today's internal settings, so the 14
    Pro's proven Maximum quality setup stays as it is.
  - **Defaults comply with the tests:** on the first launch, and after **Measure encoders
    again**, every default, codec, size, pipeline and the hot paths, is set to what this phone
    measured holding 30 fps with room. Only a setting nobody has touched moves, as `fitToPhone`
    does for codec and size today, and the notice says what moved.
  - **Run benchmark:** one button in Settings, **Advanced**, **Diagnostics**, where
    tests live by the design rules. It merges with the existing **Encoder test**, which only
    writes a report today, so one run saves the report and updates the limits. It stops the
    camera first and waits for nominal heat, since the first-launch check ran with the stream
    open and a hot phone encodes slower, and it records the heat it ran at. The notice says
    when the limits were measured, and offers a new measurement after an iOS update.
  - **Quiet when there's room:** nothing shows for a setting that holds 30 fps with room to
    spare. The format panel marks only the codecs and sizes at or over the limit, the warning
    chip appears only when the current setup is at or over it, and the one-time notice is shown
    only if a limit touches something this phone would otherwise offer.
  - **Baked looks and FX count:** today's warning skips baked takes altogether. The judgement
    should be of the whole setup a take would run: the codec the bake really writes, with
    **Bake to ProRes** and HDR's HEVC, and the GPU work of the look, the grade and baked FX on
    top of the debayer. The benchmark then also times the GPU for each setup, log, baked look,
    baked look with FX, and HDR, on the path each really uses, as the existing GPU cost test
    does, and the encoder and GPU limits are judged together.
  - **Calibrated against takes, not the cost test alone:** a take's GPU time reads two to three
    times its isolated cost on the 14 Pro, and baked FX on the Maximum path fell behind after
    about two minutes while the Efficient path held 20. So the GPU limit is set from the
    measured cost times a margin taken from those takes, and is trusted for the app's own
    internal choices and defaults only once a long take on a second phone confirms it.
  - **What the benchmark measures,** once per phone and iOS version, about 4 to 5 minutes with
    the phone lying still, pointed at any scene:
    1. **Capture per lens,** about 10 s of RAW on each, counting fps, missed, duplicates and
       stalls, and trying the capture setups in order: the setup per lens is known before first
       use, so the base 16 skips its 12 s of stalls. 30 to 60 s.
    2. **Lens profiles,** **Measure Lenses** as today, which Stabilize needs. 20 to 30 s.
    3. **Encoders,** every codec and size as today, longer, with the camera stopped and at
       nominal heat, plus the 10-bit HEVC control the 12-bit check still owes. 1 to 2 minutes.
    4. **GPU per setup,** the GPU cost test on each path: Maximum and Efficient, both debayers,
       baked look, baked FX, HDR and the scope. About a minute.
    5. **Two or three real 20 s takes** of the best candidates, camera, GPU and encoder
       together, to a scratch file deleted after: the separate trials miss what only shows
       together, as full-size ProRes on the 16 looked fine for 6 s and then lost half its frames.
       About a minute.
    6. **The probe, quietly:** formats, RAW types, stabilizer switches, and video formats for
       the native log mode. Under a minute.
    7. **Read, not tested:** the screen's refresh rate, for the viewfinder's draw rate, and free
       space.
  - **Left to real takes:** heat endurance, which would take 10 minutes or more and heat the
    phone, so each long take's heat and GPU history adjusts the internal choices instead; write
    speed past 8 GB, keeping the 10 GB stop; and anything needing movement or a target,
    stabilizer timing and direction, the optics' share, readout time and a colour chart, which
    could become an optional guided step once Measure stabilizer exists.
  - **How it runs:** offered at first launch and after an iOS update, never started unasked. It
    asks for the phone lying still, at 50% battery or more, nominal heat and preferably
    unplugged. Each step shows, it can be cancelled, a cancelled run resumes where it stopped,
    and an unfinished run leaves the defaults alone. Results are saved per model and iOS
    version, written to the session log and shown in Diagnostics.
  - Every line comes from this phone's own measurement, never a model name, by the rules in
    [decisions/per-phone-fitting.md](decisions/per-phone-fitting.md). A new iOS version measures
    again, as now.
- **Automated testing, agreed:** scripts decide results, a round runner on the server, guided
  takes with movement cues, and **Calibrate stabilizer** built on them. See
  [decisions/automated-testing.md](decisions/automated-testing.md); step 1 needs no build.
- **Laggy sliders on the base iPhone 16:** the main-thread check, in 0.1.116, ruled out a busy
  main thread in Export. Test 7 now asks whether diagonal drags stick, which would mean the
  form's scroll takes them. The viewfinder's draw stays on the main thread: it held it 0.2 to
  0.5 ms on average there.
- **Stabilize, after the phone's verdict:** see
  [decisions/stabilized-export.md](decisions/stabilized-export.md) for the design and its
  limits. Left: rolling-shutter correction, lens distortion in the warp, a horizon lock, a view
  of the whole frame with the kept part outlined, and a limit that follows the shake's size.
- **Measure stabilizer, per lens:** the take-against-gyro fit done by hand on `220644`, built
  into the app, so each lens gets its own curve in place of the 1x's 2 Hz. The exact route is
  closed: the lens's shift isn't in a RAW photo's maker note, and no switch exists for a plain
  RAW stream. Logging maker note keys 15 and 12 through a real take, and two unpublished options
  for offline stabilization, are untried.
- **The `.gcsv`'s orientation by hold,** so Gyroflow corrects the right axes on upright takes.
  Needs one test take each way up.
- **A native log mode for Pro phones,** starting with the probe listing video formats: see
  [decisions/native-log-mode.md](decisions/native-log-mode.md).
- **ACES 1.3 HDR.**
- **Lens profiles, next steps:** the straight-edge check, colour from a chart, the readout time,
  and a measured profile for the ultra wide, whose focal length comes from its field of view.
- **Then the rest of Phase 8:** denoise and proxies.

**Decisions waiting on the owner:**

- **Strike the stabilizer switch for takes off the list?** Brackets reach 20.8 fps at best on
  the 14 Pro and 18.7 on the base 16, and the probes found no other switch.

**Done for now:** FX in baked takes. They run on the Efficient path with the glow every other
frame, and held 20 minutes back to back with no cooling, 32 frames lost.

## How the copies were measured

This machine has no numpy, so a short pure-Python script did it; it isn't in the repo.

1. Fetch the take and its copy over the link with `sendFile`, and the `.gcsv`.
2. Decode each to quarter-size grey frames in the sensor's own orientation: `ffmpeg
   -noautorotate -i take.mov -fps_mode passthrough -vf scale=1008:756:flags=area,format=gray -f
   rawvideo`.
3. For each frame pair, find the shift of the middle half's row sums and column sums, and of
   the left and right thirds' row sums for roll. The content's own move is minus that shift.
4. Fit those to the angle the gyro turned between the two frame times, times the lens profile's
   focal length, split into slow and fast at about 2 Hz, trying lags of a few ms each way.

The measured directions: a turn about the phone's x moves the picture right, about y moves it
up, and about z turns it clockwise, in the stored picture's axes.
