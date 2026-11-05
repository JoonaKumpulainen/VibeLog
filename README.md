# VibeLog

See [ROADMAP.md](ROADMAP.md) for the plan.

iPhone 14 Pro camera app that captures 12 MP RAW Bayer frames at up to 30 fps, processes them on the GPU and records log video in ProRes or HEVC, or a look baked in. The goal is the full quality of the sensor, and where quality and convenience conflict, quality wins. [HANDOFF.md](HANDOFF.md) records what's been proven on the phone.

## Install on the phone

### With SideStore

Each build of `main` that passes CI goes to the `sidestore` release, with a SideStore source beside it.

1. Set up SideStore on the phone, following its own guide.
2. In SideStore, open **Sources**, tap **+**, and add `https://github.com/JoonaKumpulainen/VibeLog/releases/download/sidestore/source.json`.
3. Open VibeLog in that source and tap **Free** to install it.
4. Trust your Apple ID and turn on Developer Mode as in step 4 below, then open VibeLog and allow camera access.

New builds then show under **My Apps** as updates, numbered by CI run. SideStore refreshes the 7-day signature by itself while its own connection works.

### By hand

1. Open the repo's **Actions** tab, then the latest green **Build unsigned IPA** run.
2. Under **Artifacts**, download `VibeLog-unsigned-ipa` and unzip it to get `VibeLog-unsigned.ipa`.
3. Install it with one of these:
   - **Sideloadly** (Windows/macOS): connect the iPhone by USB, drag in the `.ipa`, enter your Apple ID, click **Start**.
   - **AltStore**: install AltServer and AltStore, then in AltStore open **My Apps**, tap **+**, and pick the `.ipa`.
4. On the phone, enable **Settings > Privacy & Security > Developer Mode** and restart if iOS asks. Then trust your Apple ID under **Settings > General > VPN & Device Management**.
5. Open VibeLog and allow camera access.

A free Apple ID signature lasts 7 days, so repeat step 3 when the app stops opening. Reinstalling keeps Documents as long as the bundle ID stays the same.

## What to run

Turn the ring/silent switch to silent first. On iOS 17 the shutter sound is only removed with a workaround.

The camera opens live, and the controls turn to match how you hold the phone, even with the rotation lock on. Recordings carry the hold they started in, so they play upright.

The format sits left of the Dynamic Island, and on its right are gauges for storage, battery and heat, beside the settings gear. Beneath the picture are the tray, the four values and the record row, with **FORMAT** and **LOOK** at its left and **MON** and the last take at its right. **ISO**, **SHUTTER**, **WB** and **FOCUS** open a dial that snaps to common values. On a dial, **FINE** switches to fine steps and **AUTO** hands the value back to the camera. The **SHUTTER** dial's **180°** sets a shutter of half the frame time. The **WB** dial also sets tint, and the **FOCUS** dial has punch-in, which opens on the last focus point and moves with a drag, and **PEAK**, which marks sharp detail in cyan. **FORMAT** opens slidable columns for codec, chroma, size, log curve, aspect and frame rate: 24, 25 or 30. Amber values were set by you, **A** means automatic and a lock means frozen for the take. **EV** shows any exposure offset, and tapping it resets the offset. **MON** swaps the tool row for the monitor tools, including **SCOPE**, a waveform, RGB and YRGB parade, vectorscope or histogram that a tap cycles through. **LOOK** opens the look panel: a carousel of LOG, MONITOR, ACES 2.0, ACES 1.3 and your LUTs, each shown on the picture as it reaches the middle, with that look's styles in a second row beneath it. Tapping ACES 2.0 again picks what it bakes: SDR, HDR PQ or HDR HLG. **ADJUST**, **COLOR** and **FX** grade the look, colour by colour, and add halation, bloom, diffusion, vignette and grain, which takes don't record yet. **BAKE** in the header records the look into takes. **Cancel** puts back what was there, and **Done** or a tap outside keeps it. The thumbnail plays the last take, and back from there are all your takes, each with its details, **Share** and **Delete**. **Select** or a long press deletes takes from the grid, along with their details. The takes and player turn with the phone. After 2 minutes untouched, the camera pauses to save heat and a tap wakes it, which you can change under Viewfinder in Settings. At 16:9, the expand button in the tool row gives a larger picture with only record, the clock and status. Tap the picture to focus and meter there, then drag to set exposure. Pinch or tap the lens value to switch camera. Settings pauses the camera while it's open, unless a take is running, and **Focus peaking sensitivity** is there under Viewfinder, with the **GUIDE** tool's frame guide and anamorphic desqueeze. With a set shutter, **AUTO** on the **ISO** dial gives shutter priority, and **EV** on that dial sets where auto exposure aims. **File tag** under Image sets what the file tells an editor. Under Viewfinder, **ISP preview** shows Apple's own picture, **Look** opens the look panel, **Overlay scope channels** sets how RGB and YRGB draw, and **Haptics** turns every tick off. **Bake** under Image records the look into takes, with **Bake to ProRes** and **Bake as** SDR, HDR PQ or HDR HLG beneath it. A switch's explanation shows while it's on, and search finds a setting by its explanation too. Drag the scope to any corner of the picture and it stays there. **Export** in the player opens on the camera's look with no grade, plays the take through it, and has its own grade editor with the same tabs, written to HEVC or ProRes in SDR or HDR.

**Presets** in Settings save and recall how you work: every setting except the test link. They don't keep what belongs to a shot, such as lens, shutter, ISO, white balance or focus. Any preset can be the default the app opens with, and without one the app opens on your last choices. **Reset all settings** returns everything to the app's own values, keeping presets, takes and the test link. Settings and toolbar choices save to `VibeLog.config.json` in the VibeLog folder. You can edit it in the Files app, and missing keys take their defaults.

During a recording you can change ISO, shutter, white balance and the monitor tools. Focus and exposure drag are off, because focus changes lost frames in testing. Everything else is locked until recording stops. Exposure and white balance freeze at the start of a take unless **Auto exposure and white balance during a take** is on, which keeps them following the scene and lets **AUTO** work on those dials. Auto never picks a shutter slower than one frame, but it can flicker under mains lights.

**Advanced** in Settings holds the pipeline, debayer and lens distortion correction, and each of the first two has a switch for what replaces it when the phone is hot. **Efficient when hot** is on and **Bilinear when hot** is off by default, which held 10 minutes at serious heat with full detail. **12-bit ProRes 4444** feeds ProRes 4444 16 bits, so it keeps 12 bits of color, at about the same size. **Color spaces and LUTs** sets which color space each curve records, which curve each color space records, and a LUT for each curve, all kept in presets. **Diagnostics** is inside it too:

| Tool | What it does |
|---|---|
| **Debug overlay** | Shows frame rate, GPU, drops, memory, heat and storage on the viewfinder. |
| **Show log** | Shows the log. **Copy** puts it on the clipboard, **Previous** opens the last session's log, which holds crash details. |
| **Run control test** | Records 56 seconds and changes focus and exposure on a schedule. Each change is logged with frame and failure counts. |
| **Run probe** | Logs every camera, format and RAW type, checks RAW availability for each session setup, tries Bayer formats on the video output, asks each rear camera for Apple's lens calibration, and scans AVCapture for RAW-related selectors. Saves `probes/probe_*.txt`. Takes up to a few minutes. |
| **Test link** | Connects to `tools/test_server.py` on your computer, which can change settings, start takes and collect logs. It can't delete takes, and it's off at every launch. Use it on your own network only. [TEST_LINK.md](TEST_LINK.md) covers privacy, the server and removing it. |
| **Fixed frame time at 30 fps** | Holds the sensor at 1/30 s. Off lets it stretch to 1/15 s, as older builds did. |
| **Start stream** / **Stop stream** | Starts or stops the selected method without saving. |
| **Encode video** | Off records a RAW dump to `clips/clip_*/`. Turn off **Write frames to disk** to measure capture speed alone. |
| **Log capture timing** | Off by default. Each encoded take saves `videos/video_*.timing.csv`, with when each photo was requested, started and arrived and when the camera wasn't ready, and logs a `Capture timing:` summary. Holds about 30 minutes in memory. |

Methods:

- **Photo RAW: readiness/ZSL** is the default and the fastest so far.
- **Photo RAW: sequential**: fires the next Bayer photo when the last one finishes.
- **Readiness/ZSL detail**: fires when `AVCapturePhotoOutputReadinessCoordinator` reports ready, with zero shutter lag, responsive capture and fast prioritization on where supported.
- **Photo RAW: bracket burst**: repeated bracket captures with equal exposures.
- **Use Photo preset**: on by default for photo methods, and required for RAW: with it off, iOS lists no RAW formats at all.
- **Video data output**: the pixel format picker shows only what iOS lists. If it lists no Bayer format this is a non-RAW control run.

## Processing

Photo methods feed a GPU pipeline: black level, white balance, debayer, camera RAW to linear Rec.2020 using the DNG's color matrices, exposure, then a log curve. **Pipeline** is **Maximum quality** by default; **Efficient** does the same math with less GPU work, as described in the roadmap. **Monitor** shows the result in Rec.709, decoded per pixel on the GPU, as plain log, or switches back to the ISP preview. **Save still** saves the next processed frame to `stills/`. The overlay's `gpu` line shows the time per frame and any frames the pipeline dropped.

Curves are Apple Log, Apple Log 2, S-Log3, S-Log2, LogC3, LogC4 and Canon Log 3. **Pair curve and color space**, on by default, records each in its own color space: Rec.2020, Apple Wide Gamut, S-Gamut3.Cine (S-Log3's default, with S-Gamut3 also available), S-Gamut, ARRI Wide Gamut 3 and 4, or Cinema Gamut. Choosing either sets the other, and **Color space** under Image picks directly. The sidecar names both. Curve constants match colour-science's implementations of the vendor formulas.

## Encoding

With **Encode video** on, recording writes the log image to `videos/video_*.mov` with stereo microphone audio, plus a `.json` sidecar naming the curve, gamut, look, and the take's shutter, ISO and white balance with how each behaved. **Run encoder test** benchmarks every codec and size on synthetic frames, without the camera, and saves `probes/encoders_*.txt`. Support differs by phone, so check that before trusting a preset.

The default is ProRes 422 HQ at 4032x3024. On an iPhone 14 Pro it recorded 60 seconds at about 30 fps, using about 160 MB/s or 9.5 GB per minute. HEVC only just reaches 30 fps at this size even with nothing else running.

The file is tagged Rec.2020, but its transfer tag is nominal. Apply the log curve named in the sidecar when grading. **File tag** under Image can tag Rec.709 instead, which also encodes in Rec.709's YCbCr matrix. A baked take is a finished Rec.709 picture, tagged so, with no log kept: **Bake** switches the codec to HEVC 4:2:0, about 25 to 30 MB/s against 160 for ProRes 422 HQ, and greys out **Color space**.

## Long recordings and monitoring

**Stop after** defaults to **Never** and goes up to 30 minutes. Recording stops safely if the thermal state turns critical or less than 10 GB is free, because writes slow down on a nearly full phone. Files are written in 10-second fragments, so a killed app should lose only the last few seconds. **Freeze viewfinder during a take** freezes the preview to save power and heat. **Stereo audio**, on by default, records left and right from the built-in microphones, with a meter for each. **Uncompressed audio** records 24-bit PCM instead of AAC. **Save gyro data** writes a `.gcsv` beside each take, which Gyroflow finds by itself when you open the video. **Efficient when hot**, **Bilinear when hot** and **Slow viewfinder when hot** switch to the Efficient path, the bilinear debayer and a slower monitor once the thermal state is serious.

On an iPhone 14 Pro, ProRes 422 HQ at full size with reduced load held 30 fps for over 8 minutes at serious thermal state. Without it, heat cut GPU speed and frames began to drop at 5 minutes. Recording near an empty battery can stall the encoder, so start with a good charge.

**Aspect** records open gate, the sensor's full 4:3 frame, or a 16:9 center crop, and the monitor dims the area outside it. **Exposure tool** adds zebras where the sensor clips, or false color: blue is four stops under middle gray, green is middle gray, pink is about one stop over, yellow is well above that, and red is clipped. These show exposure of the signal, not of the graded image.

**Import .cube LUT** adds a LUT to the viewfinder's looks, and with **Bake** on, to the file. Set **LUT made for** to Log for conversion LUTs, which take the recorded log image in the chosen curve and gamut, or to Rec.709 for look LUTs, which are applied after the built-in Rec.709 view. 3D LUTs up to size 129 work; 1D LUTs do not. The built-in **ACES 2.0** and **ACES 1.3** looks are the Academy's Rec.709 output transforms, built on the phone for the curve and color space recorded, and always work on log.

**Export** in the player writes a copy of a log take with a look baked in, after a preview with a time slider: the Rec.709 view, an ACES look or a LUT, in HEVC 4:2:0 or ProRes 422 HQ, tagged Rec.709, with the take's audio. The copy is `videos/video_*_look.mov`, and the take itself isn't changed.

## Files (Files app > On My iPhone > VibeLog)

```
benchmarks.csv              one row per recording
logs/session_*.log
probes/probe_*.txt
videos/video_*.mov          encoded log video with audio, plus .json and .gcsv
videos/video_*_look.mov     an exported copy with a look baked in
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

`clip.json` holds `blackLevel` and `whiteLevel` for `frames.raw`. The `dng` block holds the tags of `reference.dng`, which use a different scale. A recording needs about 730 MB/s, or 44 GB per minute, at 12 MP and 30 fps. An iPhone 14 Pro wrote that for about 8 GB and then fell to about 420 MB/s, so longer RAW dumps save only some frames. `frames` lists every captured frame; one with no `fileOffset` was not saved.

## Project layout

| Target | Role |
|---|---|
| `Modules/VLCore` | Frames, stats, DNG tag reader, logging, device status |
| `Modules/VLCapture` | Session, capture methods, manual controls, audio, probe |
| `Modules/VLProcessing` | Log curves, color math, Metal pipeline, looks and the ACES ports, export with look, still export |
| `Modules/VLRecording` | RAW dump writer, video encoder, encoder benchmark |
| `Modules/ObjCGuard` | Catches AVFoundation's Objective-C exceptions, runtime scan |
| `App` | SwiftUI UI, overlay and wiring |

`project.yml` is the XcodeGen spec. CI generates the Xcode project, runs the unit tests on a simulator, builds the unsigned app, and packages the `.ipa`.

## Limits

CI proves the code compiles and the file, stats and DNG parsing logic works. Nothing touching the camera has run until it runs on a phone.

## License

Copyright (C) 2026 JoonaKumpulainen

VibeLog is free software under the [GNU General Public License v3.0](LICENSE). You can use, change and share it, and anyone who distributes a modified version must share its source under the same license. It comes with no warranty, to the extent the law allows, as the license sets out in sections 15 and 16. Check important footage before relying on it.

### Third-party code

VibeLog carries two ports of other projects' code. Their licenses are in [LICENSES](LICENSES), [NOTICE](NOTICE) lists what was changed, and the app shows the same texts under **Settings > About > Legal**, since these licenses ask for their notices to travel with the app.

| Part | Ported from | License |
|---|---|---|
| ACES 2.0 look, `Modules/VLProcessing/ACES2.swift` | OpenColorIO's ACES 2.0 output transform, `src/OpenColorIO/ops/fixedfunction/ACES2` at commit `22dd9c4faa`. Copyright Contributors to the OpenColorIO Project. | [BSD 3-Clause](LICENSES/OpenColorIO-BSD-3-Clause.txt) |
| The ACES 2.0 algorithm it implements | The Academy Color Encoding System 2.0 output transform, `ampas/aces-core`. | [Apache License 2.0](LICENSES/ACES-Apache-2.0.txt) |
| ACES 1.3 look, `Modules/VLProcessing/ACES13.swift` | The Academy's ACES 1.3 reference CTL, `ampas/aces-dev` tag `v1.3.1`. Copyright © 2015 Academy of Motion Picture Arts and Sciences (A.M.P.A.S.). Portions contributed by others as indicated. All rights reserved. | [License Terms for ACES Components](LICENSES/ACES-1.3-AMPAS.txt) |

These licenses are permissive. The BSD 3-Clause and Apache 2.0 licenses are compatible with GPLv3, and the Academy's license is a BSD-style license that allows copying, changing and redistributing with its notice, conditions and disclaimer kept. None of them lets VibeLog use the names of the Academy, the OpenColorIO Project or their contributors to endorse or promote it. This is the project's reading of the terms, not legal advice.

`tools/make_aces_reference.py` writes the reference values the tests compare against, using OpenColorIO 2.6's built-in ACES configs. OpenColorIO isn't part of the app.

### Data and formulas

Log curves and color spaces follow their makers' published formulas and primaries. The constants were checked against colour-science, whose code isn't included. LUTs you import stay under their own licenses, and VibeLog doesn't ship any camera maker's LUTs.

### Trademarks and affiliation

Apple, iPhone, Apple Log and ProRes are trademarks of Apple Inc. ACES is a trademark of the Academy of Motion Picture Arts and Sciences. Sony, ARRI and Canon, and the names of their log curves and color spaces, such as S-Log2, S-Log3, S-Gamut3.Cine, LogC3, LogC4, ARRI Wide Gamut, Canon Log 3 and Cinema Gamut, may be trademarks of their owners. Gyroflow, DaVinci Resolve and other names belong to their owners. They're used only to say what VibeLog works with.

VibeLog is an independent project. It isn't affiliated with, endorsed by or certified by Apple, Sony, ARRI, Canon, the Academy of Motion Picture Arts and Sciences, the Academy Software Foundation or the OpenColorIO Project. Its ACES looks are its own implementation, checked against OpenColorIO's output, and it isn't an ACES Logo product.
