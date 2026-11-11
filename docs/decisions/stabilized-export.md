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
- **One enlargement for the take,** the least that hides every frame's edges, up to 140%. A
  frame that would still show an edge is turned back less.
- **A full perspective warp per frame,** from the lens profile's focal length, before the FX and
  the look. The picture's middle is taken as the optical centre.
- **Export only.** The preview plays the take as shot. Live stabilization stays ruled out.
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
- **No horizon lock,** and no crop set in the preview.
- **The 2 Hz and the gyro's 20 ms lead come from one take** on the 1x. The tele, the ultra wide,
  which has no optical stabilizer, and other phones are unmeasured. The ultra wide should
  correct every speed on all three axes.
- **It needs the lens measured,** under Advanced, Lenses, for its focal length.
