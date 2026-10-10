"""Makes short ElevenLabs samples of several voices to pick one for the promo.

Usage: ELEVENLABS_API_KEY=... python3 voices.py OUT_DIR
Takes the most used Ukrainian voices from the shared Voice Library plus a few
premade ones; writes NN_<name>.mp3 and voices.txt (number, name, voice_id).
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

KEY = os.environ["ELEVENLABS_API_KEY"].strip()
MODEL = os.environ.get("ELEVEN_MODEL", "").strip() or "eleven_multilingual_v2"
TEXT = ("Скільки насправді коштує ваш 3D-друк? Я зробив застосунок, "
        "який рахує це прямо в телефоні. Пишіть у коментарях!")
PREMADE = [
    ("Brian", "nPczCjzI2devNBz1zQrb"),
    ("Daniel", "onwK4e9ZLuTAKqWW03F9"),
    ("Sarah", "EXAVITQu4vr4xnSDxMaL"),
    ("Alice", "Xb7hH8MSUJpSbSDYk0k2"),
]


def call(method, path, body=None):
    req = urllib.request.Request("https://api.elevenlabs.io" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"xi-api-key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def tts(voice_id, path):
    audio = call("POST", f"/v1/text-to-speech/{voice_id}?output_format=mp3_44100_128", {
        "text": TEXT, "model_id": MODEL,
        "voice_settings": {"stability": 0.45, "similarity_boost": 0.8, "style": 0.25, "use_speaker_boost": True},
    })
    with open(path, "wb") as fh:
        fh.write(audio)


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    cands = []
    try:
        q = urllib.parse.urlencode({"language": "uk", "page_size": 40, "sort": "usage_character_count_1y"})
        res = json.loads(call("GET", f"/v1/shared-voices?{q}"))
        for v in res.get("voices", []):
            if v.get("language") not in (None, "uk"):
                continue
            label = " ".join(x for x in [v.get("name", ""), v.get("gender", ""), v.get("age", "")] if x)
            cands.append((label, v["voice_id"], v.get("public_owner_id")))
    except urllib.error.HTTPError as e:
        print("shared-voices:", e.code, e.read()[:300])
    shared = cands[:6]
    lines, n = [], 0
    for label, vid, owner in shared + [(a, b, None) for a, b in PREMADE]:
        n += 1
        safe = re.sub(r"[^\w]+", "_", label)[:40].strip("_")
        path = os.path.join(out, f"{n:02d}_{safe}.mp3")
        try:
            tts(vid, path)
        except urllib.error.HTTPError as e:
            err = e.read().decode(errors="replace")[:200]
            # Library voices may have to be added to "My voices" first.
            if owner:
                try:
                    call("POST", f"/v1/voices/add/{owner}/{vid}", {"new_name": label[:40]})
                    tts(vid, path)
                    err = None
                except urllib.error.HTTPError as e2:
                    err = f"{err} | add: {e2.code} {e2.read().decode(errors='replace')[:200]}"
            if err:
                print(f"{n:02d} {label}: FAILED {e.code} {err}")
                lines.append(f"{n:02d}\t{label}\t{vid}\tFAILED {e.code}")
                continue
        print(f"{n:02d} {label}: ok")
        lines.append(f"{n:02d}\t{label}\t{vid}")
    with open(os.path.join(out, "voices.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
