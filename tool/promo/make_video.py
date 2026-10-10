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
        "media": ["clip:ocr"],
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

# Screenshot used when a recording is missing.
FALLBACK_SHOT = {
    "open": "04_model", "rotate": "04_model", "holes": "04_model", "infill": "05_result",
    "supports": "06_layers", "layers": "06_layers", "order": "13_order", "pdf": "17_invoice",
    "ocr": "32b_label_ocr", "printers": "33a_printer_kinds", "print": "32e_print_finished", "lang": "42_en_model",
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


class Clip:
    """Frames of a screen recording between two PROMO_MARKs (decoded on demand)."""

    def __init__(self, folder, idx):
        self.folder, self.n = folder, idx
        self.cache = {}

    def get(self, i):
        i = max(0, min(self.n - 1, i))
        if i not in self.cache:
            if len(self.cache) > 4:
                self.cache.clear()
            self.cache[i] = phone(Image.open(os.path.join(self.folder, f"{i + 1:05d}.jpg")))
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
    recs = [r for r in sorted(recs) if r[0] <= m["start"]]
    if not recs:
        print(f"clip {name}: no recording", flush=True)
        return None
    t0, f = recs[-1]
    off = max(0.0, (m["start"] - t0) / 1000.0 - REC_LATENCY)
    length = (m["end"] - m["start"]) / 1000.0 + 0.2
    folder = os.path.join(tmp, "clip_" + name)
    os.makedirs(folder, exist_ok=True)
    # Crop the navigation bar at the bottom (screenshots do not have it either).
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{off:.2f}", "-t", f"{length:.2f}",
                    "-i", os.path.join(clips_dir, f),
                    "-vf", f"fps={FPS},crop=iw:ih*0.974:0:0,scale={SCREEN_W}:{SCREEN_H}",
                    "-q:v", "3", os.path.join(folder, "%05d.jpg")], check=True)
    n = len([x for x in os.listdir(folder) if x.endswith(".jpg")])
    print(f"clip {name}: {f} +{off:.1f}s, {length:.1f}s, {n} frames", flush=True)
    return Clip(folder, n) if n else None


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
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.8, "style": 0.25, "use_speaker_boost": True},
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
        lead = 0.2
        tail = 2.6 if sc.get("question") else 0.35
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
    clips_dir = os.environ.get("PROMO_CLIPS", "")
    marks = load_marks(clips_dir) if clips_dir else {}
    for sc, dur, caps in timeline:
        players = []
        slot = dur / len(sc["media"])
        for item in sc["media"]:
            kind, name = item.split(":", 1)
            clip = extract_clip(clips_dir, marks, name, tmp) if kind == "clip" and clips_dir else None
            if clip is not None:
                clip_len = clip.n / FPS
                speed = min(2.2, max(1.0, clip_len / max(slot, 0.5)))
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
            proc.stdin.write(frame(sc, phones, shadow, t, dur, cap, gt + t, total).convert("RGB").tobytes())
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
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", audio, "-c:v", "copy", "-c:a", "aac",
                    "-b:a", "160k", "-af", "loudnorm=I=-14:TP=-1.5", "-shortest", "-movflags", "+faststart", out],
                   check=True)
    print("video", out, f"{total:.1f}s")


if __name__ == "__main__":
    main()
