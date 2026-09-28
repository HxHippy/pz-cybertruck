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


# Wheel arches for the 0.23 radius tire in cybertruck.txt: 29.7 model units (a model unit is 0.00774
# vehicle units, from the 1.82 model scale and the template's FBX scale). The tires sit on the pickup
# wheel stations (+98, -76). The vanilla pickup's arches put its tire center near z=-37. This body rides
# 5.4 units lower on the same wheel offsets (model offset 0.26 against the pickup's 0.3022) and is
# heavier, so plan on z=-30.5. Each arch is a half-octagon drawn around the tire with 2 units spare,
# which still leaves a fender lip under the sloping hood. Tune TIRE_Z if the tire rubs in game.
TIRE_R, TIRE_Z, ARCH_GAP, LIP, ROCKER = 29.7, -30.5, 2.0, 2.0, -34.0
WHEEL_Y = (98.0, -76.0)


def _arch(yc):
    rv = (TIRE_R + ARCH_GAP) / math.cos(math.pi / 12)  # polygon outside the clearance circle
    pts = [(round(yc + rv + 1, 1), ROCKER)]
    for i in range(7):
        a = math.pi * i / 6
        y = yc + rv * math.cos(a)
        z = min(max(ROCKER, TIRE_Z + rv * math.sin(a)), z_top(y) - LIP)
        pts.append((round(y, 1), round(z, 1)))
    return pts + [(round(yc - rv - 1, 1), ROCKER)]


# bottom edge, nose to tail, with the arches cut in
BOTTOM = [(141, -26), (137, -28)] + _arch(WHEEL_Y[0]) + _arch(WHEEL_Y[1]) + [(-137, -30), (-141, -27)]


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


YS = sorted({141, 137, 69, 58, 15, 10, -12, -32, -40, -137, -141, _belt_cross(141, 15), _belt_cross(-12, -141)}
            | {y for y, _ in BOTTOM}, reverse=True)

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

    # fitting swatches (saws, hatch, gun); mask stays white there, so no part zone touches them
    for i, rgb in enumerate(SWATCHES):
        ds.rectangle((i * TEX // 4 + 8, (1 - SWATCH_V1) * TEX, (i + 1) * TEX // 4 - 8, (1 - SWATCH_V0) * TEX), fill=rgb + (255,))

    shell.save(path_shell)
    mask.save(path_mask)
    lights.save(path_lights)


# ---------------------------------------------------------------- FBX (vanilla layout)
def fmt(vals, per_line=12):
    s = [("%.6f" % v).rstrip("0").rstrip(".") if isinstance(v, float) else str(v) for v in vals]
    return ",".join(s)


def write_fbx(template_path, out_path, name, tex="vehicle_cybertruck_shell.png"):
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
    open(out_path, "w", encoding="latin-1").write(scrub_paths(t, tex))


def scrub_paths(t, tex="vehicle_cybertruck_shell.png"):
    """The vanilla export carries its author's Windows paths; point the texture at ours and blank the rest."""
    t = re.sub(r'"[A-Za-z]:\\[^"]*\.png"', '"' + tex + '"', t)
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


# Fitting colours live in the shell atlas, in the empty band between the roof strip (v <= 0.49) and
# the right side (v >= 0.526). Part models on a vehicle shader are always drawn with the vehicle's own
# skin as Texture0 (Model.drawVehicle binds the parent's texture), so a model script `texture` is ignored.
# Every vertex of a face shares one UV, so the sample never leaves its swatch at any mip level.
SWATCH_V0, SWATCH_V1 = 0.495, 0.521
STEEL_UV = (0.125, 0.508)   # bright stainless
GUN_UV = (0.375, 0.508)     # gunmetal
DARK_UV = (0.625, 0.508)    # near-black
RED_UV = (0.875, 0.508)     # hubs and accents
SWATCHES = ((196, 199, 203), (82, 86, 92), (26, 28, 32), (186, 30, 26))


def add_box(x0, y0, z0, x1, y1, z1, uv):
    c = [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
         (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]
    faces = [(0, 1, 2, 3, (0, 0, -1)), (4, 7, 6, 5, (0, 0, 1)),
             (0, 4, 5, 1, (0, -1, 0)), (3, 2, 6, 7, (0, 1, 0)),
             (0, 3, 7, 4, (-1, 0, 0)), (1, 5, 6, 2, (1, 0, 0))]
    for a, b, d, e, outward in faces:
        add_poly([c[a], c[b], c[d], c[e]], [uv] * 4, "none", STEEL, outward)


def add_prism(points, z0, z1, top_uv, side_uv, bottom_uv=None):
    """A flat shape extruded from z0 to z1. `points` go round the outline; it may be star-shaped
    around the origin, so the caps are fanned from the center, one triangle per edge."""
    n = len(points)
    for i in range(n):
        (ax, ay), (bx, by) = points[i], points[(i + 1) % n]
        add_poly([(0, 0, z1), (ax, ay, z1), (bx, by, z1)], [top_uv] * 3, "none", STEEL, (0, 0, 1))
        add_poly([(0, 0, z0), (bx, by, z0), (ax, ay, z0)], [bottom_uv or top_uv] * 3, "none", STEEL, (0, 0, -1))
        mx, my = (ax + bx) / 2, (ay + by) / 2
        add_poly([(ax, ay, z0), (bx, by, z0), (bx, by, z1), (ax, ay, z1)], [side_uv] * 4, "none", STEEL, (mx, my, 0))


def circle(r, n, phase=0.0):
    return [(math.cos(phase + 2 * math.pi * i / n) * r, math.sin(phase + 2 * math.pi * i / n) * r) for i in range(n)]


def mesh(fn):
    """Run fn against a fresh triangle list and return it. The body mesh is put back."""
    global tris
    saved = tris
    tris = []
    fn()
    built = tris
    tris = saved
    return built


SAW_R = 22.0


def build_saw():
    """One saw blade lying flat, centered on the origin, so each copy on the truck spins about its own hub.

    Twenty raked teeth, a stainless disc, a gunmetal edge and a red hub that reads as the motor.
    """
    def go():
        teeth = 20
        outline = []
        for i in range(teeth):
            a = 2 * math.pi * i / teeth
            b = a + 2 * math.pi / teeth * 0.72   # raked: the tip leads, the gullet trails
            outline.append((math.cos(a) * SAW_R, math.sin(a) * SAW_R))
            outline.append((math.cos(b) * SAW_R * 0.84, math.sin(b) * SAW_R * 0.84))
        add_prism(outline, -0.8, 0.8, STEEL_UV, GUN_UV)
        add_prism(circle(5.5, 10), 0.8, 2.2, RED_UV, RED_UV, RED_UV)
        add_prism(circle(5.5, 10), -2.2, -0.8, RED_UV, RED_UV, RED_UV)
        # Four dark vent slots, so a spinning blade shows motion instead of a flat grey disc.
        for k in range(4):
            a = math.pi / 2 * k
            cx, cy = math.cos(a) * 12.5, math.sin(a) * 12.5
            px, py = -math.sin(a), math.cos(a)
            pts = [(cx + px * 3.2 - math.cos(a) * 1.1, cy + py * 3.2 - math.sin(a) * 1.1, 0.85),
                   (cx - px * 3.2 - math.cos(a) * 1.1, cy - py * 3.2 - math.sin(a) * 1.1, 0.85),
                   (cx - px * 3.2 + math.cos(a) * 1.1, cy - py * 3.2 + math.sin(a) * 1.1, 0.85),
                   (cx + px * 3.2 + math.cos(a) * 1.1, cy + py * 3.2 + math.sin(a) * 1.1, 0.85)]
            add_poly(pts, [DARK_UV] * 4, "none", STEEL, (0, 0, 1))
    return mesh(go)


# Where the saws ride, in model units: (x, y, z, radius). Rockers between the arches, the rear
# quarters behind the rear wheels, and a pair jutting off the front bumper. Each clears the tires.
SAWS = [
    (W - 2, 36, -27, 22), (-(W - 2), 36, -27, 22),
    (W - 2, -12, -27, 22), (-(W - 2), -12, -27, 22),
    (W - 4, -127, -24, 16), (-(W - 4), -127, -24, 16),
    (24, NOSE + 6, -24, 18), (-24, NOSE + 6, -24, 18),
]


def build_sunroof():
    def go():
        z = z_top(0) + 2.5
        ring = circle(22.0, 16)
        inner = circle(14.0, 16)
        for i in range(16):
            j = (i + 1) % 16
            (ax, ay), (bx, by) = ring[i], ring[j]
            (cx, cy), (dx, dy) = inner[i], inner[j]
            add_poly([(cx, cy, z + 4), (dx, dy, z + 4), (bx, by, z + 4), (ax, ay, z + 4)], [STEEL_UV] * 4, "none", STEEL, (0, 0, 1))
            add_poly([(ax, ay, z), (bx, by, z), (bx, by, z + 4), (ax, ay, z + 4)], [GUN_UV] * 4, "none", STEEL, ((ax + bx) / 2, (ay + by) / 2, 0))
            add_poly([(cx, cy, z + 4), (dx, dy, z + 4), (dx, dy, z + 0.6), (cx, cy, z + 0.6)], [DARK_UV] * 4, "none", STEEL, (-(cx + dx) / 2, -(cy + dy) / 2, 0))
        add_prism(inner, z + 0.4, z + 0.6, DARK_UV, DARK_UV)
    return mesh(go)


def build_turret():
    """Pintle gun on a turntable, built around the hatch center so it swivels about its own ring.
    The barrel points up the truck's nose (+y) at rest."""
    def go():
        z = z_top(0) + 6.5
        add_prism(circle(13.0, 12), z, z + 2.5, GUN_UV, DARK_UV)          # turntable
        add_box(-3, -3, z + 2.5, 3, 3, z + 9, DARK_UV)                      # pintle post
        add_box(-4.5, -12, z + 9, 4.5, 12, z + 17, GUN_UV)                  # receiver
        add_box(-2.3, 12, z + 11, 2.3, 30, z + 15.4, GUN_UV)               # barrel shroud
        add_box(-1.3, 30, z + 12, 1.3, 68, z + 14.4, DARK_UV)              # barrel
        add_box(-2.5, 64, z + 11.2, 2.5, 72, z + 15.2, DARK_UV)            # muzzle brake
        add_box(4.5, -8, z + 8, 11, 5, z + 16, GUN_UV)                     # ammo can
        add_box(4.6, -8.2, z + 13, 11.1, 5.2, z + 14, RED_UV)              # can band
        add_box(-3.5, -18, z + 11.5, -1.5, -12, z + 15.5, DARK_UV)          # spade grips
        add_box(1.5, -18, z + 11.5, 3.5, -12, z + 15.5, DARK_UV)
        add_box(-15, 18, z + 6, -2.8, 20, z + 25, STEEL_UV)                 # split shield
        add_box(2.8, 18, z + 6, 15, 20, z + 25, STEEL_UV)
        add_box(-2.8, 18, z + 17, 2.8, 20, z + 25, STEEL_UV)
    return mesh(go)


if __name__ == "__main__":
    build()
    tex = os.path.join(MEDIA, "textures", "Vehicles")
    paint(os.path.join(tex, "vehicle_cybertruck_shell.png"),
          os.path.join(tex, "vehicle_cybertruck_mask.png"),
          os.path.join(tex, "vehicle_cybertruck_lights.png"))
    models = os.path.join(MEDIA, "models_X", "vehicles")
    template = sys.argv[1]
    write_fbx(template, os.path.join(models, "Vehicles_Cybertruck.fbx"), "Vehicles_Cybertruck")
    body_count = len(tris)
    prev = os.path.join(HERE, "..", "build")
    os.makedirs(prev, exist_ok=True)
    write_obj(os.path.join(prev, "cybertruck.obj"), os.path.abspath(os.path.join(tex, "vehicle_cybertruck_shell.png")))

    for builder, filename in ((build_saw, "Vehicles_CybertruckSaw.fbx"),
                              (build_sunroof, "Vehicles_CybertruckSunroof.fbx"),
                              (build_turret, "Vehicles_CybertruckTurret.fbx")):
        tris = builder()
        write_fbx(template, os.path.join(models, filename), filename[:-4])
        print(filename, len(tris))
    print("body triangles", body_count, "breakpoints", len(YS))
    # Part model offsets for the saws, in the vehicle script's units (see cybertruck.txt BladeKit).
    # Offsets land in plain vehicle units, same as the wheel offsets; the 1.82 model scale does not
    # apply to them (measured in game: a saw lifted to y=0.35 sits just above the 0.29 roof).
    k = 0.00774
    for i, (x, y, z, r) in enumerate(SAWS, 1):
        print("saw %d offset = %.4f %.4f %.4f, scale = %.4f" % (i, -x * k, z * k, y * k, r / SAW_R))
