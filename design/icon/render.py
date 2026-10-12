"""Lectures app icon: a black compact cassette with a hand-written saffron label,
lying on the maple of the app's shelf, lit per pixel the way iOS 6 icons were
painted (key light up-left, contact + cast shadows, springboard gloss baked in).

    uv run --with numpy --with pillow python design/icon/render.py <out-dir>

writes AppIcon-1024.png (copy to ios/Sources/Assets.xcassets/AppIcon.appiconset/
icon-1024.png) and final_sheet.png (preview at every size)."""
import math, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = sys.argv[1]
SS = 2048                      # supersampled canvas; final icon is 1024
K = SS / 1024                  # design units are 1024-px icon pixels
rng = np.random.default_rng(1966)
Y, X = np.mgrid[0:SS, 0:SS].astype(np.float32)
LW = np.array([-0.5, -0.72, 0.85]); LW /= np.linalg.norm(LW)


def _box(a, w, axis):
    if w < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (w + 1, w)
    c = np.cumsum(np.pad(a, pad, mode="edge"), axis=axis, dtype=np.float64)
    hi = np.take(c, range(2 * w + 1, c.shape[axis]), axis=axis)
    lo = np.take(c, range(0, c.shape[axis] - 2 * w - 1), axis=axis)
    return ((hi - lo) / (2 * w + 1)).astype(np.float32)


def blur(a, r):
    """Gaussian of radius r, as three box passes per axis."""
    w = max(int(round(r * 0.9)), 0)
    a = a.astype(np.float32)
    for _ in range(3):
        a = _box(_box(a, w, 0), w, 1)
    return a


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def znorm(a):
    return (a - a.mean()) / (a.std() + 1e-6)


def noise(r, gen=rng):
    """Normalised white noise, blurred to grain of radius r."""
    return znorm(blur(gen.random((SS, SS), np.float32), r))


def mix(a, c, m):
    """Lay colour c over a with coverage m."""
    return a + (np.asarray(c, np.float32) - a) * m[..., None]


def font(name, px):
    return ImageFont.truetype(f"/System/Library/Fonts/{name}.ttc", int(px), index=1)


def raster(draw, r=0.0):
    """A float mask from PIL drawing calls, optionally softened by a blur of radius r."""
    m = Image.new("L", (SS, SS), 0)
    draw(ImageDraw.Draw(m))
    if r:
        m = m.filter(ImageFilter.GaussianBlur(r))
    return np.asarray(m, np.float32) / 255


def lit_normals(h, scale, light):
    gy, gx = np.gradient(h * scale)
    nn = np.sqrt(gx * gx + gy * gy + 1)
    nx, ny, nz = -gx / nn, -gy / nn, 1 / nn
    lam = nx * light[0] + ny * light[1] + nz * light[2]
    hv = light + np.array([0, 0, 1.0]); hv /= np.linalg.norm(hv)
    spec = np.clip(nx * hv[0] + ny * hv[1] + nz * hv[2], 0, 1)
    return lam, spec


# ---------------------------------------------------------------- maple
def maple():
    """Newsstand's shelf wood: pale maple, grain running top to bottom."""
    r = np.random.default_rng(7)
    # wobble the grain sideways so the lines drift and bend like real boards
    wob = blur(r.random((SS // 8, SS // 8), np.float32), 6)
    wob = np.asarray(Image.fromarray((wob - wob.min()) / (np.ptp(wob) + 1e-6)).resize((SS, SS), Image.BICUBIC))
    xs = X + (wob - 0.5) * 14 * K
    def lines(n, seed):
        t = np.random.default_rng(seed).random(n + 2, np.float32)
        q = xs / SS * n
        i = np.clip(np.floor(q).astype(int), 0, n)
        f = smooth(0, 1, q - np.floor(q))
        return t[i] * (1 - f) + t[i + 1] * f
    g = znorm(0.62 * lines(26, 1) + 0.30 * lines(140, 2) + 0.08 * lines(520, 3))
    s = znorm(_box(blur(r.random((SS, SS), np.float32), 1.2 * K), int(40 * K), 0))   # pores stretched along the grain
    t = np.clip(0.45 + 0.17 * g + 0.10 * s, 0, 1)
    img = mix(np.full((SS, SS, 3), (246, 206, 140), np.float32), (212, 150, 72), t)
    # a couple of the darker hairline grain lines the shelf texture has
    hair = np.abs(np.sin(xs / SS * 61 * math.pi + lines(9, 4) * 2))
    img *= (1 - 0.10 * smooth(0.985, 1.0, hair))[..., None]
    # pool of light up-left, falloff to the corners
    d = np.hypot(X - SS * 0.35, Y - SS * 0.28) / SS
    img *= (1.06 - 0.38 * d ** 1.6)[..., None]
    return img


# ---------------------------------------------------------------- cassette
# Local frame: design units, origin at the cassette's centre, unrotated. The
# cassette is drawn 1.1x up so it fills the icon; P is one local unit in pixels.
TILT = 9.0                     # degrees the cassette is turned, counter-clockwise
P = K * 1.1
LIFT = int(-8 * K)                # set a touch above centre
U = (X - SS / 2) / P
V = (Y - SS / 2) / P
CW, CH = 392, 250              # half-width, half-height (a real cassette's 100.4 x 63.8 mm)
SCREW_R = 12
HUB_X, HUB_Y, HUB_RING = 168.0, -2.0, 34
LAB_T, LAB_B = -222, 114       # the label: top and bottom edges
BAND_B = LAB_T + 50            # saffron band across the top
LOW_T = 86                     # saffron band along the bottom
WRITE = (-112, -70)            # ruled lines for writing


def px(u, v):
    return SS / 2 + u * P, SS / 2 + v * P


def sd_box(cx, cy, hw, hh, r):
    qx = np.abs(U - cx) - (hw - r)
    qy = np.abs(V - cy) - (hh - r)
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def sd_circle(cx, cy, r):
    return np.hypot(U - cx, V - cy) - r


def cov(sd):
    return np.clip(0.5 - sd * P, 0, 1)


def cassette():
    th = math.radians(TILT)
    # the world light, turned into the cassette's own frame
    L = np.array([LW[0] * math.cos(th) - LW[1] * math.sin(th),
                  LW[0] * math.sin(th) + LW[1] * math.cos(th), LW[2]], np.float32)

    body = sd_box(0, 0, CW, CH, 26)
    a_body = cov(body)

    # ---- height field of the moulded shell
    bevel = 13
    h = smooth(0, bevel, -body)                               # rounded outer edge
    trap = [(-262, 142), (262, 142), (300, CH - 6), (-300, CH - 6)]
    tm = raster(lambda d: d.polygon([px(u, v) for u, v in trap], fill=255))
    h += 0.45 * blur(tm, 5 * P)                               # the raised head-guide block
    # recess the label sits in, and the ridge round it
    lab = sd_box(0, (LAB_T + LAB_B) / 2, 352, (LAB_B - LAB_T) / 2, 16)
    h -= 0.22 * smooth(8.5, 3.5, lab)
    # screws: five low domes
    screws = [(-352, -212), (352, -212), (-352, 212), (352, 212), (0, 206)]
    screw_d = [np.hypot(U - sx, V - sy) for sx, sy in screws]
    for d in screw_d:
        h += 0.35 * np.sqrt(np.clip(1 - (d / (SCREW_R + 1)) ** 2, 0, 1))
    lam, spec = lit_normals(blur(h, 1.0 * P), 22 * P / bevel, L)

    # ---- the shell: smoky black polystyrene, faint mottling, satin sheen
    base = np.array([34, 33, 37], np.float32) * (0.94 + 0.06 * noise(1.0 * P))[..., None]
    grad = 1.18 - 0.30 * (V + CH) / (2 * CH)                 # catches more light at the top
    img = base * ((0.55 + 0.75 * np.clip(lam, 0, 1)) * grad)[..., None] \
        + 255 * (0.30 * spec ** 40 + 0.06 * spec ** 6)[..., None]
    # the moulded grip ridges on the head block
    ridge = tm * (np.abs(((U + 2) % 22) - 11) < 2.2) * (np.abs(U) > 120) * (V > 170)
    img *= (1 - 0.25 * blur(ridge, 0.7 * P))[..., None]
    # holes in the head block: capstan pair, pinch pad, guides
    holes = np.maximum.reduce([cov(sd_box(-212, 214, 15, 17, 4)), cov(sd_box(212, 214, 15, 17, 4)),
                               cov(sd_circle(-128, 214, 13)), cov(sd_circle(128, 214, 13)),
                               cov(sd_box(0, 232, 40, 14, 4))])
    img *= (1 - 0.85 * holes)[..., None]
    rim = np.roll(holes, int(2 * P), 0) - holes               # lit lower lip of each hole
    img += (np.clip(rim, 0, 1) * 34)[..., None]

    # ---- screws: steel, phillips cross
    for (sx, sy), d in zip(screws, screw_d):
        steel = 120 + 110 * np.clip(-((U - sx) * L[0] + (V - sy) * L[1]) / SCREW_R, -1, 1)
        cross = (np.minimum(np.abs(U - sx), np.abs(V - sy)) < 1.8) & (d < 8)
        steel = np.where(cross, steel * 0.35, steel)
        img = mix(img, steel[..., None] * np.array([0.95, 0.97, 1.0], np.float32), cov(d - SCREW_R))

    # ---- the paper label
    a_lab = cov(lab)
    saffron = np.array([236, 128, 36], np.float32)
    lp = np.array([241, 232, 210], np.float32) * (0.97 + 0.032 * noise(0.8 * P))[..., None]
    # saffron band across the top, a thin red rule under it, a band along the bottom
    band_shade = 1.08 - 0.20 * (V - LAB_T) / (BAND_B - LAB_T)
    lp = mix(lp, saffron * band_shade[..., None], cov(np.maximum(lab, V - BAND_B)))
    lp = mix(lp, (178, 46, 34), cov(np.abs(V - (BAND_B + 7)) - 2.5) * a_lab)
    lp = mix(lp, saffron * 0.96, cov(np.maximum(lab, LOW_T - V)))
    for ly in WRITE:
        lp = mix(lp, (120, 150, 190), 0.35 * cov(np.abs(V - ly) - 1.1) * cov(np.abs(U) - 300))

    def write(d):
        d.text(px(-300, WRITE[0] - 6), "Bhagavad-gita 2.13", font=font("Noteworthy", 50 * P), fill=255, anchor="ls")
        d.text(px(150, WRITE[1] - 6), "London '73", font=font("Noteworthy", 36 * P), fill=255, anchor="ls")
    def print_(d):
        sans = font("HelveticaNeue", 36 * P)
        d.text(px(-312, BAND_B - 10), "LECTURES", font=sans, fill=255, anchor="ls")
        d.text(px(222, BAND_B - 10), "C-90", font=sans, fill=255, anchor="ls")
        # side "A": a white disc in the bottom band
        d.ellipse([*px(-328, LOW_T - 6), *px(-292, LOW_T + 30)], fill=255)
    lp = mix(lp, (30, 52, 120), 0.9 * raster(write, 0.6 * P))
    lp = mix(lp, (252, 246, 232), raster(print_, 0.4 * P))
    lp = mix(lp, (200, 96, 24), raster(lambda d: d.text(px(-310, LOW_T + 13), "A", font=font("HelveticaNeue", 27 * P),
                                                      fill=255, anchor="mm"), 0.4 * P))
    lp *= (1.04 - 0.10 * (V - LAB_T) / (LAB_B - LAB_T))[..., None]   # light falls off down the label

    # ---- the window: hub holes and the strip between them, cut through the label
    win = np.minimum.reduce([sd_circle(-HUB_X, HUB_Y, 52), sd_circle(HUB_X, HUB_Y, 52),
                             sd_box(0, HUB_Y, 120, 38, 10)])
    a_win = cov(win)
    # inside: dark cavity, the tape packs (left full, right nearly empty), the hubs
    inside = np.full((SS, SS, 3), (18, 16, 18), np.float32)
    for hx, R in ((-HUB_X, 150), (HUB_X, 86)):
        d = np.hypot(U - hx, V - HUB_Y)
        ang = np.arctan2(V - HUB_Y, U - hx)
        rings = 0.85 + 0.15 * np.sin(d * 1.7) * np.sin(d * 0.31)
        sheen = 0.55 + 0.6 * np.clip(np.cos(ang - math.radians(225)), 0, 1) ** 3
        inside = mix(inside, np.array([86, 52, 30], np.float32) * (rings * sheen)[..., None], cov(d - R))
        # the packs don't reach the other side's hub, so each hub can go straight on
        ring = cov(d - HUB_RING) * (1 - cov(d - 21))
        teeth = cov(d - 22) * (1 - cov(d - 14)) * (np.abs(((ang * 6 / (2 * math.pi)) % 1) - 0.5) < 0.12)
        shade = 205 + 40 * np.clip(-((U - hx) * L[0] + (V - HUB_Y) * L[1]) / HUB_RING, -1, 1)
        inside = mix(inside, shade[..., None] * np.array([1.0, 0.99, 0.96], np.float32), np.clip(ring + teeth, 0, 1))
    # the window is set back: the label casts a soft shadow into it
    rim_sh = np.roll(blur(1 - a_win, 6 * P), (int(5 * P), int(3 * P)), (0, 1))
    inside *= (1 - 0.6 * rim_sh * a_win)[..., None]
    # clear plastic over it: a diagonal reflection
    inside = mix(inside, 255, smooth(0.0, 1.0, 1 - np.abs((U * 0.55 + V + 34) / 36)) * 0.22)
    lp = mix(lp, inside, a_win)
    lp *= (1 - 0.5 * cov(np.abs(win) - 1.2) * a_lab)[..., None]

    # the label's own edge: a hair of shadow round it
    img = mix(img, lp, a_lab)
    img *= (1 - 0.3 * cov(np.abs(lab) - 1.0))[..., None]

    # whole-shell gloss: polished top edge highlight
    img = mix(img, 255, cov(np.abs(body + 3) - 1.5) * smooth(60, -CH, V) * 0.6)

    rgba = np.dstack([np.clip(img, 0, 255), a_body * 255]).astype(np.uint8)
    return Image.fromarray(rgba).rotate(TILT, resample=Image.BICUBIC, translate=(0, LIFT))


# ---------------------------------------------------------------- compose
bg = maple()
cas = cassette()
occ = np.asarray(cas, np.float32)[..., 3] / 255
# the cassette stays clear of the canvas edge, so roll's wrap-around never shows
contact = blur(np.roll(occ, (int(6 * K), int(3 * K)), (0, 1)), 4 * K)
cast = blur(np.roll(occ, (int(38 * K), int(22 * K)), (0, 1)), 26 * K)
bg *= np.clip(1 - 0.55 * contact - 0.45 * cast, 0.15, 1)[..., None]
img = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8)).convert("RGBA")
img.alpha_composite(cas)

# springboard gloss, as iOS 6 laid it over every icon
gl = raster(lambda d: d.ellipse([-SS * 0.62, -SS * 1.02, SS * 1.62, SS * 0.47], fill=255), 2.5 * K)
arr = np.asarray(img, np.float32)[..., :3]
arr = mix(arr, 255, gl * (np.clip(1 - Y / (SS * 0.47), 0, 1) * 0.28 + 0.06))
# the faint bright rim iOS 6 icons had along the top edge
arr = mix(arr, 255, smooth(SS * 0.012, 0, Y) * 0.25)
final = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).resize((1024, 1024), Image.LANCZOS)
final.save(f"{OUT}/AppIcon-1024.png")


def masked(im, size):
    im = im.resize((size, size), Image.LANCZOS).convert("RGBA")
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * 0.175), fill=255)
    im.putalpha(m.resize((size, size), Image.LANCZOS))
    return im


W, Hh = 1240, 760
sheet = Image.new("RGBA", (W, Hh), (28, 32, 42, 255))
d = ImageDraw.Draw(sheet)
caption = font("HelveticaNeue", 22)
big = masked(final, 640)
sh = Image.new("RGBA", big.size, (0, 0, 0, 0)); sh.putalpha(big.getchannel("A").point(lambda v: v * 0.6))
sheet.alpha_composite(sh.filter(ImageFilter.GaussianBlur(12)), (50, 66))
sheet.alpha_composite(big, (50, 56))
x = 760
for size, y0, label, named in ((228, 80, "114 px · Retina", True), (114, 360, "57 pt", True),
                               (58, 560, "29 pt · Settings", False)):
    sheet.alpha_composite(masked(final, size), (x, y0))
    if named:
        y = y0 + size + 22
        d.text((x + size // 2 + 1, y + 2), "Lectures", font=caption, fill=(0, 0, 0), anchor="mm")
        d.text((x + size // 2, y), "Lectures", font=caption, fill=(255, 255, 255), anchor="mm")
    d.text((x + 260, y0 + size // 2), label, font=caption, fill=(140, 146, 160), anchor="lm")
sheet.convert("RGB").save(f"{OUT}/final_sheet.png")
print("ok")
