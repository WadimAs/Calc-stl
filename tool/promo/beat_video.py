"""Beat-synced promo cut (no voice) for a song added later in TikTok.

Usage: python3 beat_video.py SHOTS_DIR CLIPS_DIR OUT.mp4 [--song SONG.mp3 --start SEC]

The video starts on a downbeat; every scene is two bars, words pop on beats
and the phone pulses on every beat. Without --song the file has a silent
track (the music is added in TikTok from the same point). With --song a
preview with that music is made for checking the sync.
"""
import math
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

import make_video as mv

BPM = float(os.environ.get("BEAT_BPM", "120"))
BEAT = 60.0 / BPM
BAR = 4 * BEAT
SCENE_BARS = 2
W, H, FPS = mv.W, mv.H, mv.FPS
ACCENT = mv.ACCENT
YELLOW = (255, 214, 64)

# Each scene: title lines (words pop one per beat), media for each half.
SCENES = [
    {"title": ["СКІЛЬКИ КОШТУЄ", "ТВІЙ 3D-ДРУК?"], "media": ["clip:rotate"], "hot": "3D-ДРУК?"},
    {"title": ["ВАГА. ЧАС.", "ЦІНА."], "media": ["clip:infill", "clip:cost"], "hot": "ЦІНА."},
    {"title": ["РОЗМІРИ", "МІРЯЄ САМ"], "media": ["clip:holes"], "hot": "САМ"},
    {"title": ["ПІДТРИМКИ?", "НАВІТЬ ДЕРЕВА"], "media": ["clip:supports", "clip:layers"], "hot": "ДЕРЕВА"},
    {"title": ["РАХУНОК", "КЛІЄНТУ В PDF"], "media": ["clip:order", "clip:pdf"], "hot": "PDF"},
    {"title": ["ФОТО ЕТИКЕТКИ", "→ КОТУШКА"], "media": ["clip:ocr", "clip:ocr2"], "hot": "КОТУШКА"},
    {"title": ["ДРУК ЗАВЕРШЕНО", "ПЛАСТИК СПИСАНО"], "media": ["clip:print", "clip:business"], "hot": "СПИСАНО"},
    {"title": ["ВИПУСКАТИ", "ДЛЯ ВСІХ?"], "media": ["shot:05_result"], "question": True},
]

F_BIG = mv.font(104, "Black")
F_BTN = mv.font(64, "Black")
F_SMALL = mv.font(50, "ExtraBold")


def fit_font(lines, width=940, size=104):
    """One size for all title lines so the widest fits."""
    f = mv.font(size, "Black")
    while max(f.getlength(t) for t in lines) > width and size > 56:
        size -= 4
        f = mv.font(size, "Black")
    return f


def load_media(item, shots_dir, clips_dir, marks, tmp):
    kind, name = item.split(":", 1)
    if kind == "clip" and clips_dir:
        c = mv.extract_clip(clips_dir, marks, name, tmp)
        if c is not None:
            return c
        name = mv.FALLBACK_SHOT.get(name, "05_result")
    p = os.path.join(shots_dir, name + ".png")
    img = Image.open(p).convert("RGB") if os.path.exists(p) else Image.new("RGB", (540, 1169), (40, 40, 40))
    return mv.phone(img)


def media_frame(m, local, span):
    """Phone image for time `local` within a `span`-second slot (clips are sped up to fit)."""
    if isinstance(m, Image.Image):
        return m
    length = m.n / FPS
    speed = min(4.0, max(1.0, length / span))
    return m.get(int(local * speed * FPS))


def draw_title(layer, lines, hot, beat_idx, beat_frac, appear_y):
    d = ImageDraw.Draw(layer)
    words = [(li, w) for li, line in enumerate(lines) for w in line.split()]
    shown = min(len(words), beat_idx + 1)
    y = appear_y
    k = 0
    f = fit_font(lines)
    for li, line in enumerate(lines):
        ws = line.split()
        gap = f.size * 0.32
        total_w = sum(f.getlength(w) for w in ws) + gap * (len(ws) - 1)
        x = (W - total_w) / 2
        for w in ws:
            if k < shown:
                # The newest word pops (scale overshoot) on its beat.
                pop = 1.0
                if k == shown - 1 and beat_idx < len(words):
                    q = min(1.0, beat_frac / 0.35)
                    pop = 1.0 + 0.14 * (1 - mv.ease(q))
                col = YELLOW if hot and hot in w else (255, 255, 255)
                if abs(pop - 1.0) < 0.01:
                    d.text((x, y), w, font=f, fill=col, stroke_width=7, stroke_fill=(0, 0, 0))
                else:
                    fs = mv.font(max(10, int(f.size * pop)), "Black")
                    ww, wn = fs.getlength(w), f.getlength(w)
                    d.text((x, y - (fs.size - f.size) / 2), w, font=fs, fill=col,
                           stroke_width=7, stroke_fill=(0, 0, 0))
            x += f.getlength(w) + gap
            k += 1
        y += f.size + 14


def render(shots_dir, clips_dir, out_video):
    mv.BG = mv.background()
    logo = Image.open(mv.LOGO).convert("RGBA") if os.path.exists(mv.LOGO) else None
    tmp = tempfile.mkdtemp()
    marks = mv.load_marks(clips_dir) if clips_dir else {}
    scene_len = SCENE_BARS * BAR
    total = scene_len * len(SCENES)
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                             "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
                             "-pix_fmt", "yuv420p", out_video], stdin=subprocess.PIPE)
    for si, sc in enumerate(SCENES):
        media = [load_media(m, shots_dir, clips_dir, marks, tmp) for m in sc["media"]]
        span = scene_len / len(media)
        n = int(round(scene_len * FPS))
        for fi in range(n):
            t = fi / FPS
            gt = si * scene_len + t
            beat_idx = int(t / BEAT + 1e-6)
            beat_frac = (t - beat_idx * BEAT) / BEAT
            pulse = math.exp(-beat_frac * 6)
            strong = beat_idx % 4 == 0
            img = mv.BG.copy()
            # Phone: slides in on the scene's downbeat, pulses on every beat.
            mi = min(len(media) - 1, int(t / span))
            ph = media_frame(media[mi], t - mi * span, span)
            q = sc.get("question")
            if q:
                ph = ph.filter(ImageFilter.GaussianBlur(10))
            zoom = 1.0 + (0.05 if strong else 0.025) * pulse
            slide = (1 - mv.ease(t / 0.25)) * 300 if mi == 0 else (1 - mv.ease((t - span) / 0.2)) * -40
            pw, phh = int(ph.width * zoom), int(ph.height * zoom)
            phz = ph.resize((pw, phh), Image.BILINEAR)
            top = 470 + slide - (phh - ph.height) / 2
            img.paste(phz, (int(W / 2 - pw / 2), int(top)), phz)
            layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
            d = ImageDraw.Draw(layer)
            if q:
                d.rectangle([0, 0, W, H], fill=(14, 10, 18, 175))
                if logo is not None:
                    lg = logo.resize((180, 180), Image.LANCZOS)
                    layer.alpha_composite(lg, (int(W / 2 - 90), 300))
                draw_title(layer, sc["title"], None, beat_idx, beat_frac, 560)
                if beat_idx >= 3:
                    bp = 1 + 0.08 * pulse
                    for i, (lbl, col) in enumerate([("ТАК", (46, 170, 90)), ("НІ", (210, 60, 60))]):
                        bw, bh = int(320 * bp), int(140 * bp)
                        bx = int(W / 2 + (-1 if i == 0 else 1) * 195 - bw / 2)
                        by = int(930 - bh / 2)
                        d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=36, fill=col + (255,))
                        tw = F_BTN.getlength(lbl)
                        d.text((bx + (bw - tw) / 2, by + bh / 2 - 40), lbl, font=F_BTN, fill=(255, 255, 255))
                if beat_idx >= 5:
                    mv.centered(d, 1110, "ПИШИ В КОМЕНТАРЯХ ↓", F_SMALL, (255, 200, 160, 255), 4, (0, 0, 0, 255))
            else:
                draw_title(layer, sc["title"], sc.get("hot"), beat_idx, beat_frac, 120)
            # Flash on each scene's first downbeat.
            if beat_idx == 0:
                d.rectangle([0, 0, W, H], fill=(255, 255, 255, int(150 * pulse)))
            d.rectangle([0, 0, int(W * gt / total), 7], fill=ACCENT + (235,))
            img.paste(layer, (0, 0), layer)
            proc.stdin.write(img.convert("RGB").tobytes())
        print(f"scene {si}: {scene_len:.1f}s", flush=True)
    proc.stdin.close()
    proc.wait()
    return total


def main():
    shots_dir, clips_dir, out = sys.argv[1], sys.argv[2], sys.argv[3]
    song = start = None
    if "--song" in sys.argv:
        song = sys.argv[sys.argv.index("--song") + 1]
        start = float(sys.argv[sys.argv.index("--start") + 1])
    tmp = tempfile.mkdtemp()
    video = os.path.join(tmp, "v.mp4")
    total = render(shots_dir, clips_dir, video)
    if song:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-ss", f"{start:.3f}", "-t", f"{total:.3f}",
                        "-i", song, "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                        "-af", f"afade=t=out:st={total - 1.2:.2f}:d=1.2", "-c:a", "aac", "-b:a", "192k",
                        "-movflags", "+faststart", out], check=True)
    else:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-f", "lavfi", "-t", f"{total:.3f}",
                        "-i", "anullsrc=r=44100:cl=stereo", "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                        "-c:a", "aac", "-shortest", "-movflags", "+faststart", out], check=True)
    print("video", out, f"{total:.1f}s")


if __name__ == "__main__":
    main()
