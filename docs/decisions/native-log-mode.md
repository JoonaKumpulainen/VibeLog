# A native log mode for Pro phones

Discussed on 2026-11-11. Not built, and nothing here is proven on a phone. The owner has friends
with 15 Pro, 16 Pro and 17 Pro phones, so it can be tested.

## What it is

On Pro phones from the 15 Pro on, the camera's video path can deliver Apple Log itself, with
hardware ProRes. That would be a second capture path beside the RAW photo stream, chosen by the
owner and labelled as not RAW. The RAW path stays the default and the reference.

| Phone | Native video path, from memory, to be confirmed by a probe |
|---|---|
| 14 Pro, iPhone 16 | HLG or SDR only, so no native log mode |
| 15 Pro, 16 Pro | Apple Log, hardware ProRes |
| 17 Pro | Apple Log and Apple Log 2. ProRes RAW too, perhaps to external storage only: unchecked |

## Why

- **Frame rate:** 60 fps and higher. The RAW path is capped at 30.
- **Heat:** Apple's processing replaces the GPU debayer, so long takes should run far cooler.
- **Stabilization:** Apple's own.

## What it gives up

- It isn't RAW. Apple's noise reduction and sharpening are in the picture, against the app's goal
  of the sensor's full quality. So it's a labelled mode, never a default, and the sidecar says
  which path made the take.
- The debayer choice, vignette correction, RAW levels and the exposure handling don't apply.
- A second path to keep working: session setup, format choice, and what presets keep.

## What carries over

The app's pipeline turns RAW into a log image first, and the grade, look, FX and scopes all read
that log image. Apple Log and Apple Log 2 are already among its curves, with their gamuts. A
native frame would enter at that point, skipping only the debayer.

| Feature | With native log | Notes |
|---|---|---|
| Viewfinder looks, ADJUST, COLOR, WHEELS | Yes | Needs a step turning Apple's YCbCr frames into the RGB image the viewfinder reads |
| FX on the viewfinder | Yes | The same shader |
| Scopes, zebras, false colour, peaking | Yes | They measure the viewfinder's image |
| Export with look, grade, FX, HDR, **Write as** | Yes | After the shot, with no real-time limit |
| Looks and FX baked into the take | Uncertain | See below |
| Debayer, vignette correction, RAW levels | No | Apple's processing replaces them |

**Baking is the uncertain part.** A clean log take can go from the camera straight to Apple's
hardware encoder, which is what makes 60 fps and long takes cheap. A baked take must pass every
frame through the GPU and the app's own encoder. At 4K60 that's more pixels a second than the 12
MP path at 30 fps, which already struggles when hot. It should work at 30 fps and needs measuring
above that.

**The split to start from:** record clean Apple Log natively, show the look live in the
viewfinder, and apply it at export.

## HLG was dropped

A 10-bit HLG mode at 1080p 60 fps was in the roadmap's later ideas, for phones without native
log. HLG is a finished HDR picture from Apple's processing, the same the stock Camera app records
as Dolby Vision, so the mode would add only VibeLog's controls around a picture the phone already
makes. Converting it to a log curve would give a log wrapper that holds nothing more. Removed on
2026-11-11.

## Order of work

1. **Probe first:** **Run probe** lists every video format's colour spaces, frame rates and sizes,
   and each friend's phone sends one probe file. That confirms the table above before any capture
   code, and follows [per-phone-fitting.md](per-phone-fitting.md): a phone gets the mode because
   its own formats offer Apple Log, never by model name.
2. **Capture:** a clean Apple Log take through Apple's encoder, with the sidecar, gyro log and
   audio the RAW path writes.
3. **Viewfinder:** the YCbCr step, then the existing look, grade, FX and tools.
4. **Export:** confirm the existing export reads a native take.
5. **Baking:** measure at 30 fps, then higher, before offering it.

Each step needs a tester's phone to prove it. Per the roadmap's rules, the mode also needs its
home in the format panel and a decision in "What presets keep".
