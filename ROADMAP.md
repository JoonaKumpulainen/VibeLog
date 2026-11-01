# VibeLog roadmap

**Goal:** record the full quality of the iPhone sensor, using the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

| Phase | Scope | Status |
|---|---|---|
| 1 | Prove a continuous RAW stream | Done: 12 MP Bayer at 30 fps |
| 2 | GPU debayer, color and log curves | Done |
| 3 | ProRes and HEVC encoding with audio | Done: ProRes 422 HQ at 4032x3024 |
| 4 | Heat, crop, exposure tools, LUT import | In progress |
| 5 | Camera experience redesign | Planned |
| 6 | Image quality and capture | Planned |
| 7 | Shooting tools | Planned |
| 8 | On-phone finishing | Planned |

## Phase 4: what's left

- Find the cause of the encoder stall seen at 1% battery.
- Measure how long recording lasts before heat costs frames, in both pipelines.
- Check that **Reduce load when hot** helps.
- Check **LUT input** with a look LUT.

## Pipelines

Both pipelines use the same debayer, color and log math at every pixel.

- **Maximum quality** is the default. It builds a full RGB image, then converts it for the encoder. It is the reference that the other pipeline is tested against, and the only one that can resize.
- **Efficient** writes the encoder's planes directly, and gives the monitor its own half-size image. It should use less GPU time and memory while recording the same picture, to within rounding. Other sizes fall back to Maximum quality.

Half-resolution color is left out because it could soften fine red and blue detail.

## Phase 5: camera experience redesign

Rebuild the interface to the standard of a first-party Apple camera app, with the same care for detail. The camera path stays as it is, and full quality stays the default.

- **Camera-first screen:** a full-screen viewfinder with minimal, purposeful controls and no debug text by default.
- **Direct control:** tap to focus, drag for exposure, pinch or tap to change lens, and clear locks for focus, exposure and white balance.
- **Pro controls:** ISO, shutter, white balance and focus on compact dials, plus a focus punch-in.
- **Shooting information:** timecode, recording state, storage time left, battery, heat and audio meters, shown only when useful.
- **Motion and feel:** SF Symbols, native materials, smooth transitions and haptics, with interface elements that rotate with the phone.
- **Library:** browse, play, share and delete clips, with their settings.
- **Settings:** codec, size, log curve, color space and pipeline in a clean native sheet, with presets.
- **Reliability:** warnings before heat, storage or battery can ruin a take.
- **Accessibility:** VoiceOver labels, Dynamic Type and high-contrast support.
- **Developer tools:** the debug overlay, logs and benchmarks stay available in a hidden diagnostics screen, because phone testing depends on them.

The screen design should leave room for the tools in Phases 6 and 7.

## Phase 6: image quality and capture

The rule for this phase: anything that adds to real-time GPU load must prove it doesn't cost frames or shorten recording.

- **24 and 25 fps:** test whether the sensor mode runs at these rates under the Photo preset. RAW Cam offers 18, 24, 25 and 30 fps.
- **Highlight reconstruction:** rebuild clipped green from red and blue, which still hold data above the point where green saturates. This could recover some highlight range that is currently clipped.
- **Vignette correction:** apply the `FixVignetteRadial` values already found in the photo metadata.
- **Gyro logging:** record CoreMotion data at high rate and save a Gyroflow `.gcsv` next to each clip. This costs little and can land early.
- **Stabilization check:** find out whether optical stabilization is active during RAW capture, and how it affects gyro stabilization.
- **Exposure modes:** 180-degree shutter, shutter priority, auto exposure with an EV slider, and lock at start.
- **Focus while recording:** test whether focus can change during capture.
- **Audio:** PCM recording, level meters and external microphones.
- **Native gamuts:** S-Gamut3 and ARRI Wide Gamut for S-Log3 and LogC3, plus options for how the file is tagged.
- **Color accuracy:** measure against a chart, and confirm the exposure default.
- **Lenses:** test recording on the ultra wide and tele, each with its own calibration.

## Phase 7: shooting tools

- Focus peaking and a focus punch-in.
- RAW histogram, waveform and vectorscope.
- Horizon indicator, using the Phase 6 motion data.
- Frame guides, a 3x3 grid and anamorphic desqueeze.
- LUTs baked into recordings, as an option.
- Timecode and Apple Watch control, if they prove useful.

## Phase 8: on-phone finishing

Keep recording clean, and do the heavy work after the shot, when real-time limits and most heat limits no longer apply. Each step writes a new file and leaves the original untouched.

- **One-tap stabilization:** use the saved gyro data and the spare sensor area from open gate, with an optional horizon lock.
- **One-tap denoise:** use the noise profile from the metadata, with temporal denoise where quality justifies the time.
- **Export presets:** bake a LUT, render Rec.709 or HDR, and make small proxies for sharing.
- **Roll-off and gamut conversions:** convert between log curves and gamuts for different grading workflows.

## Later ideas

- Short RAW bursts in CinemaDNG, within the 8 GB the phone can write at full speed.
- A labeled 10-bit HLG mode at 1080p 60 fps, which would not be RAW.
- Live gyro stabilization while recording, only if GPU headroom allows it.
- Cloud sync, streaming and multi-camera control, which matter less for this app's goal.
- External storage on phones with fast USB-C. The iPhone 14 Pro's Lightning port is likely too slow for this.
