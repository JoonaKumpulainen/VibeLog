# Plan for the rest of Phase 7, agreed

Timecode and Apple Watch control are left out. Each step gets its own build and phone test, apart
from 2 and 3, which can share one, since both change how the ACES LUT is built.

1. **Build what's waiting:** the export player, **Bake to ProRes**, the look panel header and the
   calibration probe, under **After `4241f0d`**.
2. **Look adjustments, global sliders:** under **Planned: look adjustments** below. No GPU cost
   during takes, since the grade sits inside the look's LUT.
3. **Baked HDR:** under **Planned: baked HDR** below.
4. **Scopes:** histogram, waveform and vectorscope. They cost GPU time on every viewfinder frame, so
   each needs a frame-cost test on the phone, as peaking had.
5. **Per-colour adjustments**, then shadow, midtone and highlight wheels.
6. **Spatial effects:** under **Planned: spatial effects**, export and viewfinder first, baked takes
   only if a long take shows headroom.

Phase 8 also gets **log conversion** in export: a take turned from one curve and gamut into another,
such as Apple Log 2 into S-Log3 in S-Gamut3.Cine, written as ProRes. The pipeline already has the
math, so it's a small export option.
