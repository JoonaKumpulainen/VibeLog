#!/usr/bin/env python3
"""Summarize a VibeLog clip and export one Bayer frame as a half-resolution PNG.

Usage: inspect_clip.py CLIP_FOLDER [--frame N] [--png out.png]
"""
import argparse
import json
import statistics
import struct
import sys
import zlib
from pathlib import Path

BLOCKS = {
    "RGGB": ((0, 0), (1, 1)),
    "BGGR": ((1, 1), (0, 0)),
    "GRBG": ((1, 0), (0, 1)),
    "GBRG": ((0, 1), (1, 0)),
}


def summarize(clip):
    frames = clip["frames"]
    print(f"device {clip['device']}  method {clip['context']['method']}  frames {len(frames)}")
    layout = clip.get("layout")
    if layout:
        print(f"format {layout['pixelFormat']} {layout['width']}x{layout['height']} "
              f"{layout['bytesPerFrame']} bytes per frame")
    print(f"cfa {clip.get('cfaPattern')}  black {clip.get('blackLevel')}  white {clip.get('whiteLevel')}")
    times = [f["pts"] for f in frames]
    gaps = [(b - a) * 1000 for a, b in zip(times, times[1:])]
    if gaps:
        total = times[-1] - times[0]
        print(f"sustained {(len(times) - 1) / total:.2f} fps over {total:.2f}s")
        print(f"gaps ms: min {min(gaps):.1f} median {statistics.median(gaps):.1f} max {max(gaps):.1f}")
    for error in clip.get("errors", []):
        print(f"error: {error}")


def png_chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def write_png(path, width, height, rows):
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    payload = zlib.compress(b"".join(b"\0" + row for row in rows), 6)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", header)
                     + png_chunk(b"IDAT", payload) + png_chunk(b"IEND", b""))


def export_frame(folder, clip, index, output):
    layout = clip["layout"]
    pattern = clip.get("cfaPattern")
    if pattern not in BLOCKS:
        sys.exit(f"cannot debayer pattern {pattern}")
    record = clip["frames"][index]
    if record.get("fileOffset") is None:
        sys.exit("this clip was recorded without frames")
    width, height = layout["width"], layout["height"]
    stride = layout["planes"][0]["bytesPerRow"]
    black = (clip.get("blackLevel") or [0])[0]
    white = (clip.get("whiteLevel") or [16383])[0]
    gains = record.get("whiteBalanceGains") or [1, 1, 1]
    (rx, ry), (bx, by) = BLOCKS[pattern]

    with open(folder / "frames.raw", "rb") as handle:
        handle.seek(record["fileOffset"])
        raw = handle.read(stride * height)

    def sample(x, y):
        return struct.unpack_from("<H", raw, y * stride + x * 2)[0]

    def tone(value, gain):
        level = max(0.0, min(1.0, (value - black) / (white - black) * gain))
        return int(level ** (1 / 2.2) * 255)

    rows = []
    for y in range(0, height - 1, 2):
        row = bytearray()
        for x in range(0, width - 1, 2):
            red = sample(x + rx, y + ry)
            blue = sample(x + bx, y + by)
            green = (sample(x + rx, y + by) + sample(x + bx, y + ry)) / 2
            row += bytes((tone(red, gains[0]), tone(green, gains[1]), tone(blue, gains[2])))
        rows.append(bytes(row))
    write_png(output, width // 2, height // 2, rows)
    print(f"wrote {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("clip", type=Path)
    parser.add_argument("--frame", type=int, default=0)
    parser.add_argument("--png", type=Path)
    args = parser.parse_args()
    clip = json.loads((args.clip / "clip.json").read_text())
    summarize(clip)
    if args.png:
        export_frame(args.clip, clip, args.frame, args.png)


if __name__ == "__main__":
    main()
