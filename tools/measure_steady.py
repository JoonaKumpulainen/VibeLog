#!/usr/bin/env python3
"""Measures how a take moves against its gyro log, and how much shake a stabilized copy leaves.
ffmpeg, and numpy when it's installed; without numpy the same fit runs in pure Python, slower.

    python3 tools/measure_steady.py video_20261112_140255.mov
    python3 tools/measure_steady.py video_20261112_140255.mov --copy video_20261112_140255_look.mov
    python3 tools/measure_steady.py take.mov --focal 1585.7 --json result.json

The take's `.gcsv` and `.mov.json` are read from beside it. The focal length comes from
`--focal`, in pixels at the take's full width, or else from a lens profile found beside the take
or in `--lenses`, such as `back-ultrawide-4032x3024.json`.

How it measures, the method of 2026-11-12:

1. Each frame is decoded to quarter-size grey in the sensor's own orientation (no autorotate).
2. Between each pair of frames, the shift of the middle half's column sums gives the sideways
   move, of its row sums the up-and-down move, and the left and right thirds' row sums give roll.
   The content's own move is minus that shift.
3. Each move is fitted to the angle the gyro turned between the two frame times, times the
   focal length: x to gyro x, y to gyro y, roll to gyro z, trying lags of a few ms each way.
4. Motion is split at about 2 Hz into slow and fast: the fast band is what the optical
   stabilizer takes a share of, the slow band reaches the picture whole.

Figures are in pixels of the full-size frame, and roll in milliradians, all per frame.
"""
import argparse
import json
import math
import os
import re
import subprocess
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

try:
    import numpy as np
except ImportError:   # the pure-Python path gives the same figures, about ten times slower
    np = None

SCALE = 4                 # analysis frames are a quarter of the full width
SLOW_FRAMES = 15          # a moving average this long at 30 fps first cancels 2 Hz
LAGS_MS = [x * 2.5 for x in range(-16, 17)]
MAX_SHIFT = 48            # per frame, in analysis pixels


# ---------------------------------------------------------------- frames


def frame_size(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
         "-of", "csv=p=0", str(path)], capture_output=True, text=True, check=True).stdout
    width, height = (int(v) for v in out.strip().split(",")[:2])
    return width, height


def frame_times(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time",
         "-of", "csv=p=0", str(path)], capture_output=True, text=True, check=True).stdout
    times = sorted(float(line.split(",")[0]) for line in out.split() if line.strip() and line != "N/A")
    return [t - times[0] for t in times]


def profiles(path, width, height):
    """Yields, for each frame, the column sums of the middle half and the row sums of the
    middle half and the left and right thirds, each with its mean removed."""
    w, h = width // SCALE, height // SCALE
    command = ["ffmpeg", "-v", "error", "-noautorotate", "-i", str(path), "-fps_mode", "passthrough",
               "-vf", f"scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"]
    x0, x1, y0, y1 = w // 4, 3 * w // 4, h // 4, 3 * h // 4
    third = w // 3
    size = w * h
    with subprocess.Popen(command, stdout=subprocess.PIPE) as decoder:
        while True:
            frame = decoder.stdout.read(size)
            if len(frame) < size:
                break
            columns = [sum(frame[y0 * w + x:y1 * w:w]) for x in range(x0, x1)]
            rows = [sum(frame[y * w + x0:y * w + x1]) for y in range(h)]
            left = [sum(frame[y * w:y * w + third]) for y in range(h)]
            right = [sum(frame[y * w + w - third:y * w + w]) for y in range(h)]
            yield tuple(prepared(p) for p in (columns, rows, left, right))
    return


def prepared(profile):
    """The profile's slope, lightly smoothed, which ignores changes in overall brightness."""
    slope = [b - a for a, b in zip(profile, profile[1:])]
    smooth = [(slope[max(i - 1, 0)] + 2 * slope[i] + slope[min(i + 1, len(slope) - 1)]) / 4 for i in range(len(slope))]
    mean = sum(smooth) / len(smooth)
    return [v - mean for v in smooth]


def cost(a, b, shift, step=1):
    """Mean squared difference of a against b moved by shift, over their overlap."""
    n = len(a)
    lo, hi = max(0, shift), min(n, n + shift)
    if hi - lo < n // 2:
        return float("inf")
    total = 0.0
    count = 0
    for i in range(lo, hi, step):
        d = a[i] - b[i - shift]
        total += d * d
        count += 1
    return total / count


def shift_between(a, b):
    """How far b's content moved to make a, in analysis pixels, to a tenth or so."""
    coarse = min(range(-MAX_SHIFT, MAX_SHIFT + 1, 2), key=lambda s: cost(a, b, s, 2))
    near = {s: cost(a, b, s) for s in range(coarse - 3, coarse + 4)}
    best = min(near, key=near.get)
    left, mid, right = near.get(best - 1), near[best], near.get(best + 1)
    if left is None or right is None or not all(map(math.isfinite, (left, right))):
        return float(best)
    bend = left - 2 * mid + right
    return best + (0.5 * (left - right) / bend if bend > 0 else 0.0)


def pair_moves(pair):
    before, after = pair
    columns, rows, left, right = (shift_between(a, b) for a, b in zip(after, before))
    return columns, rows, left, right


def np_prepared(profile):
    slope = np.diff(profile)
    padded = np.concatenate(([slope[0]], slope, [slope[-1]]))
    smooth = (padded[:-2] + 2 * padded[1:-1] + padded[2:]) / 4
    return smooth - smooth.mean()


def np_profiles(path, width, height):
    """As profiles(), with numpy."""
    w, h = width // SCALE, height // SCALE
    command = ["ffmpeg", "-v", "error", "-noautorotate", "-i", str(path), "-fps_mode", "passthrough",
               "-vf", f"scale={w}:{h}:flags=area,format=gray", "-f", "rawvideo", "-"]
    x0, x1, y0, y1 = w // 4, 3 * w // 4, h // 4, 3 * h // 4
    third = w // 3
    with subprocess.Popen(command, stdout=subprocess.PIPE) as decoder:
        while True:
            frame = decoder.stdout.read(w * h)
            if len(frame) < w * h:
                break
            image = np.frombuffer(frame, np.uint8).reshape(h, w).astype(np.float64)
            yield tuple(np_prepared(p) for p in (
                image[y0:y1, x0:x1].sum(axis=0), image[:, x0:x1].sum(axis=1),
                image[:, :third].sum(axis=1), image[:, w - third:].sum(axis=1)))


def np_costs(a, b, shifts):
    n = len(a)
    out = np.full(len(shifts), np.inf)
    for k, shift in enumerate(shifts):
        lo, hi = max(0, shift), min(n, n + shift)
        if hi - lo >= n // 2:
            d = a[lo:hi] - b[lo - shift:hi - shift]
            out[k] = np.dot(d, d) / (hi - lo)
    return out


def np_shift_between(a, b):
    shifts = list(range(-MAX_SHIFT, MAX_SHIFT + 1))
    costs = np_costs(a, b, shifts)
    k = int(np.argmin(costs))
    if 0 < k < len(shifts) - 1 and np.isfinite(costs[k - 1]) and np.isfinite(costs[k + 1]):
        left, mid, right = costs[k - 1], costs[k], costs[k + 1]
        bend = left - 2 * mid + right
        return shifts[k] + (0.5 * (left - right) / bend if bend > 0 else 0.0)
    return float(shifts[k])


def measure_frames(path):
    if np is not None:
        return np_measure_frames(path)
    width, height = frame_size(path)
    frames = list(profiles(path, width, height))
    with ProcessPoolExecutor() as pool:
        moves = list(pool.map(pair_moves, zip(frames, frames[1:]), chunksize=16))
    w = width // SCALE
    # The thirds' centres are two thirds of the width apart.
    span = w - w // 3
    result = {"x": [], "y": [], "roll": []}
    for columns, rows, left, right in moves:
        result["x"].append(columns * SCALE)
        result["y"].append(rows * SCALE)
        result["roll"].append((right - left) / span * 1000)
    return result, width, height


def np_measure_frames(path):
    width, height = frame_size(path)
    frames = list(np_profiles(path, width, height))
    w = width // SCALE
    span = w - w // 3
    result = {"x": [], "y": [], "roll": []}
    for before, after in zip(frames, frames[1:]):
        columns, rows, left, right = (np_shift_between(a, b) for a, b in zip(after, before))
        result["x"].append(columns * SCALE)
        result["y"].append(rows * SCALE)
        result["roll"].append((right - left) / span * 1000)
    return result, width, height


# ---------------------------------------------------------------- gyro


def read_gcsv(path):
    tscale = gscale = 1.0
    samples = []
    with open(path, encoding="utf-8") as log:
        header = True
        for line in log:
            line = line.strip()
            if header:
                if line.startswith("tscale,"):
                    tscale = float(line.split(",")[1])
                elif line.startswith("gscale,"):
                    gscale = float(line.split(",")[1])
                elif line.startswith("t,"):
                    header = False
                continue
            parts = line.split(",")
            if len(parts) >= 4:
                samples.append((float(parts[0]) * tscale, *(float(v) * gscale for v in parts[1:4])))
    return samples


def turned(samples, start, end):
    """The angle turned about each axis between two times, in radians, by the trapezoid rule."""
    if start < samples[0][0] or end > samples[-1][0]:
        return None
    total = [0.0, 0.0, 0.0]

    def at(t):
        lo, hi = 0, len(samples) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if samples[mid][0] <= t:
                lo = mid
            else:
                hi = mid
        a, b = samples[lo], samples[hi]
        f = 0.0 if b[0] == a[0] else (t - a[0]) / (b[0] - a[0])
        return [a[k] + f * (b[k] - a[k]) for k in (1, 2, 3)]

    points = [(start, at(start))]
    points += [(s[0], list(s[1:])) for s in samples if start < s[0] < end]
    points.append((end, at(end)))
    for (t0, r0), (t1, r1) in zip(points, points[1:]):
        for k in range(3):
            total[k] += (r0[k] + r1[k]) / 2 * (t1 - t0)
    return total


# ---------------------------------------------------------------- statistics


def slow_part(series):
    half = SLOW_FRAMES // 2
    out = []
    for i in range(len(series)):
        window = series[max(0, i - half):i + half + 1]
        out.append(sum(window) / len(window))
    return out


def split(series):
    slow = slow_part(series)
    return slow, [v - s for v, s in zip(series, slow)]


def rms(series):
    return math.sqrt(sum(v * v for v in series) / len(series)) if series else 0.0


def fit(measured, predicted):
    """Gain through the origin and correlation of measured against predicted."""
    pairs = [(m, p) for m, p in zip(measured, predicted) if p is not None and m is not None]
    if len(pairs) < 10:
        return None, None
    mm = [m for m, _ in pairs]
    pp = [p for _, p in pairs]
    spp = sum(p * p for p in pp)
    gain = sum(m * p for m, p in pairs) / spp if spp else None
    mmean, pmean = sum(mm) / len(mm), sum(pp) / len(pp)
    cov = sum((m - mmean) * (p - pmean) for m, p in pairs)
    var = math.sqrt(sum((m - mmean) ** 2 for m in mm) * sum((p - pmean) ** 2 for p in pp))
    return gain, (cov / var if var else None)


# ---------------------------------------------------------------- the take


def sidecar(path):
    side = Path(str(path) + ".json")
    return json.loads(side.read_text()) if side.exists() else {}


def enlargement(meta):
    match = re.search(r"enlarged (\d+(?:\.\d+)?)%", meta.get("metadata", {}).get("steadied", ""))
    return float(match.group(1)) / 100 if match else 1.0


LENS_NAMES = {"0.5x": "back-ultrawide", "1x": "back-wide", "2x": "back-wide", "3x": "back-tele"}


def find_focal(take, meta, width, height, lens_folders):
    lens = LENS_NAMES.get(meta.get("metadata", {}).get("lens", ""))
    if not lens:
        return None, None
    for folder in [take.parent, *lens_folders]:
        for name in (f"{lens}-{width}x{height}.json", f"{lens}-4032x3024.json"):
            profile = Path(folder) / name
            if profile.exists():
                data = json.loads(profile.read_text())
                return data["fx"] * width / data["width"], str(profile)
    return None, None


def gyro_predictions(samples, times, focal, lag):
    """For each frame pair, the move the gyro predicts: x and y in pixels, roll in mrad."""
    out = {"x": [], "y": [], "roll": []}
    for t0, t1 in zip(times, times[1:]):
        angle = turned(samples, t0 + lag, t1 + lag)
        if angle is None:
            for key in out:
                out[key].append(None)
            continue
        out["x"].append(angle[0] * focal)
        out["y"].append(angle[1] * focal)
        out["roll"].append(angle[2] * 1000)
    return out


def against_gyro(moves, samples, times, focal):
    """Best lag and gain per axis, overall and in the slow and fast bands."""
    best = None
    for lag_ms in LAGS_MS:
        predicted = gyro_predictions(samples, times, focal, lag_ms / 1000)
        score = 0.0
        axes = {}
        for axis in ("x", "y", "roll"):
            gain, r = fit(moves[axis], predicted[axis])
            axes[axis] = {"gain": gain, "r": r}
            score += abs(r or 0)
        if best is None or score > best[0]:
            best = (score, lag_ms, axes, predicted)
    _, lag_ms, axes, predicted = best
    for axis in ("x", "y", "roll"):
        usable = [i for i, p in enumerate(predicted[axis]) if p is not None]
        m = [moves[axis][i] for i in usable]
        p = [predicted[axis][i] for i in usable]
        m_slow, m_fast = split(m)
        p_slow, p_fast = split(p)
        axes[axis]["slowGain"], axes[axis]["slowR"] = fit(m_slow, p_slow)
        axes[axis]["fastGain"], axes[axis]["fastR"] = fit(m_fast, p_fast)
        axes[axis]["predictedFastRms"] = rms(p_fast)
    return lag_ms, axes


def shake(moves, scale=1.0):
    out = {}
    for axis in ("x", "y", "roll"):
        slow, fast = split([v / (1 if axis == "roll" else scale) for v in moves[axis]])
        out[axis] = {"slowRms": rms(slow), "fastRms": rms(fast)}
    return out


def window(moves, times, start, end):
    keep = [i for i in range(len(times) - 1) if (start is None or times[i] >= start) and (end is None or times[i + 1] <= end)]
    return {k: [v[i] for i in keep] for k, v in moves.items()}, [times[i] for i in keep] + ([times[keep[-1] + 1]] if keep else [])


# ---------------------------------------------------------------- report


def number(value, digits=2):
    return "-" if value is None else f"{value:+.{digits}f}" if digits == 2 else f"{value:.{digits}f}"


def report(result):
    lines = [f"Take: {result['take']}, {result['frames']} frames"]
    if result.get("gyro"):
        g = result["gyro"]
        lines.append(f"Against the gyro, focal {g['focal']:.1f} px ({g['focalFrom']}), best lag {g['lagMs']:+.1f} ms:")
        names = {"x": "sideways (gyro x)", "y": "up and down (gyro y)", "roll": "roll (gyro z)"}
        for axis in ("x", "y", "roll"):
            a = g["axes"][axis]
            lines.append(
                f"  {names[axis]:22} gain {number(a['gain'])} r {number(a['r'])}   "
                f"slow {number(a['slowGain'])} (r {number(a['slowR'])})   "
                f"fast {number(a['fastGain'])} (r {number(a['fastR'])})")
        lines.append("  Slow gain near 1 and fast gain under it means the optics take part of the fast shake.")
    units = {"x": "px", "y": "px", "roll": "mrad"}
    lines.append("Shake per frame, rms, slow and fast (above about 2 Hz):")
    lines.append(f"  take     " + "   ".join(
        f"{axis} {result['shake'][axis]['slowRms']:.2f} / {result['shake'][axis]['fastRms']:.2f} {units[axis]}" for axis in ("x", "y", "roll")))
    if result.get("copy"):
        c = result["copy"]
        lines.append(f"  copy     " + "   ".join(
            f"{axis} {c['shake'][axis]['slowRms']:.2f} / {c['shake'][axis]['fastRms']:.2f} {units[axis]}" for axis in ("x", "y", "roll"))
            + f"   (enlarged {c['enlargement'] * 100:.0f}%, divided out)")
        lines.append("  copy keeps, of the take's fast shake: " + "   ".join(
            f"{axis} {c['keeps'][axis] * 100:.0f}%" for axis in ("x", "y", "roll")))
        if c.get("gyro"):
            g = c["gyro"]
            lines.append(f"  copy's fast shake still following the gyro, lag {g['lagMs']:+.1f} ms: " + "   ".join(
                f"{axis} {number(g['axes'][axis]['fastGain'])} (r {number(g['axes'][axis]['fastR'])})" for axis in ("x", "y", "roll")))
            lines.append("  Near 0 means the correction is in step. A large share at a lag means a timing error.")
    return "\n".join(lines)


def measure(options):
    take = Path(options.take)
    meta = sidecar(take)
    times = frame_times(take)
    print(f"Reading {take.name} ...", file=sys.stderr, flush=True)
    moves, width, height = measure_frames(take)
    moves, times = window(moves, times[:len(moves["x"]) + 1], options.start, options.end)
    result = {"take": take.name, "frames": len(times), "shake": shake(moves)}

    gcsv = Path(options.gcsv) if options.gcsv else take.with_suffix(".gcsv")
    samples, focal = None, None
    if gcsv.exists():
        if options.focal:
            focal, source = options.focal * width / 4032, "given"
        else:
            focal, source = find_focal(take, meta, width, height, options.lenses)
        if focal:
            samples = read_gcsv(gcsv)
            lag_ms, axes = against_gyro(moves, samples, times, focal)
            result["gyro"] = {"focal": focal, "focalFrom": source, "lagMs": lag_ms, "axes": axes}
        else:
            print("No focal length: give --focal or --lenses to fit against the gyro.", file=sys.stderr)

    if options.copy:
        copy = Path(options.copy)
        scale = options.enlargement or enlargement(sidecar(copy))
        print(f"Reading {copy.name} ...", file=sys.stderr, flush=True)
        copy_moves, _, _ = measure_frames(copy)
        copy_times = frame_times(copy)
        copy_moves, copy_window = window(copy_moves, copy_times[:len(copy_moves["x"]) + 1], options.start, options.end)
        copy_shake = shake(copy_moves, scale)
        keeps = {axis: (copy_shake[axis]["fastRms"] / result["shake"][axis]["fastRms"]
                        if result["shake"][axis]["fastRms"] else None) for axis in ("x", "y", "roll")}
        result["copy"] = {"file": copy.name, "enlargement": scale, "shake": copy_shake, "keeps": keeps}
        if samples and focal:
            # What's left in the copy that still follows the gyro: near 0 when the correction is
            # in step, and a lag here is a timing error in the correction.
            usable = copy_window
            lag_ms, axes = against_gyro(copy_moves, samples, usable, focal * scale)
            result["copy"]["gyro"] = {"lagMs": lag_ms, "axes": axes}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("take")
    parser.add_argument("--copy", help="a stabilized copy of the take to compare")
    parser.add_argument("--gcsv", help="the gyro log, if not beside the take")
    parser.add_argument("--focal", type=float, help="focal length in pixels at 4032 wide")
    parser.add_argument("--lenses", action="append", default=[], help="a folder of lens profiles")
    parser.add_argument("--enlargement", type=float, help="the copy's enlargement, if not in its sidecar")
    parser.add_argument("--start", type=float, help="seconds into the take to start")
    parser.add_argument("--end", type=float, help="seconds into the take to end")
    parser.add_argument("--json", help="also write the figures to this file")
    options = parser.parse_args()
    result = measure(options)
    print(report(result))
    if options.json:
        Path(options.json).write_text(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
