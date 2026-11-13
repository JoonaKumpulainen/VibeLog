#!/usr/bin/env python3
"""Fits a lens's optical stabilizer from a take's own frames and its gyro log, for SteadyPath.Optics.

    python3 tools/fit_optics.py video_20261111_220644.mov --focal 2840.9

Needs numpy and ffmpeg. The take's `.gcsv` is read from beside it. Use a take on a lens with an
optical stabilizer, held by hand with a stretch of plain holding and a few slow pans, at a fast
shutter so frames stay sharp.

The model is SteadyPath's: the optics hold back `share` of each turn's part faster than
`corner` Hz, a causal first-order high-pass, up to `travel` radians, past which they give way
along a tanh. What reaches the picture is the turn less that. Each candidate is scored by what a
correction from it would leave of the picture's own shake above about 2 Hz, per frame, sideways
and up and down in the sensor's frame; the best one over the whole take wins, and each half of
the take is shown so a fit that holds only for one stretch shows up. Roll isn't modelled, since
the optics don't steady it, but its best timing is shown.

Frames are measured as `measure_steady.py` measures them, so the same take reads the same.
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import measure_steady as ms  # noqa: E402

if ms.np is None:
    sys.exit("fit_optics.py needs numpy")

SHARES = (0.6, 0.7, 0.8, 0.9, 1.0)
CORNERS = (0.3, 0.45, 0.6, 0.8, 1.0, 1.5, 2.0)
TRAVELS = (0.002, 0.003, 0.004, 0.005, 0.006, 0.008, 0.012)
LAGS_MS = (-10, -5, 0, 5, 10)


def fast(series, n=ms.SLOW_FRAMES):
    slow = np.convolve(np.pad(series, n // 2, mode="edge"), np.ones(n) / n, "valid")
    return series - slow


def held(angles, step, share, corner, travel):
    keep = 1 / (1 + 2 * math.pi * corner * step)
    out = np.zeros_like(angles)
    part = 0.0
    for i in range(1, len(angles)):
        part = keep * (part + angles[i] - angles[i - 1])
        out[i] = travel * math.tanh(share * part / travel)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("take")
    parser.add_argument("--focal", type=float, required=True, help="focal length in pixels at 4032 wide")
    options = parser.parse_args()
    take = Path(options.take)

    print(f"Reading {take.name} ...", file=sys.stderr)
    moves, width, _ = ms.measure_frames(take)
    times = np.array(ms.frame_times(take))
    focal = options.focal * width / 4032
    samples = np.array(ms.read_gcsv(str(take.with_suffix(".gcsv"))))
    seconds = samples[:, 0]
    step = (seconds[-1] - seconds[0]) / (len(seconds) - 1)
    angles = np.vstack([np.zeros(3), np.cumsum(
        (samples[1:, 1:4] + samples[:-1, 1:4]) / 2 * np.diff(seconds)[:, None], axis=0)])
    picture = {axis: np.array(moves[axis]) for axis in ("x", "y", "roll")}
    # The picture's y runs against gyro y in the sensor's frame.
    sign = {}
    for k, axis in enumerate(("x", "y")):
        predicted = np.diff(np.interp(times, seconds, angles[:, k]))
        sign[axis] = 1.0 if predicted @ picture[axis] >= 0 else -1.0
    halves = (slice(0, len(times) // 2), slice(len(times) // 2, len(times) - 1))

    def left(axis, k, model, lag):
        moved = np.diff(np.interp(times + lag, seconds, model)) * focal
        rest = fast(sign[axis] * picture[axis] - moved)
        return rest.std(), [rest[h].std() for h in halves]

    print(f"{take.name}: {len(times)} frames, focal {focal:.1f} px")
    for k, axis in enumerate(("x", "y")):
        a = angles[:, k]
        print(f"  {axis}: shake above 2 Hz {fast(picture[axis]).std():.2f} px a frame; "
              f"a plain gyro correction leaves {left(axis, k, a, 0)[0]:.2f}")
    results = []
    for share in SHARES:
        for corner in CORNERS:
            for travel in TRAVELS:
                total = 0.0
                parts = []
                for k, axis in enumerate(("x", "y")):
                    a = angles[:, k]
                    whole, by_half = left(axis, k, a - held(a, step, share, corner, travel), 0)
                    total += whole
                    parts.append((whole, by_half))
                results.append((total, share, corner, travel, parts))
    results.sort(key=lambda r: r[0])
    print("  Best fits (what each leaves, px a frame: whole take, first half / second half):")
    for total, share, corner, travel, parts in results[:5]:
        text = "  ".join(f"{axis} {w:.2f} ({h[0]:.2f} / {h[1]:.2f})" for axis, (w, h) in zip(("x", "y"), parts))
        print(f"    share {share:.1f}, corner {corner:.2f} Hz, travel {travel:.3f} rad "
              f"({travel * focal:.0f} px):  {text}")
    _, share, corner, travel, _ = results[0]
    print("  Timing, with the best fit, x + y px and roll mrad left:")
    for lag_ms in LAGS_MS:
        lag = lag_ms / 1000
        xy = sum(left(axis, k, angles[:, k] - held(angles[:, k], step, share, corner, travel), lag)[0]
                 for k, axis in enumerate(("x", "y")))
        roll = fast(picture["roll"] / 1000 - np.diff(np.interp(times + lag, seconds, angles[:, 2]))).std() * 1000
        print(f"    {lag_ms:+d} ms: {xy:.2f} px, roll {roll:.2f} mrad")


if __name__ == "__main__":
    main()
