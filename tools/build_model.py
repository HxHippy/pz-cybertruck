#!/usr/bin/env python3
"""Builds the Cybertruck body mesh and its three textures.

The mesh is written as ASCII FBX in the same layout the vanilla vehicles use (Z-up raw
geometry, -90 X pre-rotation, two UV channels, model scale 0.008), so the game loads it the
same way it loads Vehicles_PickUpTruck. It also fits inside the vanilla pickup's bounding box,
so the pickup's wheel, area and physics numbers carry over.

Textures are painted from the same triangles that make the mesh, so skin, part mask and lights
always line up:
  shell  - what you see
  mask   - part zones from media/shaders/vehicle_common.frag.h (hides removed doors, glass...)
  lights - what glows when the head/tail/brake lights are on

Usage: python3 tools/build_model.py <vanilla Vehicles_PickUpTruck.fbx>
"""
import math
import os
import random
import re
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
MEDIA = os.path.join(HERE, "..", "Contents", "mods", "Cybertruck", "42", "media")
TEX = 1024

# ---------------------------------------------------------------- shape (model units, 1 = 0.008 world)
W = 57.0          # half width at the body sides
IN, CH = 6.0, 3.0  # shoulder chamfer: inset and rise
BELT = 8.0        # door top / window bottom

NOSE, TAIL = 141.0, -141.0
APEX_F, APEX_R = 15.0, -12.0


def z_top(y):
    """Side top edge: one straight line nose to apex, a short roof, one straight line to the tail."""
    if y >= APEX_F:
        return -8.0 + (NOSE - y) * (42.0 / (NOSE - APEX_F))
    if y >= APEX_R:
        return 34.0 - (APEX_F - y) * (3.0 / (APEX_F - APEX_R))
    return 31.0 - (APEX_R - y) * (35.0 / (APEX_R - TAIL))


# bottom edge with trapezoid wheel arches around the pickup's wheel centers (+98, -76)
BOTTOM = [(141, -26), (137, -28), (124, -34), (114, -12), (82, -12), (72, -34),
          (-50, -34), (-60, -12), (-92, -12), (-102, -34), (-137, -30), (-141, -27)]


def z_bot(y):
    for (y0, z0), (y1, z1) in zip(BOTTOM, BOTTOM[1:]):
        if y1 <= y <= y0:
            t = (y0 - y) / (y0 - y1)
            return z0 + (z1 - z0) * t
    raise ValueError(y)


# every place something changes, front to rear
def _belt_cross(lo, hi):
    for _ in range(60):
        mid = (lo + hi) / 2
        if (z_top(mid) - BELT) * (z_top(lo) - BELT) > 0:
            lo = mid
        else:
            hi = mid
    return round((lo + hi) / 2, 3)


YS = sorted({141, 137, 124, 114, 82, 72, 69, 58, 15, 10, -12, -32, -40, -50, -60, -92, -102, -137, -141,
             _belt_cross(141, 15), _belt_cross(-12, -141)}, reverse=True)

# ---------------------------------------------------------------- zones (vehicle_common.frag.h)
Z = {
    "none": (1.0, 1.0, 1.0),
    "door_fr": (0.0, 1.0, 1.0), "door_rr": (1.0, 1.0, 0.0),
    "door_fl": (1.0, 0.0, 1.0), "door_rl": (0.0, 0.0, 1.0),
    "win_fr": (0.0, 0.5, 0.5), "win_rr": (0.5, 0.5, 0.0),
    "win_fl": (0.5, 0.0, 0.5), "win_rl": (0.0, 0.0, 0.5),
    "win_rear": (0.5, 0.0, 0.0), "win_front": (0.0, 0.5, 0.0),
    "light_r_h": (0.25, 0.0, 0.0), "light_l_h": (0.75, 0.0, 0.0),
    "light_r_t": (0.0, 0.75, 0.0), "light_l_t": (0.0, 0.25, 0.0),
    "stop_r": (0.5, 0.25, 0.0), "stop_l": (0.5, 0.75, 0.0),
    "hood": (1.0, 0.0, 0.5), "boot": (0.0, 1.0, 0.5),
}

STEEL, GLASS, HEAD, TAILL, STOP, UNDER, TRIM = "steel", "glass", "head", "tail", "stop", "under", "trim"

tris = []  # (p0,p1,p2), (uv0,uv1,uv2), zone, material


def add_poly(pts, uvs, zone, mat, outward):
    """Fan-triangulate a convex polygon, winding so the normal points along `outward`."""
    n = normal(pts[0], pts[1], pts[2])
    if dot(n, outward) < 0:
        pts, uvs = pts[::-1], uvs[::-1]
    for i in range(1, len(pts) - 1):
        a, b, c = pts[0], pts[i], pts[i + 1]
        if length(cross(sub(b, a), sub(c, a))) < 1e-6:
            continue
        tris.append(((a, b, c), (uvs[0], uvs[i], uvs[i + 1]), zone, mat))


def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def length(a): return math.sqrt(dot(a, a))


def normal(a, b, c):
    n = cross(sub(b, a), sub(c, a))
    l = length(n) or 1.0
    return (n[0] / l, n[1] / l, n[2] / l)


# ---------------------------------------------------------------- UV atlas
# v is up (FBX); the painter flips it for the PNG.
def uv_side(y, z, left):
    v0 = 0.76 if left else 0.52
    u = (NOSE - y) / (NOSE - TAIL) if left else (y - TAIL) / (NOSE - TAIL)
    return (0.01 + u * 0.98, v0 + (z + 36.0) / 72.0 * 0.23)


_S = [0.0]
for a, b in zip(YS, YS[1:]):
    _S.append(_S[-1] + math.hypot(a - b, z_top(a) - z_top(b)))
S_LEN = dict(zip(YS, _S))
ACROSS = [0.0, math.hypot(IN, CH), math.hypot(IN, CH) + (W - IN)]
ACROSS += [ACROSS[2] + (W - IN), ACROSS[2] + 2 * (W - IN) + math.hypot(IN, CH)]


def uv_top(y, k):
    return (0.01 + S_LEN[y] / _S[-1] * 0.98, 0.07 + ACROSS[k] / ACROSS[-1] * 0.42)


def uv_face(x, z, u0):
    return (u0 + (x + W) / (2 * W) * 0.24, 0.005 + (z + 36.0) / 72.0 * 0.055)


def uv_bottom(y, x):
    return (0.5 + (NOSE - y) / (NOSE - TAIL) * 0.49, 0.005 + (x + W) / (2 * W) * 0.055)


def section(y):
    zs = z_top(y)
    return [(W, y, zs), (W - IN, y, zs + CH), (0.0, y, zs + CH), (-(W - IN), y, zs + CH), (-W, y, zs)]


def between(y, hi, lo): return lo <= y <= hi


# ---------------------------------------------------------------- build
def build():
    for ya, yb in zip(YS, YS[1:]):
        ym = (ya + yb) / 2
        sa, sb = section(ya), section(yb)

        # top strip, 4 quads across
        for k in range(4):
            left = k < 2
            chamfer = k in (0, 3)
            zone, mat = "none", STEEL
            if between(ym, 141, 137):
                zone, mat = ("light_l_h" if left else "light_r_h"), HEAD
            elif between(ym, 137, 69):
                zone = "hood"
            elif between(ym, 69, 15) and not chamfer:
                zone, mat = "win_front", GLASS
            elif between(ym, 15, -12) and not chamfer:
                mat = GLASS
            elif between(ym, -12, -32) and not chamfer:
                zone, mat = "win_rear", GLASS
            elif between(ym, -40, -137):
                zone = "boot"
            elif between(ym, -137, -141):
                if chamfer:
                    zone, mat = ("stop_l" if left else "stop_r"), STOP
                else:
                    zone, mat = ("light_l_t" if left else "light_r_t"), TAILL
            pts = [sa[k], sa[k + 1], sb[k + 1], sb[k]]
            uvs = [uv_top(ya, k), uv_top(ya, k + 1), uv_top(yb, k + 1), uv_top(yb, k)]
            add_poly(pts, uvs, zone, mat, (0, 0, 1))

        # sides
        for left in (True, False):
            x = W if left else -W
            za_b, zb_b = z_bot(ya), z_bot(yb)
            za_t, zb_t = z_top(ya), z_top(yb)
            above = za_t > BELT + 1e-6 and zb_t > BELT + 1e-6
            la, lb = (min(za_t, BELT) if above else za_t), (min(zb_t, BELT) if above else zb_t)
            front_door, rear_door = between(ym, 58, 10), between(ym, 10, -32)
            s = "l" if left else "r"
            lower_zone = f"door_f{s}" if front_door else f"door_r{s}" if rear_door else "none"
            pts = [(x, ya, za_b), (x, yb, zb_b), (x, yb, lb), (x, ya, la)]
            add_poly(pts, [uv_side(p[1], p[2], left) for p in pts], lower_zone, STEEL, (1 if left else -1, 0, 0))
            if above:
                upper_zone = f"win_f{s}" if front_door else f"win_r{s}" if rear_door else "none"
                pts = [(x, ya, BELT), (x, yb, BELT), (x, yb, zb_t), (x, ya, za_t)]
                add_poly(pts, [uv_side(p[1], p[2], left) for p in pts], upper_zone,
                         GLASS if upper_zone != "none" else STEEL, (1 if left else -1, 0, 0))

        # underside, arch roofs included
        pts = [(W, ya, z_bot(ya)), (-W, ya, z_bot(ya)), (-W, yb, z_bot(yb)), (W, yb, z_bot(yb))]
        add_poly(pts, [uv_bottom(p[1], p[0]) for p in pts], "none", UNDER, (0, 0, -1))

    # nose and tail faces
    for y, u0, out in ((NOSE, 0.005, 1), (TAIL, 0.255, -1)):
        s = section(y)
        zb, zs = z_bot(y), z_top(y)
        quad = [(W, y, zb), (W, y, zs), (-W, y, zs), (-W, y, zb)]
        add_poly(quad, [uv_face(p[0], p[2], u0) for p in quad], "none" if out > 0 else "boot", STEEL, (0, out, 0))
        cap = s  # the chamfered top edge, closed flat
        add_poly(cap, [uv_face(p[0], p[2], u0) for p in cap], "none", TRIM, (0, out, 0))


# ---------------------------------------------------------------- textures
def paint(path_shell, path_mask, path_lights):
    rng = random.Random(42)
    shell = Image.new("RGBA", (TEX, TEX), (60, 60, 62, 255))
    mask = Image.new("RGB", (TEX, TEX), (255, 255, 255))
    lights = Image.new("RGBA", (TEX, TEX), (0, 0, 0, 0))
    ds, dm, dl = ImageDraw.Draw(shell), ImageDraw.Draw(mask), ImageDraw.Draw(lights)

    base = {STEEL: (168, 170, 172), GLASS: (24, 28, 36), HEAD: (236, 238, 240), TAILL: (150, 18, 22),
            STOP: (190, 24, 28), UNDER: (34, 34, 36), TRIM: (70, 72, 74)}
    glow = {HEAD: (255, 250, 225, 255), TAILL: (255, 40, 30, 255), STOP: (255, 60, 40, 255)}

    def px(uv): return (uv[0] * TEX, (1.0 - uv[1]) * TEX)

    for _, uvs, zone, mat in tris:
        poly = [px(u) for u in uvs]
        c = base[mat]
        ds.polygon(poly, fill=c + (255,), outline=c + (255,))
        zc = tuple(int(round(v * 255)) for v in Z[zone])
        dm.polygon(poly, fill=zc, outline=zc)
        if mat in glow:
            dl.polygon(poly, fill=glow[mat], outline=glow[mat])

    # brushed stainless: horizontal streaks, only where the steel is
    steel = Image.new("L", (TEX, TEX), 0)
    dsm = ImageDraw.Draw(steel)
    for _, uvs, _, mat in tris:
        if mat == STEEL:
            dsm.polygon([px(u) for u in uvs], fill=255)
    streaks = Image.new("RGBA", (TEX, TEX), (0, 0, 0, 0))
    dst = ImageDraw.Draw(streaks)
    for y in range(TEX):
        d = rng.randint(-9, 9)
        v = 128 + d
        dst.line([(0, y), (TEX, y)], fill=(v, v, v + 1, 40))
    streaks = streaks.filter(ImageFilter.GaussianBlur(0.6))
    shell.paste(Image.alpha_composite(shell, streaks), (0, 0), steel)

    # panel seams: outline every door, hood and vault zone in the shell
    for zone in [z for z in Z if z.startswith(("door", "hood", "boot"))]:
        zc = tuple(int(round(v * 255)) for v in Z[zone])
        diff = ImageChops.difference(mask, Image.new("RGB", (TEX, TEX), zc)).convert("L")
        sel = diff.point(lambda v: 255 if v == 0 else 0)
        edge = sel.filter(ImageFilter.FIND_EDGES)
        shell.paste((52, 54, 56, 255), (0, 0), edge)

    # black cladding along the rocker and arches on both sides
    for left in (True, False):
        top_v = uv_side(0, -27, left)[1]
        bot_v = uv_side(0, -36, left)[1]
        box = [0, (1 - top_v) * TEX, TEX, (1 - bot_v) * TEX]
        clad = Image.new("L", (TEX, TEX), 0)
        ImageDraw.Draw(clad).rectangle(box, fill=255)
        side_sel = Image.new("L", (TEX, TEX), 0)
        dss = ImageDraw.Draw(side_sel)
        for pts, uvs, _, mat in tris:
            if mat == STEEL and abs(abs(pts[0][0]) - W) < 1e-6 and abs(pts[1][0] - pts[0][0]) < 1e-6 \
                    and (pts[0][0] > 0) == left:
                dss.polygon([px(u) for u in uvs], fill=255)
        clad = Image.composite(clad, Image.new("L", (TEX, TEX), 0), side_sel)
        shell.paste((40, 40, 42, 255), (0, 0), clad)

    # glass gets a soft sky reflection gradient so it reads as glass from above
    gl = Image.new("L", (TEX, TEX), 0)
    dgl = ImageDraw.Draw(gl)
    for _, uvs, _, mat in tris:
        if mat == GLASS:
            dgl.polygon([px(u) for u in uvs], fill=255)
    grad = Image.linear_gradient("L").resize((TEX, TEX)).point(lambda v: int(v * 0.35))
    sheen = Image.new("RGBA", (TEX, TEX), (120, 140, 165, 255))
    shell.paste(sheen, (0, 0), Image.composite(grad, Image.new("L", (TEX, TEX), 0), gl))

    shell.save(path_shell)
    mask.save(path_mask)
    lights.save(path_lights)


# ---------------------------------------------------------------- FBX (vanilla layout)
def fmt(vals, per_line=12):
    s = [("%.6f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v) for v in vals]
    return ",".join(s)


def write_fbx(template_path, out_path, name):
    t = open(template_path, encoding="latin-1").read()
    verts, pvi, normals, uv, uvi = [], [], [], [], []
    for pts, uvs, _, _ in tris:
        n = normal(*pts)
        for p, u in zip(pts, uvs):
            verts.extend(p)
            normals.extend(n)
            uv.extend(u)
        i = len(verts) // 3 - 3
        pvi.extend([i, i + 1, ~(i + 2)])
        uvi.extend([i, i + 1, i + 2])

    def arr(tag, vals):
        return "%s: *%d {\n\t\t\ta: %s\n\t\t} " % (tag, len(vals), fmt(vals))

    g0 = t.index("\tGeometry: ")
    g1 = t.index("\tModel: ", g0)
    geo = t[g0:g1]
    geo = re.sub(r"Vertices: \*\d+ \{.*?\} ", lambda m: arr("Vertices", verts), geo, flags=re.S)
    geo = re.sub(r"PolygonVertexIndex: \*\d+ \{.*?\} ", lambda m: arr("PolygonVertexIndex", pvi), geo, flags=re.S)
    geo = re.sub(r"\t\tEdges: \*\d+ \{.*?\} \n", "", geo, flags=re.S)
    geo = re.sub(r"Normals: \*\d+ \{.*?\} ", lambda m: arr("Normals", normals), geo, flags=re.S)
    geo = re.sub(r"NormalsW: \*\d+ \{.*?\} ", lambda m: arr("NormalsW", [1] * (len(normals) // 3)), geo, flags=re.S)
    geo = re.sub(r"UV: \*\d+ \{.*?\} ", lambda m: arr("UV", uv), geo, flags=re.S)
    geo = re.sub(r"UVIndex: \*\d+ \{.*?\} ", lambda m: arr("UVIndex", uvi), geo, flags=re.S)
    geo = re.sub(r"Smoothing: \*\d+ \{.*?\} ", lambda m: arr("Smoothing", [0] * len(tris)), geo, flags=re.S)
    t = t[:g0] + geo + t[g1:]
    t = t.replace("Model::Vehicles_PickUpTruck", "Model::" + name)
    open(out_path, "w", encoding="latin-1").write(scrub_paths(t))


def scrub_paths(t):
    """The vanilla export carries its author's Windows paths; point the texture at ours and blank the rest."""
    t = re.sub(r'"[A-Za-z]:\\[^"]*\.png"', '"vehicle_cybertruck_shell.png"', t)
    return re.sub(r'"[A-Za-z]:\\[^"]*"', '""', t)


def write_obj(path, tex_name):
    """Preview copy for Blender renders; not shipped."""
    with open(path, "w") as f:
        f.write("mtllib cybertruck.mtl\nusemtl shell\n")
        for pts, uvs, _, _ in tris:
            for p in pts:
                f.write("v %f %f %f\n" % p)
            for u in uvs:
                f.write("vt %f %f\n" % u)
        for i in range(len(tris)):
            a = i * 3 + 1
            f.write("f %d/%d %d/%d %d/%d\n" % (a, a, a + 1, a + 1, a + 2, a + 2))
    with open(os.path.join(os.path.dirname(path), "cybertruck.mtl"), "w") as f:
        f.write("newmtl shell\nKd 1 1 1\nmap_Kd %s\n" % tex_name)


if __name__ == "__main__":
    build()
    tex = os.path.join(MEDIA, "textures", "Vehicles")
    paint(os.path.join(tex, "vehicle_cybertruck_shell.png"),
          os.path.join(tex, "vehicle_cybertruck_mask.png"),
          os.path.join(tex, "vehicle_cybertruck_lights.png"))
    write_fbx(sys.argv[1], os.path.join(MEDIA, "models_X", "vehicles", "Vehicles_Cybertruck.fbx"), "Vehicles_Cybertruck")
    prev = os.path.join(HERE, "..", "build")
    os.makedirs(prev, exist_ok=True)
    write_obj(os.path.join(prev, "cybertruck.obj"), os.path.abspath(os.path.join(tex, "vehicle_cybertruck_shell.png")))
    print("triangles", len(tris), "breakpoints", YS)
