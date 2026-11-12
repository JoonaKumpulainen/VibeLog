# The benchmark: every iPhone from the 12 on fits itself

Agreed on 2026-11-12. VibeLog should work on every iPhone from the 12 on without anyone testing
each model and fitting it by hand. Each phone measures itself, real takes correct the
measurements, and log sharing tells the owner where a phone disagrees. The detailed plan it
grew from is under **Still to build** in [status.md](../status.md); the rules are in
[per-phone-fitting.md](per-phone-fitting.md).

## What "works" means on an older phone

Less, and said plainly. A 12 or 13 likely records HEVC, possibly at 2880x2160 or 24 fps, on the
Efficient path. Full-sensor RAW at 30 fps in ProRes stays a Pro-phone feature. The benchmark's
job is to find the most each phone holds and to say what it can't do.

## What scales, and what doesn't

- **Measured, so it scales:** capture rate per lens, encoders, the GPU per setup, memory, and the
  trial takes that check them together. Real takes outrank every trial, for encoders and GPU.
- **Not measurable, so it needs a real device:** bugs, such as a shader or camera call that
  crashes on an older GPU, or an iOS quirk like the base 16's capture stalls. Phones sharing a
  chip behave alike, so one tester per chip family is enough: A14 (12), A15 (13, 14), A16 (14 Pro,
  15), A17 Pro (15 Pro), A18 (16), A19 (17). Covered today: A16 (owner) and A18 (base 16).

## One batch, fixed from the logs

Built as one batch, then fixed in batches from what log sharing brings in, not one build per
fix. A build cycle takes about 3 minutes to the IPA since the tests and the IPA run as two jobs.

1. **Capture rate per lens:** about 10 s of RAW on each lens, counting fps, missed frames and
   stalls, trying the capture setups in order and then 24 fps, so the setup per lens is known
   before first use. The base 16's 12 s of first-launch stalls go.
2. **Memory:** the headroom with the camera and pipeline running; a phone with less gets fewer
   buffers and lighter internal settings.
3. **The first-launch offer:** capture, lens profiles, encoders, GPU, trial takes and the probe
   in one guided run of about 5 minutes, the phone lying still. Offered at first launch and
   after an iOS update, never started unasked, resumable, cancellable; an unfinished run leaves
   the defaults alone. **Run benchmark** runs it all later.
4. **Defaults fitted from the careful figures:** codec, size, frame rate, pipeline and the hot
   paths, moving only settings nobody has touched, and saying what moved.
5. **Showing it:** the format panel marks codecs and sizes at or over the limit, and a one-time
   notice says what this phone records best and what it can't.
6. **Internal limits:** the baked-FX path, how often the monitor image and glow are made, the
   viewfinder's LUT size, the scope's rate and the export preview's size follow the figures.

## Built so the logs can diagnose it

- Each benchmark step logs what it tried, the result, the heat and any error, in lines
  `tools/read_log.py` parses. A step that fails is skipped and logged and never blocks
  recording; recording keeps the safe defaults until the benchmark finishes.
- The benchmark keeps its progress on disk, so a crash shows in the next upload and the next
  launch skips the step that crashed.
- A benchmark result file per phone goes with the logs; `tools/check_benchmark.py` and
  `phones/report.md` show each phone's figures against its takes.
- At the end, one question asks the tester to turn on log sharing, which still needs the invite
  code. Without it there are no logs to fix from.

## Progress

- **Built on 2026-11-12, untested on a phone:** the benchmark runner (`App/Benchmark.swift`,
  `BenchmarkProgress` in VLCore) with capture on each lens, memory sampled, 24 fps tried where 30
  won't hold, trial takes, lens profiles, encoders and GPU, and the probe; the offer at first
  launch and after an iOS update; **Run benchmark** running all of it; defaults
  fitted for untouched settings (codec, size, frame rate, the Efficient path for little memory
  or a Maximum path that fell behind); the one-time summary; "!" on format choices past the
  limit; `Benchmark:` log lines that `read_log.py` reads; `benchmark.json` with shared logs.
- **Left until a phone's logs call for it:** internal limits (the glow's and monitor image's
  rate, the scope's rate, the export preview's size), and fewer buffers for little memory. They
  change the real-time path, which the design rules only allow on a measured need.

## Still to decide

- **Which iOS versions to support.** Check that the 12 still gets the iOS version VibeLog
  requires; Apple drops its oldest phones first.
- **Testers for A14 and A15:** one session each would show whether anything crashes.
