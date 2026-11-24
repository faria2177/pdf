#!/usr/bin/env python3
"""Synthetic photos for the on-device auto-crop check (no real documents).

Copies the reported failure: an ID card inside a clear plastic sleeve on a
grey table, photographed in portrait with the card turned sideways, saved by
the camera as landscape pixels + EXIF orientation 6 — at 12 MP and at 50 MP
(above the native decoder's 4096 px cap). Plus an upright card, a landscape
card and an A4 page.

Writes integration_test/scan_fixture_data.dart: base64 JPEG, true corners in
the *upright* image (normalized, TL TR BR BL as the document reads) and the
document's true aspect ratio. With --jpg DIR also writes viewable JPEGs.
"""
import base64, io, math, os, sys
import cv2
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(__file__), '..', 'integration_test', 'scan_fixture_data.dart')
rng = np.random.default_rng(20261124)
CARD = (85.6, 54.0)


def background(w, h, base=(150, 153, 160)):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    img = np.empty((h, w, 3), np.float32)
    img[:] = base
    # soft light falloff + a cast shadow band on the left (like a hand/phone)
    shade = 1 - .18 * ((xx / w - .7) ** 2 + (yy / h - .3) ** 2)
    shade -= .12 * np.exp(-((xx / w - .12) ** 2) / .01)
    img *= shade[..., None]
    img += rng.normal(0, 3, img.shape)
    return img


def card_texture(cw, ch):
    """Upright (landscape) card face, cw x ch pixels."""
    c = np.full((ch, cw, 3), (236, 238, 232), np.float32)
    c[: int(ch * .22)] = (214, 236, 214)                       # green header band
    cv2.circle(c, (int(cw * .12), int(ch * .12)), int(ch * .08), (40, 40, 200), -1)
    cv2.rectangle(c, (int(cw * .06), int(ch * .30)), (int(cw * .30), int(ch * .82)), (150, 150, 150), -1)
    for i in range(6):
        y = int(ch * (.32 + i * .09))
        cv2.rectangle(c, (int(cw * .36), y), (int(cw * (.62 + .25 * (i % 2))), y + max(2, int(ch * .025))), (25, 25, 25), -1)
    t = max(2, int(ch * .012))
    cv2.rectangle(c, (int(cw * .03), int(ch * .05)), (int(cw * .97), int(ch * .95)), (30, 30, 30), t)
    return c


def page_texture(pw, ph):
    c = np.full((ph, pw, 3), (240, 240, 236), np.float32)
    for i in range(34):
        y = int(ph * (.08 + i * .025))
        cv2.rectangle(c, (int(pw * .1), y), (int(pw * (.9 - .2 * (i % 3 == 2))), y + max(2, int(ph * .007))), (35, 35, 35), -1)
    return c


def paste(dst, tex, quad, alpha=1.0):
    h, w = tex.shape[:2]
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    m = cv2.getPerspectiveTransform(src, np.float32(quad))
    H, W = dst.shape[:2]
    warped = cv2.warpPerspective(tex, m, (W, H), flags=cv2.INTER_AREA)
    mask = cv2.warpPerspective(np.ones((h, w), np.float32), m, (W, H))
    mask = cv2.GaussianBlur(mask, (5, 5), 0)[..., None] * alpha
    return dst * (1 - mask) + warped * mask


def rotated_rect(cx, cy, w, h, deg):
    a = math.radians(deg)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for dx, dy in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        pts.append((cx + dx * ca - dy * sa, cy + dx * sa + dy * ca))
    return pts


def scene_card(W, H, sideways, tilt):
    img = background(W, H)
    if sideways:  # card turned 90°: long side vertical
        ch = H * .58; cw = ch * CARD[1] / CARD[0]
        # Card "reads" TL..BL after turning: corners listed clockwise from the
        # card's own top-left, which sits at the photo's top-right.
        r = rotated_rect(W * .52, H * .5, cw, ch, tilt)
        quad = [r[1], r[2], r[3], r[0]]
    else:
        cw = W * .62; ch = cw * CARD[1] / CARD[0]
        quad = rotated_rect(W * .5, H * .52, cw, ch, tilt)
    # clear plastic sleeve, 9% larger, slightly brighter with a bright rim
    sleeve = rotated_rect(np.mean([p[0] for p in quad]), np.mean([p[1] for p in quad]),
                          (cw if not sideways else cw) * 1.13, (ch if not sideways else ch) * 1.09, tilt)
    sw = int(max(cw, ch) * 1.2)
    sl = np.full((int(sw * .7), sw, 3), (205, 208, 214), np.float32)
    cv2.rectangle(sl, (0, 0), (sl.shape[1] - 1, sl.shape[0] - 1), (232, 234, 238), max(3, sw // 120))
    img = paste(img, sl, sleeve if not sideways else sleeve, alpha=.45)
    tex = card_texture(1712, 1080)
    img = paste(img, tex, quad)
    return np.clip(img, 0, 255).astype(np.uint8), quad, CARD[0] / CARD[1]


def scene_page(W, H):
    img = background(W, H, base=(92, 78, 64))  # wooden table
    pw = W * .74; ph = pw * 297 / 210
    quad = [(W * .14, H * .10), (W * .86, H * .12), (W * .89, H * .90), (W * .11, H * .88)]
    img = paste(img, page_texture(1240, 1754), quad)
    return np.clip(img, 0, 255).astype(np.uint8), quad, 297 / 210


def scene_guide(W, H):
    """Card held in the camera's guide frame, with a sheet of paper above it
    and a dark notebook below — things a full-frame detector grabs first."""
    img = background(W, H)
    paper = [(W * .06, H * .02), (W * .94, H * .03), (W * .93, H * .235), (W * .05, H * .225)]
    img = paste(img, page_texture(1240, 1754), paper)
    book = np.full((600, 900, 3), (60, 45, 40), np.float32)
    img = paste(img, book, [(W * .1, H * .74), (W * .95, H * .72), (W * .97, H * .99), (W * .12, H * 1.0)])
    cw = W * .80; ch = cw * CARD[1] / CARD[0]
    quad = rotated_rect(W * .5, H * .5, cw, ch, 2.0)
    img = paste(img, card_texture(1712, 1080), quad)
    return np.clip(img, 0, 255).astype(np.uint8), quad, CARD[0] / CARD[1]


def encode(upright_bgr, exif6):
    """JPEG bytes. With exif6 the pixels are stored rotated 90° CCW and tagged
    orientation 6, exactly like a phone camera held in portrait."""
    rgb = cv2.cvtColor(upright_bgr, cv2.COLOR_BGR2RGB)
    im = Image.fromarray(rgb)
    buf = io.BytesIO()
    if exif6:
        im = im.transpose(Image.Transpose.ROTATE_90)  # CCW
        ex = Image.Exif(); ex[0x0112] = 6
        im.save(buf, 'JPEG', quality=88, exif=ex.tobytes())
    else:
        im.save(buf, 'JPEG', quality=88)
    return buf.getvalue()


def main():
    scenes = {}
    for name, (W, H), kind, exif6 in [
        ('card_sleeve_sideways_exif6_12mp', (3000, 4000), 'sideways', True),
        ('card_sleeve_sideways_exif6_50mp', (6120, 8160), 'sideways', True),
        ('card_sleeve_sideways_upright', (3000, 4000), 'sideways', False),
        ('card_landscape_exif6', (3000, 4000), 'flat', True),
        ('page_a4_exif6_12mp', (3000, 4000), 'page', True),
        ('guide_card_with_clutter_exif6', (3000, 4000), 'guide', True),
    ]:
        if kind == 'guide':
            img, quad, aspect = scene_guide(W, H)
        elif kind == 'page':
            img, quad, aspect = scene_page(W, H)
        else:
            img, quad, aspect = scene_card(W, H, kind == 'sideways', tilt=3.0)
        data = encode(img, exif6)
        flat = [v for (x, y) in quad for v in (x / W, y / H)]
        scenes[name] = (data, flat, aspect, kind != 'page')
        if '--jpg' in sys.argv:
            d = sys.argv[sys.argv.index('--jpg') + 1]
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, name + '.jpg'), 'wb').write(data)
        print(name, len(data) // 1024, 'KB', [round(v, 3) for v in flat])
    with open(OUT, 'w') as f:
        f.write('// GENERATED by tool/make_scan_fixtures.py — do not edit, not committed.\n')
        f.write('const scanScenes = <String, (String, List<double>, double, bool)>{\n')
        for name, (data, flat, aspect, card) in scenes.items():
            f.write(f"  '{name}': ('{base64.b64encode(data).decode()}', {flat}, {aspect}, {str(card).lower()}),\n")
        f.write('};\n')


if __name__ == '__main__':
    main()
