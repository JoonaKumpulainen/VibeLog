# Automated testing, guided movement and the calibration it shares

Agreed on 2026-11-12. The test link already drives most of the app, so the time left in a round
goes to judging results by eye and coordinating the tester. Everything that can be measured is
measured by a script, and a person is only asked for movement, a scene or an opinion.

## What a round looks like today

| Test | Manual now | Becomes |
|---|---|---|
| FX keep the shadows | Taps in Export, a screen recording, judged by eye | Automatic: record and `export effects=` over the link, compare the dark end of each frame |
| Stabilize keeps the codec | Taps, reading each `.mov.json` | Automatic over the link, only the walk needs a person |
| Stabilize and the ultra wide's edges | A movement script followed from text, an analysis script not in the repo | Guided by cues on the phone, analyzed by a script |
| Returning to the app | Leaving it for 3 minutes, then reporting | The person leaves the app, the log decides |
| Laggy sliders | Dragging and judging by feel | The person drags, the log decides |

## 1. Results decided by scripts

- **`tools/measure_steady.py`:** the take-against-gyro fit done by hand on `000714`, `220644` and
  `140255`, kept in the repo. ffmpeg and pure Python, since this machine has no numpy. It reports
  shake left per band, timing lag and roll for a take against its copy and `.gcsv`.
- **`tools/read_log.py`:** a session log summed up: stalls, encoder errors, main-thread stalls,
  foreground and idle-pause events, each take's result and heat.
- **Expectations in suites:** a step can say what it expects, such as
  `"expect": {"lost": "<=2", "codec": "same as take"}`, and prints PASS or FAIL with the figure.
- **One report per round,** in Markdown, laid out like [findings.md](../findings.md), so closing
  a session means pasting verdicts rather than working them out again.

## 2. A step runner on the server

`python3 tools/test_server.py round tools/rounds/<date>.json` runs a whole round:

1. **Checks the build.** The status reply gains the app's version, and the runner refuses an
   older build than the round needs.
2. **Saves the tester's settings** and puts them back at the end, as was done by hand on
   2026-11-12.
3. **Runs the automatic steps,** fetches their files and analyzes them.
4. **Hands movement steps to the phone** as guided takes, then fetches and analyzes them.
5. **Writes the report,** naming what still needs a person's opinion.

[next-tests.md](../next-tests.md) then keeps only what needs a person's eyes or hands.

## 3. Guided takes: cues for movement

A guided take is a script of timed parts, started from the server or from Diagnostics.

- **What the tester sees:** a cue in the tray and control bar area, never over the picture. A
  3-2-1 countdown, then parts such as "Hold still", "Pan left and right", "Small quick shakes" and
  "Walk forward", each with a progress bar.
- **Live feedback from the gyro:** a speed meter with a target band reading "faster" or "good",
  such as about half a turn a second for the readout pan, and a level for roll. A part done
  outside its range is marked for redoing on the spot, not found at analysis.
- **The cues go into the files.** Each part's start and end are written to the sidecar and the
  `.gcsv`, so the analysis knows which seconds are still and which are a pan, instead of guessing.
- **No vibration during a take,** since the gyro and the optical stabilizer would both see it.
  Cues are visual. One beep before the start is allowed and doubles as a sync mark in the sound.
- **Scene cues:** such as "Point at straight vertical lines near the edges", with shutter and lens
  set by the script.
- **Where it lives:** Diagnostics, by the design rules, and over the link. It follows the cost
  rules: cue updates draw on their own layers, not through SwiftUI each frame.

## 4. Calibrate stabilizer, in the first-launch benchmark

The benchmark in [status.md](../status.md) leaves out what needs movement: stabilizer timing and
direction, the optical stabilizer's share, and readout time. With guided takes these become an
optional **Calibrate stabilizer** step after the still benchmark, about 60 s of hold, pan and
shake per lens, fitted on the phone and saved to the lens profile. It is the same fit as
`measure_steady.py`, so the tests prove the calibration and every phone is measured the same way,
by the rules in [per-phone-fitting.md](per-phone-fitting.md). This is **Measure stabilizer, per
lens** from Still to build. A colour chart step can join it later.

## 5. Instrument instead of asking

- **Sliders:** log when a slider's drag is cancelled because a scroll took it.
- **Returning to the app:** log the idle pause with how long the app was away.

The tester uses the app normally, and the session log answers.

## 6. A Tests page for testers without the link

Under Diagnostics: the round's tests, each with **Start**, which applies its settings and runs its
cues. **Send results** zips the take sidecars, `.gcsv` files, copies and the session log for the
share sheet, instead of picking files one by one in Files.

## Left out

**Automated UI tests and simulator screenshots.** Interface additions have been preference
changes, nearly always settled in one round on the phone, so the owner judged them not worth it.

## Progress

- **Built on 2026-11-12:** `tools/measure_steady.py`, checked against the hand fits of `140255`
  and `000714`; `tools/read_log.py`; rounds in `test_server.py`, with expectations, fetching,
  levels, the analysis tools, settings put back and `round_*.md`, checked against a fake phone;
  the first round, `tools/rounds/2026-11-13.json`. In the app, for 0.1.117: the version and the
  newest take in status, the version in the first log line, leaving and returning to the app
  logged, and each Export slider drag logged.
- **Slider drags:** a drag the form's scroll takes never starts the slider, so the log can only
  count the drags the slider did take. The tester still says how many drags they made.

## Order

1. `measure_steady.py` and `read_log.py`: Python and docs only, no build.
2. The version in status, expectations in suites, the step runner and its report.
3. Guided takes with cues and markers in the files, first used by the stabilize tests.
4. Calibrate stabilizer in the benchmark, built on step 3.
5. Slider and idle-pause logging, and the Tests page.
