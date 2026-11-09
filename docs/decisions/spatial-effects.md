# Spatial effects, the first design, built for the viewfinder and export in Batch 7

The owner asked about halation and other grading effects, and baking them during takes. Per-pixel
effects such as vignette, split toning or a print look can go in the look's LUT or `lookColor` at no
extra cost. Spatial ones, halation, bloom and diffusion, need neighbours: highlights above a
threshold in scene-linear, blurred wide and added back tinted, red-orange for halation. They're
low-frequency, so the blur can run at an eighth of the size and be sampled back up, which should
cost a millisecond or two, unmeasured. They sit before the look, so they need their own passes and a
texture the encode kernels and the viewfinder both read, unlike the LUT grade. Order of work: export
and viewfinder first, then a frame-cost test in long takes, then baked takes. Take 2 showed Maximum
quality has no headroom when hot, so baking them may need the Efficient path. Grain is cheap to draw
but HEVC at 25 MB/s smears it into blocks and spends bits on it, so it suits export to ProRes rather
than baked takes.
