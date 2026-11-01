# VibeLog roadmap

**Goal:** record the full quality of the iPhone sensor, using the best codecs, color spaces and log curves the phone can sustain. When quality and convenience conflict, quality wins.

| Phase | Scope | Status |
|---|---|---|
| 1 | Prove a continuous RAW stream | Done: 12 MP Bayer at 30 fps |
| 2 | GPU debayer, color and log curves | Done |
| 3 | ProRes and HEVC encoding with audio | Done: ProRes 422 HQ at 4032x3024 |
| 4 | Heat, crop, exposure tools, LUT import | In progress |
| 5 | Camera experience redesign | Planned |

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

## Later ideas

- Measure color against a chart, and confirm the exposure default.
- Add S-Gamut3 and ARRI Wide Gamut for S-Log3 and LogC3.
- Test recording on the ultra wide and tele lenses.
- Add a labeled 10-bit HLG mode at 1080p 60 fps, which would not be RAW.
