# VibeLog roadmap

**Goal:** record the full quality of the iPhone sensor, using the best codecs, color spaces and log
curves the phone can sustain. When quality and convenience conflict, quality wins.

| Phase | Scope | Status |
|---|---|---|
| 1 | Prove a continuous RAW stream | Done: 12 MP Bayer at 30 fps |
| 2 | GPU debayer, color and log curves | Done |
| 3 | ProRes and HEVC encoding with audio | Done: ProRes 422 HQ at 4032x3024 |
| 4 | Heat, crop, exposure tools, LUT import | Done: 10 minutes at 30 fps |
| 5 | Camera experience redesign | Done, apart from the long heat tests |
| 6 | Image quality and capture | In progress |
| 7 | Shooting tools | In progress: grading with wheels, styles, scopes, FX, HDR and an HDR viewfinder built |
| 8 | On-phone finishing | Started: export with look, grade, FX, HDR10 light levels and log conversion |

## Design rules for new additions

Everything added from here on follows these rules, so the app stays one instrument instead of a pile
of features. If an addition can't fit, change the rules here first, on purpose.

### Rules that never bend

- **Nothing covers the picture.** Controls and messages stay in the space around it. Monitoring
  marks that help judge the image, such as zebras or peaking, are the only things drawn on it, and
  they never reach the file.
- **Controls don't move.** Every control keeps its portrait position in every hold, and only its
  contents turn in place. Record never moves.
- **A take comes first.** A new control must say whether it's allowed during a take, and it stays
  off until a control test shows it costs no frames. See "Adjusting the camera while recording" in
  [docs/how-it-works.md](docs/how-it-works.md).
- **Keep the main thread quiet.** Interface values update about once a second during a take, and
  nothing animates continuously. Short animations only follow a tap. A reading that must move faster
  draws on its own layers from its own queue, as the audio bar does.

### Where a new thing goes

| It is | It goes |
|---|---|
| A setting changed between shots | The format panel, as a list entry or a new column |
| A setting changed rarely | Settings, in the section it belongs to, with search terms |
| A setting only needed for fine tuning | **Advanced** in Settings, with what replaces it when hot beside it |
| A value changed while shooting | The control bar. It holds four values, so a fifth needs one to leave |
| A way to adjust a control bar value | That value's dial, as a tray button |
| A monitoring aid | `Tool`, which adds it to the MON tray and the tool row. Add a dial button if it serves one control |
| A live reading | The tray during a take, or a status line if it's worth a permanent line |
| Something that could spoil a take | A warning chip while it's a risk, and a notice card when it happens |
| A test or measurement | Diagnostics, under **Advanced**, never the camera screen |

Only one thing occupies the tray at a time. Status keeps three lines on each side of the Dynamic
Island, so a new line has to replace one.

Each setting has one home. Settings can link to the format panel, but never repeats it.

### How it should look

- **Color has fixed meanings.** Amber is set by the user. Orange fill is a warning. Red is recording
  only. Cyan is peaking. The exceptions are the audio bar, which uses the standard green, yellow
  and red scale, and an action that discards work and asks first, such as the look panel's reset
  all, which is red as the system's own are. A new meaning needs a new shape, because color can't be the only signal.
- **Use `Tokens` and `CameraGeometry`,** never new sizes or colors in a view. Text sizes follow the
  hold, not a per-view shrink.
- **Labels are plain.** Use a whole word where it fits, and an industry term where one exists. Icons
  need a text label beside them or an accessibility label.
- **No boxes.** Group with alignment and spacing. A flat `Tokens.surface` fill marks what's
  selected, and `Tokens.opaquePanel` is for a panel that sits above the controls.
- **Touch targets are at least 44 points,** in both axes where a control turns.

### Before it's done

- Check it in all four holds, in 4:3, 16:9 and Full view, and during a take.
- Give it an accessibility label and value.
- Respect Reduce Motion for any animation.
- Say what it costs. Anything adding real-time GPU work follows the Phase 6 rule below and gets a
  test on the phone.
- Decide if a new setting belongs in presets, and add it to "What presets keep" in
  [docs/how-it-works.md](docs/how-it-works.md). It's in if it describes how you work, and out if it
  belongs to the shot in front of the camera.
- Update this file, the docs and the README in the same change.

## Pipelines

Both pipelines use the same debayer, color and log math at every pixel.

- **Maximum quality** is the default. It builds a full RGB image, then converts it for the encoder.
  It is the reference that the other pipeline is tested against, and the only one that can resize.
- **Efficient** writes the encoder's planes directly, and gives the monitor its own half-size image.
  It records the same picture to within rounding in tests, and one person could not see a difference
  on real footage. Other sizes fall back to Maximum quality. In one 10-minute run its GPU time was
  about the same as Maximum quality, and it had more failed photos, so it is not yet proven better.

Half-resolution color is left out because it could soften fine red and blue detail.

## Phase 5: camera experience redesign

Rebuild the interface to the standard of a first-party Apple camera app, with the same care for
detail. The camera path stays as it is, and full quality stays the default.

- **Camera-first screen:** a full-screen viewfinder with minimal, purposeful controls and no debug
  text by default.
- **Direct control:** tap to focus, drag for exposure, pinch or tap to change lens, and clear locks
  for focus, exposure and white balance.
- **Pro controls:** ISO, shutter, white balance and focus on compact dials, plus a focus punch-in.
- **Shooting information:** timecode, recording state, storage time left, battery, heat and audio
  meters, shown only when useful.
- **Motion and feel:** SF Symbols, native materials, smooth transitions and haptics, with interface
  elements that rotate with the phone.
- **Library:** browse, play, share and delete clips, with their settings.
- **Settings:** codec, size, log curve, color space and pipeline in a clean native sheet, with
  presets.
- **Reliability:** warnings before heat, storage or battery can ruin a take.
- **Accessibility:** VoiceOver labels, Dynamic Type and high-contrast support.
- **Developer tools:** the debug overlay, logs and benchmarks stay available in a hidden diagnostics
  screen, because phone testing depends on them.

The screen design should leave room for the tools in Phases 6 and 7.

## Phase 6: image quality and capture

The rule for this phase: anything that adds to real-time GPU load must prove it doesn't cost frames
or shorten recording.

- **Frame rates:** 24, 25 and 30 fps record with no dropped frames. 23.98 and 29.97 were removed:
  set to them, the camera still delivered 24 and 30. RAW Cam also offers 18 fps.
- **Highlight reconstruction:** rebuild clipped green from red and blue, which still hold data above
  the point where green saturates. This could recover some highlight range that is currently
  clipped.
- **Vignette correction:** built. Apple's own `FixVignetteRadial` from each RAW photo's metadata,
  about two stops at the 1x's corners, applied in the debayer, with a switch under Advanced.
  Untested on the phone.
- **Gyro logging:** done. CoreMotion data at 100 Hz in a Gyroflow `.gcsv` next to each clip, with
  the axes right in Gyroflow and no frame cost seen.
- **Stabilization check:** find out whether optical stabilization is active during RAW capture, and
  how it affects gyro stabilization.
- **Exposure modes:** a 180-degree button, lock at start and auto during a take are in. Shutter
  priority and an EV dial are added, and their frame cost is unmeasured.
- **Bit depth:** 10-bit everywhere, with 12-bit ProRes 4444 as an **Advanced** switch, proven on the
  phone. Whether HEVC can keep 12 bits is being tested.
- **Focus while recording:** tested. Even a slow focus move lost 30 of 240 frames, so focus stays
  held during takes.
- **Audio:** PCM recording and level meters are in, and PCM sounded clean over a 10-minute take.
  External microphones are left.
- **Log curves and gamuts:** Apple Log, Apple Log 2, S-Log3, S-Log2, LogC3, LogC4 and Canon Log 3,
  with S-Gamut3.Cine, S-Gamut3, S-Gamut, ARRI Wide Gamut 3 and 4, Cinema Gamut, Apple Wide Gamut and
  Rec.2020. Each curve pairs with a color space, and the pairs and a viewfinder LUT for each curve
  can be set under **Advanced** and kept in presets. Apple Log 2 grades well. The others haven't
  been graded, and file tag options are untested.
- **Color accuracy:** measure against a chart, and confirm the exposure default.
- **Lenses:** the ultra wide and tele record at 30 fps with lens correction off. Each still needs
  its own color calibration. Lens profiles from Apple's calibration, averaged over five captures
  with focus held, are saved per phone under Advanced, Lenses; the ultra wide's comes from its field
  of view.
- **Zoom RAW:** not available. Bayer RAW refuses any zoom and the 48 MP size, so 2x can only be a
  crop of the 12 MP frame.

## Phase 7: shooting tools

- Focus peaking and a focus punch-in: done.
- Focus peaking sensitivity: a low and high switch in Settings, so it's there but out of the way.
  Added, untested.
- Scopes: a luma waveform, RGB and YRGB parades, overlaid by default, a Rec.709 vectorscope with the
  skin tone line, and an RGB histogram, measuring the viewfinder's look. Built, untested in long
  takes. A RAW histogram is left.
- Horizon indicator: the Level tool does this.
- Frame guides, a 3x3 grid and anamorphic desqueeze: added, with frame guides and desqueeze
  untested.
- Look adjustments: ADJUST and COLOR grade any look but LOG live in the viewfinder, in scene-linear
  before the look, and bake in with it. Built, with styles, built-in and saved, under each look.
- Baked HDR: ACES 2.0 at 1000 nits recorded as PQ with HDR10 metadata or as HLG, as Bake does for
  SDR. Built and working on the phone, both PQ and HLG. The HDR viewfinder shows it through the
  screen's extended range, at no measurable draw cost.
- Shadow, midtone and highlight wheels: built, in WHEELS and in export's grade editor.
- Halation, bloom, diffusion, vignette and grain: built for the viewfinder, export and baked takes.
  Baked into takes, they fell behind at about 2 minutes in both early long takes. The viewfinder
  then shared the take's glow, which slowed the Maximum path from the start of a third take; the
  glow now comes from a pool and is handed over with the finished frame, proven on the phone. The
  Maximum path still fell behind from about 2 minutes, so baked-FX takes run on the Efficient
  path throughout, with the glow made every other frame, which held a 10-minute take from
  nominal heat with no cooling wait. A phone that starts hot is untested.
- Looks baked into recordings: built and proven, at no measurable GPU cost in a 60-second take, to
  HEVC or ProRes.
- Timecode and Apple Watch control, if they prove useful.

## Phase 8: on-phone finishing

Keep recording clean, and do the heavy work after the shot, when real-time limits and most heat
limits no longer apply. Each step writes a new file and leaves the original untouched.

- **One-tap stabilization:** use the saved gyro data and the spare sensor area from open gate, with
  an optional horizon lock.
- **One-tap denoise:** use the noise profile from the metadata, with temporal denoise where quality
  justifies the time.
- **Export with look:** a copy with any look, its grade, FX and SDR or HDR, played through first, is
  built, with HEVC's rate, a smaller resolution, a centred 16:9 or 9:16 crop and ProRes 422 LT. A
  movable crop, a crop outline on the preview and a new name for each export are left.
- **Roll-off and gamut conversions:** export's **Write as** writes a take as another log curve and
  gamut, such as Apple Log 2 as S-Log3 in S-Gamut3.Cine, in ProRes. Built, untested on the phone.

## Later ideas

- Short RAW bursts in CinemaDNG, within the 8 GB the phone can write at full speed.
- A native Apple Log mode for Pro phones from the 15 Pro on, labelled as not RAW, for 60 fps and
  cooler long takes. See [docs/decisions/native-log-mode.md](docs/decisions/native-log-mode.md).
- Live gyro stabilization while recording, only if GPU headroom allows it.
- Cloud sync, streaming and multi-camera control, which matter less for this app's goal.
- External storage on phones with fast USB-C. The iPhone 14 Pro's Lightning port is likely too slow
  for this.
