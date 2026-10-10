"""Adds native Android dependencies to the Flutter-generated app Gradle file
(ML Kit text recognition for reading spool labels)."""
import os

DEPS = ["com.google.mlkit:text-recognition:16.0.1"]

path = "android/app/build.gradle.kts"
kts = os.path.exists(path)
if not kts:
    path = "android/app/build.gradle"
src = open(path, encoding="utf-8").read()
lines = "\n".join(
    (f'    implementation("{d}")' if kts else f"    implementation '{d}'") for d in DEPS if d not in src
)
if lines:
    src = src.rstrip() + "\n\ndependencies {\n" + lines + "\n}\n"
    open(path, "w", encoding="utf-8").write(src)
print("dependencies:", DEPS)
