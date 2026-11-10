# Status

Where things stand now. Rewrite this at the end of each session: move the finished session's
notes to [history](history/), anything proven to [findings.md](findings.md), and keep this file
short.

## Latest build

As of mid Phase 7. The latest build is `cb8137a`, CI run 97, which passed with 163 tests and one
skip: during baked-FX takes the viewfinder samples the take's own glow instead of making a second
one, keeping the FX preview. It was sent to the owner but isn't on the phone or measured yet. Before
it, `947b90e`, run 96, applied baked FX to the direct kernels' linear light, so they can take the
Efficient path when hot; on the phone on 2026-11-08 it closed the short-take gap, but the long take
still fell behind at 2 minutes; see **Last session** below. Before that, `b76befc`, run 95, kept
baked FX on the full path, whose long take failed hot; `f41859c`, run 94, added FX in baked takes
behind a switch, the 1x's focus lock for lens measuring, the movable export crop and focus peaking
at 0.15 and 0.075, all tested over the link; `d14bf0e`, run 93, added lens shading correction, log
conversion in export, the faster PQ export, the Fine look LUT switch and the crop outline, all
tested over the link. Earlier sessions' work is in [history/2026-11.md](history/2026-11.md), from
**Session on 2026-11-07, on `88728c4`** onward.

## This session: 2026-11-10, written but not built

A second tester's iPhone 16 (`iPhone17,3`, iOS 26.6.2) sent three logs from `d2958aa`. What they
show is in [findings.md](findings.md) under **iPhone 16**: the RAW photo loop hangs after its first
frame, so both takes wrote 0 frames, and the fit left it on ProRes 422 HQ at 1920x1440. The plan
the owner agreed is [decisions/per-phone-fitting.md](decisions/per-phone-fitting.md). Written, not
committed or built:

- **Capture ladder:** `CaptureSupport` in VLCore. A phone stays on the standard setup until its
  loop stalls twice with no frame between, or four times in 20 seconds. Then the loop stops instead
  of piling requests up to `-11830`, and the app rebuilds the session on the next step: Apple's
  preview connected, fast capture off, both, then sequential requests. A step that streams 90
  frames is saved in `capture_support.json` for that phone model and iOS version. An interrupted
  session never escalates. The cause of the hang isn't known; the ladder's order is a guess, with
  the missing preview first.
- **Stall log:** each stall line names the last photo callback reached, the frames since start and
  the output's readiness.
- **Record guard:** record is refused with a notice when no frame has arrived for 2 seconds, and a
  take with none for 3 seconds stops with a card.
- **Codec default:** `EncoderSupport.bestDefault`. On the iPhone 16's numbers it picks HEVC 4:2:2
  at 2880x2160. A phone already fitted by the old rule is fitted once more, if its choice still
  matches what that rule made. A chosen codec and size that measured under 30 fps warns at record.
- **Tests:** 7 new, 170 in all, none run yet, since nothing here compiles Swift.

## Earlier session: 2026-11-08, on `947b90e`

- **Baked FX on the Efficient path, short, gap closed:** four alternating 15-second SDR HEVC takes
  baked with ACES 2.0 (graded exposure +1.1), FX halation and bloom +50, diffusion and grain +30,
  `pipeline efficient`, charging at 30%. FX on at fair, `185455`: 446 frames, 1 lost, GPU 20 ms. At
  serious: FX off `185519` 449 frames, 0 lost, GPU 11 rising to 29.7 ms; FX on `185544` 443 frames,
  4 lost, 20.7 rising to 29.8 ms; FX off `185608` 450 frames, 0 lost, 11.4 rising to 29.8 ms. Queue
  under 1 ms throughout, against 60 ms and 42.9 ms GPU with 72 lost on `b76befc`. The sidecars name
  the FX and the Efficient path.
- **Baked FX, the long take, failed again:** `fx_baked.json`, take `192732`, after 30 minutes'
  cooling, charging from 50%. Nominal, then fair at 1:31, GPU 22 ms, `draw` 8 ms, nothing lost. At
  1:57, still fair and on the full path, GPU time doubled in one step to 44 ms, queue 54 to 69 ms
  and `draw` 21 to 28 ms, and frames began to drop. Serious at 2:05, when the Efficient path took
  over, made no difference: GPU held 44 ms, about 7 frames a second lost, over 1,000 viewfinder
  yields. Stopped by hand at 2:47: 4,622 frames at 27.66 fps written, 389 lost at the GPU, capture
  29.98 fps. So the short takes' 30 ms didn't survive the GPU's step down, which came at fair this
  time. Both failed baked-FX long takes were charging and slowed within about 2 minutes, where
  `fx_cost`, unplugged, held, so charging isn't ruled out.
- **The viewfinder shares the take's glow:** the owner first chose a plain viewfinder during
  baked-FX takes, then wanted the FX kept on it, since they're what's being baked. So while a take
  bakes FX, `draw` shows the take's own FX and samples the glow texture the take's last frame made,
  `takeGlow`, handed over by `shareTakeGlow`, instead of a downsample and two blurs of its own each
  draw. Both run on one command queue, so a draw reads a finished glow. Both paths make it at
  504x378, from the full image at an eighth or the half-size monitor at a quarter. The per-pixel FX
  step in `monitorFragment` stays. Whether that saves enough is what the next long take shows; a
  plain viewfinder is still the fallback. Built in `cb8137a`, CI run 97, untested on the phone.

## Waiting on the phone

**The iPhone 16, once this session's changes are built:** open the app and wait 20 seconds on the
1x, switch to the 0.5x and wait 20 seconds, record 10 seconds, then send the `session_*.log`, with
**Log capture timing** on in Diagnostics if they can. The log should show which setup streams, or
where the request hangs. **The 14 Pro, same build:** one launch and a short take, to confirm no
`Capture stalled` line appears and the format is unchanged, and its `Encoder check` lines if the
check runs, to see how the trial's numbers sit against real takes.

**Start of the next session:** once `cb8137a` is on the phone, start the server, which isn't running
between sessions, with `python3 tools/test_server.py serve` (it prints the address, port 8765, the
token is in the results folder's `token` file, and the results folder is the one
`~/.vibelog_test_folder` names), have the owner turn on **Connect** with the phone on a stand on the
camera screen, unplugged if they can, then:

1. **The long take again:** `suite tools/suites/fx_baked.json`, 30 minutes' cooling and 10 minutes,
   about 15 GB. Watch the heat CSV: the take's label has a comma, so read it with a CSV parser. If
   the GPU passes about 40 ms with frames falling away, stop it with `send stop` rather than run on,
   as the owner asked. `send stop` ends the take, but the suite keeps waiting out its timer, so stop
   the suite too and put the settings back by hand. Over the link, `set` takes name and value as two
   arguments, so in zsh pass them separately, not as one string. If it fails again, run it unplugged
   to rule out charging.
2. **Still waiting on the owner:** a stabilization take, slow pans and quick shakes at 1/250 s; a
   colour chart shot for per-lens colour and the exposure default; the matched pair for Apple's
   preview; corners with lens shading on real scenes, which the owner confirmed work.

The phone had about 130 GB free at the end, after the owner cleared takes.

Of the older list: the HLG bake is proven, `fx_cost.json` ran clean on the viewfinder, the gear,
scope, look panel and haptics are confirmed. Still open from it: `scope_cost.json`, the Apple's
preview pair, the stabilization check and ARRI Wide Gamut 3, left for later at the owner's choice.

Vignette correction is built from Apple's own `FixVignetteRadial`; no sample is needed any more.

## Still to build

- **FX in baked takes: the long take** with them on and the viewfinder sharing the glow, against
  `fx_cost`.
- **ACES 1.3 HDR.**
- **Lens profiles, next steps:** checking the table against a straight edge in a RAW corner, colour
  from a chart and Gyroflow import.
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
