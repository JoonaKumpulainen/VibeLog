# Baked HDR, the first design, built in Batch 8

Record an HDR look straight from the shot, as Bake does for SDR. It costs what a baked look costs
now: one LUT lookup per pixel, which the 60-second baked ACES take showed adds no GPU time.

- **Look:** ACES 2.0 at 1000 nits, from `ACES2OutputTransform(peakLuminance:limiting:)`, which the
  port already takes, with Rec.2020 or P3 limiting primaries as OpenColorIO's 1000-nit views use.
  Encoded as PQ for HDR10, or as HLG from that picture by the BT.2100 conversion. The 65-point LUT
  holds the encoded values.
- **File:** tagged Rec.2020 with PQ or HLG transfer, through `FileTag` and `VideoEncoder`'s color
  properties. PQ also gets HDR10 mastering display and content light level metadata. HEVC 10-bit, or
  ProRes 422 HQ with **Bake to ProRes**.
- **Setting:** a Bake target, SDR, HDR PQ or HDR HLG, kept in presets, with the sidecar's `look`
  naming it.
- **Limits:** ACES 2.0 only at first. ACES 1.3's HDR outputs would each need porting, and imported
  `.cube` LUTs are SDR looks, so they stay SDR.
- **Viewfinder:** first it shows the SDR look while HDR records, with a note. A true HDR viewfinder
  needs the screen's extended range, a 16-bit float drawable and its own draw path, so it's a later
  step with a `draw` time check.
- **Tests:** compare against OpenColorIO's ACES 2.0 1000-nit output for the same 148 colours, from
  `tools/make_aces_reference.py`, and check the file's tags read back.
