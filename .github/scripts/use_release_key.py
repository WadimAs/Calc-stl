"""Makes the Flutter-generated android/app/build.gradle(.kts) sign release
builds with the keystore at $STL_KEYSTORE (alias androiddebugkey, password
"android"), so every CI build has the same signature."""
import os
import re
import sys

ks = os.environ.get("STL_KEYSTORE")
if not ks or not os.path.exists(ks):
    print("No keystore, leaving debug signing")
    sys.exit(0)

path = "android/app/build.gradle.kts"
kts = os.path.exists(path)
if not kts:
    path = "android/app/build.gradle"
src = open(path, encoding="utf-8").read()

if kts:
    block = f'''    signingConfigs {{
        create("stl") {{
            storeFile = file("{ks}")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }}
    }}

'''
    use = 'signingConfig = signingConfigs.getByName("stl")'
    pattern = r'signingConfig\s*=\s*signingConfigs\.getByName\("debug"\)'
else:
    block = f'''    signingConfigs {{
        stl {{
            storeFile file("{ks}")
            storePassword "android"
            keyAlias "androiddebugkey"
            keyPassword "android"
        }}
    }}

'''
    use = "signingConfig signingConfigs.stl"
    pattern = r"signingConfig\s+signingConfigs\.debug"

if not re.search(pattern, src):
    sys.exit(f"Release signing line not found in {path}")
src = re.sub(pattern, use, src, count=1)
i = src.index("    buildTypes")
src = src[:i] + block + src[i:]
open(path, "w", encoding="utf-8").write(src)
print(f"Patched {path} to use {ks}")
