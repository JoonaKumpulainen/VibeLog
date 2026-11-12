# Next phone tests

Step-by-step tests for the builds of 2026-11-12, written so a tester can run them without
knowing the code. Each test says what to set, what to do, what to look for and what to send.
Rewrite this file when a new round of tests is planned, and move the results to
[findings.md](findings.md).

## Before you start

- **Install 0.1.116 or later.** SideStore should offer it as an update. If it doesn't, install
  the `.ipa` from the latest green build. Say which version you tested; SideStore shows it.
- **Charge to at least 50%,** and let the phone cool for a few minutes if it was hot.
- **Where the files are:** Files app, **On My iPhone**, **VibeLog**. Takes are in `videos/`:
  each take is `video_<date>_<time>.mov` with `.mov.json` (its details) and `.gcsv` (its gyro
  log) beside it, and a stabilized or exported copy is `<take>_look.mov`, with its own
  `.mov.json`. Session logs are in `logs/`, and lens profiles in `lenses/<phone model>/`.
- **Sending files:** select them in Files and share by AirDrop, or upload them to a shared
  folder. A take's `.mov` is large: for the stabilization tests, keep takes short, 20 to 30
  seconds. On the 14 Pro, plugging into the owner's computer or the test link also works.
- **Through the test link instead:** on 0.1.116 a phone elsewhere can connect to the owner's
  computer through ngrok, and the owner fetches files and runs the steps marked for the link.
  The owner sends the address and token privately. In Settings, **Advanced**, **Diagnostics**,
  turn on **Over the internet**, enter the whole `https://` address as the server and the token,
  and turn on **Connect**.
  While connected, the owner's computer can start takes, take stills of what the camera sees
  and fetch files, and the files pass through ngrok's servers. Turn **Connect** and **Over the
  internet** off and clear both fields when done.
- **Always send the session log** from `logs/` for the time of the tests, the newest
  `session_*.log`, even when a test looks fine.

## On the 14 Pro with the test link: one round

From 0.1.117, Tests 1, 2, 3, 5 and 6 run as one round from the owner's computer, which records,
exports, fetches and judges them itself and puts the settings back after:

```bash
python3 tools/test_server.py round tools/rounds/2026-11-13.json
```

The phone stays on the camera screen. The round waits for Enter before each step that needs a
person: pointing at a dim scene, walking, the two ultra wide takes, and leaving the app for 3
minutes. It writes `round_*.md` in the results folder, with the questions it can't answer. The
steps below are the same tests by hand, for the iPhone 16's tester.

## Test 1: FX keep the shadows (both phones)

Checks `eed6df9`. FX used to lift the darkest parts of the picture to a grey floor.

1. Record a 10-second **log** take of a dim indoor scene with dark areas, at a high ISO such as
   2000 or more. Look **LOG**, so nothing is baked.
2. Open it from the thumbnail and tap **Export**. In the grade editor's **FX** page, raise
   **Grain** to about 20, then set it back to 0. Do the same with **Bloom**.
3. Look at the darkest areas of the preview each time.

**Expected:** with FX on, the shadows stay as dark as with FX off. Only the effect itself
changes: grain shows in the shadows, bloom glows around lights. No grey veil over the picture.

**Send:** a screen recording of step 2, the take's name and the session log.

## Test 2: the camera keeps running after leaving the app (both phones)

Checks `eed6df9`. The camera used to pause itself a second after coming back.

1. Open VibeLog on the camera screen, with the picture moving.
2. Go to the home screen, wait **3 minutes**, then open VibeLog again. Touch nothing.
3. Watch for 10 seconds.

**Expected:** the picture keeps moving, with no "Camera paused to save heat" notice.

**Send:** say what happened, and the session log.

## Test 3: Stabilize keeps a baked take's codec (14 Pro)

Checks `8c7f7d5`. A baked take's Stabilize screen no longer has a codec choice.

1. In **LOOK**, pick ACES 2.0 and turn on **BAKE**. In **FORMAT**, pick ProRes 422 HQ.
2. Record 10 seconds, walking slowly with the phone, which gives it something to steady.
3. Open the take and tap **Stabilize**. Check the screen has **Smoothness** and **Show
   stabilized**, but no **Codec** or **Size**. Tap **Save stabilized copy**.
4. Repeat steps 1 to 3 with HEVC 4:2:2 instead of ProRes.
5. In the library, open each copy's **Details**.

**Expected:** each copy's **Codec** in Details is the same as its take's: ProRes 422 HQ for the
first and HEVC 10-bit 4:2:2 for the second. The ProRes copy is about as large as its take; the HEVC
copy no smaller than its take.

**Send:** both takes' and both copies' `.mov.json`, and the session log. The videos aren't
needed.

## Test 4: the ultra wide's stabilization on the iPhone 16 (done)

Run over the internet link on 2026-11-12: take `140255` and its copy, measured. The copy steadied
the take everywhere and added no shake; the results are in [findings.md](findings.md). Two
questions for the tester remain:

1. **Which build made the copy that shook more?** Before 0.1.112, every copy was 20 ms out of
   step, which on this lens works against small fast shake.
2. **If a copy on 0.1.116 still looks shakier,** send that take and its copy, and its shutter
   speed. At 1/50 s the picture holds still but its motion blur changes direction with each shake,
   which can look like vibration; stabilized takes want 1/250 s or faster.

## Test 5: the ultra wide's edges on the 14 Pro

The edges of a stabilized ultra wide copy shake and bend. This take shows how much comes from
the lens's distortion and how much from rolling shutter, and measures the sensor's readout time.

**Settings:** as Test 4, on the 14 Pro's **0.5x**. The lens profiles were measured before;
measure again only if Lenses shows no 0.5x.

**The scene:** straight vertical and horizontal lines near the **edges** of the frame, such as
door frames, shelves, window frames or tiles, at least 2 metres away.

**Take A, 25 seconds:** the same script as Test 4, held sideways.

**Take B, 10 seconds, for the readout time:** shutter at **1/1000 s**. Point at a scene with
tall vertical lines. Hold still 2 seconds, then **pan quickly** left and right across them,
about half a turn a second, three times, then hold still 2 seconds.

**Then:** export Take A with **Stabilize** on, Smoothness Medium. Watch the copy and write down
whether the edges bend as the picture moves, whether the middle stays steady, and whether
vertical lines lean during fast moves.

**Send:** both takes with their `.mov.json` and `.gcsv`, Take A's copy and its `.mov.json`, and
the session log. With the phone on the test link, the owner's computer can fetch these with
`sendFile` instead.

## Test 6: Stabilize with its timing fixed (14 Pro)

Waiting since `2368f1d`. The first copies kept too much shake on the 0.5x.

1. Open take `000714` (0.5x) and `220644` (1x), both still on the phone. On each, tap
   **Stabilize** and save a copy at Smoothness Medium.
2. Record one new **log** take on the 1x with some walking, and export it with **Stabilize** on.
3. Compare each copy with its take.

**Report:** whether each copy is steadier than its take, whether anything shakes that didn't
before, whether the 0.5x still shakes, and whether an edge of the picture ever shows.

**Send:** the three copies with their `.mov.json`, and the session log. With the test link on,
the copies can be fetched instead.

## Test 7: laggy sliders (base iPhone 16)

The first part ran on 2026-11-12: dragging Export's grade sliders for a minute stalled the main
thread only twice, worst 128 ms, so a busy main thread isn't the cause. The next suspect is the
scrolling form the sliders sit in, which may take a drag that moves even slightly up or down.

1. Open a log take, tap **Export**, open the grade editor.
2. Drag one slider **slowly and exactly sideways**, keeping the finger level, ten times.
3. Drag the same slider **diagonally**, a little up or down as it moves, ten times.
4. Do the same with **Smoothness** under **Stabilize**, which sits in the same form.

**Send:** a screen recording, the session log, and say for each how many drags you made. From
0.1.117 the log counts the drags each slider took, so a drag the scroll took shows as missing.
If only the diagonal drags go missing, the scroll is taking them.

## Test 8: log sharing (both phones, 0.1.117)

New in 0.1.117. Checks that logs reach the test service, made anonymous, and only when allowed.

1. In Settings, **Advanced**, **Diagnostics**, turn on **Share test logs** and confirm. Check the
   server reads `https://vibelog-logs.vibelog-testing.workers.dev`, and enter the invite code
   the owner sends privately.
2. On Wi-Fi, tap **Send now**. **State** should read "Sent N files" within a minute.
3. Turn Wi-Fi off, leaving mobile data on, and tap **Send now**: it should read "Waiting for
   Wi-Fi". Turn on **Use mobile data**, record a 5-second take, and tap **Send now**: it should
   send the new files.
4. Note the **Anonymous ID** shown, and say it to the owner.

**Owner:** `python3 tools/pull_logs.py`, then check `phones/report.md` lists the phone, and that
no file under `phones/` holds a date like `20261113_`, a network address or a preset name.

**Send:** what **State** read at each step.

## What the results decide

- **Tests 1 to 3** close `eed6df9` and `8c7f7d5`, or show what's still wrong.
- **Test 4** showed the 16 needs no per-phone timing or direction fix; its two questions say
  whether anything is left.
- **Test 7** decides the slider fix: if diagonal drags stick, keep the form from scrolling while
  a slider is held, or give the grade editor's sliders a layout that doesn't scroll.
- **Tests 5 and 6** decide what comes after: lens distortion in the warp first if the edges bend
  while the middle stays steady, rolling-shutter correction first if lines lean in Take B.
