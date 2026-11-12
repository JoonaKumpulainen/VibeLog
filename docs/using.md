# Using VibeLog

Turn the ring/silent switch to silent first. On iOS 17 the shutter sound is only removed with a
workaround.

The camera opens live, and the controls turn to match how you hold the phone, even with the rotation
lock on. Recordings carry the hold they started in, so they play upright.

## The camera screen

The format sits left of the Dynamic Island, and on its right are gauges for storage, battery and
heat, beside the settings gear. Beneath the picture are the tray, the four values and the record
row, with **FORMAT** and **LOOK** at its left and **MON** and the last take at its right. Amber
values were set by you, **A** means automatic and a lock means frozen for the take. **EV** shows any
exposure offset, and tapping it resets the offset.

Tap the picture to focus and meter there, then drag to set exposure. Pinch or tap the lens value to
switch camera. At 16:9, the expand button in the tool row gives a larger picture with only record,
the clock and status. After 2 minutes untouched, the camera pauses to save heat and a tap wakes it,
which you can change under Viewfinder in Settings.

## Dials

**ISO**, **SHUTTER**, **WB** and **FOCUS** open a dial that snaps to common values. On a dial,
**FINE** switches to fine steps and **AUTO** hands the value back to the camera. The **SHUTTER**
dial's **180°** sets a shutter of half the frame time. The **WB** dial also sets tint, and the
**FOCUS** dial has punch-in, which opens on the last focus point and moves with a drag, and
**PEAK**, which marks sharp detail in cyan. With a set shutter, **AUTO** on the **ISO** dial gives
shutter priority, and **EV** on that dial sets where auto exposure aims.

## Format

**FORMAT** opens slidable columns for codec, chroma, size, log curve, aspect and frame rate: 24, 25
or 30.

## Looks

**LOOK** opens the look panel: a carousel of LOG, MONITOR, ACES 2.0, ACES 1.3 and your LUTs, each
shown on the picture as it reaches the middle, with that look's styles in a second row beneath it.
Tapping ACES 2.0 again picks what it bakes: SDR, HDR PQ or HDR HLG. **ADJUST**, **COLOR**,
**WHEELS** and **FX** grade the look, colour by colour and in shadow, midtone and highlight wheels,
and add halation, bloom, diffusion, vignette and grain, which baked takes record with **FX in baked
takes**. A dot over a page's name marks one that holds a change. Beside each page's **RESET**, the
red circled arrow puts all four pages back at once, after asking, and leaves the look. **BAKE** in
the header records the look into takes. **Cancel** puts back what was there, and **Done** or a tap
outside keeps it. Export's grade editor marks its pages the same way and has **Reset All** at the
bottom.

## Monitor tools and scopes

**MON** swaps the tool row for the monitor tools, including **SCOPE**, a waveform, RGB and YRGB
parade, vectorscope or histogram that a tap cycles through. Drag the scope to any corner of the
screen and it stays in that corner however you turn the phone, and drag from its inner corner to
resize it.

## Your takes

The thumbnail plays the last take, and back from there are all your takes, each with its details,
**Share** and **Delete**. **Select** or a long press deletes takes from the grid, along with their
details. The takes and player turn with the phone.

## Export

**Export** in the player opens on the camera's look with no grade, plays the take through it, with a
scope over the preview if you pick one, and has its own grade editor with the same tabs, written to
HEVC or ProRes in SDR or HDR. The scope works as the camera's does: tap it for the next kind, drag
it to any corner of the preview, and drag from just outside its inner corner to resize it. The
arrows at the preview's top right fill the screen with the preview and bring the settings back.

**Stabilize** in Export steadies the copy from the take's gyro log. **Smoothness** is how long a
stretch of the camera's movement is averaged into one steady path: a short one follows your pans
and crops little, a long one holds the frame nearly still, lags behind a pan and crops more. The
copy is enlarged just enough to hide its moving edges, up to 130%, and moves too big to hide at
that are steadied less. Fast small shake is left to the lens's own stabilizer, which already
took most of it out. The preview plays the take stabilized and says how far it's enlarged; switch
**Stabilize** off and on to compare. It needs the take's lens measured under Advanced, Lenses.
For a take you mean to stabilize, use a shutter of 1/250 s or faster: Stabilize holds the frame
still, but blur from a slow shutter still changes direction with each shake.

A take with its look baked in can't be given another look, so the player offers **Stabilize** for
it instead of Export: a screen with only smoothness, which saves the same picture, steadied and
encoded again in the take's own codec, so it loses as little as it can.

**Export** in the player writes a copy of a log take with a look baked in, after a preview that
plays it with the look: the Rec.709 view, an ACES look or a LUT, in HEVC 4:2:0 or ProRes 422 LT, 422
or 422 HQ, tagged Rec.709, or Rec.2020 PQ or HLG for HDR, with the take's audio. An HDR10 export in
HEVC first measures the take's MaxCLL and MaxFALL and writes them into the file. **Size** sets
HEVC's rate (Master, High or Share), **Resolution** shrinks it to 2880 or 1920 wide, and **Crop**
cuts it to 16:9 or 9:16 as it plays. The copy is `videos/video_*_look.mov`, then `_look2.mov` and on
for later exports of the same take, and the take itself isn't changed.

## During a take

During a recording you can change ISO, shutter, white balance and the monitor tools. Focus and
exposure drag are off, because focus changes lost frames in testing. Everything else is locked until
recording stops. Exposure and white balance freeze at the start of a take unless **Auto exposure and
white balance during a take** is on, which keeps them following the scene and lets **AUTO** work on
those dials. Auto never picks a shutter slower than one frame, but it can flicker under mains
lights.

## Settings

Settings pauses the camera while it's open, unless a take is running, and **Focus peaking
sensitivity** is there under Viewfinder, with the **GUIDE** tool's frame guide and anamorphic
desqueeze. **File tag** under Image sets what the file tells an editor. Under Viewfinder, **ISP
preview** shows Apple's own picture, **Look** opens the look panel, **Overlay scope channels** sets
how RGB and YRGB draw, and **Haptics** turns every tick off, and **HDR viewfinder** shows ACES 2.0's
HDR picture with the screen's extra brightness while its dynamic range is HDR. **Lenses** under
Advanced measures this phone's lenses from Apple's calibration, and **Share for Gyroflow** there
sends them as Gyroflow lens profiles, for the 1x and tele, open gate and 16:9. **Bake** under Image records the
look into takes, with **Bake to ProRes**, **FX in baked takes** and **Bake as** SDR, HDR PQ or HDR
HLG beneath it. A take with FX baked in runs on the Efficient pipeline whichever is chosen, and
its details say so. **Lens shading correction** under Advanced brightens the corners by Apple's own lens
shading. A switch's explanation shows while it's on, and search finds a setting by its explanation
too.

**Presets** in Settings save and recall how you work: every setting except the test link. They don't
keep what belongs to a shot, such as lens, shutter, ISO, white balance or focus. Any preset can be
the default the app opens with, and without one the app opens on your last choices. **Reset all
settings** returns everything to the app's own values, keeping presets, takes and the test link.
Settings and toolbar choices save to `VibeLog.config.json` in the VibeLog folder. You can edit it in
the Files app, and missing keys take their defaults.

## Advanced and Diagnostics

**Advanced** in Settings holds the pipeline, debayer and lens distortion correction, and each of the
first two has a switch for what replaces it when the phone is hot. **Efficient when hot** is on and
**Bilinear when hot** is off by default, which held 10 minutes at serious heat with full detail.
**12-bit ProRes 4444** feeds ProRes 4444 16 bits, so it keeps 12 bits of color, at about the same
size. **Color spaces and LUTs** sets which color space each curve records, which curve each color
space records, and a LUT for each curve, all kept in presets. **Diagnostics** is inside it too:

| Tool | What it does |
|---|---|
| **Debug overlay** | Shows frame rate, GPU, drops, memory, heat and storage on the viewfinder. |
| **Show log** | Shows the log. **Copy** puts it on the clipboard, **Previous** opens the last session's log, which holds crash details. |
| **Run control test** | Records 56 seconds and changes focus and exposure on a schedule. Each change is logged with frame and failure counts. |
| **Run probe** | Logs every camera, format and RAW type, checks RAW availability for each session setup, tries Bayer formats on the video output, asks each rear camera for Apple's lens calibration, and scans AVCapture for RAW-related selectors. Saves `probes/probe_*.txt`. Takes up to a few minutes. |
| **Test link** | Connects to `tools/test_server.py` on your computer, which can change settings, start takes and collect logs. It can't delete takes, and it's off at every launch. Use it on your own network only. [test-link.md](test-link.md) covers privacy, the server and removing it. |
| **Log sharing** | Off until you turn it on and enter an invite code. Sends session logs, take details, test reports and lens profiles to the VibeLog test service on Wi-Fi, or mobile data with **Use mobile data** on, never during a take and never videos or stills. Dates, addresses and names you typed are taken out first, and the phone is known only by a random ID. Gyro logs have their own switch. |
| **Fixed frame time at 30 fps** | Holds the sensor at 1/30 s. Off lets it stretch to 1/15 s, as older builds did. |
| **Start stream** / **Stop stream** | Starts or stops the selected method without saving. |
| **Encode video** | Off records a RAW dump to `clips/clip_*/`. Turn off **Write frames to disk** to measure capture speed alone. |
| **Log capture timing** | Off by default. Each encoded take saves `videos/video_*.timing.csv`, with when each photo was requested, started and arrived and when the camera wasn't ready, and logs a `Capture timing:` summary. Holds about 30 minutes in memory. |

Methods:

- **Photo RAW: readiness/ZSL** is the default and the fastest so far.
- **Photo RAW: sequential**: fires the next Bayer photo when the last one finishes.
- **Readiness/ZSL detail**: fires when `AVCapturePhotoOutputReadinessCoordinator` reports ready,
  with zero shutter lag, responsive capture and fast prioritization on where supported.
- **Photo RAW: bracket burst**: repeated bracket captures with equal exposures.
- **Use Photo preset**: on by default for photo methods, and required for RAW: with it off, iOS
  lists no RAW formats at all.
- **Video data output**: the pixel format picker shows only what iOS lists. If it lists no Bayer
  format this is a non-RAW control run.

## Processing

Photo methods feed a GPU pipeline: black level, white balance, debayer, camera RAW to linear
Rec.2020 using the DNG's color matrices, exposure, then a log curve. **Pipeline** is **Maximum
quality** by default; **Efficient** does the same math with less GPU work, as described in the
[roadmap](../ROADMAP.md). **Monitor** shows the result in Rec.709, decoded per pixel on the GPU, as
plain log, or switches back to the ISP preview. **Save still** saves the next processed frame to
`stills/`. The overlay's `gpu` line shows the time per frame and any frames the pipeline dropped.

Curves are Apple Log, Apple Log 2, S-Log3, S-Log2, LogC3, LogC4 and Canon Log 3. **Pair curve and
color space**, on by default, records each in its own color space: Rec.2020, Apple Wide Gamut,
S-Gamut3.Cine (S-Log3's default, with S-Gamut3 also available), S-Gamut, ARRI Wide Gamut 3 and 4, or
Cinema Gamut. Choosing either sets the other, and **Color space** under Image picks directly. The
sidecar names both. Curve constants match colour-science's implementations of the vendor formulas.

## Encoding

With **Encode video** on, recording writes the log image to `videos/video_*.mov` with stereo
microphone audio, plus a `.json` sidecar naming the curve, gamut, look, and the take's shutter, ISO
and white balance with how each behaved. **Measure this phone again** stops the camera, lets the phone
cool to nominal heat for up to five minutes, times every codec and size on synthetic frames, saves
`probes/encoders_*.txt`, and replaces the quick first-launch figures the warnings use. It then
times the GPU for each recording setup, as **Run GPU cost test** does. **Encoder limits** and
**GPU limits** below it say how and when they were measured, and what takes proved. A take of
two and a half minutes or more that keeps nearly every frame proves its setup on the GPU; one
that falls behind makes that setup warn. **Run trial takes** records up to three 20-second takes
of the setups this phone records best, with the camera on, lying still: the best codec and size,
ProRes 422 HQ at full size, and the first with the look baked in. Each counts as evidence like
any take, then is deleted; the results go to `probes/trials_*.txt`. A take of five seconds or more that holds
30 fps in a codec and size proves it, and its warning stops for good; a take whose encoder drops
frames makes it warn from then on. **Run GPU cost test** times each stage of a frame on the
GPU the same way, for both pipelines and debayers, and saves `probes/gpu_cost_*.txt`.

The default is ProRes 422 HQ at 4032x3024. On an iPhone 14 Pro it recorded 60 seconds at about 30
fps, using about 160 MB/s or 9.5 GB per minute. HEVC only just reaches 30 fps at this size even with
nothing else running.

The file is tagged Rec.2020, but its transfer tag is nominal. Apply the log curve named in the
sidecar when grading. **File tag** under Image can tag Rec.709 instead, which also encodes in
Rec.709's YCbCr matrix. A baked take is a finished Rec.709 picture, tagged so, with no log kept:
**Bake** switches the codec to HEVC 4:2:0, about 25 to 30 MB/s against 160 for ProRes 422 HQ, and
greys out **Color space**.

## Long recordings and monitoring

**Stop after** defaults to **Never** and goes up to 30 minutes. Recording stops safely if the
thermal state turns critical or less than 10 GB is free, because writes slow down on a nearly full
phone. Files are written in 10-second fragments, so a killed app should lose only the last few
seconds. **Freeze viewfinder during a take** freezes the preview to save power and heat. **Stereo
audio**, on by default, records left and right from the built-in microphones, with a meter for each.
**Uncompressed audio** records 24-bit PCM instead of AAC. **Save gyro data** writes a `.gcsv` beside
each take, which **Stabilize** in Export steadies the take from. Gyroflow finds it by itself when
you open the video, with two cautions: the 1x and tele steady themselves optically while recording,
which the gyro can't see, so Gyroflow adds small fast shake back on them, and a take held upright
is corrected on the wrong axes until the log says how the phone was held. The ultra wide has no
optical stabilizer and suits Gyroflow as it is. **Efficient when hot**,
**Bilinear when hot** and **Slow viewfinder when hot** switch to the Efficient path, the bilinear
debayer and a slower monitor once the thermal state is serious.

On an iPhone 14 Pro, ProRes 422 HQ at full size with reduced load held 30 fps for over 8 minutes at
serious thermal state. Without it, heat cut GPU speed and frames began to drop at 5 minutes.
Recording near an empty battery can stall the encoder, so start with a good charge.

**Aspect** records open gate, the sensor's full 4:3 frame, or a 16:9 center crop, and the monitor
dims the area outside it. **Exposure tool** adds zebras where the sensor clips, or false color: blue
is four stops under middle gray, green is middle gray, pink is about one stop over, yellow is well
above that, and red is clipped. These show exposure of the signal, not of the graded image.

**Import .cube LUT** adds a LUT to the viewfinder's looks, and with **Bake** on, to the file. Set
**LUT made for** to Log for conversion LUTs, which take the recorded log image in the chosen curve
and gamut, or to Rec.709 for look LUTs, which are applied after the built-in Rec.709 view. 3D LUTs
up to size 129 work; 1D LUTs do not. The built-in **ACES 2.0** and **ACES 1.3** looks are the
Academy's Rec.709 output transforms, built on the phone for the curve and color space recorded, and
always work on log.

## On other iPhones

VibeLog is built on the iPhone 14 Pro and fits itself to other models from the 12 on.

- **Codec and size:** at the first launch it times each encoder for a few seconds, then starts on
  the largest picture the phone records at 30 fps. Phones with a slow ProRes encoder start on HEVC.
  You can still pick any codec and size, and a choice that measured under 30 fps warns when you
  press record.
- **Camera:** if the picture freezes just after opening, the app says **Camera stalled, trying
  another setup** and restarts the camera a different way. It remembers the one that works.
- **Record:** it won't start while the camera delivers no frames, and a take stops with a message
  if the frames stop.

## Files (Files app > On My iPhone > VibeLog)

```
benchmarks.csv              one row per recording
logs/session_*.log
probes/probe_*.txt
videos/video_*.mov          encoded log video with audio, plus .json and .gcsv
videos/video_*_look*.mov    an exported copy with a look baked in
luts/                       imported .cube files
stills/still_*/             log_rec2020.png (16-bit), rec709_half.png, still.json
clips/clip_*/
  frames.raw                frames back to back, rows keep their bytesPerRow
  clip.json                 layout, CFA, black/white, WB, matrices, stats, per-frame timestamps
  reference.dng             a real DNG of one frame (photo methods), opens in any RAW editor
  reference_metadata.json   full photo metadata for that frame
```

Summarize a clip and export a frame on a computer:

```bash
python3 tools/inspect_clip.py path/to/clip_x --png frame.png
```

`clip.json` holds `blackLevel` and `whiteLevel` for `frames.raw`. The `dng` block holds the tags of
`reference.dng`, which use a different scale. A recording needs about 730 MB/s, or 44 GB per minute,
at 12 MP and 30 fps. An iPhone 14 Pro wrote that for about 8 GB and then fell to about 420 MB/s, so
longer RAW dumps save only some frames. `frames` lists every captured frame; one with no
`fileOffset` was not saved.
