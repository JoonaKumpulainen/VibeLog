# Status

Where things stand now. Rewrite this at the end of each session: move the finished session's
notes to [history](history/), anything proven to [findings.md](findings.md), and keep this file
short.

## Latest build

As of mid Phase 7, with Phase 8's stabilized export begun. The latest build is `d232d7e`, CI run
115, version 0.1.115, which passed with 189 tests and one skip. The test link can now reach a
phone elsewhere: the app takes an `https://` server address, and `serve --public` runs behind an
ngrok tunnel with a long token and lockouts, checked here through a real tunnel. Nothing from
0.1.113 on has been tried on a phone.

The builds before it, all from the sessions of 2026-11-11 and 12:

| Build | Run | What it added | On the phone |
|---|---|---|---|
| `8c7f7d5` | 114 | A baked take's stabilized copy keeps its own codec | Not yet |
| `eed6df9` | 113 | FX keep light below zero; returning to the app no longer idle-pauses the camera | Not yet |
| `2368f1d` | 112 | Stabilize's timing fixed, its limit eased at 130%, a Stabilize screen for baked takes | Not yet |
| `652ba7a` | 111 | Ultra wide corrects every speed, maker note probe, legal and Gyroflow wording | Probe ran; stabilized copies measured |
| `7e2b514` | 110 | Stabilized export, its preview, stabilized copies of baked takes, stabilizer names in the probe | Probe ran |
| `35d43dc` | 108 | Baked-FX takes make the monitor image and glow every other frame | Proven: 20 minutes back to back |
| `907287d` | 107 | GPU cost test | Ran |
| `b740eab` | 106 | Baked-FX takes on the Efficient path, probe crash fix | Proven |

Run 109 never started and can be ignored. Every session is in
[history/2026-11.md](history/2026-11.md); the last is **Session on 2026-11-12, iPhone 16 logs**.

## Start here next session

1. **Ask for the results of [next-tests.md](next-tests.md)** from both phones, 0.1.115. Tests
   1 to 3 close `eed6df9` and `8c7f7d5`; Test 6 says how Stabilize looks with its timing fixed.
2. **If the phone is linked, measure the new copies** against their gyro logs, as was done for
   the first ones. The method is under **How the copies were measured** below.
3. **The ultra wide's stabilization:** on the base iPhone 16 it adds small fast shake, and on
   the 14 Pro its edges shake and bend. Fit Test 4's take and copy as under **How the copies
   were measured**, at lags of ±100 ms and both signs, to tell timing from direction from
   scale; Test 5 separates distortion from rolling shutter. The plan, not yet agreed, is in
   **Still to build**.
4. **Then pick from Still to build.** Measure stabilizer, per lens, is the natural next step if
   Stabilize now works; rolling shutter if fast moves still lean or wobble.

## Waiting on the phone

A phone elsewhere, such as the iPhone 16, can join the test link through ngrok on 0.1.115: see
**A phone elsewhere, through ngrok** in [test-link.md](test-link.md).
Files can be read straight from a phone plugged in here, under `/run/user/<uid>/gvfs/afc:*/`.
The test server is `python3 tools/test_server.py serve`; the phone then needs **Connect** on in
Diagnostics. The server prints its address and token, which have stayed the same across restarts
and are kept out of this public repo. Over the link,
`set` takes name and value as two arguments, and `sendFile` fetches a take whole.

Step-by-step instructions for every test below, with what to send, are in
[next-tests.md](next-tests.md).

**The 14 Pro, on 0.1.115:**

1. **Tests 1 to 3:** FX keep the shadows, the camera keeps running after leaving the app, and
   Stabilize keeps a baked take's codec.
2. **Test 5:** the ultra wide's edges, with a take for its readout time.
3. **Test 6:** Stabilize with its timing fixed, on `000714` and `220644`, and on a log take.
4. **Gyroflow's axes:** a take held sideways, with a few seconds held still, played in Gyroflow,
   to check `yXZ` is right there. Upright takes are corrected a quarter-turn off until the
   `.gcsv` says how the phone was held.
5. **Look panel:** the red reset arrow and the change dots in all four holds, and the
   confirmation sideways.
6. **Export:** whether "Wheels •" fits its tab upright; the fullscreen preview upright and
   sideways, with a crop outline on; the scope's drag, snap and resize, on the camera too.
7. **SideStore:** whether a new build shows as an update by itself.
8. **Later:** a colour chart shot; the matched pair for Apple's preview; ARRI Wide Gamut 3;
   `scope_cost.json`, which needs about 112 GB free.

**The iPhone 16, base model, on 0.1.115:** Tests 1, 2 and 4, the ultra wide's stabilization.
Then **Run probe**, phone still, for its overlapped bracket cases and stabilizer names; a
five-minute HEVC 4:2:2 take at full size, started cold and unplugged, and one at 2880x2160.

**Friends' 15 Pro, 16 Pro and 17 Pro:** nothing yet. The probe must first list video formats.

## Still to build

In rough order of what's most useful next:

- **The ultra wide's stabilization, proposed:** measure the 16's take first; then build Measure
  stabilizer below, saving each lens's timing offset, direction and optics share, with fast
  correction off for a lens whose fit is poor; then lens distortion in the warp, from a Gyroflow
  calibration import for the ultra wide, which Apple gives no table for in RAW; then rolling
  shutter, once the readout time is measured.
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
  the 14 Pro, and the probes found no other switch.

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
