# VibeLog

See [ROADMAP.md](ROADMAP.md) for the plan.

iPhone 14 Pro camera app, working towards RAW Bayer capture processed on the GPU and recorded as log video. **Phase 1 only answers one question: can we get a continuous RAW stream, and how fast?**

## Install on the phone

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

Status sits in the corners beside the Dynamic Island. Beneath the picture are the tray, the four values and the record row. **ISO**, **SHUTTER**, **WB** and **FOCUS** open a dial that snaps to common values. On a dial, **FINE** switches to fine steps and **AUTO** hands the value back to the camera. The **WB** dial also sets tint, and the **FOCUS** dial has punch-in, which opens on the last focus point and moves with a drag, and **PEAK**, which marks sharp detail in cyan. **FORMAT** opens slidable columns for codec, chroma, size, log curve, aspect and frame rate, including 23.98 and 29.97. Amber values were set by you, **A** means automatic and a lock means frozen for the take. **EV** shows any exposure offset, and tapping it resets the offset. **MON** swaps the tool row for the monitor look and tools. The thumbnail plays the last take, and back from there are all your takes, each with its details, **Share** and **Delete**. **Select** or a long press deletes takes from the grid, along with their details. At 16:9, the expand button in the tool row gives a larger picture with only record, the clock and status. Tap the picture to focus and meter there, then drag to set exposure. Pinch or tap the lens value to switch camera.

**Presets** in Settings save and recall the format, pipeline, debayer and exposure offset. Settings and toolbar choices save to `VibeLog.config.json` in the VibeLog folder. You can edit it in the Files app, and missing keys take their defaults.

During a recording you can change ISO, shutter, white balance and the monitor tools. Focus and exposure drag are off, because focus changes lost frames in testing. Everything else is locked until recording stops. Exposure and white balance freeze at the start of a take unless **Auto exposure and white balance during a take** is on, which keeps them following the scene and lets **AUTO** work on those dials. Auto never picks a shutter slower than one frame, but it can flicker under mains lights.

Long-press **Version** in Settings to open **Diagnostics**:

| Tool | What it does |
|---|---|
| **Debug overlay** | Shows frame rate, GPU, drops, memory, heat and storage on the viewfinder. |
| **Show log** | Shows the log. **Copy** puts it on the clipboard, **Previous** opens the last session's log, which holds crash details. |
| **Run control test** | Records 46 seconds and changes focus and exposure on a schedule. Each change is logged with frame and failure counts. |
| **Run probe** | Logs every camera, format and RAW type, checks RAW availability for each session setup, tries Bayer formats on the video output, and scans AVCapture for RAW-related selectors. Saves `probes/probe_*.txt`. Takes up to a few minutes. |
| **Start stream** / **Stop stream** | Starts or stops the selected method without saving. |
| **Encode video** | Off records a RAW dump to `clips/clip_*/`. Turn off **Write frames to disk** to measure capture speed alone. |

Methods:

- **Photo RAW: readiness/ZSL** is the default and the fastest so far.
- **Photo RAW: sequential**: fires the next Bayer photo when the last one finishes.
- **Readiness/ZSL detail**: fires when `AVCapturePhotoOutputReadinessCoordinator` reports ready, with zero shutter lag, responsive capture and fast prioritization on where supported.
- **Photo RAW: bracket burst**: repeated bracket captures with equal exposures.
- **Use Photo preset**: on by default for photo methods, and required for RAW: with it off, iOS lists no RAW formats at all.
- **Video data output**: the pixel format picker shows only what iOS lists. If it lists no Bayer format this is a non-RAW control run.

## Processing

Photo methods feed a GPU pipeline: black level, white balance, debayer, camera RAW to linear Rec.2020 using the DNG's color matrices, exposure, then a log curve. **Pipeline** is **Maximum quality** by default; **Efficient** does the same math with less GPU work, as described in the roadmap. **Monitor** shows the result through a Rec.709 LUT, as plain log, or switches back to the ISP preview. **Save still** saves the next processed frame to `stills/`. The overlay's `gpu` line shows the time per frame and any frames the pipeline dropped.

The log image is Rec.2020 with the chosen curve for all three curves, so S-Log3 and LogC3 here use their transfer functions but not S-Gamut3 or ARRI Wide Gamut. Curve constants match colour-science's implementations of the vendor formulas.

## Encoding

With **Encode video** on, recording writes the log image to `videos/video_*.mov` with microphone audio, plus a `.json` sidecar naming the curve and gamut. **Run encoder test** benchmarks every codec and size on synthetic frames, without the camera, and saves `probes/encoders_*.txt`. Support differs by phone, so check that before trusting a preset.

The default is ProRes 422 HQ at 4032x3024. On an iPhone 14 Pro it recorded 60 seconds at about 30 fps, using about 160 MB/s or 9.5 GB per minute. HEVC only just reaches 30 fps at this size even with nothing else running.

The file is tagged Rec.2020, but its transfer tag is nominal. Apply the log curve named in the sidecar when grading.

## Long recordings and monitoring

**Stop after** defaults to **Never** and goes up to 30 minutes. Recording stops safely if the thermal state turns critical or less than 10 GB is free, because writes slow down on a nearly full phone. Files are written in 10-second fragments, so a killed app should lose only the last few seconds. **Freeze viewfinder during a take** freezes the preview to save power and heat. **Save gyro data** writes a `.gcsv` beside each take, which Gyroflow finds by itself when you open the video. **Keep recording when hot** switches to the bilinear debayer and a slower monitor once the thermal state is serious.

On an iPhone 14 Pro, ProRes 422 HQ at full size with reduced load held 30 fps for over 8 minutes at serious thermal state. Without it, heat cut GPU speed and frames began to drop at 5 minutes. Recording near an empty battery can stall the encoder, so start with a good charge.

**Aspect** records open gate, the sensor's full 4:3 frame, or a 16:9 center crop, and the monitor dims the area outside it. **Exposure tool** adds zebras where the sensor clips, or false color: blue is four stops under middle gray, green is middle gray, pink is about one stop over, yellow is well above that, and red is clipped. These show exposure of the signal, not of the graded image.

**Import .cube LUT** replaces the Rec.709 monitor LUT, for monitoring only: it isn't baked into recordings. Set **LUT made for** to Log for conversion LUTs, which take log Rec.2020 in the chosen curve, or to Rec.709 for look LUTs, which are applied after the built-in Rec.709 conversion. 3D LUTs up to size 129 work; 1D LUTs do not.

## Files (Files app > On My iPhone > VibeLog)

```
benchmarks.csv              one row per recording
logs/session_*.log
probes/probe_*.txt
videos/video_*.mov          encoded log video with audio, plus .json and .gcsv
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
| `Modules/VLProcessing` | Log curves, color math, monitor LUT, Metal pipeline, still export |
| `Modules/VLRecording` | RAW dump writer, video encoder, encoder benchmark |
| `Modules/ObjCGuard` | Catches AVFoundation's Objective-C exceptions, runtime scan |
| `App` | SwiftUI UI, overlay and wiring |

`project.yml` is the XcodeGen spec. CI generates the Xcode project, runs the unit tests on a simulator, builds the unsigned app, and packages the `.ipa`.

## Limits

CI proves the code compiles and the file, stats and DNG parsing logic works. Nothing touching the camera has run until it runs on a phone.

## License

Copyright (C) 2026 JoonaKumpulainen

VibeLog is free software under the [GNU General Public License v3.0](LICENSE). You can use, change and share it, and anyone who distributes a modified version must share its source under the same license.

Apple Log, ProRes, S-Log3 and LogC3 are trademarks of their owners. VibeLog is an independent project and is not affiliated with or endorsed by them.
