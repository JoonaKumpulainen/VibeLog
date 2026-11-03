"""Writes the OpenColorIO reference values behind Tests/VLTests/ACESReference.swift to a JSON file: python3 tools/make_aces_reference.py out.json"""
import PyOpenColorIO as o, json, itertools
samples = []
for s in range(-12, 9):
    v = 0.18 * 2 ** s
    samples.append([v, v, v])
samples.append([0.0, 0.0, 0.0])
levels = [0.0, 0.02, 0.18, 0.9, 4.0]
for r, g, b in itertools.product(levels, repeat=3):
    if not (r == g == b):
        samples.append([r, g, b])
samples += [[-0.01, 0.1, 0.3], [0.5, -0.02, 0.05], [0.05, 0.6, -0.03], [12.0, 3.0, 0.5], [0.3, 0.25, 0.2], [60.0, 60.0, 60.0]]
out = {"samples": samples}
for key, cfgname, view in [("aces20", "studio-config-v4.0.0_aces-v2.0_ocio-v2.5", "ACES 2.0 - SDR 100 nits (Rec.709)"),
                           ("aces13", "studio-config-v2.2.0_aces-v1.3_ocio-v2.4", "ACES 1.0 - SDR Video")]:
    c = o.Config.CreateFromBuiltinConfig(cfgname)
    t = o.DisplayViewTransform(src="Linear Rec.2020", display="Rec.1886 Rec.709 - Display", view=view)
    p = c.getProcessor(t).getDefaultCPUProcessor()
    out[key] = [list(p.applyRGB(list(map(float, s)))) for s in samples]
    m = c.getProcessor("Linear Rec.2020", "ACES2065-1").getDefaultCPUProcessor()
    out[key + "_rec2020_to_ap0"] = [list(m.applyRGB(e)) for e in ([1.0,0,0],[0,1.0,0],[0,0,1.0])]
print(json.dumps({k: (v if not isinstance(v, list) or len(v) < 10 else len(v)) for k, v in out.items()}, indent=0)[:600])
json.dump(out, open(__import__("sys").argv[1], "w"))
