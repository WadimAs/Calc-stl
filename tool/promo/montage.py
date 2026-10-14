"""Vertical montage of real screen recordings with short captions and music.

Usage: python3 montage.py PLAN.json OUT.mp4 [--music MUSIC.mp3]

PLAN.json:
{
  "title": "Як працює облік котушок",
  "outro": ["А як ви ведете облік пластику?", "Пишіть у коментарях ↓"],
  "scenes": [
    {"caption": "…", "parts": [["video.mp4", start, end], …]}, …
  ]
}
Scene lengths are snapped to the music beat (BPM detected from the track)
so every cut lands on a beat; recordings are sped up / slowed to fit.
"""
import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import make_video as mv

W, H, FPS = 1080, 1920, 30
ACCENT = mv.ACCENT
SCREEN_H = 1400
INTRO = 2.0
OUTRO = 4.2

F_TITLE = mv.font(104, "Black")
F_CAP = mv.font(62, "ExtraBold")
F_SMALL = mv.font(36, "SemiBold")
F_OUT = mv.font(88, "Black")
F_OUT2 = mv.font(56, "Black")


# ------------------------------------------------------------------ music

def beat_grid(path):
    """(bpm, first beat time) of a music file, by spectral flux autocorrelation."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", "22050", "-f", "s16le", "-"],
                         capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768
    hop, n = 512, 2048
    frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * np.hanning(n)
    mag = np.log1p(100 * np.abs(np.fft.rfft(frames, axis=1)))
    flux = np.maximum(0, np.diff(mag, axis=0)).sum(1)
    flux = np.maximum(0, flux - np.convolve(flux, np.ones(16) / 16, "same"))
    fps = 22050 / hop
    best = (0, 120, 0)
    for bpm in np.arange(90, 170, 0.25):
        p = 60 / bpm * fps
        for ph in np.linspace(0, p, 24, endpoint=False):
            idx = (ph + np.arange(0, len(flux) / p - 1) * p).astype(int)
            sc = flux[idx].mean()
            if sc > best[0]:
                best = (sc, bpm, ph / fps)
    # Prefer the half-time reading when it is nearly as strong (dance tracks).
    return float(best[1]), float(best[2])


# ------------------------------------------------------------------ frames

def extract(path, a, b, speed, out_dir, start_no, width):
    os.makedirs(out_dir, exist_ok=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{a:.3f}", "-t", f"{b - a + 1:.3f}", "-i", path,
                    "-vf", f"setpts=(PTS-STARTPTS)/{speed:.4f},fps={FPS},scale={width}:-2",
                    "-frames:v", str(max(1, int(round((b - a) / speed * FPS)))),
                    "-start_number", str(start_no), "-q:v", "3", os.path.join(out_dir, "%05d.jpg")], check=True)
    return len([f for f in os.listdir(out_dir) if f.endswith(".jpg")])


def rounded_phone(img):
    pad = 14
    w, h = img.size
    out = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
    d = ImageDraw.Draw(out)
    d.rounded_rectangle([0, 0, out.width - 1, out.height - 1], radius=58, fill=(8, 8, 10, 255))
    d.rounded_rectangle([1, 1, out.width - 2, out.height - 2], radius=58, outline=(70, 66, 74, 255), width=2)
    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=46, fill=255)
    out.paste(img, (pad, pad), mask)
    return out


def shadow_for(size):
    w, h = size
    sh = Image.new("RGBA", (w + 140, h + 140), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([70, 90, w + 70, h + 90], radius=64, fill=(0, 0, 0, 190))
    return sh.filter(ImageFilter.GaussianBlur(40))


def caption(d, text, y, alpha, f=F_CAP, width=960):
    lines = mv.wrap(text, f, width)
    for line in lines:
        w = f.getlength(line)
        d.text(((W - w) / 2, y), line, font=f, fill=(255, 255, 255, alpha), stroke_width=6,
               stroke_fill=(0, 0, 0, alpha))
        y += f.size + 12
    return y


# ------------------------------------------------------------------ render

def main():
    plan_path, out = sys.argv[1], sys.argv[2]
    music = sys.argv[sys.argv.index("--music") + 1] if "--music" in sys.argv else None
    plan = json.load(open(plan_path, encoding="utf-8"))
    base = os.path.dirname(os.path.abspath(plan_path))
    tmp = tempfile.mkdtemp()

    bpm, first_beat = (120.0, 0.0)
    if music:
        bpm, first_beat = beat_grid(music)
        print(f"music: {bpm:.2f} BPM, first beat {first_beat:.3f}s", flush=True)
    beat = 60.0 / bpm

    sw = int(SCREEN_H * 720 / 1594) // 2 * 2
    bg = mv.background()
    logo = Image.open(mv.LOGO).convert("RGBA") if os.path.exists(mv.LOGO) else None

    # Scene clips, each length snapped to whole beats (pairs of beats).
    scenes = []
    for si, sc in enumerate(plan["scenes"]):
        natural = sum((p[2] - p[1]) / (p[3] if len(p) > 3 else 1.0) for p in sc["parts"])
        beats = max(4, int(round(natural / beat / 2)) * 2)
        length = beats * beat
        k = natural / length  # extra speed factor to fit the beat grid
        folder = os.path.join(tmp, f"s{si}")
        n = 0
        for p in sc["parts"]:
            sp = (p[3] if len(p) > 3 else 1.0) * k
            n = extract(os.path.join(base, p[0]), p[1], p[2], sp, folder, n + 1, sw)
        scenes.append({"caption": sc["caption"], "folder": folder, "n": n, "len": length})
        print(f"scene {si}: {length:.2f}s ({beats} beats), {n} frames", flush=True)

    intro = max(4, round(INTRO / beat / 2) * 2) * beat
    outro = max(4, round(OUTRO / beat / 2) * 2) * beat
    total = intro + sum(s["len"] for s in scenes) + outro

    def frame_img(sc, i):
        i = max(1, min(sc["n"], i + 1))
        return Image.open(os.path.join(sc["folder"], f"{i:05d}.jpg")).convert("RGB")

    first = rounded_phone(frame_img(scenes[0], 0))
    shadow = shadow_for(first.size)
    phone_top = 380

    video = os.path.join(tmp, "v.mp4")
    proc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
                             "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
                             "-pix_fmt", "yuv420p", video], stdin=subprocess.PIPE)

    def compose(phone, t_scene, cap, gt, pulse=True):
        img = bg.copy()
        # Small punch on every beat, bigger on the cut.
        bt = (gt % beat) / beat
        cut = math.exp(-t_scene * 7)
        z = 1.0 + 0.045 * cut + (0.012 * math.exp(-bt * 6) if pulse else 0)
        pw, ph = int(phone.width * z), int(phone.height * z)
        p = phone.resize((pw, ph), Image.BILINEAR) if z != 1.0 else phone
        cx = W / 2
        top = phone_top - (ph - phone.height) / 2
        img.paste(shadow, (int(cx - phone.width / 2 - 70), int(phone_top - 70)), shadow)
        img.paste(p, (int(cx - pw / 2), int(top)), p)
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        # Series title (small) and the scene caption popping in on the cut.
        tw = F_SMALL.getlength(plan["title"].upper())
        d.text(((W - tw) / 2, 70), plan["title"].upper(), font=F_SMALL, fill=ACCENT + (235,))
        if cap:
            a = mv.ease(t_scene / 0.25)
            caption(d, cap, 150 + (1 - a) * 30, int(255 * a))
        d.rectangle([0, 0, int(W * gt / total), 7], fill=ACCENT + (235,))
        img.paste(layer, (0, 0), layer)
        return img

    gt = 0.0
    # Intro: big title over the first scene's opening frame (blurred), then it slides away.
    blur_bg = None
    for f in range(int(round(intro * FPS))):
        t = f / FPS
        ph_img = rounded_phone(frame_img(scenes[0], 0))
        img = compose(ph_img, 9, None, gt + t, pulse=False)
        if blur_bg is None:
            blur_bg = img.filter(ImageFilter.GaussianBlur(14))
        k = mv.ease((t - (intro - 0.35)) / 0.35)  # reveal the sharp phone at the end
        base_img = Image.blend(blur_bg, img, k)
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rectangle([0, 0, W, H], fill=(12, 8, 14, int(150 * (1 - k))))
        a = int(255 * mv.ease(t / 0.3) * (1 - k))
        title_lines = plan.get("title_lines") or mv.wrap(plan["title"], F_TITLE, 940)
        block = len(title_lines) * (F_TITLE.size + 18)
        y = int(H * 0.47 - block / 2) + 120  # title block centred, logo above it
        if logo is not None and a > 0:
            lg = logo.resize((190, 190), Image.LANCZOS)
            lg.putalpha(lg.getchannel("A").point(lambda v: v * a // 255))
            layer.alpha_composite(lg, (int(W / 2 - 95), y - 250))
        for li, line in enumerate(title_lines):
            pop = 1 + 0.12 * math.exp(-max(0, t - li * beat) * 8) if t >= li * beat else 0
            if pop:
                fs = mv.font(int(F_TITLE.size * pop), "Black")
                w = fs.getlength(line)
                d.text(((W - w) / 2, y - (fs.size - F_TITLE.size) / 2), line, font=fs,
                       fill=(255, 255, 255, a), stroke_width=8, stroke_fill=(0, 0, 0, a))
            y += F_TITLE.size + 18
        base_img.paste(layer, (0, 0), layer)
        proc.stdin.write(base_img.convert("RGB").tobytes())
    gt += intro

    last = None
    for sc in scenes:
        n = int(round(sc["len"] * FPS))
        cache = {}
        for f in range(n):
            t = f / FPS
            i = int(f * sc["n"] / n)
            if i not in cache:
                cache.clear()
                cache[i] = rounded_phone(frame_img(sc, i))
            img = compose(cache[i], t, sc["caption"], gt + t)
            proc.stdin.write(img.tobytes())
            last = img
        gt += sc["len"]

    # Outro: blurred last frame and the question.
    blur = last.filter(ImageFilter.GaussianBlur(16))
    for f in range(int(round(outro * FPS))):
        t = f / FPS
        img = blur.copy()
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rectangle([0, 0, W, H], fill=(12, 8, 14, int(170 * mv.ease(t / 0.3))))
        a = int(255 * mv.ease(t / 0.3))
        if logo is not None and a > 0:
            lg = logo.resize((170, 170), Image.LANCZOS)
            lg.putalpha(lg.getchannel("A").point(lambda v: v * a // 255))
            layer.alpha_composite(lg, (int(W / 2 - 85), 470))
        y = caption(d, plan["outro"][0], 700, a, F_OUT, 940)
        a2 = int(255 * mv.ease((t - beat * 2) / 0.3))
        if a2 > 0:
            # Call to action in an accent pill that pulses on the beat.
            bt = ((t % beat) / beat)
            z = 1 + 0.05 * math.exp(-bt * 6)
            f2 = mv.font(int(F_OUT2.size * z), "Black")
            lines = mv.wrap(plan["outro"][1], f2, 860)
            lh = f2.size + 14
            bw = max(f2.getlength(l) for l in lines) + 80
            bh = lh * len(lines) + 50
            top = y + 50
            d.rounded_rectangle([(W - bw) / 2, top, (W + bw) / 2, top + bh], radius=bh / 2 if len(lines) == 1 else 44,
                                fill=ACCENT + (a2,))
            ty = top + 25
            for l in lines:
                w = f2.getlength(l)
                d.text(((W - w) / 2, ty), l, font=f2, fill=(255, 255, 255, a2))
                ty += lh
        left = outro - t
        if left < 0.6:
            d.rectangle([0, 0, W, H], fill=(0, 0, 0, int(255 * (1 - left / 0.6))))
        img.paste(layer, (0, 0), layer)
        proc.stdin.write(img.convert("RGB").tobytes())
    proc.stdin.close()
    proc.wait()

    if music:
        start = first_beat
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-ss", f"{start:.3f}", "-i", music,
                        "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                        "-af", f"atrim=0:{total:.3f},afade=t=in:d=0.05,afade=t=out:st={total - 1.2:.3f}:d=1.2,"
                               "loudnorm=I=-14:TP=-1.5",
                        "-c:a", "aac", "-b:a", "192k", "-t", f"{total:.3f}", "-movflags", "+faststart", out],
                       check=True)
    else:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", video, "-f", "lavfi", "-t", f"{total:.3f}",
                        "-i", "anullsrc=r=44100:cl=stereo", "-map", "0:v", "-map", "1:a", "-c:v", "copy",
                        "-c:a", "aac", "-shortest", "-movflags", "+faststart", out], check=True)
    print("video", out, f"{total:.1f}s")


if __name__ == "__main__":
    main()
