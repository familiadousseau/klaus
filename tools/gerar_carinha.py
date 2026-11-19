"""Gera 21 GIFs de emoções (240x240) com uma carinha original de robô."""
import math, os, sys
from PIL import Image, ImageDraw

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)

S = 3                      # supersampling
W = 240
FACE0 = (28, 38, 66)
BG = FACE0                 # fundo = cor do rosto (cantos ficam transparentes)
FACE = (28, 38, 66)
EYE = (90, 230, 255)       # ciano
MOUTH = (90, 230, 255)
BLUSH = (255, 110, 150)
RED = (255, 90, 90)
TEAR = (120, 190, 255)
WHITE = (235, 245, 255)
N = 24                     # frames
DUR = 70                   # ms por frame


def P(v):
    return v * S


class Canvas:
    def __init__(self):
        self.im = Image.new("RGB", (P(W), P(W)), BG)
        self.d = ImageDraw.Draw(self.im)
        # "ecrã" arredondado do rosto

    def rrect(self, cx, cy, w, h, color, r=None):
        h = max(h, 2)
        r = min(w, h) / 2 if r is None else r
        self.d.rounded_rectangle([P(cx - w / 2), P(cy - h / 2), P(cx + w / 2), P(cy + h / 2)],
                                 radius=P(r), fill=color)

    def ellipse(self, cx, cy, rx, ry, color, width=None):
        box = [P(cx - rx), P(cy - ry), P(cx + rx), P(cy + ry)]
        if width:
            self.d.ellipse(box, outline=color, width=int(P(width)))
        else:
            self.d.ellipse(box, fill=color)

    def arc(self, cx, cy, rx, ry, start, end, color, width=7):
        h = width / 2
        self.d.arc([P(cx - rx - h), P(cy - ry - h), P(cx + rx + h), P(cy + ry + h)], start, end,
                   fill=color, width=int(P(width)))
        # pontas arredondadas
        for a in (start, end):
            x = cx + rx * math.cos(math.radians(a))
            y = cy + ry * math.sin(math.radians(a))
            self.ellipse(x - 0 * width, y, width / 2 - 0.3, width / 2 - 0.3, color)

    def line(self, pts, color, width=7):
        self.d.line([(P(x), P(y)) for x, y in pts], fill=color, width=int(P(width)), joint="curve")
        for x, y in (pts[0], pts[-1]):
            self.ellipse(x, y, width / 2 - 0.3, width / 2 - 0.3, color)

    def poly(self, pts, color):
        self.d.polygon([(P(x), P(y)) for x, y in pts], fill=color)

    def heart(self, cx, cy, s, color):
        pts = []
        for i in range(60):
            t = 2 * math.pi * i / 60
            x = 16 * math.sin(t) ** 3
            y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
            pts.append((cx + x * s / 16, cy + y * s / 16))
        self.poly(pts, color)

    def text_z(self, cx, cy, s, color):
        self.line([(cx - s, cy - s), (cx + s, cy - s), (cx - s, cy + s), (cx + s, cy + s)], color, width=max(2, s / 3))

    def done(self):
        rgb = self.im.resize((W, W), Image.LANCZOS)
        m = Image.new("L", (P(W), P(W)), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, P(W) - 1, P(W) - 1], radius=P(52), fill=255)
        m = m.resize((W, W), Image.LANCZOS).point(lambda v: 255 if v >= 128 else 0)
        q = rgb.quantize(colors=63, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
        pal = q.getpalette()[:63 * 3]
        pal += [0, 0, 0] * (256 - 63)
        q.putpalette(pal)
        q.paste(63, mask=m.point(lambda v: 255 - v))
        return q


# ---------- peças ----------
LX, RX, EY = 82, 158, 100   # posição dos olhos
MY = 160                    # posição da boca


def blink_scale(f, period=N, at=16):
    """Pisca uma vez por ciclo."""
    k = (f - at) % period
    return {0: 0.55, 1: 0.1, 2: 0.55}.get(k, 1.0)


def eyes_normal(c, f, h=46, w=34, dx=0, dy=0, blink=True, color=EYE):
    s = blink_scale(f) if blink else 1
    for x in (LX, RX):
        c.rrect(x + dx, EY + dy, w, h * s, color, r=14)


def eyes_happy(c, dy=0, color=EYE):
    for x in (LX, RX):
        c.arc(x, EY + 8 + dy, 18, 16, 200, 340, color, width=10)


def eyes_closed(c, dy=0, color=EYE):
    for x in (LX, RX):
        c.arc(x, EY - 4 + dy, 18, 12, 20, 160, color, width=7)


def cheeks(c, alpha=1.0):
    col = tuple(int(FACE[i] + (BLUSH[i] - FACE[i]) * 0.55 * alpha) for i in range(3))
    for x in (LX - 22, RX + 22):
        c.ellipse(x, EY + 38, 15, 8, col)


def mouth_smile(c, w=26, h=14, dy=0, width=7):
    c.arc(120, MY - 8 + dy, w, h, 20, 160, MOUTH, width)


def mouth_open(c, w=26, h=20, dy=0):
    c.d.pieslice([P(120 - w), P(MY - h - 6 + dy), P(120 + w), P(MY + h - 6 + dy)], 0, 180, fill=MOUTH)
    c.d.pieslice([P(120 - w * 0.55), P(MY + h * 0.2 - 6 + dy), P(120 + w * 0.55), P(MY + h - 9 + dy)],
                 0, 180, fill=BLUSH)


def mouth_frown(c, w=22, h=12, dy=0):
    c.arc(120, MY + 8 + dy, w, h, 200, 340, MOUTH, 7)


def mouth_o(c, r=12, dy=0):
    c.ellipse(120, MY + dy, r * 0.8, r, MOUTH, width=6)


def mouth_flat(c, w=18, dy=0):
    c.line([(120 - w, MY + dy), (120 + w, MY + dy)], MOUTH, 7)


def tongue(c, dx=0, dy=0, down=10):
    c.rrect(120 + dx, MY + 4 + dy + down / 2, 16, 14 + down, BLUSH, r=8)


def bob(f, amp=3, speed=1):
    return amp * math.sin(2 * math.pi * f * speed / N)


# ---------- emoções ----------
def neutral(c, f):
    eyes_normal(c, f, dx=bob(f, 3, 1) if 4 < f < 12 else 0)
    mouth_smile(c, w=18, h=8)


def happy(c, f):
    b = abs(bob(f, 5, 2))
    eyes_happy(c, dy=-b)
    cheeks(c)
    mouth_smile(c, w=30, h=18, dy=-b)


def laughing(c, f):
    b = abs(bob(f, 6, 3))
    eyes_happy(c, dy=-b)
    cheeks(c)
    mouth_open(c, w=30, h=24, dy=-b)


def funny(c, f):
    b = bob(f, 4, 2)
    eyes_happy(c, dy=-abs(b))
    mouth_open(c, w=28, h=20, dy=-abs(b))
    c.ellipse(60 + abs(b), 60, 5, 7, TEAR)   # gotinha de riso


def silly(c, f):
    c.rrect(LX, EY, 34, 46, EYE, r=14)
    c.arc(RX, EY + 8, 18, 16, 200, 340, EYE, 8)
    mouth_smile(c, w=24, h=10)
    tongue(c, dx=8, down=8 + abs(bob(f, 6, 2)))


def sad(c, f):
    s = blink_scale(f)
    b = bob(f, 2, 1)
    for x, sgn in ((LX, -1), (RX, 1)):
        c.rrect(x, EY + 10 + b, 30, 32 * s, EYE, r=12)
        # sobrancelha triste: ponta de dentro mais alta
        c.line([(x - 18 * sgn, EY - 24), (x + 16 * sgn, EY - 14)], EYE, 6)
    mouth_frown(c, w=20, h=10, dy=b)


def crying(c, f):
    for x in (LX, RX):
        c.arc(x, EY + 2, 18, 12, 200, 340, EYE, 7)
    mouth_frown(c, w=24, h=14)
    for i, x in enumerate((LX - 6, RX + 6)):
        t = ((f + i * N // 2) % N) / N
        c.ellipse(x, EY + 18 + t * 70, 5, 8, TEAR)


def angry(c, f):
    # rosto a ficar vermelho (pulsa)
    k = 0.35 + 0.25 * abs(math.sin(2 * math.pi * f * 2 / N))
    face = tuple(int(FACE0[i] + ((150, 20, 30)[i] - FACE0[i]) * k) for i in range(3))
    c.d.rectangle([0, 0, P(W), P(W)], fill=face)
    sh = (3 if f % 2 else -3) if (f // 4) % 2 == 0 else 0      # tremer
    ey = EY + 8
    glow = (255, 60, 40)
    for x, sgn in ((LX, 1), (RX, -1)):
        xx = x + sh
        # olho em fenda, inclinado para dentro
        c.poly([(xx - 22, ey - 8 * sgn - 2), (xx + 22, ey + 8 * sgn - 2),
                (xx + 20, ey + 8 * sgn + 14), (xx - 20, ey - 8 * sgn + 14)], glow)
        c.ellipse(xx + 4 * sgn, ey + 5, 5, 5, (255, 230, 120))      # pupila brilhante
        # sobrancelha grossa em V
        c.line([(xx - 26 * sgn, ey - 30 - 10 * sgn * sgn + (0 if sgn > 0 else 0)),
                (xx + 22 * sgn, ey - 12)], (255, 90, 70), 10)
    # dentes cerrados
    mx, my = 120 + sh, MY + 6
    c.rrect(mx, my, 70, 26, (255, 90, 70), r=8)
    c.rrect(mx, my, 62, 18, (250, 245, 240), r=5)
    for i in range(1, 6):
        x = mx - 31 + i * 62 / 6
        c.line([(x, my - 8), (x, my + 8)], (150, 40, 40), 2.5)
    c.line([(mx - 30, my), (mx + 30, my)], (150, 40, 40), 2.5)
    # vapor a sair da cabeça
    for i, x0 in enumerate((42, 198)):
        t = ((f + i * N // 2) % N) / N
        r = 6 + t * 10
        col = tuple(int(face[j] + (235 - face[j]) * (1 - t) * 0.8) for j in range(3))
        c.ellipse(x0 + (t * 10 if i else -t * 10), 40 - t * 30, r, r * 0.8, col)
    # veia de raiva
    vx, vy = 172, 34
    for a, b in (((vx - 10, vy - 4), (vx - 2, vy - 2)), ((vx + 2, vy - 10), (vx + 4, vy - 2)),
                 ((vx + 10, vy + 4), (vx + 2, vy + 2)), ((vx - 4, vy + 10), (vx - 2, vy + 2))):
        c.line([a, b], (255, 70, 70), 4)


def surprised(c, f):
    g = 1 + 0.06 * math.sin(2 * math.pi * f / N)
    for x in (LX, RX):
        c.ellipse(x, EY, 20 * g, 24 * g, EYE)
    mouth_o(c, r=12 * g)


def shocked(c, f):
    sh = 3 if f % 2 else -3
    for x in (LX, RX):
        c.ellipse(x + sh, EY, 22, 26, EYE)
        c.ellipse(x + sh, EY, 8, 9, FACE)
    mouth_o(c, r=16)
    c.line([(200, 30), (200, 52)], WHITE, 6)
    c.ellipse(200, 64, 3.5, 3.5, WHITE)


def thinking(c, f):
    look = 8
    for x in (LX, RX):
        c.rrect(x + look, EY - 6, 30, 40 * blink_scale(f, at=20), EYE, r=13)
    c.line([(104, MY), (138, MY - 6)], MOUTH, 7)
    for i in range(3):
        on = (f // 6) % 4 > i
        if on:
            c.ellipse(170 + i * 16, 40, 5, 5, WHITE)


def sleepy(c, f):
    b = bob(f, 2, 1)
    eyes_closed(c, dy=b)
    mouth_o(c, r=7, dy=b)
    for i in range(2):
        t = ((f + i * N // 2) % N) / N
        c.text_z(175 + t * 25, 70 - t * 45, 6 + t * 5, WHITE)


def relaxed(c, f):
    b = bob(f, 3, 1)
    eyes_closed(c, dy=b)
    cheeks(c, 0.6)
    mouth_smile(c, w=20, h=10, dy=b)


def loving(c, f):
    g = 1 + 0.15 * abs(math.sin(2 * math.pi * f * 2 / N))
    for x in (LX, RX):
        c.heart(x, EY - 2, 24 * g, BLUSH)
    cheeks(c)
    mouth_smile(c, w=26, h=14)


def kissy(c, f):
    eyes_happy(c)
    cheeks(c)
    c.arc(118, MY - 6, 7, 6, 250, 110 + 360, MOUTH, 6)
    c.arc(118, MY + 6, 7, 6, 250, 110 + 360, MOUTH, 6)
    t = f / N
    c.heart(160 + t * 30, MY - 10 - t * 60, 12 + t * 6, BLUSH)


def winking(c, f):
    c.rrect(LX, EY, 34, 46, EYE, r=14)
    if 6 <= f < 18:
        c.arc(RX, EY + 6, 18, 14, 200, 340, EYE, 8)
    else:
        c.rrect(RX, EY, 34, 46 * blink_scale(f, at=3), EYE, r=14)
    mouth_smile(c, w=24, h=12)


def cool(c, f):
    c.rrect(120, EY - 2, 170, 10, (10, 12, 20), r=4)
    for x in (LX, RX):
        c.rrect(x, EY + 6, 56, 34, (10, 12, 20), r=12)
    # brilho a passar
    t = f / N
    gx = 50 + t * 150
    c.line([(gx, EY - 6), (gx + 10, EY + 18)], (120, 140, 180), 4)
    c.arc(132, MY - 10, 22, 12, 20, 120, MOUTH, 7)


def confident(c, f):
    s = blink_scale(f, at=18)
    # olhos ligeiramente semicerrados (topo reto = ar seguro)
    for x in (LX, RX):
        c.rrect(x, EY + 6, 34, 30 * s, EYE, r=12)
        c.d.rectangle([P(x - 20), P(EY - 14), P(x + 20), P(EY - 4)], fill=FACE0)
    # uma sobrancelha levantada, a outra reta
    c.line([(LX - 16, EY - 18), (LX + 16, EY - 18)], EYE, 6)
    up = 3 * abs(math.sin(2 * math.pi * f / N))
    c.arc(RX, EY - 14 - up, 18, 8, 200, 340, EYE, 6)
    # sorriso de canto (meio-sorriso)
    c.arc(128, MY - 14, 24, 14, 10, 100, MOUTH, 7)
    c.line([(104, MY), (120, MY)], MOUTH, 7)
    # brilho a piscar
    t = (f % N) / N
    if t < 0.5:
        k = 1 - abs(t - 0.25) * 4
        cx, cy, r = 196, 52, 4 + 8 * k
        c.poly([(cx, cy - r), (cx + r * 0.3, cy - r * 0.3), (cx + r, cy), (cx + r * 0.3, cy + r * 0.3),
                (cx, cy + r), (cx - r * 0.3, cy + r * 0.3), (cx - r, cy), (cx - r * 0.3, cy - r * 0.3)], WHITE)


def confused(c, f):
    c.rrect(LX, EY + 4, 30, 30 * blink_scale(f), EYE, r=12)
    c.rrect(RX, EY - 2, 38, 48 * blink_scale(f), EYE, r=15)
    c.line([(100, MY + 2), (112, MY - 4), (126, MY + 4), (140, MY - 2)], MOUTH, 6)
    b = bob(f, 4, 1)
    # ponto de interrogação
    c.arc(195, 48 + b, 11, 11, 180, 450, WHITE, 6)
    c.line([(195, 59 + b), (195, 68 + b)], WHITE, 6)
    c.ellipse(195, 80 + b, 3.5, 3.5, WHITE)


def embarrassed(c, f):
    for x in (LX, RX):
        c.rrect(x - 2, EY + 10, 30, 30 * blink_scale(f), EYE, r=12)
    cheeks(c, 0.8 + 0.4 * abs(math.sin(math.pi * f / N)))
    c.line([(106, MY), (114, MY - 4), (122, MY), (130, MY - 4), (138, MY)], MOUTH, 6)
    c.ellipse(190, 50 + f * 0.8, 5, 8, TEAR)   # gota de suor


def delicious(c, f):
    eyes_happy(c)
    cheeks(c)
    mouth_smile(c, w=28, h=14)
    t = math.sin(2 * math.pi * f * 2 / N)
    c.rrect(120 + 14 * t, MY + 4, 18, 16, BLUSH, r=9)


EMOTIONS = dict(neutral=neutral, happy=happy, laughing=laughing, funny=funny, silly=silly,
                sad=sad, crying=crying, angry=angry, surprised=surprised, shocked=shocked,
                thinking=thinking, sleepy=sleepy, relaxed=relaxed, loving=loving, kissy=kissy,
                winking=winking, cool=cool, confident=confident, confused=confused,
                embarrassed=embarrassed, delicious=delicious)

for name, fn in EMOTIONS.items():
    frames = []
    for f in range(N):
        c = Canvas()
        fn(c, f)
        frames.append(c.done())
    frames[0].save(os.path.join(OUT, f"{name}.gif"), save_all=True, append_images=frames[1:],
                   duration=DUR, loop=0, disposal=2, transparency=63, optimize=False)
print("ok", len(EMOTIONS))
