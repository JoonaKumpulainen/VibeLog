# VibeLog

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

| Button | What it does |
|---|---|
| **Probe** | Logs every camera, format and RAW type, checks RAW availability for each session setup, tries Bayer formats on the video output, and scans AVCapture for RAW-related selectors. Saves `probes/probe_*.txt`. Takes up to a few minutes. |
| **Stream** | Runs the selected method without saving, for the overlay and the small RAW monitor. |
| **Record** | Records for the chosen duration to `clips/clip_*/`. Turn off **Write frames to disk** to measure capture speed alone. |
| **Log** | Shows the log. **Copy** puts it on the clipboard, **Previous** opens the last session's log, which holds crash details. |

Methods:

- **Photo RAW: readiness/ZSL** is the default and the fastest so far.
- **Photo RAW: sequential**: fires the next Bayer photo when the last one finishes.
- **Readiness/ZSL detail**: fires when `AVCapturePhotoOutputReadinessCoordinator` reports ready, with zero shutter lag, responsive capture and fast prioritization on where supported.
- **Photo RAW: bracket burst**: repeated bracket captures with equal exposures.
- **Use Photo preset**: on by default for photo methods, and required for RAW: with it off, iOS lists no RAW formats at all.
- **Video data output**: the pixel format picker shows only what iOS lists. If it lists no Bayer format this is a non-RAW control run.

## Processing

Photo methods feed a GPU pipeline: black level, white balance, debayer, camera RAW to linear Rec.2020 using the DNG's color matrices, exposure, then a log curve. **Monitor** shows the result through a Rec.709 LUT, as plain log, or switches back to the ISP preview. **Still** saves the next processed frame to `stills/`. The overlay's `gpu` line shows the time per frame and any frames the pipeline dropped.

The log image is Rec.2020 with the chosen curve for all three curves, so S-Log3 and LogC3 here use their transfer functions but not S-Gamut3 or ARRI Wide Gamut. Curve constants match colour-science's implementations of the vendor formulas.

## Files (Files app > On My iPhone > VibeLog)

```
benchmarks.csv              one row per recording
logs/session_*.log
probes/probe_*.txt
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
| `Modules/VLCapture` | Session, capture methods, manual controls, probe |
| `Modules/VLProcessing` | Log curves, color math, monitor LUT, Metal pipeline, still export |
| `Modules/VLRecording` | RAW dump writer; the Phase 3 encoder goes here |
| `Modules/ObjCGuard` | Catches AVFoundation's Objective-C exceptions, runtime scan |
| `App` | SwiftUI UI, overlay and wiring |

`project.yml` is the XcodeGen spec. CI generates the Xcode project, runs the unit tests on a simulator, builds the unsigned app, and packages the `.ipa`.

## Limits

CI proves the code compiles and the file, stats and DNG parsing logic works. Nothing touching the camera has run until it runs on a phone.
