# Next phone tests

Step-by-step tests for the builds of 2026-11-12, written so a tester can run them without
knowing the code. Each test says what to set, what to do, what to look for and what to send.
Rewrite this file when a new round of tests is planned, and move the results to
[findings.md](findings.md).

## Before you start

- **Install 0.1.114 or later.** SideStore should offer it as an update. If it doesn't, install
  the `.ipa` from the latest green build. Say which version you tested; SideStore shows it.
- **Charge to at least 50%,** and let the phone cool for a few minutes if it was hot.
- **Where the files are:** Files app, **On My iPhone**, **VibeLog**. Takes are in `videos/`:
  each take is `video_<date>_<time>.mov` with `.mov.json` (its details) and `.gcsv` (its gyro
  log) beside it, and a stabilized or exported copy is `<take>_look.mov`, with its own
  `.mov.json`. Session logs are in `logs/`, and lens profiles in `lenses/<phone model>/`.
- **Sending files:** select them in Files and share by AirDrop, or upload them to a shared
  folder. A take's `.mov` is large: for the stabilization tests, keep takes short, 20 to 30
  seconds. On the 14 Pro, plugging into the owner's computer or the test link also works.
- **Always send the session log** from `logs/` for the time of the tests, the newest
  `session_*.log`, even when a test looks fine.

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

## Test 4: the ultra wide's stabilization on the iPhone 16

The tester reported that Stabilize adds small fast shake on this lens. This take lets the cause
be measured against the gyro log: timing, direction or scale. The phone is the base iPhone 16,
`iPhone17,3`, whose ultra wide has no optical stabilizer.

**Once, before the take:** Settings, **Advanced**, **Lenses**, **Measure Lenses**, with the
phone lying still. It must list the 0.5x.

**Settings:**

- Lens **0.5x**. Look **LOG**, nothing baked, no FX.
- **FORMAT:** HEVC 4:2:2, the size the phone uses normally.
- **SHUTTER** at 1/250 s, set by hand, so frames are sharp. **ISO** whatever gives a normal
  picture; a bright room or daylight helps.
- **Save gyro data** on, which is the default.

**The scene:** something with plenty of detail and straight lines, at least 3 metres away: a
bookshelf, a building, a room with furniture. No people or cars moving through it.

**The take, about 25 seconds, holding the phone sideways (landscape) with both hands:**

1. Hold as still as you can for **3 seconds**.
2. **Three slow pans:** turn left over 2 seconds, then back right over 2 seconds, three times.
3. Hold still for **3 seconds**.
4. **Small fast shake for 4 seconds:** keep the phone pointed at the same spot and shake it in
   small quick movements, as a tired hand or a running engine would.
5. Hold still for **3 seconds**.
6. **Two slow tilts:** up over 2 seconds and back down over 2 seconds, twice.
7. Stop.

**Then:** open the take, tap **Export**, turn **Stabilize** on, leave **Smoothness** at
Medium, 0.6 s, and export. Watch the preview with Stabilize off and on before exporting, and
write down where the copy shakes more than the take: during the fast shake, the holds or the
pans.

**Send all of these:**

- The take: `video_…mov`, `video_…mov.json` and `video_…gcsv`
- The copy: `video_…_look.mov` and its `.mov.json`
- The lens profiles: everything in `lenses/<phone model>/`
- The session log
- What you wrote down, and whether the phone was held sideways the whole time

If the files are too large to send, record step 4 only, with 3 seconds still before and after.

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

## What the results decide

- **Tests 1 to 3** close `eed6df9` and `8c7f7d5`, or show what's still wrong.
- **Test 4** decides the fix for the 16: a timing offset or a flipped direction for that lens,
  saved per phone by the planned **Measure stabilizer**.
- **Tests 5 and 6** decide what comes after: lens distortion in the warp first if the edges bend
  while the middle stays steady, rolling-shutter correction first if lines lean in Take B.
