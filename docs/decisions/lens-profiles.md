# Per-phone lens profiles: Apple's calibration and Gyroflow export built, colour not started

The app is for every iPhone, so lens data is per device, in layers from free to manual. Apple's
per-frame metadata already gives the color matrices, `FixVignetteRadial` and the 35 mm focal length
on any phone, with nothing stored. Apple's factory calibration, if the probe shows it comes with
RAW, gives intrinsics and a distortion table, read once per lens and saved. What Apple doesn't give
comes from the owner: color from a ColorChecker photo with a patch grid overlay, fitting a 3x3
matrix per lens, and distortion from a lens profile imported from Gyroflow's calibrator rather than
checkerboard detection in the app. Each profile is a JSON file per model, lens and format, such as
`lenses/iPhone15,2/back-wide-4032x3024.json`, noting each value's source and date, on a **Lenses**
page under Advanced with export, import and reset, kept out of presets. A phone without one falls
back to Apple's metadata.
