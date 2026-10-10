"""Prints release notes (newest entry of assets/changelog.json) as Markdown."""
import json

entries = json.load(open("assets/changelog.json", encoding="utf-8"))
e = entries[0]
print("## Що нового\n")
for line in e["uk"]:
    print(f"- {line}")
print("\n## What's new\n")
for line in e["en"]:
    print(f"- {line}")
print("\n`stl-weight.apk` — для більшості телефонів, `stl-weight-arm32.apk` — для старих 32-бітних.")
