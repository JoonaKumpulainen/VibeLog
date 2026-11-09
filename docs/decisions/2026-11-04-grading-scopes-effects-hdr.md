# Plan agreed on 2026-11-04: grading, scopes, effects and HDR

Batches, each built and tested on the phone before the next. Each works the same live in the
viewfinder, baked into takes and in export, since all three share the look step.

1. **Built in `68811c4`:** the live grade, haptics, tab merging, the grade under imported LUTs,
   MONITOR and ACES 2.0 by default, under **After `b759417`**.
2. **COLOR tab, built in `9da3d7b`:** a third tab, LOOKS, ADJUST, COLOR, hiding with ADJUST for LOG.
   Swatches for red, orange, yellow, green, cyan, blue, magenta and skin, a HUE, SAT and LUM row,
   and one slider, tapping a chosen swatch again to reset it. Soft overlapping hue windows in Oklab,
   which is cheaper per LUT point than ACES's JMh and keeps the drag preview fast, with skin a
   narrower window that spares near-grays. Inside the same LUT, after the global grade.
3. **Styles, built in `0b56b1a`:** pre-made grades as cards in the LOOKS carousel after the ACES
   looks, such as Warm, Cool, Punchy, Faded, Mono, Teal & Orange and Bleach bypass, each a look plus
   a grade that loads into ADJUST and COLOR to adjust further, and SAVE STYLE to add the owner's
   own, kept beside the presets. Called styles, not presets, to keep them apart from settings
   presets. After COLOR, since Teal & Orange and Bleach bypass need per-colour control.
4. **Scopes, built in `f443ce8`:** waveform, RGB parade, Y RGB parade, vectorscope with Rec.709 or
   Rec.2020 targets and the skin tone line, and a luma or RGB histogram. Standard math, with no
   licence needed; Blackmagic's "DaVinci YRGB" is a brand name to avoid. GPU bins from a frame about
   256 wide with atomic adds, 10 to 15 updates a second, drawn on its own layer, measuring the
   look's output by default or log. A SCOPE tool in the MON tray, needing a frame-cost test.
5. **FX tab, viewfinder and export built in `f53121e`:** a fourth tab with HALATION, BLOOM, DIFFUSE,
   VIGNETTE and GRAIN, hiding only for LOG, for any look including imported LUTs. Applied in
   scene-linear before the look: highlights blurred at an eighth of the size, halation tinted
   red-orange, read back per pixel with a curve decode and encode before the LUT. Estimated 1 to 3
   ms a frame, unmeasured. Viewfinder and export first, then baked takes only after long takes show
   headroom, likely requiring the Efficient path when hot, and never switching off mid-take. Grain
   only for export or baked ProRes, since HEVC at 25 MB/s smears it.
6. **HDR, baked and exported, built in `f53121e`:** ACES 2.0 at 1000 nits with P3-D65 limiting in
   Rec.2020, as OpenColorIO's ACES 2.0 HDR views do. PQ for HDR10 as the master, tagged Rec.2020 PQ
   with HDR10 mastering display metadata for P3-D65 at 1000 nits; export measures MaxCLL and MaxFALL
   in a first pass, and live takes carry the mastering values only. HLG from the same picture by the
   BT.2100 conversion. HEVC Main10 by default, ProRes 422 HQ with **Bake to ProRes**, and 12-bit
   ProRes 4444 as the top master for short takes or a cool phone. An HDR viewfinder through the
   screen's extended range. Dolby Vision and HDR10+ are left out, since both need licensed metadata
   tools. Details under **Planned: baked HDR**.
