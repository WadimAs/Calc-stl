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
# Keep the R8 rules file in release builds (Flutter adds proguard-rules.pro,
# this makes it explicit) and use the compatible R8 mode: ML Kit's
# reflection breaks under "full mode".
src = open(path, encoding="utf-8").read()
if "proguard-rules.pro" not in src:
    if kts:
        src = src.replace(
            'buildTypes {\n        release {',
            'buildTypes {\n        release {\n            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")',
            1,
        )
    else:
        src = src.replace(
            "buildTypes {\n        release {",
            "buildTypes {\n        release {\n            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'",
            1,
        )
    open(path, "w", encoding="utf-8").write(src)
props = "android/gradle.properties"
p = open(props, encoding="utf-8").read() if os.path.exists(props) else ""
if "android.enableR8.fullMode" not in p:
    open(props, "a", encoding="utf-8").write("\nandroid.enableR8.fullMode=false\n")
print("dependencies:", DEPS)
