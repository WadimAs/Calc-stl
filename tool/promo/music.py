"""Generates an instrumental background track with ElevenLabs Music.

Usage: ELEVENLABS_API_KEY=... python3 music.py OUT.mp3 SECONDS
"""
import json
import os
import sys
import urllib.error
import urllib.request

KEY = os.environ["ELEVENLABS_API_KEY"].strip()
PROMPT = os.environ.get("PROMO_MUSIC_PROMPT", "").strip() or (
    "Upbeat modern electronic background music for a tech product promo video. "
    "Light driving beat, warm synth chords, soft plucks, positive and confident mood, "
    "steady energy without drops, no vocals, smooth gentle ending.")


def compose(body):
    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128", method="POST",
        data=json.dumps(body).encode(),
        headers={"xi-api-key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read()


def main():
    out, seconds = sys.argv[1], float(sys.argv[2])
    body = {"prompt": PROMPT, "music_length_ms": int(min(300, max(10, seconds)) * 1000),
            "model_id": "music_v1", "force_instrumental": True}
    try:
        audio = compose(body)
    except urllib.error.HTTPError as e:
        err = e.read().decode(errors="replace")[:400]
        print("music:", e.code, err)
        if e.code not in (400, 422):
            sys.exit(1)
        body.pop("force_instrumental")
        audio = compose(body)
    with open(out, "wb") as fh:
        fh.write(audio)
    print("music saved", out, len(audio), "bytes")


if __name__ == "__main__":
    main()
