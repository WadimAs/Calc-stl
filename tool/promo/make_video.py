"""Builds the vertical (TikTok / Reels / Shorts) promo video of STL Вага.

Usage: python3 make_video.py SHOTS_DIR OUT.mp4 [--silent]

1080x1920. Per scene: a headline on top, the phone with one or two UI-test
screenshots (slide-in, cross-fade, slow zoom) and big word-timed captions.
The voice is Microsoft Edge neural TTS (uk-UA); --silent renders a preview
without network access, with estimated caption timing.
"""
import asyncio
import json
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1080, 1920, 30
ACCENT = (255, 122, 47)
VOICE = os.environ.get("PROMO_VOICE", "uk-UA-OstapNeural")
RATE = os.environ.get("PROMO_RATE", "+8%")
HERE = os.path.dirname(os.path.abspath(__file__))
LOGO = os.path.join(HERE, "..", "..", "assets", "logo.png")

# media: "shot:<png name from the UI test>" or "clip:<screen recording mark>".
SCENES = [
    {
        "title": "Скільки коштує\nваш 3D-друк?",
        "kicker": "STL Вага — рахує телефон",
        "media": ["clip:open"],
        "say": "Скільки насправді коштує ваш 3D-друк? Я зробив застосунок, який рахує це прямо в телефоні.",
    },
    {
        "title": "3D-перегляд",
        "kicker": "STL · 3MF · G-code",
        "media": ["clip:rotate"],
        "say": "Відкриваєте модель з файлів, Телеграму чи за посиланням — і крутите її, як у слайсері.",
    },
    {
        "title": "Вимірювання",
        "kicker": "відстані · кола · кути · отвори",
        "media": ["clip:holes"],
        "say": "Є вимірювання: відстані, кола й кути, а отвори застосунок знаходить сам.",
    },
    {
        "title": "Вага наживо",
        "kicker": "змінюєте — перераховує",
        "media": ["clip:infill"],
        "say": "Рухаєте заповнення — і вага з ціною перераховуються одразу.",
    },
    {
        "title": "Справжнє нарізання",
        "kicker": "шари · підтримки · дерева",
        "media": ["clip:supports", "clip:layers"],
        "say": "Застосунок справді нарізає модель на шари й рахує підтримки — навіть деревоподібні.",
    },
    {
        "title": "Чесна ціна",
        "kicker": "пластик · світло · знос · заробіток",
        "media": ["clip:cost"],
        "say": "У ціні — пластик, світло, знос принтера і ваш заробіток. А файли з Bambu Studio чи Orca дають точні цифри слайсера.",
    },
    {
        "title": "Замовлення і PDF",
        "kicker": "клієнти · терміни · рахунки",
        "media": ["clip:order", "clip:pdf"],
        "say": "Розрахунок одразу йде в замовлення: клієнт, термін із нагадуванням, і рахунок у PDF в один дотик.",
    },
    {
        "title": "Котушки з фото",
        "kicker": "розпізнавання етикетки",
        "media": ["clip:ocr", "clip:ocr2"],
        "say": "Котушку додаєте по фото етикетки: виробник, пластик, колір і навіть рефіл розпізнаються самі.",
    },
    {
        "title": "Bambu Lab і Klipper",
        "kicker": "автосписання пластику",
        "media": ["clip:printers", "clip:print"],
        "say": "Підключіть Bambu Lab — вдома чи через інтернет — або Klipper. Після друку застосунок сам запропонує списати пластик.",
    },
    {
        "title": "Ваша справа",
        "kicker": "статистика · прайс · автокопія",
        "media": ["clip:business"],
        "say": "Статистика покаже виручку, витрати й прибуток. А ще прайс-лист, клієнти й автокопія на Google Диск.",
    },
    {
        "title": "UA / EN · ₴ € $",
        "kicker": "мова й валюта",
        "media": ["clip:lang", "shot:37c_settings_eur"],
        "say": "Українська чи англійська, гривні, євро чи долари — як вам зручно.",
    },
    {
        "title": "Випускати\nдля всіх?",
        "kicker": "",
        "media": ["shot:05_result"],
        "say": "Поки що застосунок не в загальному доступі. Чи варто випустити його для всіх? Пишіть у коментарях!",
        "question": True,
    },
]

# Short, fast cut (PROMO_CUT=short): ~45 s for TikTok.
SCENES_SHORT = [
    {
        "title": "Друкуєте\nна замовлення?",
        "kicker": "тоді дивіться",
        "media": ["clip:open"],
        "say": "Друкуєте на замовлення і рахуєте ціну на око? Тоді дивіться.",
    },
    {
        "title": "Файл → ціна",
        "kicker": "грами · години · гроші",
        "media": ["clip:rotate", "clip:cost"],
        "say": "Кидаєте файл — і телефон сам рахує грами, години й гроші.",
    },
    {
        "title": "Міряйте\nпрямо на моделі",
        "kicker": "отвори знаходить сам",
        "media": ["clip:holes"],
        "say": "Треба перевірити розмір? Отвори застосунок знаходить сам.",
    },
    {
        "title": "Підтримки?\nТеж пораховано",
        "kicker": "навіть деревоподібні",
        "media": ["clip:supports", "clip:layers"],
        "say": "Підтримки, навіть деревоподібні, теж ідуть у вагу — шар за шаром.",
    },
    {
        "title": "Рахунок\nза хвилину",
        "kicker": "клієнт · термін · PDF",
        "media": ["clip:order", "clip:pdf"],
        "say": "Клієнт, термін і рахунок у PDF — усе за хвилину.",
    },
    {
        "title": "Сфоткали —\nкотушка додана",
        "kicker": "розпізнавання етикетки",
        "media": ["clip:ocr", "clip:ocr2"],
        "say": "Нова котушка? Сфоткали етикетку — і вона вже в списку.",
    },
    {
        "title": "Принтер\nсам звітує",
        "kicker": "Bambu Lab · Klipper",
        "media": ["clip:printers", "clip:print"],
        "say": "А принтер сам каже, скільки пластику пішло, і списує його з котушки.",
    },
    {
        "title": "Прибуток\nбез таблиць",
        "kicker": "статистика за місяць",
        "media": ["clip:business"],
        "say": "У кінці місяця — чистий прибуток без жодних таблиць.",
    },
    {
        "title": "Викладати\nдля всіх?",
        "kicker": "",
        "media": ["shot:05_result"],
        "say": "Поки що застосунок є тільки в мене. Викладати його для всіх? Пишіть у коментарях!",
        "question": True,
    },
]
SHORT = os.environ.get("PROMO_CUT", "") == "short"
if SHORT:
    SCENES = SCENES_SHORT

# Screenshot used when a recording is missing.
FALLBACK_SHOT = {
    "open": "04_model", "rotate": "04_model", "holes": "04_model", "infill": "05_result",
    "supports": "06_layers", "layers": "06_layers", "order": "13_order", "pdf": "17_invoice",
    "ocr": "32_spool_dialog", "ocr2": "32b_label_ocr", "printers": "33a_printer_kinds", "print": "32e_print_finished", "lang": "42_en_model",
    "cost": "09_settings_cost", "business": "37_stats_after",
}

INTER = "/usr/share/fonts/opentype/inter/"


def font(size, weight="Regular"):
    for p in [INTER + f"Inter-{weight}.otf", INTER + "Inter-Bold.otf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


F_TITLE = font(84, "ExtraBold")
F_KICK = font(40, "SemiBold")
F_CAP = font(68, "Black")
F_Q = font(120, "Black")
F_Q2 = font(54, "Bold")


def background():
    bg = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(30 + 10 * t), int(22 + 4 * t), int(36 - 10 * t)))
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.3, H * 0.15, W * 1.3, H * 0.85], fill=(140, 58, 20))
    glow = glow.filter(ImageFilter.GaussianBlur(200))
    return Image.blend(bg, glow, 0.4)


BG = None
SCREEN_W, SCREEN_H = 600, 1300


def fit_screen(img):
    from PIL import ImageOps

    return ImageOps.fit(img.convert("RGB"), (SCREEN_W, SCREEN_H), Image.LANCZOS, centering=(0.5, 0.0))


def phone(shot):
    sw, sh = SCREEN_W, SCREEN_H
    if shot.size != (sw, sh):
        shot = fit_screen(shot)
    pad = 18
    img = Image.new("RGBA", (sw + 2 * pad, sh + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=66, fill=(10, 10, 12, 255))
    d.rounded_rectangle([1, 1, img.width - 2, img.height - 2], radius=66, outline=(70, 70, 78, 255), width=2)
    scr = shot
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=50, fill=255)
    img.paste(scr, (pad, pad), mask)
    return img


def make_shadow(ph):
    sh = Image.new("RGBA", (ph.width + 120, ph.height + 120), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([60, 80, ph.width + 60, ph.height + 80], radius=70, fill=(0, 0, 0, 170))
    return sh.filter(ImageFilter.GaussianBlur(36))


def ease(t):
    t = max(0.0, min(1.0, t))
    return 1 - (1 - t) ** 3


def centered(d, y, text, f, fill, stroke=0, stroke_fill=None):
    w = f.getlength(text)
    d.text(((W - w) / 2, y), text, font=f, fill=fill, stroke_width=stroke, stroke_fill=stroke_fill)


def wrap(text, f, width):
    lines, cur = [], ""
    for w in text.split():
        t = (cur + " " + w).strip()
        if f.getlength(t) <= width or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


LOGO_IMG = None
PHONE_TOP = 430


TOUCH_R = 30  # finger mark radius on the screen image (SCREEN_W wide), px
TOUCH_FADE = 380  # ms of the release ripple


def load_touches(clips_dir):
    """PROMO_VIEW / PROMO_TOUCH lines -> (view, {pointer: [(ms, kind, x, y)]})."""
    view, touches = None, {}
    p = os.path.join(clips_dir, "marks.txt")
    if not os.path.exists(p):
        return None, {}
    for line in open(p, encoding="utf-8", errors="replace"):
        parts = line.split()
        try:
            if parts[0] == "PROMO_VIEW":
                view = (float(parts[1]), float(parts[2]), float(parts[3]))
            elif parts[0] == "PROMO_TOUCH":
                touches.setdefault(parts[1], []).append(
                    (int(parts[5]), parts[2], float(parts[3]), float(parts[4])))
        except (IndexError, ValueError):
            pass
    return view, touches


def touch_marks(view, touches, t_ms):
    """Finger marks at device time t_ms: list of (x, y, kind, progress)."""
    if not view:
        return []
    pw, ph, dpr = view
    # The Flutter view ends above the navigation bar, i.e. where the frame is cropped.
    sx, sy = SCREEN_W * dpr / pw, SCREEN_H * dpr / ph
    out = []
    for evs in touches.values():
        down = evs[0][0]
        up = next((e[0] for e in evs if e[1] == "up"), evs[-1][0])
        if t_ms < down or t_ms > up + TOUCH_FADE:
            continue
        pos = evs[0]
        for e in evs:
            if e[0] <= t_ms:
                pos = e
            else:
                break
        x, y = pos[2] * sx, pos[3] * sy
        if t_ms <= up:
            out.append((x, y, "hold", min(1.0, (t_ms - down) / 120.0)))
        else:
            out.append((x, y, "release", (t_ms - up) / TOUCH_FADE))
    return out


def draw_touches(img, marks):
    if not marks:
        return img
    img = img.convert("RGBA")
    k = 3  # supersampling for smooth circles
    for x, y, kind, p in marks:
        if kind == "hold":
            r = TOUCH_R * (0.7 + 0.3 * ease(p))
            fill_a, ring_a, ring_r = 110, 235, r
        else:
            q = ease(p)
            r = TOUCH_R
            fill_a, ring_a, ring_r = int(110 * (1 - q) ** 2), int(235 * (1 - q)), TOUCH_R * (1 + 1.1 * q)
        size = int((ring_r + 10) * 2)
        patch = Image.new("RGBA", (size * k, size * k), (0, 0, 0, 0))
        d = ImageDraw.Draw(patch)
        c = size * k / 2
        if fill_a > 0:
            d.ellipse([c - (r + 3) * k, c - (r + 3) * k, c + (r + 3) * k, c + (r + 3) * k],
                      outline=(0, 0, 0, int(fill_a * 0.5)), width=2 * k)
            d.ellipse([c - r * k, c - r * k, c + r * k, c + r * k], fill=(255, 255, 255, fill_a))
        if ring_a > 0:
            d.ellipse([c - ring_r * k, c - ring_r * k, c + ring_r * k, c + ring_r * k],
                      outline=ACCENT + (ring_a,), width=4 * k)
        patch = patch.resize((size, size), Image.LANCZOS)
        img.alpha_composite(patch, (int(x - size / 2), int(y - size / 2)))
    return img.convert("RGB")


class Clip:
    """Frames of a screen recording between two PROMO_MARKs (decoded on demand)."""

    def __init__(self, folder, idx, start_ms=None, view=None, touches=None):
        self.folder, self.n = folder, idx
        self.start_ms, self.view, self.touches = start_ms, view, touches or {}
        self.cache = {}

    def get(self, i):
        i = max(0, min(self.n - 1, i))
        if i not in self.cache:
            if len(self.cache) > 4:
                self.cache.clear()
            img = Image.open(os.path.join(self.folder, f"{i + 1:05d}.jpg"))
            if self.start_ms is not None:
                img = draw_touches(img, touch_marks(self.view, self.touches, self.start_ms + i * 1000.0 / FPS))
            self.cache[i] = phone(img)
        return self.cache[i]


def load_marks(clips_dir):
    marks = {}
    p = os.path.join(clips_dir, "marks.txt")
    if not os.path.exists(p):
        return marks
    for line in open(p, encoding="utf-8", errors="replace"):
        parts = line.split()
        if len(parts) >= 4 and parts[0] == "PROMO_MARK" and parts[2] in ("start", "end"):
            marks.setdefault(parts[1], {})[parts[2]] = int(parts[3])
    return marks


END_FADE = 0.9  # seconds of fade to black at the end
MUSIC_VOL = float(os.environ.get("PROMO_MUSIC_VOL", "0.28" if SHORT else "0.22"))  # music level under the voice
MUSIC_FADE = 3.5  # seconds of music fade-out at the end
MAX_SPEED = 3.5 if SHORT else 2.5  # fastest playback of a screen recording
MAX_SCENE = 5.5 if SHORT else 11.0  # longest scene stretched for a recording, seconds
VOICE_SPEED = float(os.environ.get("PROMO_SPEED", "1.1" if SHORT else "1.0"))
REC_LATENCY = float(os.environ.get("PROMO_REC_LATENCY", "0.6"))


def extract_clip(clips_dir, marks, name, tmp):
    m = marks.get(name)
    if not m or "start" not in m or "end" not in m:
        print(f"clip {name}: no marks", flush=True)
        return None
    recs = []
    for f in os.listdir(clips_dir):
        if f.startswith("rec_") and f.endswith(".mp4"):
            try:
                recs.append((int(f[4:-4]), f))
            except ValueError:
                pass
    recs = sorted((t, f, duration(os.path.join(clips_dir, f))) for t, f in recs)
    folder = os.path.join(tmp, "clip_" + name)
    os.makedirs(folder, exist_ok=True)
    # Recordings overlap; a long clip is stitched from consecutive ones.
    cursor, end, used = m["start"], m["end"] + 200, []
    while cursor < end - 100:
        cand = [r for r in recs if r[0] + REC_LATENCY * 1000 <= cursor and r[0] + r[2] * 1000 > cursor + 300]
        if not cand:
            break
        t0, f, d = cand[0]  # the earliest one that still runs: longest stretch from one file
        seg_end = min(end, t0 + d * 1000 - 100)
        off = max(0.0, (cursor - t0) / 1000.0 - REC_LATENCY)
        length = (seg_end - cursor) / 1000.0
        first = len([x for x in os.listdir(folder) if x.endswith(".jpg")]) + 1
        # Crop the navigation bar at the bottom (screenshots do not have it either).
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{off:.2f}", "-t", f"{length:.2f}",
                        "-i", os.path.join(clips_dir, f),
                        "-vf", f"fps={FPS},crop=iw:ih*0.974:0:0,scale={SCREEN_W}:{SCREEN_H}",
                        "-start_number", str(first), "-q:v", "3", os.path.join(folder, "%05d.jpg")], check=True)
        used.append(f"{f}+{off:.1f}s/{length:.1f}s")
        cursor = seg_end
    if not used:
        print(f"clip {name}: no recording", flush=True)
        return None
    n = len([x for x in os.listdir(folder) if x.endswith(".jpg")])
    print(f"clip {name}: {' '.join(used)}, {n} frames", flush=True)
    view, touches = load_touches(clips_dir)
    return Clip(folder, n, m["start"], view, touches) if n else None


def frame(scene, phones, shadow, t, dur, caption, global_t, total):
    img = BG.copy()
    appear = ease(t / 0.5)
    q = scene.get("question")

    # Phone with slow zoom and a cross-fade to the second screenshot.
    if len(phones) == 1:
        base = phones[0](t, 0)
    else:
        half = dur / len(phones)
        k = (t - half + 0.2) / 0.4
        if k <= 0:
            base = phones[0](t, 0)
        elif k >= 1:
            base = phones[1](t - half, 1)
        else:
            base = Image.blend(phones[0](t, 0), phones[1](t - half, 1), ease(k))
    zoom = 1.0 + (0.04 if scene.get("static") else 0.012) * (t / max(dur, 0.1))
    ph = base.resize((int(base.width * zoom), int(base.height * zoom)), Image.BILINEAR)
    slide = (1 - appear) * 160
    cx = W / 2
    top = PHONE_TOP + slide
    if q:
        ph = ph.filter(ImageFilter.GaussianBlur(10))
    img.paste(shadow, (int(cx - base.width / 2 - 60), int(top - 60)), shadow)
    img.paste(ph, (int(cx - ph.width / 2), int(top - (ph.height - base.height) / 2)), ph)

    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    a = int(255 * appear)

    if q:
        # Dark veil and the big question.
        ld.rectangle([0, 0, W, H], fill=(14, 10, 18, int(170 * appear)))
        y = 560 - int((1 - appear) * 60)
        if LOGO_IMG is not None:
            lg = LOGO_IMG.resize((200, 200), Image.LANCZOS)
            layer.alpha_composite(lg, (int(W / 2 - 100), y - 260))
        for line in scene["title"].split("\n"):
            centered(ld, y, line, F_Q, (255, 255, 255, a), 6, (0, 0, 0, a))
            y += 140
        # Yes / No buttons pulse in after the question is asked.
        b = ease((t - 2.0) / 0.5)
        if b > 0:
            pulse = 1 + 0.04 * math.sin(t * 5)
            for i, (lbl, col) in enumerate([("ТАК", (46, 170, 90)), ("НІ", (210, 60, 60))]):
                bw, bh = int(300 * pulse), int(130 * pulse)
                bx = int(W / 2 + (-1 if i == 0 else 1) * 185 - bw / 2)
                by = int(y + 70 - bh / 2 + 65 + (1 - b) * 80)
                ld.rounded_rectangle([bx, by, bx + bw, by + bh], radius=34, fill=col + (int(255 * b),))
                tw = F_Q2.getlength(lbl)
                ld.text((bx + (bw - tw) / 2, by + bh / 2 - 34), lbl, font=F_Q2, fill=(255, 255, 255, int(255 * b)))
        c = ease((t - 3.0) / 0.5)
        if c > 0:
            centered(ld, y + 330, "Пишіть у коментарях ↓", F_Q2, (255, 200, 160, int(255 * c)))
    else:
        # Headline on top.
        y = 120 - int((1 - appear) * 40)
        ld.rounded_rectangle([W / 2 - 50, y - 26, W / 2 + 50, y - 18], radius=4, fill=ACCENT + (a,))
        for line in scene["title"].split("\n"):
            centered(ld, y, line, F_TITLE, (255, 255, 255, a))
            y += 98
        if scene["kicker"]:
            centered(ld, y + 8, scene["kicker"], F_KICK, (255, 190, 150, a))

    # Captions: big, centered, stroked, in the lower third (above TikTok's own UI).
    if caption:
        lines = wrap(caption, F_CAP, 940)
        cy = 1330 - 40 * (len(lines) - 1)
        for line in lines:
            w = F_CAP.getlength(line)
            pad = 22
            ld.rounded_rectangle([(W - w) / 2 - pad, cy - 6, (W + w) / 2 + pad, cy + 86], radius=20,
                                 fill=(0, 0, 0, 120))
            centered(ld, cy, line, F_CAP, (255, 255, 255, 255), 5, (0, 0, 0, 255))
            cy += 96

    # Thin progress bar at the very top.
    ld.rectangle([0, 0, int(W * global_t / total), 6], fill=ACCENT + (230,))
    img.paste(layer, (0, 0), layer)
    return img


def chunks(words, max_chars=20):
    """Groups (start, end, word) into caption chunks of a few words."""
    out, cur = [], []
    for w in words:
        text = " ".join(x[2] for x in cur + [w])
        if cur and (len(text) > max_chars or cur[-1][2][-1] in ".,?!:—"):
            out.append(cur)
            cur = [w]
        else:
            cur.append(w)
    if cur:
        out.append(cur)
    return [(c[0][0], c[-1][1], " ".join(x[2] for x in c)) for c in out]


def estimate_words(text, speech):
    ws = text.split()
    total = sum(len(w) + 1 for w in ws)
    acc, out = 0.0, []
    for w in ws:
        d = speech * (len(w) + 1) / total
        out.append((acc, acc + d, w))
        acc += d
    return out


EL_KEY = os.environ.get("ELEVENLABS_API_KEY", "").strip()
EL_VOICE = os.environ.get("ELEVEN_VOICE", "").strip() or "JBFqnCBsd6RMkjVDRZzb"
EL_MODEL = os.environ.get("ELEVEN_MODEL", "").strip() or "eleven_multilingual_v2"


def eleven(text, path, prev="", nxt=""):
    """ElevenLabs TTS with character timestamps -> list of (start, end, word)."""
    import base64
    import urllib.request

    body = {
        "text": text,
        "model_id": EL_MODEL,
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.8, "style": 0.3 if SHORT else 0.25,
                           "use_speaker_boost": True, "speed": VOICE_SPEED},
    }
    if EL_MODEL != "eleven_v3":
        body["previous_text"], body["next_text"] = prev, nxt
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{EL_VOICE}/with-timestamps?output_format=mp3_44100_128",
        data=json.dumps(body).encode(), method="POST",
        headers={"xi-api-key": EL_KEY, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            res = json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"ElevenLabs HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")
    with open(path, "wb") as fh:
        fh.write(base64.b64decode(res["audio_base64"]))
    al = res.get("alignment") or res.get("normalized_alignment") or {}
    chars = al.get("characters") or []
    st = al.get("character_start_times_seconds") or []
    en = al.get("character_end_times_seconds") or []
    words, cur, s0, e0 = [], "", None, None
    for c, a, b in zip(chars, st, en):
        if c.isspace():
            if cur:
                words.append((s0, e0, cur))
            cur, s0 = "", None
            continue
        if s0 is None:
            s0 = a
        cur += c
        e0 = b
    if cur:
        words.append((s0, e0, cur))
    return words


async def tts(text, path):
    import edge_tts

    words = []
    try:
        com = edge_tts.Communicate(text, VOICE, rate=RATE, boundary="WordBoundary")
    except TypeError:
        com = edge_tts.Communicate(text, VOICE, rate=RATE)
    with open(path, "wb") as fh:
        async for ch in com.stream():
            if ch["type"] == "audio":
                fh.write(ch["data"])
            elif ch["type"] == "WordBoundary":
                s = ch["offset"] / 1e7
                words.append((s, s + ch["duration"] / 1e7, ch["text"]))
    return words


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                       capture_output=True, text=True)
    return float(json.loads(r.stdout)["format"]["duration"])


def attach_punct(words, text):
    """Edge returns words without punctuation; take the original tokens instead when counts match."""
    toks = [t for t in text.split() if any(ch.isalnum() for ch in t)]
    if len(toks) == len(words):
        return [(s, e, t) for (s, e, _), t in zip(words, toks)]
    return words


def main():
    global BG, LOGO_IMG
    shots_dir, out = sys.argv[1], sys.argv[2]
    silent = "--silent" in sys.argv
    only = os.environ.get("PROMO_ONLY")  # e.g. "7" renders one scene for previews
    BG = background()
    if os.path.exists(LOGO):
        LOGO_IMG = Image.open(LOGO).convert("RGBA")
    tmp = tempfile.mkdtemp()
    audio_parts, timeline = [], []
    scenes = [SCENES[int(only)]] if only else SCENES
    clips_dir = os.environ.get("PROMO_CLIPS", "")
    marks = load_marks(clips_dir) if clips_dir else {}

    def clip_need(sc):
        """Seconds of screen recording the scene should show (sped up to MAX_SPEED)."""
        need = 0.0
        for item in sc["media"]:
            kind, name = item.split(":", 1)
            m = marks.get(name, {})
            if kind == "clip" and "start" in m and "end" in m:
                need += (m["end"] - m["start"]) / 1000.0 / MAX_SPEED
        return min(need, MAX_SCENE)

    for i, sc in enumerate(scenes):
        wav = os.path.join(tmp, f"s{i}.wav")
        if silent:
            speech = max(2.5, len(sc["say"]) / 15.5)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono",
                            "-t", f"{speech:.2f}", wav], check=True)
            words = estimate_words(sc["say"], speech)
        else:
            mp3 = os.path.join(tmp, f"s{i}.mp3")
            if EL_KEY:
                prev = scenes[i - 1]["say"] if i > 0 else ""
                nxt = scenes[i + 1]["say"] if i + 1 < len(scenes) else ""
                words = eleven(sc["say"], mp3, prev, nxt)
            else:
                words = asyncio.run(tts(sc["say"], mp3))
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-ar", "24000", "-ac", "1", wav], check=True)
            speech = duration(wav)
            if not EL_KEY:
                words = attach_punct(words, sc["say"])
            words = words or estimate_words(sc["say"], speech)
        lead = 0.1 if SHORT else 0.2
        tail = (3.4 if SHORT else 4.2) if sc.get("question") else (0.12 if SHORT else 0.35)
        # Let the recording play out a bit after the voice when it needs more time.
        tail = max(tail, clip_need(sc) - speech - lead)
        padded = os.path.join(tmp, f"p{i}.wav")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-af",
                        f"adelay={int(lead * 1000)},apad=pad_dur={tail}", "-ar", "24000", "-ac", "1", padded],
                       check=True)
        dur = duration(padded)
        audio_parts.append(padded)
        caps = [(s + lead, e + lead, txt) for s, e, txt in chunks(words)]
        timeline.append((sc, dur, caps))
        print(f"scene {i}: {dur:.1f}s, {len(words)} words", flush=True)

    total = sum(t[1] for t in timeline)
    video = os.path.join(tmp, "video.mp4")
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                             "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
                             "-pix_fmt", "yuv420p", video], stdin=subprocess.PIPE)
    gt = 0.0
    for sc, dur, caps in timeline:
        players = []
        slot = dur / len(sc["media"])
        for item in sc["media"]:
            kind, name = item.split(":", 1)
            clip = extract_clip(clips_dir, marks, name, tmp) if kind == "clip" and clips_dir else None
            if clip is not None:
                clip_len = clip.n / FPS
                speed = min(MAX_SPEED, max(1.0, clip_len / max(slot, 0.5)))
                players.append(lambda tt, _i, c=clip, sp=speed: c.get(int(tt * sp * FPS)))
                continue
            if kind == "clip":
                name = FALLBACK_SHOT.get(name, "05_result")
            p = os.path.join(shots_dir, name + ".png")
            shot = Image.open(p).convert("RGB") if os.path.exists(p) else Image.new("RGB", (540, 1169), (40, 40, 40))
            img = phone(shot)
            players.append(lambda tt, _i, im=img: im)
        sc["static"] = all(m.startswith("shot:") for m in sc["media"])
        shadow = make_shadow(players[0](0, 0))
        phones = players
        n = int(round(dur * FPS))
        for f in range(n):
            t = f / FPS
            cap = None
            for k, (s, e, txt) in enumerate(caps):
                nxt = caps[k + 1][0] if k + 1 < len(caps) else e + 0.6
                if s <= t < nxt:
                    cap = txt
                    break
            img = frame(sc, phones, shadow, t, dur, cap, gt + t, total).convert("RGB")
            left = total - (gt + t)
            if left < END_FADE:  # gentle fade to black at the very end
                img = Image.blend(Image.new("RGB", img.size), img, max(0.0, left / END_FADE))
            proc.stdin.write(img.tobytes())
        gt += dur
    proc.stdin.close()
    proc.wait()

    lst = os.path.join(tmp, "list.txt")
    with open(lst, "w") as fh:
        for p in audio_parts:
            fh.write(f"file '{p}'\n")
    audio = os.path.join(tmp, "audio.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", audio],
                   check=True)
    music = os.environ.get("PROMO_MUSIC", "")
    if music and os.path.exists(music):
        # Music loops under the voice, ducks while the voice speaks (sidechain)
        # and fades in/out with the picture; the voice itself is untouched.
        fade_st = max(0.0, total - MUSIC_FADE)
        graph = (
            "[1:a]aresample=44100,aformat=channel_layouts=stereo,asplit=2[v][key];"
            f"[2:a]aresample=44100,aformat=channel_layouts=stereo,atrim=0:{total:.2f},asetpts=N/SR/TB,"
            f"volume={MUSIC_VOL},afade=t=in:d=1.2,afade=t=out:st={fade_st:.2f}:d={MUSIC_FADE}[m];"
            "[m][key]sidechaincompress=threshold=0.02:ratio=6:attack=30:release=600:makeup=1[duck];"
            "[v][duck]amix=inputs=2:duration=first:normalize=0,loudnorm=I=-14:TP=-1.5:LRA=9[a]")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", audio, "-stream_loop", "-1", "-i", music,
                        "-filter_complex", graph, "-map", "0:v", "-map", "[a]", "-c:v", "copy", "-c:a", "aac",
                        "-b:a", "192k", "-t", f"{total:.2f}", "-movflags", "+faststart", out], check=True)
        print("music", music, flush=True)
    else:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", audio, "-c:v", "copy", "-c:a", "aac",
                        "-b:a", "160k", "-af", "loudnorm=I=-14:TP=-1.5", "-shortest", "-movflags", "+faststart", out],
                       check=True)
    print("video", out, f"{total:.1f}s")


if __name__ == "__main__":
    main()
