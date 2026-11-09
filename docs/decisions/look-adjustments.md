# Look adjustments, the first design, built in Batches 1 to 3

The owner wants sliders that grade the built-in looks, set while watching the viewfinder before a
take and baked in with it. Agreed design:

- **Where the grade sits:** in scene-linear, before the ACES output transform, inside the LUT
  `BuiltInLook.lut(curve:gamut:size:)` already builds. Each grid point is decoded, taken to linear
  Rec.2020, graded, then sent through ACES. ACES then still rolls highlights off and compresses
  gamut, so pushes stay smooth, the way Resolve works under ACES. It adds no GPU work: the
  viewfinder, baking and export each still do one LUT lookup a pixel.
- **First build, the global sliders:** exposure, contrast around 0.18, temperature and tint, and
  saturation, in that order of use. Contrast pivots at middle gray in log2, saturation works against
  Rec.2020 luminance, and white balance is a Bradford shift of the white, as `ColorMath.bradford`
  does.
- **Second build, per colour:** hue, saturation and brightness for red, orange, yellow, green, cyan,
  blue, magenta and skin, in a perceptual space, ACES 2.0's JMh from `ACES2OutputTransform.rgbToJMh`
  or Oklab, with soft overlapping hue weights so ranges blend without edges. Then optional shadow,
  midtone and highlight wheels.
- **Live while dragging:** a 65-point LUT takes about a second, so while a slider moves, build a 17
  or 33-point LUT at utility priority, then the 65-point one on release, and don't rebuild while a
  slider holds still. The camera streams meanwhile, so it must not starve capture: check
  `Recording:` timing and photo failures while dragging, on the phone.
- **On the camera screen:** an **ADJUST** page in the LOOK panel, over the controls like the rest,
  with Cancel, BAKE and Select in the header. Select keeps the grade. It's locked during takes, like
  the curve and BAKE, and the take's LUT is frozen in `setSink` already, so a bake never changes
  mid-take.
- **Saving:** the grade is part of the look: kept in presets and linkable per curve like any LUT, in
  `AppConfig`, with an entry in **What presets keep**. A **Save as .cube** for Resolve would be
  cheap.
- **Scope:** the built-in looks and the plain Rec.709 view only. Grading under an imported `.cube`
  means grading before someone else's look, which is possible but less predictable, and left for
  later.
- **Tests:** a neutral grade must leave the look exactly as it is, exposure must move middle gray by
  the right stops through the tone curve, and saturation 0 must give neutral output. The owner
  judges how it looks, so slider ranges and hue widths start conservative and are tuned from the
  phone.
