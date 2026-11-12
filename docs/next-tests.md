# Next phone tests

Step-by-step tests for 0.1.118, written so a tester can run them without knowing the code. Each
test says what to do, what to look for and what to send. Rewrite this file when a new round of
tests is planned, and move the results to [findings.md](findings.md).

Settled on 2026-11-12 by the first self-checking round on the 14 Pro, and no longer here: FX keep
the shadows, the camera keeps running after leaving the app, Stabilize keeps a baked take's codec,
Stabilize's timing fix on the 0.5x, and the ultra wide's edges (they shake in hard shake but
don't bend). See [findings.md](findings.md).

## Before you start

- **Install 0.1.118 or later.** SideStore should offer it as an update. Say which version you
  tested; Diagnostics' **Encoder limits** line only exists from 0.1.118.
- **Charge to at least 50%,** and let the phone cool for a few minutes if it was hot. Low Power
  Mode slows the phone's Wi-Fi a lot, so turn it off.
- **Sending files:** with **Log sharing** on (Settings, **Advanced**, **Diagnostics**), logs,
  take details and test reports reach the owner by themselves. Videos never go that way: share
  those by AirDrop, a shared folder, or the test link.
- **For the owner, on the 14 Pro:** plug it into the computer by USB, unlocked and trusted. The
  round and `sendFile` then fetch files at about 39 MB/s instead of over Wi-Fi. This needs
  `pymobiledevice3` in `~/.venvs/imobile` and the app's bundle ID in the results folder's
  `usb_app_id`, both set up on 2026-11-12.

## Test 1: Measure encoders again (both phones)

New in 0.1.118. The first launch's encoder check runs with the camera on and reads too slow:
on the 14 Pro it warned that HEVC at full size managed 27 fps, while 65 real takes held 30.

1. Let the phone sit for a few minutes so it's cool. Leave VibeLog open on the camera screen.
2. In Settings, **Advanced**, **Diagnostics**, tap **Measure encoders again**. The camera stops;
   if the phone is warm it waits up to 5 minutes, showing "Letting the phone cool first".
3. Wait for the camera to come back, about a minute. Don't record meanwhile.
4. Open Diagnostics again and read the line **Encoder limits**.

**Expected:** **Encoder limits** reads "Camera stopped, nominal" and today's date. On the 14 Pro,
the warning "This codec and size encoded at 27 fps" no longer appears for HEVC at full size. On
the base iPhone 16, ProRes 422 HQ at full size should still warn: its encoder is really slow.

**Send:** what **Encoder limits** reads. With **Log sharing** on, the rest arrives by itself;
otherwise send the newest `probes/encoders_*.txt` and the session log.

**Owner:** `python3 tools/pull_logs.py`, then `python3 tools/check_benchmark.py`. It should list
no false alarms for that phone.

## Test 2: a take that held stops its warning (both phones)

New in 0.1.118. A real take outranks any measurement.

1. In **FORMAT**, pick a codec and size that shows the orange warning chip at record. On the 14
   Pro before Test 1, HEVC 4:2:2 at full size did; after Test 1, try 12-bit ProRes 4444
   (Settings, **Advanced**, **12-bit ProRes 4444**).
2. In **LOOK**, keep **LOG**, with **BAKE** off. Keep **ASPECT** at **OPEN GATE**.
3. Record 10 seconds, the phone held still.
4. Look at the warning chip before recording again.

**Expected:** if the take lost no frames at the encoder, the chip is gone for good for that codec
and size, and **Encoder limits** adds "1 proven by takes". If the encoder dropped frames, the chip
stays, saying so: that's right too.

**Send:** whether the chip went, and the take's frame count from the library's **Details**.

## Test 3: log sharing sends less (both phones)

New in 0.1.118: uploads are compressed, leaving the app sends at most every 15 minutes unless a
take ran, and the log of the session still running waits for a take or **Send now**.

1. In Diagnostics, **Log sharing** on, with the invite code from the owner. Tap **Send now**
   once and wait for **State** to read "Sent" or "Up to date".
2. Go to the home screen and straight back, twice. Read **State**: it shouldn't change from step 1.
3. Record a 5-second take, go to the home screen, wait 10 seconds and come back. **State** should
   read "Sent N files".
4. On the base iPhone 16 only: say the **Anonymous ID** shown, so the owner can find its uploads.

**Owner:** `python3 tools/pull_logs.py`. Each upload should be a tenth or so of its files' size,
and `phones/report.md` should list the phone.

**Send:** what **State** read after steps 2 and 3.

## Test 4: the iPhone 16's ultra wide copy (base iPhone 16)

Two questions left from 2026-11-12, when take `140255`'s copy measured steady:

1. **Which build made the copy that looked shakier?** Before 0.1.112, every copy was 20 ms out
   of step.
2. **If a copy on 0.1.118 still looks shakier,** send that take, its copy and its shutter speed.
   At 1/50 s the motion blur changes direction with each shake, which can look like vibration;
   stabilized takes want 1/250 s or faster.

## Test 5: laggy sliders (base iPhone 16)

A busy main thread was ruled out on 2026-11-12. The suspect is the scrolling form the sliders sit
in, taking drags that move even slightly up or down. From 0.1.117 the log counts each drag a
slider took, so a drag the scroll took shows up as missing.

1. Open a log take, tap **Export**, open the grade editor.
2. Drag one slider **slowly and exactly sideways**, keeping the finger level, **ten times**.
3. Drag the same slider **diagonally**, a little up or down as it moves, **ten times**.
4. Do the same with **Smoothness** under **Stabilize**.

**Send:** how many drags you made of each kind, and whether the slider refused to move. With
**Log sharing** on, the log arrives by itself; tap **Send now** after the test.

## Test 6: a long take started cold (base iPhone 16)

Still owed from 2026-11-11: how fast the base 16 heats from a real cold start.

1. Leave the phone off the charger and unused for 30 minutes.
2. In **FORMAT**, pick **HEVC 4:2:2** at full size, **LOG**, **BAKE** off.
3. Record **5 minutes**, the phone lying still. Then record 5 minutes at **2880x2160**.

**Send:** the session log (automatic with **Log sharing**), and whether either take stopped
early.

## What the results decide

- **Tests 1 and 2** decide whether the encoder limits now say only what takes agree with. If
  `check_benchmark.py` still finds false alarms, the careful measurement needs more frames.
- **Test 3** closes log sharing's first version.
- **Test 5** decides the slider fix: if only diagonal drags go missing, keep the form from
  scrolling while a slider is held, or lay the grade editor out without scrolling.
- **Test 6** is the base 16's first clean heat figure, which the benchmark's internal limits need.
