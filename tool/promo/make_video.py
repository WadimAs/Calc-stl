"""Builds the promo video of STL Вага from UI-test screenshots and a voice-over.

Usage: python3 make_video.py SHOTS_DIR OUT.mp4 [--silent]

Per scene: a headline on the left, the phone with one or two screenshots on
the right (cross-fade, slow zoom), subtitles = the narration. The voice is
Microsoft Edge neural TTS (uk-UA), or silence with --silent for previews.
"""
import asyncio
import json
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H, FPS = 1920, 1080, 30
ACCENT = (255, 122, 47)
VOICE = os.environ.get("PROMO_VOICE", "uk-UA-OstapNeural")

SCENES = [
    {
        "title": "STL Вага",
        "kicker": "калькулятор 3D-друку у телефоні",
        "shots": ["04_model"],
        "say": "Знайомтесь: STL Вага — застосунок, який рахує вагу, час і вартість 3D-друку прямо у вашому телефоні.",
        "card": True,
    },
    {
        "title": "Справжнє нарізання",
        "kicker": "STL · 3MF · G-code",
        "shots": ["04_model", "06_layers"],
        "say": "Відкрийте модель STL, 3MF чи G-code — з файлів, із Телеграму або за посиланням. "
        "Застосунок нарізає її, як слайсер, і показує шари, стінки та підтримки.",
    },
    {
        "title": "Вага, час і ціна",
        "kicker": "за секунди",
        "shots": ["05_result", "09_settings_cost"],
        "say": "За кілька секунд ви бачите вагу пластику, довжину філаменту й час друку. "
        "Ціна — чесна: пластик, електроенергія, знос принтера і ваш заробіток. "
        "Файли з Bambu Studio чи Orca дають точні цифри слайсера.",
    },
    {
        "title": "Замовлення",
        "kicker": "клієнти · терміни · нагадування",
        "shots": ["13_order", "15_order_due"],
        "say": "Додайте розрахунок до замовлення: клієнт, термін із нагадуванням, знижки від кількості й доплати.",
    },
    {
        "title": "Рахунок у PDF",
        "kicker": "з вашими реквізитами",
        "shots": ["16_quote", "17_invoice"],
        "say": "Пропозицію або рахунок у PDF — з вашими реквізитами й фото готового виробу — "
        "можна надіслати клієнту в один дотик.",
    },
    {
        "title": "Котушки з фото",
        "kicker": "розпізнавання етикетки",
        "shots": ["32b_label_ocr", "32h_spool_icons"],
        "say": "Котушку додають по фото етикетки: застосунок сам розпізнає виробника, пластик, колір і вагу — "
        "навіть рефіли й двоколірний шовковий PLA.",
    },
    {
        "title": "Принтери онлайн",
        "kicker": "Bambu Lab · Klipper",
        "shots": ["33a_printer_kinds", "34a_bambu_login"],
        "say": "Підключіть принтер Bambu Lab — вдома або через інтернет — чи Klipper. "
        "Статус друку та залишок пластику в AMS видно наживо.",
    },
    {
        "title": "Автосписання",
        "kicker": "після кожного друку",
        "shots": ["32e_print_finished", "32g_writeoffs"],
        "say": "Коли друк завершено, застосунок запропонує списати пластик з потрібної котушки — "
        "для замовлення, для себе чи як брак. Усе записується в журнал.",
    },
    {
        "title": "Прибуток під контролем",
        "kicker": "статистика · витрати",
        "shots": ["37_stats_after", "22_catalog"],
        "say": "Статистика покаже виручку, витрати й чистий прибуток за кожен місяць, "
        "а прайс-лист готових виробів завжди під рукою.",
    },
    {
        "title": "Просто або професійно",
        "kicker": "українською та англійською",
        "shots": ["38_simple_mode", "42_en_model"],
        "say": "Простий режим — для швидкого розрахунку, розширений — для вашої справи. Українською або англійською.",
    },
    {
        "title": "STL Вага",
        "kicker": "друкуйте з розрахунком",
        "shots": ["05_result"],
        "say": "STL Вага. Друкуйте з розрахунком.",
        "card": True,
        "outro": True,
    },
]


def font(size, bold=False):
    for p in [
        "/usr/share/fonts/opentype/inter/Inter-Bold.otf" if bold else "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" if bold else "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        os.path.join(os.path.dirname(__file__), "Inter-Bold.otf" if bold else "Inter-Regular.otf"),
    ]:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


F_TITLE = font(84, True)
F_KICK = font(36)
F_SUB = font(34)
F_SMALL = font(28)


def background():
    bg = Image.new("RGB", (W, H), (24, 20, 28))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=(int(28 + 14 * t), int(22 + 6 * t), int(34 - 6 * t)))
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse([W * 0.45, -H * 0.3, W * 1.25, H * 0.9], fill=(120, 52, 18))
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    return Image.blend(bg, glow, 0.35)


BG = None


def phone(shot, scale):
    """Screenshot in a phone frame, returns RGBA image."""
    sw, sh = 470, int(470 * shot.height / shot.width)
    sw, sh = int(sw * scale), int(sh * scale)
    pad = int(16 * scale)
    img = Image.new("RGBA", (sw + 2 * pad, sh + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=int(56 * scale), fill=(12, 12, 14, 255))
    scr = shot.resize((sw, sh), Image.LANCZOS)
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=int(42 * scale), fill=255)
    img.paste(scr, (pad, pad), mask)
    return img


def wrap(text, f, width):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if f.getlength(t) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def ease(t):
    return 0.5 - 0.5 * math.cos(math.pi * max(0.0, min(1.0, t)))


def make_shadow(ph):
    sh = Image.new("RGBA", (ph.width + 80, ph.height + 80), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([40, 50, ph.width + 40, ph.height + 50], radius=60, fill=(0, 0, 0, 150))
    return sh.filter(ImageFilter.GaussianBlur(28))


def frame(scene, phones, shadow, t, dur, sub_lines):
    img = BG.copy()
    appear = ease(t / 0.6)
    # Phone (right), slow zoom, cross-fade between the scene's screenshots.
    if len(phones) == 1:
        base = phones[0]
    else:
        k = ease((t - dur / 2 + 0.4) / 0.8)
        base = phones[0] if k <= 0 else (phones[1] if k >= 1 else Image.blend(phones[0], phones[1], k))
    zoom = 1.0 + 0.035 * (t / max(dur, 0.1))
    ph = base.resize((int(base.width * zoom), int(base.height * zoom)), Image.BILINEAR)
    px = int(W * 0.66 - ph.width / 2 + (1 - appear) * 80)
    py = int(H / 2 - ph.height / 2)
    img.paste(shadow, (int(W * 0.66 - base.width / 2) - 40 + int((1 - appear) * 80), int(H / 2 - base.height / 2) - 40), shadow)
    img.paste(ph, (px, py), ph)

    # Headline (left).
    x0 = 120
    alpha = int(255 * appear)
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    y = 300 if not scene.get("card") else 380
    ld.rectangle([x0, y - 34, x0 + 90, y - 26], fill=ACCENT + (alpha,))
    for line in wrap(scene["title"], F_TITLE, 760):
        ld.text((x0, y), line, font=F_TITLE, fill=(255, 255, 255, alpha))
        y += 100
    ld.text((x0, y + 6), scene["kicker"], font=F_KICK, fill=(255, 190, 150, alpha))
    if scene.get("outro"):
        ld.text((x0, y + 90), "github.com/WadimAs/Calc-stl/releases", font=F_SMALL, fill=(220, 220, 230, alpha))
    # Subtitles (bottom left).
    if sub_lines:
        sy = H - 90 - 46 * len(sub_lines)
        box_w = max(F_SUB.getlength(l) for l in sub_lines) + 48
        ld.rounded_rectangle([x0 - 24, sy - 18, x0 - 24 + box_w, sy + 46 * len(sub_lines) + 10], radius=18, fill=(0, 0, 0, 150))
        for l in sub_lines:
            ld.text((x0, sy), l, font=F_SUB, fill=(245, 245, 250, 255))
            sy += 46
    img.paste(layer, (0, 0), layer)
    return img


def sentences(text):
    out, cur = [], ""
    for ch in text:
        cur += ch
        if ch in ".!?—" and len(cur.strip()) > 25 and ch != "—":
            out.append(cur.strip())
            cur = ""
    if cur.strip():
        out.append(cur.strip())
    return out


async def tts(text, path):
    import edge_tts

    await edge_tts.Communicate(text, VOICE, rate="+4%").save(path)


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", path],
                       capture_output=True, text=True)
    return float(json.loads(r.stdout)["format"]["duration"])


def main():
    global BG
    shots_dir, out = sys.argv[1], sys.argv[2]
    silent = "--silent" in sys.argv
    BG = background()
    tmp = tempfile.mkdtemp()
    audio_parts = []
    timeline = []
    for i, sc in enumerate(SCENES):
        wav = os.path.join(tmp, f"s{i}.wav")
        if silent:
            dur = max(3.0, len(sc["say"]) / 14.0)
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono",
                            "-t", f"{dur:.2f}", wav], check=True)
        else:
            mp3 = os.path.join(tmp, f"s{i}.mp3")
            asyncio.run(tts(sc["say"], mp3))
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", mp3, "-ar", "24000", "-ac", "1", wav], check=True)
        speech = duration(wav)
        lead, tail = 0.5, 0.9
        padded = os.path.join(tmp, f"p{i}.wav")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", wav, "-af",
                        f"adelay={int(lead * 1000)},apad=pad_dur={tail}", "-ar", "24000", "-ac", "1", padded], check=True)
        dur = duration(padded)
        audio_parts.append(padded)
        timeline.append((sc, dur, speech, lead))

    # Video frames → ffmpeg.
    video = os.path.join(tmp, "video.mp4")
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                             "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                             "-pix_fmt", "yuv420p", video], stdin=subprocess.PIPE)
    for sc, dur, speech, lead in timeline:
        phones = []
        for name in sc["shots"]:
            p = os.path.join(shots_dir, name + ".png")
            shot = Image.open(p).convert("RGB") if os.path.exists(p) else Image.new("RGB", (540, 1200), (40, 40, 40))
            phones.append(phone(shot, 1.0))
        shadow = make_shadow(phones[0])
        parts = sentences(sc["say"])
        # Subtitle timing proportional to characters.
        total_chars = sum(len(p) for p in parts) or 1
        spans, acc = [], lead
        for p in parts:
            dt = speech * len(p) / total_chars
            spans.append((acc, acc + dt, wrap(p, F_SUB, 900)))
            acc += dt
        n = int(round(dur * FPS))
        for f in range(n):
            t = f / FPS
            lines = next((s[2] for s in spans if s[0] <= t < s[1] + 0.25), [])
            proc.stdin.write(frame(sc, phones, shadow, t, dur, lines).convert("RGB").tobytes())
    proc.stdin.close()
    proc.wait()

    # Audio concat and mux.
    lst = os.path.join(tmp, "list.txt")
    with open(lst, "w") as fh:
        for p in audio_parts:
            fh.write(f"file '{p}'\n")
    audio = os.path.join(tmp, "audio.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", audio], check=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-i", audio, "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
                    "-shortest", out], check=True)
    print("video", out, f"{sum(t[1] for t in timeline):.1f}s")


if __name__ == "__main__":
    main()
