# Status

Where things stand now. Rewrite this at the end of each session: move the finished session's
notes to [history](history/), anything proven to [findings.md](findings.md), and keep this file
short.

## Latest build

As of mid Phase 7. The latest build is `02d2d11`, CI run 105, version 0.1.105, which passed
with 181 tests and one skip: a baked-FX take
hands its glow to the viewfinder only when a frame finishes, from a pool of four, after take
`164209` ran 45 ms a frame from its start on the Maximum path. The 14 Pro proved the fix in take
`190958`, which then stepped down at 2:27 as `192732` had. Before it,
`6f4d393`, run 104, passed with 180 tests and one skip: measuring lenses also writes their
Gyroflow profiles, so the test link can fetch them. `f8eb02a`, run 103, added Gyroflow lens profiles from the Lenses
page and overlapped bracket cases in the probe; `657767f`,
run 102, versioned each build `0.1.<CI run>` for SideStore, and `1a1d56c`, run 101, added reset
all, change dots, export's fullscreen preview and movable scope, and the lens stabilization
probe. None of that has been tried on a phone except the first probe, on the iPhone 16. `edec570`
fitted capture and the codec default to each phone, and worked on the iPhone 16. `cb8137a`, run
97, shared the take's glow with the viewfinder during baked-FX takes, which the 14 Pro showed
slows the Maximum path: see [findings.md](findings.md). Every
session is in [history/2026-11.md](history/2026-11.md); the last is **Session on 2026-11-11**.

## Waiting on the phone

Files can be read straight from a phone plugged in here, under `/run/user/<uid>/gvfs/afc:*/`.

**Either phone, on `6f4d393` or later:**

1. **SideStore:** whether the build after the one installed shows as an update by itself.
2. **Look panel:** the red arrow and the dots in all four holds, and the confirmation sideways.
3. **Export:** whether "Wheels •" fits its tab upright; the fullscreen preview upright and
   sideways, with a crop outline on; the scope's drag, snap and resize, and the camera's scope
   too, whose code changed.
4. **Run probe**, phone still, and send the newest `probes/probe_*.txt`. In its lens stabilization
   section, a stabilizer-off case holding about 30 fps with even 33 ms gaps would make a
   stabilizer switch for takes worth building. From the 14 Pro it also shows whether its lenses
   have the switch.

**The 14 Pro:**

5. **Gyroflow:** in Lenses, **Measure Lenses** if none are saved, then **Share for Gyroflow**; or
   over the link, `send measureLenses`, then `listFiles` and `sendFile` for `gyroflow-*.json`. Load
   the 1x open gate profile in Gyroflow with a 1x take that has slow pans and a straight edge near
   a corner, shot at 1/250 s with lens distortion correction off. Say whether Gyroflow loads it,
   whether it stabilizes, and whether the edge comes out straight. A bowed edge means Apple's
   table runs the other way.
6. **A launch and a short take on `edec570` or later,** to confirm no `Capture stalled` line and
   an unchanged format.
7. **Nothing for baked FX until the next build:** the long take ran on `02d2d11`, and what's
   left needs a change first. To run a suite, start the server with `python3
   tools/test_server.py serve`, turn on **Connect**, then `suite tools/suites/fx_baked.json`.
   Over the link, `set` takes name and value as two arguments.
8. **Still waiting on the owner:** the stabilization take, slow pans and quick shakes at 1/250 s;
   a colour chart shot; the matched pair for Apple's preview; `scope_cost.json`; ARRI Wide Gamut
   3, left for later.

**The iPhone 16:** a five-minute HEVC 4:2:2 take at full size, started cold and unplugged, and one
at 2880x2160.

## Still to build

- **A stabilizer switch for takes,** only if the probe shows brackets can hold 30 fps.
- **FX in baked takes: a way through the GPU's step down.** The Maximum path loses about 7
  frames a second from about 2 minutes until serious heat brings the Efficient path, which then
  holds. Not decided: take the Efficient path when the GPU falls behind, not only when hot, or
  from the start of a baked-FX take.
- **ACES 1.3 HDR.**
- **Lens profiles, next steps:** the straight-edge check, colour from a chart, the readout time
  for Gyroflow, and a profile for the ultra wide, which Apple gives no table for.
- **A native log mode for Pro phones,** starting with the probe listing video formats: see
  [decisions/native-log-mode.md](decisions/native-log-mode.md). The HLG idea was dropped.
- **Stabilized export**, after the stabilization check. Then Phase 8: denoise, proxies and
  log-to-log conversion.

## In progress: stabilization check

Before building stabilized export, find out whether optical stabilization moves the picture during
RAW capture, which the gyro can't see, and the sensor's rolling-shutter readout time. The owner
recorded `video_20261103_235155.mov`, a 6-second 4032x2268 HEVC take with its `.gcsv`, propped on a
surface with short shakes at about 4 to 5.5 seconds, and is checking it in Gyroflow.

- **Gyroflow setup:** set the frame rate to 30 by hand, since Gyroflow read it as "---". Its only
  lens profile, "iphone 14 pro 30", is for Apple's 3840x2160 video with distortion corrected, not
  VibeLog's uncorrected 4032-wide frames, so judge the centre of the frame or make a VibeLog profile
  with Gyroflow's lens calibration. Use a fixed zoom and 4032x2268 output.
- **Export trouble on the owner's Linux PC:** with **Use GPU encoding** on, Gyroflow wrote a corrupt
  HEVC file, all green with `cu_qp_delta` errors in ffmpeg, then failed outright: AMD's
  `libamfrt64.so.1` isn't installed, and VAAPI refuses 10-bit `yuv420p10le`. Turn GPU encoding off,
  or use ProRes or 8-bit H.264.
- **What decides it:** steady after stabilizing means optical stabilization isn't in the way. A
  small float that follows the shakes means it is. A fast pan's leaning verticals give the readout
  time.
- **Result, not decisive:** measured frame to frame by phase correlation on the centre of the frame,
  at 960 wide. Gyroflow's `video_20261103_235155_stabilized.mp4` (3840x2160 H.264) kept the motion:
  its vertical motion over frames 60 to 133 was 8.3 px rms against 7.5 in the original, the same
  moves one frame later, so Gyroflow stabilized nothing and says nothing about optical
  stabilization. The take wasn't propped: from about 4.5 s the phone swung up to the ceiling at up
  to 16 rad/s, with heavy motion blur. In the original, the gyro's y axis followed the picture's
  vertical motion with a correlation of 0.96 at a lag within 3 ms, and explained about 92% of it, 2
  px rms left over. The motion was 0.79 of what a rough focal length, 24 mm equivalent or 2795 px at
  4032 wide, predicts. That gap may be the estimate, or optical stabilization taking a fifth, and
  needs a lens calibration to tell. So the `.gcsv` timing and axes look right. A cleaner test needs
  no Gyroflow: a take at 1/250 s or shorter with a few slow two-second pans or tilts, then a few
  seconds of small quick shakes. Optical stabilization can't follow big slow moves, so the pans
  should match the gyro 1:1, and if the shakes come out smaller, it's active and the gap measures
  it. Phase correlation of frames against the `.gcsv`, a short numpy script, analyses it here.
- **Then:** stabilized export, as a step before the look in `LookExporter`, from the `.gcsv`, with
  lookahead smoothing, an optional horizon lock, rolling-shutter correction per row and a crop set
  in the preview. Live baked stabilization was ruled out: it needs future frames, GPU time the hot
  path doesn't have, and bakes in a crop.
