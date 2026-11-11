# What the phone has shown

Camera behaviour counts as proven only once it has run on the phone. This file keeps what has
been, and what still hasn't. Add new results here when a session proves something, and remove
an item from **Not verified** once it is.

## Proven on the phone

- **RAW source:** `AVCapturePhotoOutput` with the readiness coordinator, zero shutter lag and
  responsive capture gives 12 MP Bayer (`bgg4`, 14-bit in 16-bit words) at 30 fps. The app fires
  requests from camera events as well as the coordinator, with a minimum gap of 0.9 frame times,
  which is 30 ms at 30 fps.
- **Preset:** RAW is listed only under the `.photo` session preset, never `.inputPriority`. That
  mode is capped at 30 fps, so RAW at 60 fps is not available this way.
- **Video output:** offers no Bayer format under either preset.
- **Levels:** use the photo metadata's `{DNG}` values for the pixel buffer: black 2112, white 16383.
  The DNG file's tags are a quarter of that scale, so don't apply them to buffers. Highlights really
  clip at 14271 at ISO 100 and 3000.
- **Exposure:** default is -0.5 stops, from a single measurement.
- **Frame copy:** RAW frames must be copied to GPU memory. Holding camera buffers through a GPU pass
  correlated with `-12686` photo failures, so zero-copy input is off the table.
- **Main thread:** keep capture timing independent of it. The old overlay timer cost exactly 2
  frames per second.
- **Encoding:** ProRes 422 HQ at 4032x3024 is the default, at about 160 MB/s or 9.5 GB per minute.
  ProRes 4444 held 30 fps for 30 seconds at 240 MB/s. HEVC only just reaches 30 fps at full size. On
  `b86f6bd`, take `185616`, 1x, ProRes 4444, Maximum quality and Apple Log 2 in a dark scene at ISO
  9799, ran 60 seconds at 29.91 fps written, 1796 frames, 259.8 MB/s, with 0 lost at the GPU or
  encoder and heat nominal throughout. The only loss was the start: 17.5 fps over the first 0.4
  seconds, `missed 5` and a 200 ms gap. GPU time sat near 26 ms. HEVC 4:4:4 is real 4:4:4: take
  `185048` reads as the HEVC Range Extensions profile, `yuv444p10le`, and its chroma holds detail
  past half resolution. That 3.9-second take wrote 28.94 fps at 38.7 MB/s, with 0 lost at the GPU or
  encoder, but 2 failed photos and `missed 4`. Its time base of 1/600 confirms the decimal-rate
  cause.
- **Long run:** 10 minutes at 29.81 fps with 0 encoder drops, with **Keep recording when hot** on.
  Thermal state reached serious but not critical, and no throttling happened. Without reduced load,
  the GPU throttled at 5 minutes.
- **Battery:** recording near 1% stalled the encoder, and the same test at 70% was clean. That is
  strong evidence, from one comparison.
- **Storage:** full RAW dumps need 732 MB/s, but the phone sustains about 420 MB/s after about 8 GB.
  Encoder drops began at about 8 GB free, so recording stops at 10 GB free. Free space must use
  `volumeAvailableCapacityKey`; the important-usage figure counts purgeable data.
- **Pipelines:** **Maximum quality** is the app's default, but the owner's phone is saved on
  **Efficient**, so every take in the last session used it. **Efficient** matches it within one
  10-bit code in tests and looked identical to the owner, but one run showed no clear gain, plus
  more failed photos and memory. It isn't proven better.
- **Features confirmed:** synced audio, 16:9 crop, zebras, false color and `.cube` import with **LUT
  made for**.
- **Redesign:** the owner approved the camera screen after phone testing, apart from the fixes
  listed under Phase 5. Switching **Full view** five times during a take dropped no frames, and a
  recording with focus peaking on dropped none.
- **Mic meter:** the bar reacts to sound, and a take with it showing dropped no frames.
- **Frame rates:** no dropped frames at 24, 25 and 30 fps. One take each at 24 and 25 wrote 23.90
  fps over 10 seconds and 24.97 fps over 42 seconds. The owner reported no drops at 23.98 and 29.97,
  with no logs seen yet. DaVinci Resolve reports 24 for the 23.98 file and 30 for the 29.97 file,
  which is wrong. A fix is listed under **New in `623c5a9`**.
- **Decimal timing:** the `Frame timing:` log confirms the sensor accepted 0.033367 s for 29.97 and
  0.041708 s for 23.98. A 31-second take at 29.97 lost 3 frames at the GPU in its first second,
  started 1.2 seconds after the session rebuild, then held. A 30-second take at 23.98 lost nothing,
  with `missed 0`.
- **Duplicate frames:** that 23.98 take logged 4 encoder drops, though 738 frames arrived in 30.6
  seconds, more than 23.98 fps gives. The first was exactly 0.0 ms behind the last frame, so the
  camera delivered the same frame twice, probably because the 0.9 frame gap lets a request reach the
  same frame. The others weren't logged. The encoder rightly skips these, but they count as `DROP`,
  so the number overstates the loss.
- **Uncompressed audio:** the owner reported that sound in the 10-minute take is crisp and in sync.
- **Color space:** the owner reported that S-Gamut3 with S-Log3 works. LogC3 takes recorded, but
  ARRI Wide Gamut 3 hasn't been graded. The owner reported that Apple Log 2 grades well.
- **Ultra wide falls short of 30 fps:** every take on it missed frames, while the main camera held
  30.00 fps after a start hitch of 133 to 200 ms. Locked 20-second ProRes 422 HQ takes wrote 18.94
  fps at 1/30 s, 20.45 at 1/60 and 20.37 at 1/120. HEVC and ProRes 4444 gave 20.0 fps at 1/120, and
  auto at 1/33 gave 24.7. So neither shutter nor codec sets the limit. GPU time stayed near 14 ms at
  the start of those takes with no drops, so nor does the GPU. The camera delivers the frames late,
  and `PhotoRawDriver` has no per-lens logic. The cause is unproven. See **Variable frame timing**.
  `missed` understates this lens, because it compares gaps with the take's median: take `190710`
  lost about a third of its frames and logged `missed 2`.
- **Ultra wide long run:** 10:08 of ProRes 4444 in LogC3 and Maximum quality at 23.29 fps written,
  14173 frames and 190.7 MB/s. Encoder drops were 0, but 441 frames dropped at the GPU and 33 photos
  failed. Heat reached serious after 65 seconds. From about 2 minutes in, GPU time jumped from 28 ms
  to about 65 ms for long stretches with a return to 28 ms in between, which looks like GPU
  throttling, and every loss came during the slow stretches. An earlier 7:42 take ran serious for
  2:40 at 20 fps with no drops. This doesn't test 30 fps.
- **Monitoring cost:** none measurable, and earlier notes blaming tools were wrong. At serious heat,
  40-second 1x takes showed GPU 28.1 ms with all tools except zebras and 28.4 ms with none, and at
  fair heat 25.2 ms with none. GPU time climbs from about 13 ms to about 25 ms within 10 seconds of
  any take, with or without tools, for a reason not yet known. The figure only times the compute
  pass, not the viewfinder draw, so the tools' full cost needs a long take. All three takes lost 0
  frames with the test link connected.
- **Gyro cost:** none seen. Two 40-second 1x takes, gyro on and off, both wrote 1200 frames with 0
  lost.
- **Main camera, Maximum quality, 10 minutes:** take `192944`, 1x, ProRes 422 HQ, uncompressed audio
  and all tools except zebras, ran 10:01. The camera delivered 29.99 fps with `missed 5`, and the
  encoder dropped nothing, but the file wrote 28.11 fps because 1128 frames (6%) dropped at the GPU.
  The first 6:20 lost none. Heat reached fair at 38 seconds and serious at 1:48. At 6:20, GPU time
  jumped from about 27 ms to 52 ms, then to about 70 ms by 8:30, with no other change, which looks
  like GPU throttling. Tools were first blamed for this, but a later comparison showed no measurable
  difference, so the slowdown itself is the problem. `a2d2cab` has the viewfinder yield in that
  case, which still needs a long take.
- **Viewfinder yields didn't save a long take:** take `210133` on `a2d2cab`, 1x, ProRes 422 HQ,
  Maximum quality, uncompressed audio and all tools except zebras, began at nominal heat but only
  about 2 minutes after leaving fair, following a run of short takes. The camera delivered 29.99 fps
  with `missed 8`, but 1982 frames (12%) dropped at the GPU and the file wrote 26.35 fps. Heat
  reached serious at 1:30 and critical at 9:05, the first critical seen, so the app ended the take.
  GPU time left about 30 ms at about 3 minutes and settled near 78 ms. The viewfinder gave up 11909
  draws and losses still grew, so the compute work itself is what slows. Starting heat differs from
  `192944`, so it isn't a direct comparison, and that take's lower loss may only reflect a cooler
  phone.
- **Efficient path when hot held a full take:** take `222321` on `021248e`, 1x, ProRes 422 HQ,
  Maximum quality with **Efficient path when hot** on, uncompressed audio, correction off and all
  tools except zebras, after a 30-minute rest with the stream off. It ran the full 10:00 at 29.96
  fps written, 17975 frames at 169.4 MB/s, with 9 lost, all in the first 5 minutes before the phone
  was hot, and `missed 17`. Heat reached serious at 4:41 and never critical. GPU time stayed near 26
  ms for the 5 minutes at serious, where `210133` and `192944` climbed to 70 ms or more. Both the
  longer rest and the hot path differ from those takes, so it doesn't yet separate them. `viewfinder
  yields` was 1897, but Settings was open over the camera, which likely inflated it: 20-second takes
  with Settings open gave 184 to 491 yields, against 0 to 52 in 40-second takes on the camera
  screen. Heat also differed between those runs. Run linked takes from the camera screen.
- **The picture changes when hot:** What was **Keep recording when hot**, now **Bilinear when hot**,
  changes the debayer as well as the path. Two 10-second takes at ISO 800, matching each half of
  `222321`, kept the same brightness and color (mean 0.366 and 0.365), but the Efficient Bilinear
  frame had about 4% of the fine detail energy of Maximum Malvar-He-Cutler. Most of that is noise at
  this ISO: side by side it's clearly less grainy and slightly softer, with lettering intact. A low
  ISO scene with fine detail hasn't been compared. The next step is a long take with the hot path on
  and **Keep recording when hot** off, which should keep Malvar-He-Cutler if the heat allows.
- **Tele:** take `194057` delivered 29.86 fps. It started at serious heat, and GPU time reached 66
  ms once tools were on, so 68 frames dropped at the GPU over 21 seconds. Take `194232`, in the same
  conditions, logged 664 frames at 29.98 fps, but 151 were duplicates with the same timestamp as the
  frame before, so the file wrote 23.13 fps. `missed` showed 0.
- **Frame time doesn't set the lens limit:** on `a2d2cab`, 20-second takes at 1/120 s wrote 21.33
  fps fixed and 21.50 variable on the ultra wide, and 29.91 both ways on the tele. Fixed stays the
  default until the 1x long run says otherwise, and the Diagnostics switch can go once it does.
- **Why the ultra wide was slow:** distortion correction. On `021248e`, 20-second takes at 1/120 s
  wrote 22.89 fps with it on and 29.85 fps with it off, and the camera's not-ready time fell from
  40.5 ms to 31.9 ms. With it on, previews came out 704x504 with black edges, and with it off
  672x504 with none, so correction reshapes the frame the app receives. Off gives the sensor's plain
  4032x3024, which suits the app's goal, but the lens's distortion then stays in the picture. The
  switch is on by default, so the ultra wide stays slow until that changes. Whether colors and
  levels stay right with it off hasn't been checked on footage.
- **Correction on the 1x and tele:** 20-second takes were the same with it on and off: 1x 29.71 and
  29.30 fps, tele 29.71 and 29.81, all with the same 672x504 previews. The phone heated through this
  run, so the small losses of 1 to 10 frames at the GPU follow the order of the takes more than the
  setting. Off is fine as the default on every lens.
- **Slow focus move still costs frames:** in the 56-second control test, 16 small focus changes at
  two a second over 8 seconds delivered 210 of 240 frames. A rack lost 30 of 60 in 2 seconds, and
  tap focus lost about 4 to 7 frames, as before. ISO and exposure bias steps stayed clean. Focus
  stays blocked during takes.
- **Shutter priority:** at 1x and 1/60 s, a 20-second take frozen at the start and a 30-second take
  with ISO live both lost 0 frames, at 29.75 and 29.84 fps. ISO moved from 926 to 1114 between them,
  but no take has followed a real change of light.
- **Frame steps:** in a 20-second 1x take, copy took about 7 ms, queue 0.3 ms, append 0 ms and draw
  6 ms, with the compute pass at 26 ms. The viewfinder is small next to compute. A long take should
  show which step grows when hot.
- **Tele:** two 20-second takes at 1/120 s kept every frame at 29.91 fps with no duplicates. The
  earlier 23 fps duplicates take hasn't repeated.
- **Auto during a take:** the owner reported that auto exposure and white balance work. It hasn't
  been in a logged test, so its cost isn't measured.
- **Long run in Efficient:** 10:12 of ProRes 422 HQ at full size with 0 `DROP`, 18338 frames and 172
  MB/s, in a dark scene at 1/31 s and ISO 8710. Heat reached serious at 5 minutes, with **Keep
  recording when hot** on and no failure. The file wrote 29.97 fps, about 16 frames fewer than 30
  fps gives, and the rolling rate dipped to 29.49 in 8 of 122 samples. `DROP` doesn't count frames
  the camera never delivered, so result lines now log `missed` and `gap`.
- **Library and peaking:** the owner reported both working. Delete removes a take with its metadata.
- **Format panel:** the owner reported that the wheels open on the current choice, and that the
  ProRes names, **OPEN GATE** and the sizes read correctly.
- **180° button:** the owner reported it working.
- **Gyroflow:** the owner reported that it works with the saved `.gcsv`, with the axes right. A
  5-second sample also had the right header, even 100 Hz spacing and 1.00 g at rest.

- **Session on `623c5a9`, run over the link:**
  - **12-bit ProRes 4444 works.** Take `202954`, 1x, Maximum quality, Apple Log 2 at ISO 956, ran 60
    seconds at 29.78 fps written, 1791 frames, 254.7 MB/s, about the same rate as 10-bit. 9 were
    lost: 2 at the GPU in the first 4 seconds and 7 encoder `not ready` in the last half-second,
    around the stop, with `writer drops 0` at every progress line before. Memory was about 950 MB
    against 783 for 10-bit `185616`, and GPU time about 22 ms in a brighter scene. Heat reached fair
    at 53 seconds. Take `203115` reads as `prores` profile 4444, `yuva444p12le`, 12 bits per sample,
    and its luma's low two bits are spread evenly, so they carry picture, not padding.
  - **The camera doesn't run at decimal rates.** With the new timescale, 23.98 take `203319` has a
    1/24000 time base and frames exactly 1000 ticks apart, which is 24.00 fps, and 29.97 take
    `203334` averages 1000.09 ticks at 1/30000, which is 29.997 fps. The `Frame timing:` line still
    shows the decimal durations accepted. So Resolve's 24 and 30 described the files correctly, and
    the timescale fix only made the true timing visible. See **Decimal rates** under Planned.
  - **Apple's preview disconnected:** take `204936`, 20 seconds at 1x in ProRes 422 HQ, wrote 596
    frames with 0 lost, `missed 6`. Auto exposure still metered, at 1/50 s and ISO 937 against 956
    with the preview connected, and photo failures were the usual one or two. A 20-second take can't
    show a heat saving.
  - **Curves, pairing and presets over the link:** every curve set its own gamut and every gamut its
    curve, Rec.2020 chose Apple Log, and pairing off kept the pair. Presets saved, updated in place,
    applied, set as default and survived **Reset all settings** with the link. The phone still holds
    the presets **Before tests** and **Link test**, which the link can't delete.
  - **48mm RAW probe crashed the app.** Its first case, 4032x3024 at 1x with speed priority, worked:
    `bgg4` at 35mm=24, with 40 ms between shots. The second case set `photoQualityPrioritization =
    .quality` on a RAW capture, which raised `NSInvalidArgumentException` "Unsupported when
    capturing RAW" outside `VLTryCatch`, and the app ended. The format lists photo sizes 4032x3024
    and 8064x6048 and a 2x secondary zoom. The fix, not built, catches the exception, logs it and
    skips the quality cases, so the 2x and 8064x6048 cases can run.
- **48mm RAW isn't available, proven on `7501cae`.** The fixed probe ran every case. Bayer RAW
  refuses any zoom: at 2x, `capturePhoto` raised "When specifying Bayer raw capture, the
  videoZoomFactor of the video device must be set to 1.0". Asking for 8064x6048 still delivered
  4032x3024 `bgg4`, so the format's 48 MP size doesn't reach Bayer RAW. Quality priority is refused
  for RAW in every case, so speed is the only choice, as `PhotoRawDriver` already uses. At 1x, shots
  came 33 ms apart after the first. So 2x can only be a digital crop of the 4032x3024 frame, which
  keeps 2016x1512 sensor pixels. The report is `probes/zoom_raw_20261103_215643.txt` on the phone.

- **Session on `c459497`, over the link:** the owner confirmed that the curve and LUT links work and
  that S-Log3 opens in S-Gamut3.Cine.
  - **ProRes 4444, 60 seconds each at 1x, Maximum quality, S-Log3 in S-Gamut3.Cine:** 10-bit take
    `230259` wrote 1797 frames at 29.90 fps, 252.8 MB/s, with 3 lost at the GPU. 12-bit take
    `230412`, right after it, wrote 1798 at 29.93 fps, 253.4 MB/s, with 2 lost at the GPU and none
    at the encoder, so the end-of-take encoder losses of `202954` didn't return. It started at fair
    heat and ended serious. Memory peaked near 1 GB in both.
  - **GPU viewfinder:** `draw` was 4.8 ms and 3.7 ms in those takes, against 5.7 ms for `185616` and
    7.1 ms for `202954` on the old 33-point LUT, so doing the math per pixel costs no more.
  - **Encoder test:** at 4032x3024, 10-bit ProRes 4444 encoded at 132.7 fps and 12-bit at 59.1 fps,
    both well above 30. HEVC 4:4:4 from 16-bit input encoded at 26.7 fps, below 30, at 41 MB/s. Both
    16-bit trials reported `kept 12 bits`, with 72 to 73% of samples finer than 10 bits. That's
    proven for ProRes by `ffprobe` on `203115`, but not for HEVC: if the reader turns a 10-bit file
    into 16 bits by scaling rather than shifting, the low bits fill in and the check is fooled. The
    test has no 10-bit control and deletes its files. Next build: run the same check on 10-bit HEVC
    4:4:4 as a control, and keep the 16-bit HEVC file in `probes/` for `ffprobe`. Even if HEVC keeps
    12 bits, it doesn't reach 30 fps at full size, so a switch would only suit smaller sizes, where
    it reached 54 fps at 2880x2160.

- **Long take 1: Malvar-He-Cutler survives the heat.** Take `231150`'s suite on `c459497`, 1x,
  ProRes 422 HQ, Maximum quality with **Efficient when hot** on and **Bilinear when hot** off,
  uncompressed audio, lens correction off and all tools except zebras, S-Log3 in S-Gamut3.Cine. It
  started at nominal heat after only about 6 minutes of rest, a harder start than `222321`'s 30
  minutes. It ran the full 10:00 at 29.99 fps written, 17996 frames at 171.0 MB/s, with 4 lost at
  the GPU, all in the first minute, and `missed 3`. Heat reached fair at 1:37 and serious at 2:57,
  when the Efficient path took over, and stayed serious for 7 minutes, never critical. GPU time held
  near 30 to 32 ms at serious, `draw` 9.2 ms on average and 577 viewfinder yields. So the
  full-detail debayer can stay on when hot, at least with the Efficient path. **Bilinear when hot**
  should become off by default; that needs a build. Take 2, **Efficient when hot** off, is next.

- **Long take 2: the Efficient path is what holds a hot take.** Suite `235409` on `c459497`, set up
  as take 1 but with **Efficient when hot** off too, so Maximum quality and Malvar-He-Cutler
  throughout. It started at nominal heat, reached fair at 2:37 and serious at 4:18, and held 30 fps
  with 1 lost until about 7:00. Then GPU time doubled from about 30 ms to 55 to 63 ms, as in
  `192944` and `210133`, and frames dropped at the GPU for the rest of the take: 453 lost (2.5%),
  29.23 fps written, 17539 frames, and 4759 viewfinder yields. Capture stayed at 29.99 fps with
  `missed 8`, so the camera delivered and the GPU fell behind. Battery fell from 50% to 25% over the
  take. With take 1, this shows that **Efficient when hot** carries the full-detail debayer through
  heat, and Maximum quality alone doesn't. Both stay as the defaults: Efficient when hot on,
  Bilinear when hot off.

- **Session on `4241f0d`, over the link:**
  - **12-bit ProRes 4444 doesn't hold a hot take.** Take `170031`, 1x, Maximum quality with
    **Efficient when hot** on and **Bilinear when hot** off, 24-bit PCM stereo and all tools except
    zebras, Apple Log 2, started cool at nominal heat and 65% battery. It ran 8:00, limited by
    storage, at 26.52 fps written, 12731 frames, 105 GB at 219 MB/s, with 1589 lost (12.5%), all at
    the GPU, and `missed 82`. Heat reached fair at 1:05 and serious at 2:10, when the Efficient path
    took over, never critical. The Efficient path held 30 fps at about 25 ms of GPU time until about
    4:45, then GPU time jumped to about 80 ms and every loss came after. Copy grew from about 6 to
    10 ms and memory reached 1.2 GB. Long take 1 in ProRes 422 HQ held 10 minutes with the same hot
    path, so 12-bit 4444 at full size is for short takes or a cool phone. Battery fell from 65% to
    50%.
  - **A baked ACES look costs nothing measurable, and stereo AAC works.** Take `172929`, after 20
    minutes of cooling, 60 seconds of ACES 2.0 baked into HEVC 4:2:0 with AAC stereo, wrote 29.90
    fps, 1794 frames, 25.1 MB/s, with 4 lost at the GPU in the first 5 seconds, `missed 2`. GPU time
    about 26 ms and `draw` about 4 ms, the same as unbaked takes. The sidecar reads "ACES 2.0
    Rec.709, baked in" and the tag Rec.709. The look built in 0.08 s. Stereo AAC at 256 kbps
    recorded with no writer failure, so the `c1e1041` failure is fixed.
  - **First 10 minutes with nothing lost, Apple's preview disconnected.** Take `180159`, after 30
    minutes of cooling, 1x, ProRes 422 HQ, Maximum quality with **Efficient when hot** on and
    **Bilinear when hot** off, 24-bit PCM stereo, all tools except zebras, Apple Log 2, **Disconnect
    Apple's preview** on and the phone charging from 70%. It ran 10:00 at 29.99 fps written, 17997
    frames at 165.4 MB/s, 0 lost at the GPU or encoder, `missed 5`. Heat reached fair at 2:33 and
    serious at 4:03, when the Efficient path took over, never critical. GPU time held near 30 ms at
    serious, `draw` 12 to 16 ms, and 788 viewfinder yields. Against long take 1, which reached
    serious at 2:57 with the preview connected, heat came about a minute later, but this take had a
    30-minute rest against 6 and was charging, so it doesn't yet separate the preview from the rest.
    A matched pair, preview on and off after the same rest, unplugged, would. The owner confirmed
    auto exposure works with it disconnected, so it became the normal behavior after `fa15863`: see
    **After `fa15863`**.
  - **Encoder test, same as before:** 12-bit ProRes 4444 at 57.5 fps at full size, HEVC 4:4:4 from
    16-bit at 29.3 fps, both `kept 12 bits`. This build still has no 10-bit HEVC control.

- **HDR bakes, proven on 2026-11-07 on `88728c4`:** an HLG take from
  `tools/suites/hdr_bakes.json` reads as `arib-std-b67` in BT.2020 in `ffprobe`, so the `-12902`
  fix holds. A PQ take keeps its HDR10 metadata: `ffprobe -show_frames` reads `smpte2084`, BT.2020
  and P3-D65 mastering at 0.0001 to 1000 nits on the stream and every frame. Details are under
  **Session on 2026-11-07** in [history/2026-11.md](history/2026-11.md).

- **iPhone 16 (`iPhone17,3`, iOS 26.6.2), from a second tester's logs on `d2958aa`, 2026-11-10:**
  - **The formats match the 14 Pro's:** 4032x3024 Bayer RAW on both lenses, `bgg4` on the 1x and
    `rgg4` on the 0.5x, black 2112, white 16383, clip 14271, zero shutter lag and responsive capture
    supported. There's no tele.
  - **The photo loop hangs.** Each stream start gave one `-12686`, one good frame, then `Photo loop
    stalled with 1 in flight` every 2 to 3 seconds, on both lenses. Each restart fired a request
    that also hung, and after about ten the camera refused with `-11830`, too many still requests,
    and the loop sat at 0 in flight. Once, the 0.5x ran 11 seconds with no stall line, so the phone
    can deliver.
  - **Both takes wrote nothing:** `133524`, ProRes 422 HQ at 1920x1440, and `134217`, HEVC 4:2:2 at
    4032x3024, ran with `n=0` and ended "No frames were written". The encoder never got a frame.
  - **Encoder check, frames a second at 4032x3024, 2880x2160, 1920x1440:** HEVC 4:2:0 28.0, 51.2;
    4:2:2 26.6, 48.5; 4:4:4 26.4, 45.3; ProRes 422 17.0, 33.4; 422 HQ 14.9, 27.6, 58.0; 4444 9.4,
    20.7, 42.6; 422 LT 24.2, 42.6; 12-bit 4444 8.5 at full size. So ProRes is far below real time
    at full size on this phone. The check ran while the stalled stream was open.

  - **Fast capture off streams, on `edec570`, 2026-11-11:** the ladder ran as designed. The
    standard setup stalled twice with 2 frames since start, and so did Apple's preview connected.
    With zero shutter lag, responsive capture and fast priority off, the stream ran and was kept
    after 90 frames: `capture_support.json` holds step 2, and the next launch opened on it with no
    stall. That setup also has no `-12686` at stream start. So the fast capture options are what
    hang this phone, not the missing preview. Only the 1x was tried.
  - **Full-size takes hold about 30 fps there:** all 1x, Apple Log, Maximum quality, nominal heat.
    HEVC 4:2:2 at 4032x3024: `110931`, 152 frames at 29.04 fps, 0 lost, `missed 5`, gap 200 ms;
    `111223`, 239 frames at 29.63 fps, 0 lost, `missed 3`. ProRes 422 HQ at 4032x3024: `111419`,
    171 frames at 29.65 fps, 1 lost at the GPU, 156.3 MB/s, `missed 1`. GPU 14 to 19 ms. All are 5
    to 8 seconds, so nothing here shows a long or hot take.
  - **ProRes at full size doesn't hold there, read from the phone on 2026-11-11:** take `135411`,
    0.5x, ProRes 422 HQ at 4032x3024, charging at 70%, right after an encoder test. Over 70.7
    seconds it wrote 1010 frames at 14.26 fps and lost 1003: 997 at the encoder, `not ready`, from
    the first 5 seconds on, and 6 at the GPU. Capture ran 28.30 fps with `missed 121` and 14
    duplicates. Heat reached fair at 19 seconds and serious at 29. So the short `111419` only
    looked fine because 6 seconds fit in the encoder's queue. This phone's ProRes encoders are
    software (`prores.sw`, not hardware accelerated), which the 14 Pro's aren't.
  - **The encoder check is right:** run again with the stream up, it read HEVC 4:2:0, 4:2:2 and
    4:4:4 at 30.3, 30.0 and 29.5 fps at full size and 57.3, 54.5 and 53.6 at 2880x2160; ProRes
    422, 422 HQ and 4444 at 21.5, 17.7 and 11.1 at full size and 38.9, 33.8 and 21.7 at
    2880x2160. That is close to the first run and to the long take's 14 fps, so `bestDefault`'s
    HEVC 4:2:2 at 2880x2160 suits this phone. Full-size HEVC sits right at 30, with nothing spare.
  - **Full-size HEVC 4:2:2 held 80 seconds:** take `135906`, 0.5x, 4032x3024, Apple Log 2,
    Maximum quality, charging at 70%. 2381 frames at 29.94 fps, 0 lost at the GPU or encoder,
    `missed 5`, 37.7 MB/s, GPU 23.4 ms, no viewfinder yields. Heat was nominal at the start, 23
    seconds after cooling from serious, then fair at 0:29 and serious at 1:08, when the Efficient
    path took over with no change in GPU time. Nothing was lost in the 10 seconds at serious.
  - **The 0.5x streams on the kept setup:** that take and two stream starts ran with no stall.
  - **Export works:** `111223` exported with ACES 2.0 and a grade to HEVC 4:2:0 at full size, 239
    frames in 8.8 s at about 31 fps, footprint 2.47 GB.

- **Lens stabilization in RAW brackets, iPhone 16 on `1a1d56c`, 2026-11-11:** from
  `probe_20261111_142741.txt`, with one request at a time.
  - **The 1x's stabilizer can be switched for RAW.** `isLensStabilizationDuringBracketedCapture
    Supported` is true, with brackets of up to 8. Every photo of a bracket with it off reported
    `off`, and with it on `active`.
  - **Brackets are too slow one at a time.** Brackets of 1 came 133 ms apart, 7.5 a second. In
    brackets of 3 the frames came 33 ms apart, then 167 ms to the next bracket's first. Plain RAW
    came 33 ms apart.
  - **Plain RAW says nothing of the stabilizer:** its photos report `unsupported`, so whether it
    runs in the app's normal stream is still unknown.
  - **The 0.5x has no switch:** not supported, and asking for it raises, which the probe caught.
  - The probe's photos were 4224x3024, the size with distortion correction left at its default,
    not the app's 4032x3024.

- **Baked FX with the shared glow, 14 Pro, 2026-11-11:** take `164209` from `fx_baked.json` with
  no cooling wait, on a build with `cb8137a`'s shared glow, unplugged from 40% to 20%, nominal at
  the start after a few minutes with the stream off. It ran 10:00 and wrote 14,747 frames at 24.58
  fps, with 3,247 lost at the GPU and none at the encoder; capture held 29.99 fps, `missed 7`.
  - **The Maximum path was slow from the first 5 seconds, at nominal heat:** GPU 45 to 48 ms,
    queue 71 to 77 ms, `draw` 88 to 97 ms and about 9 frames a second lost, through fair at 2:54,
    until serious at 6:20. Take `192732` on `947b90e`, the same settings without the shared glow,
    had 19 to 22 ms, 0.5 ms and 6 to 8 ms for its first two minutes. So heat isn't the cause. That
    take was charging after 30 minutes' cooling, which also differs.
  - **The Efficient path with baked FX held at serious heat:** from 6:20 to the end, 3:40, GPU 24
    to 29 ms, queue about 1 ms, `draw` 9 to 17 ms and 1 frame lost. On `947b90e` it held 44 ms.
  - **Read from the code, not proven:** the viewfinder sampled the one glow texture every queued
    frame rewrites, handed over at encoding, so each draw waited on those frames. `02d2d11` pools
    the glows and hands one over with the finished image.

- **The glow fix works, and the Maximum path still steps down, 14 Pro on `02d2d11`, 2026-11-11:**
  take `190958` from `fx_baked.json`, after 30 minutes' cooling, unplugged from 70%. It ran 10:00
  and wrote 16,471 frames at 27.45 fps, with 1,524 lost at the GPU and none at the encoder;
  capture held 29.99 fps, `missed 7`.
  - **The start is fixed:** for 2:25 at nominal heat, GPU 26 ms, queue 0.4 ms, `draw` 4 ms and
    nothing lost, where `164209` had 45, 71 and 93 ms. `draw` is under the 6 to 8 ms it cost
    before the glow was shared.
  - **The step down came anyway:** at 2:27, still nominal, GPU time went from 26 to 43 ms in one
    step, queue to 64 ms and `draw` to 24 ms, and about 7 frames a second dropped. Fair followed
    12 seconds later. `192732` did the same at 1:57. So it's the GPU's own step, ahead of the
    heat state, and baked FX on the Maximum path don't fit in what's left.
  - **The Efficient path ended it:** at serious, 6:09, it took over, and the last 3:50 ran at 28
    to 29 ms, queue about 1 ms, `draw` 4 ms, with nothing lost.

- **14 Pro over the link on `02d2d11`, 2026-11-11:**
  - **The standard capture setup holds there:** three launches and two 10-minute takes with no
    `Capture stalled` line, `captureSetup` standard and the format 4032x3024 `bgg4` as before.
  - **Measuring lenses writes the Gyroflow profiles:** `measureLenses` saved the three lens
    profiles and four Gyroflow files, 1x and tele, open gate and 16:9, and `sendFile` fetched
    them. The 1x reads fx 2840.9 px, centre (2004.3, 1528.8), fitted within 0.56 px; the tele fx
    9258.4, centre (2029.4, 1444.1), within 0.02 px.
  - **The probe ended the app:** `probe` crashed with signal 5 in `StabilizationCatcher`'s
    release, reached from `probeLensStabilization`, and wrote no report. A dispatch semaphore
    freed below the value it was made with traps, which happens when a photo's wait times out. So
    at least one stabilization case never got its photo back in 5 seconds on this phone. Fixed in
    `b740eab` by making the semaphore empty and filling it.

- **Lens stabilization in RAW brackets, 14 Pro on `b740eab`, 2026-11-11:** from
  `probe_20261111_200208.txt`, which ran to its end, so the probe's crash is fixed.
  - **The 1x and tele can switch the stabilizer, the ultra wide can't,** as on the iPhone 16.
    Brackets with it off reported `off` on every photo, and with it on `active`.
  - **No bracket holds 30 fps.** On the 1x, frames in a bracket came 33 ms apart, then 161 to 202
    ms passed before the next bracket: 6.2 fps in brackets of 1, about 14 in 3s and 20.8 in 8s.
    Two or four requests in flight changed nothing, and brackets of 3 with 2 in flight gave four
    `-11800` errors. The tele gave 70 ms in a bracket and 252 ms between, 11.6 fps at best.
  - **Plain RAW in the probe** came 40 ms apart on the 1x, 60 on the tele and 50 on the ultra
    wide, and reports `unsupported`, so the stabilizer's state in a normal take is still unknown.
  - So a stabilizer switch for takes fails the condition set for building it.

- **Baked FX on the Efficient path throughout, 14 Pro on `b740eab`, 2026-11-11:** take `200230`
  from `fx_baked.json` with no cooling wait, unplugged from 65%, minutes after the probe and
  about 50 after the last 10-minute take. It ran 10:00 and wrote 17,182 frames at 28.64 fps, with
  812 lost at the GPU and none at the encoder; capture held 29.99 fps, `missed 5`. The sidecar
  reads "Efficient, for the baked FX".
  - **Nothing was lost for 5:07,** at 28 to 30 ms a frame, queue under 1 ms, `draw` 3 to 4 ms and
    no viewfinder yields, through fair at 0:40 and serious at 2:00. The Maximum path's step at
    about 2 minutes didn't come.
  - **Then the GPU stepped again:** at 5:07, after 3:07 at serious, GPU time went from 29 to 37
    ms and queue to 50 ms, and about 2.7 frames a second dropped to the end, with 7,054 yields.
  - It heated far faster than the cooled takes, which reached serious at 4 to 6 minutes, so this
    doesn't show what a cooled take does. Long take 1, without FX, held 7 minutes at serious on
    this path at 30 to 32 ms.

- **What each stage costs the GPU, 14 Pro on `907287d`, 2026-11-11:** from
  `gpu_cost_20261111_205853.txt`, at fair heat, a made-up frame run 45 times back to back with
  the camera stopped, median ms, Malvar-He-Cutler unless said. Stage to stage the figures wander
  by a millisecond or two: the first stage read 17.7 ms and the same work plus the look 14.9.
  - **A frame costs far less than a take reports.** An Efficient baked-FX frame takes 12.0 ms and
    a log one 8.2, where takes read 28 to 30 and about 25. The Maximum path's baked-FX frame
    takes 18.7. So a take's GPU time isn't the work's own length. The likely cause, unproven, is
    that iOS runs the GPU slower when the load leaves room, and caps it when hot.
  - **Where an Efficient baked-FX frame's 12.0 ms goes:** the planes in log 6.9, the look 0.6,
    the per-pixel FX about 1.3, the monitor image 1.1 and its glow 2.2. Grain is about 0.7 of
    the FX.
  - **Making the monitor image and glow less often:** every fourth frame, the frames between
    take 8.8 ms, so every other frame averages about 10.4, 13% less, and every fourth about 9.6,
    20% less.
  - **Other cuts:** 16:9 takes 9.8 ms, 18% less. Bilinear takes 10.6, 12% less.

- **A baked-FX take held 10 minutes with no cooling wait, 14 Pro on `35d43dc`, 2026-11-11:** take
  `212113` from `fx_baked.json` with `cool` at 0, from 60%, about 20 minutes after the cost test
  at fair heat. Efficient throughout, with the monitor image and glow every other frame. It ran
  10:00 and wrote 17,993 frames at 29.99 fps, with 2 lost at the GPU, in the first minute and at
  about 5:30, and none at the encoder; `missed 7`, 366 viewfinder yields.
  - **GPU time held 29 to 30 ms throughout,** queue about 1 ms, `draw` 5 to 15 ms.
  - **It heated far slower than `200230`:** fair at 3:55 and serious at 7:45, against 0:40 and
    2:00. So it spent 2:15 at serious, and `200230` stepped down after 3:07 there. This take
    doesn't show the glow change surviving that step, only that this start no longer reaches it
    in 10 minutes. The phone had rested longer before it, which may be all of the difference.
  - **GPU time didn't fall with the work:** 29 ms, as before the change that the cost test puts
    at 13% less work. That fits the GPU's speed following its load.

- **A second baked-FX take, started hot, held too, 14 Pro on `35d43dc`, 2026-11-11:** take
  `213229`, begun 76 seconds after `212113` ended, at serious heat and 50%, with no cooling step.
  It ran 10:00 at serious throughout, never critical, and wrote 17,969 frames at 29.95 fps, with
  30 lost at the GPU, 0.17%, and none at the encoder; `missed 2`, 560 viewfinder yields.
  - **No step down:** GPU time stayed 26 to 32 ms and queue under 3 ms for the whole take, about
    13.5 minutes after the phone first reached serious. `200230` stepped to 37 ms after 3:07.
  - **The losses came in short bursts** between 4:30 and 8:30: 3, then 9, then 17, then 1.
  - `draw` read 7 to 25 ms, higher than the cool take's 5 to 15.
  - So 20 minutes of baked FX recorded back to back with 32 frames lost in all.

- **Gyroflow on an upright take, measured from a screen recording, 2026-11-11:** take `220644`, 38
  seconds held upright, slow pans at 0.3 to 0.4 rad/s, then held with small shakes, played in
  Gyroflow on the phone with the 1x profile at 118.6% zoom. Frame-to-frame shifts of the
  preview, by matching row and column sums, were fitted to the `.gcsv`. This is a recording of
  Gyroflow's preview, not the take's own frames, so it counts as strong evidence, not proof.
  - **Gyroflow corrects on the wrong axes when the phone is upright.** A pan about the phone's
    long axis, gyro y, moves the picture sideways, as it must. In the hold, Gyroflow's frame
    outline moved sideways with gyro x instead, and the picture moved up and down with gyro y:
    0.22 to 0.27 screen px per predicted sensor px, the same scale as the pan, explaining 62 to
    87% of the motion. The `.gcsv` always says `yXZ`, which is the sensor's own frame, while an
    upright take's file carries a quarter-turn. So the shakes aren't removed, they're moved to
    the other axis.
  - **The shakes the gyro saw aren't in the footage.** With Gyroflow correcting the wrong axis,
    the camera's real shake should still show on the right one: gyro y in the picture's sideways
    motion at -0.22. It came out at +0.02, and gyro x in the up and down motion at +0.03 to
    +0.04. The simplest reading is that the optical stabilizer had already taken nearly all of
    a hand's small shake out of the RAW frames, while pans pass whole.
  - **What follows, if the take's own frames confirm it:** a gyro correction of small shakes
    would add them back in reverse, so stabilized export should leave fast small motion to the
    optics and correct only the slow, large motion, or measure the picture as well.

## Not verified

- **The two Gyroflow readings above, on the take's own frames:** a small export of `220644`
  against its `.gcsv` would settle both without Gyroflow in between.

- **Baked FX past 20 minutes, or in a warm room:** both takes were indoors on a phone lying
  still.

- **Why a take's frame reads two to three times its own cost:** the GPU's speed following the
  load is a guess. A take that reads the same GPU time with half the work would support it.


- **Gyroflow lens profiles:** Gyroflow on the phone loaded the 1x open gate profile with take
  `215524` on 2026-11-11 and stabilized with it, by the owner's word and a screen recording. Its
  `.gcsv` is sound: 1,064 samples at an even 9.98 ms, 1.00 g. The take can't judge the profile,
  though: its pans ran 1 to 2 rad/s, about 100 degrees a second, and it was heavily blurred.
  Still open: whether Apple's table describes the RAW
  frame, and whether it runs undistorted to distorted, as Apple's sample code reads it and the
  fit assumes. The optical centre is used for the profile, 9 px from Apple's distortion centre.

- **Lens stabilization:** whether brackets requested before the last one ends, or brackets of 8,
  give a steady 30 fps, which a take would need. What the 14 Pro's probe says. Whether switching it
  off removes the gap between the gyro and the picture's motion.

- **iPhone 16:** why the fast capture options hang its photo requests. Whether Apple's preview
  connected alone would have streamed: it ran about 4 seconds without a stall line before the app
  was left, then stalled on return. HEVC past 80 seconds, and how long it holds at serious heat. How fast
  it heats from a real cold start, unplugged: both long takes followed a long stream, an encoder
  test or a hot take, and were charging, which the tester takes to be the cause.

- **From Batches 1 to 10:** what SCOPE and FX each cost the GPU in a long hot take; that grading
  sliders don't cost capture while dragging;
  whether the gear's larger target settles its taps; the look panel and its pages on a phone other
  than the 14 Pro; and how baked HDR looks on an HDR display against SDR.

- **ACES camera inputs, checked against OpenColorIO 2.6 on 2026-11-07** with
  `tools/check_camera_inputs.py`, which copies VibeLog's curve decoders and gamut matrices and sends
  729 log codes per pair two ways to the ACES 2.0 SDR view: VibeLog's decode and matrix to linear
  Rec.2020, then OCIO's view, and OCIO's own camera input. Every curve matches exactly: grays differ
  by 0.0000 for all six pairs, and Apple Log matches everywhere. Each gamut matrix differs from
  OCIO's by about 0.4%, at most 0.0043 to 0.0056 per entry, the same pattern for every gamut, and
  neutrals stay neutral both ways. The cause is OCIO's route, through ACES white with the vendors'
  matrices to AP0 and Bradford back to D65, where VibeLog converts directly between two D65 spaces
  from the published primaries, which is what a non-ACES colour-managed grade does. In the ACES look
  that gives display differences of p95 0.005 to 0.011, and up to 0.044 to 0.064 for strongly
  saturated codes near the gamut boundary, where ACES 2.0's gamut compression magnifies small
  changes. The Canon D55 worry doesn't show: OCIO's Canon input keeps neutrals neutral, with no
  cast. Still open: whether the in-app ACES looks should take the vendors' route to AP0 so they
  match an ACES grade in Resolve exactly.

- Recording well past 10 minutes. Ten minutes with nothing lost happened once, in take `180159`.
- Why the long run was about 16 frames short of 30 fps: skipped frames or the sensor's real rate.
  The new `missed` and `gap` figures should show which.
- Whether **Auto exposure and white balance during a take** costs frames.
- Why a take at 00:24:03 in the last session stopped after 76 ms with no frames. It may have been a
  double tap or record firing twice.
- Whether the 8-minute clip played to the end.
- Color accuracy against a chart.
- Whether the exposure default holds across scenes.
- Whether footage with distortion correction off keeps correct color and levels.
- Crash recovery from the 10-second file fragments.
- What `-12686` and `-16800` mean. Nearly every one is the single failure right after a session
  rebuild. The exception is the ultra wide long run, where 33 came mid-take while the GPU ran slow.
- Why `-11819` session runtime errors appear. Three came with the camera idle, and each stream
  recovered within a second.
- False color ranges, which are my own choice.
- Whether the **Color space** choices match real S-Gamut3 and AWG3 footage. Its matrices come from
  published primaries.
