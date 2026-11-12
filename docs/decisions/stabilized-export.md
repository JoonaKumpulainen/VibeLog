# Stabilized export, working with the optical stabilizer

Agreed on 2026-11-11, after take `220644` showed the optical stabilizer running during RAW
capture. The owner chose to work with it rather than wait for a way to switch it off.

## What the phone showed

On the 14 Pro's 1x, against the gyro's prediction: pans reach the picture whole, a hand's shake
above about 2 Hz at 0.13 to 0.35, small slow drift at 0.56 to 0.97, and roll at 0.89. The
optics steady two axes and leave roll alone. The figures are in [findings.md](../findings.md).

## The design

- **Two axes share the work.** For turns that move the picture sideways or up and down, the
  export corrects what lies between the wanted smoothness and about 2 Hz, and leaves faster
  motion to the optics. A plain gyro correction would add that shake back in reverse.
- **Roll is all the gyro's.** It's corrected at every speed.
- **One enlargement for the take,** the least that hides every frame's edges, up to 130%. Moves
  too big to hide at that are turned back less, eased in and out over about a third of a
  second, since cutting them off frame by frame showed as a shake of its own.
- **Smoothness is a length of time,** the stretch of the camera's movement averaged into the
  steady path, 0.2 to 2 seconds. Short follows a pan closely and crops little; long holds the
  frame nearly still, lags behind a pan and crops more. The screen names it Light to Strongest.
- **A full perspective warp per frame,** from the lens profile's focal length, before the FX and
  the look. The picture's middle is taken as the optical centre.
- **The preview shows it.** Export's preview plays the take stabilized, through the same step
  the export uses, and says how far it's enlarged. Switching **Stabilize** off and on compares.
  Live stabilization while recording stays ruled out.
- **Baked takes too.** A take with its look baked in has no log to export, so its screen is
  **Stabilize**, with only smoothness to set, and offers only this: the same picture, steadied
  and encoded again in the take's own tag and codec, with no look applied. Encoding again can't
  win anything back, so it only loses as little as it can: ProRes stays in its profile, and HEVC
  keeps its chroma at no less than the take's own rate. It costs one more encode.
- **It says what it did:** the export's sidecar has `steadied`, and it gets no copy of the gyro
  log, which no longer describes it.

`SteadyPath` in VLCore holds the path and its tests, `steadyWarp` in `Shaders.metal` the warp,
and `LookExporter.Look.steadying` carries them into an export. In the export screen it's
**Stabilize** with **Smoothness**, and over the link `stabilize=on` and `smooth=<seconds>`.

## Known limits of the first version

- **Large fast shake is under-corrected.** The optics can't absorb it, and the 2 Hz limit doesn't
  know how large a shake is. A limit that follows the motion's size is the next step.
- **No rolling-shutter correction,** so fast pans keep their lean.
- **No lens distortion in the warp,** which matters most on the ultra wide.
- **No horizon lock,** and no view of the whole frame with the kept part outlined, as Gyroflow
  has. The preview shows the result, not what was cut away.
- **A baked HDR take previews with its codes shown as SDR,** so it looks flat there. The copy
  keeps its PQ or HLG tag.
- **The 2 Hz comes from one take** on the 1x. The tele, the ultra wide,
  which has no optical stabilizer, and other phones are unmeasured. The ultra wide corrects
  every speed on all three axes.
- **It guesses what the optics did.** The share they take is a figure from one take, not each
  frame's own lens shift. An exact correction needs that shift, which the system tracks but
  doesn't hand over through any public route found so far, or a measurement per lens: a take
  compared with its gyro log, as `220644` was, giving the share at each speed.
- **It needs the lens measured,** under Advanced, Lenses, for its focal length.
