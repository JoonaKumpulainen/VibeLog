"""Checks VibeLog's camera inputs against OpenColorIO's for the six pairs OCIO has.

    python3 -m venv ocio && ocio/bin/pip install opencolorio numpy
    ocio/bin/python tools/check_camera_inputs.py

VibeLog's curve decoders and gamut matrices are copied here from LogCurve.swift and
ColorScience.swift. Each log code goes two ways to the ACES 2.0 SDR Rec.709 view: VibeLog's decode
and matrix to linear Rec.2020, then OCIO's view from Linear Rec.2020, which the app's port matches
within 0.002; and OCIO's own camera input. It prints the largest display difference for grays,
which tests the curve alone, and for colours inside and outside AP1, and the largest difference of
the matrices themselves against OCIO's.
"""
import itertools
import math

import numpy as np
import PyOpenColorIO as o

D65 = np.array([0.95047, 1, 1.08883])
XYZ_TO_2020 = np.array([
    [1.7166512, -0.3556708, -0.2533663],
    [-0.6666844, 1.6164812, 0.0157685],
    [0.0176399, -0.0427706, 0.9421031],
])
PRIMARIES = {
    "rec2020": None,
    "sGamut3": ((0.730, 0.280), (0.140, 0.855), (0.100, -0.050)),
    "sGamut3Cine": ((0.766, 0.275), (0.225, 0.800), (0.089, -0.087)),
    "awg3": ((0.6840, 0.3130), (0.2210, 0.8480), (0.0861, -0.1020)),
    "awg4": ((0.7347, 0.2653), (0.1424, 0.8576), (0.0991, -0.0308)),
    "cinema": ((0.74, 0.27), (0.17, 1.14), (0.08, -0.10)),
}


def to_rec2020(gamut):
    """The inverse of Gamut.fromRec2020: a gamut's linear RGB to linear Rec.2020, both D65."""
    primaries = PRIMARIES[gamut]
    if primaries is None:
        return np.eye(3)
    xyz = lambda p: np.array([p[0] / p[1], 1, (1 - p[0] - p[1]) / p[1]])
    unscaled = np.column_stack([xyz(p) for p in primaries])
    return XYZ_TO_2020 @ unscaled @ np.diag(np.linalg.solve(unscaled, D65))


def apple_log(y):
    r0, rt, sigma, beta, gamma, delta = -0.05641088, 0.01, 47.28711236, 0.00964052, 0.08550479, 0.69336945
    if y >= sigma * (rt - r0) ** 2:
        return 2 ** ((y - delta) / gamma) - beta
    return math.sqrt(y / sigma) + r0 if y >= 0 else r0


def s_log3(y):
    cut, knee = 0.01125, 171.2102946929
    if y >= knee / 1023:
        return 10 ** ((y * 1023 - 420) / 261.5) * 0.19 - 0.01
    return (y * 1023 - 95) * cut / (knee - 95)


def log_c3(y):
    cut, a, b, c, d, e, f = 0.010591, 5.555556, 0.052272, 0.247190, 0.385537, 5.367655, 0.092809
    return (10 ** ((y - d) / c) - b) / a if y > e * cut + f else (y - f) / e


A4, B4, C4 = (2 ** 18 - 16) / 117.45, (1023 - 95) / 1023, 95 / 1023
S4 = 7 * math.log(2) * 2 ** (7 - 14 * C4 / B4) / (A4 * B4)
T4 = (2 ** (14 * -C4 / B4 + 6) - 64) / A4


def log_c4(y):
    return (2 ** (14 * (y - C4) / B4 + 6) - 64) / A4 if y >= 0 else y * S4 + T4


def canon_log3_encode(x):
    x, cut, slope, scale = x / 0.9, 0.014, 0.36726845, 14.98325
    if x < -cut:
        return -slope * math.log10(-x * scale + 1) + 0.12783901
    if x <= cut:
        return 1.9754798 * x + 0.12512219
    return slope * math.log10(x * scale + 1) + 0.12240537


def canon_log3(y):
    cut, slope, scale = 0.014, 0.36726845, 14.98325
    if y < canon_log3_encode(-cut * 0.9):
        x = -(10 ** ((0.12783901 - y) / slope) - 1) / scale
    elif y <= canon_log3_encode(cut * 0.9):
        x = (y - 0.12512219) / 1.9754798
    else:
        x = (10 ** ((y - 0.12240537) / slope) - 1) / scale
    return x * 0.9


PAIRS = [
    ("Apple Log", apple_log, "rec2020", "Apple Log", None),
    ("S-Log3 S-Gamut3", s_log3, "sGamut3", "S-Log3 S-Gamut3", "Linear S-Gamut3"),
    ("S-Log3 S-Gamut3.Cine", s_log3, "sGamut3Cine", "S-Log3 S-Gamut3.Cine", "Linear S-Gamut3.Cine"),
    ("LogC3 AWG3", log_c3, "awg3", "ARRI LogC3 (EI800)", "Linear ARRI Wide Gamut 3"),
    ("LogC4 AWG4", log_c4, "awg4", "ARRI LogC4", "Linear ARRI Wide Gamut 4"),
    ("Canon Log 3 Cinema Gamut", canon_log3, "cinema", "CanonLog3 CinemaGamut D55", "Linear CinemaGamut D55"),
]

config = o.Config.CreateFromBuiltinConfig("studio-config-v4.0.0_aces-v2.0_ocio-v2.5")


def view(source):
    transform = o.DisplayViewTransform(
        src=source, display="Rec.1886 Rec.709 - Display", view="ACES 2.0 - SDR 100 nits (Rec.709)")
    return config.getProcessor(transform).getDefaultCPUProcessor()


def main():
    from_rec2020 = view("Linear Rec.2020")
    to_ap1 = config.getProcessor("ACES2065-1", "ACEScg").getDefaultCPUProcessor()
    grays = [[v, v, v] for v in np.linspace(0.05, 0.95, 19)]
    codes = [list(map(float, c)) for c in itertools.product(np.linspace(0.1, 0.9, 9), repeat=3)]
    for name, decode, gamut, camera, linear in PAIRS:
        ocio_view = view(camera)
        to_ap0 = config.getProcessor(camera, "ACES2065-1").getDefaultCPUProcessor()
        matrix = to_rec2020(gamut)

        def difference(code):
            ours = from_rec2020.applyRGB(list(map(float, matrix @ np.array([decode(v) for v in code]))))
            return np.abs(np.array(ours) - np.array(ocio_view.applyRGB(code))).max()

        gray = max(difference(c) for c in grays)
        inside, outside = [], []
        for code in codes:
            in_ap1 = min(to_ap1.applyRGB(to_ap0.applyRGB(code))) >= 0
            (inside if in_ap1 else outside).append(difference(code))
        if linear:
            to_linear = config.getProcessor(linear, "Linear Rec.2020").getDefaultCPUProcessor()
            theirs = np.column_stack([to_linear.applyRGB(list(e)) for e in np.eye(3)])
            matrix_text = f"matrix max {np.abs(matrix - theirs).max():.4f}"
        else:
            matrix_text = "matrix identity"
        print(
            f"{name:26s} gray {gray:.4f} | inside AP1 max {max(inside):.4f} p95 {np.percentile(inside, 95):.4f}"
            f" | outside max {max(outside, default=0):.4f} | {matrix_text}")


if __name__ == "__main__":
    main()
