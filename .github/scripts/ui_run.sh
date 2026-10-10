#!/usr/bin/env bash
# Runs the UI test on the emulator; screenshots are written by the app into
# its private files/screens and pulled regularly (also if the test hangs).
set -u
PKG=com.printcalc.stl_weight
mkdir -p screenshots
adb logcat -c || true

pull() {
  # Copy each file separately (base64 keeps binary data intact over adb shell).
  for f in $(adb shell run-as $PKG ls files/screens 2>/dev/null | tr -d '\r'); do
    case "$f" in *.tmp) continue ;; esac
    if [ ! -s "screenshots/$f" ] || [ "$f" = report.txt ]; then
      adb shell "run-as $PKG base64 files/screens/$f" 2>/dev/null | tr -d '\r' | base64 -d > "screenshots/$f.tmp" 2>/dev/null \
        && [ -s "screenshots/$f.tmp" ] && mv "screenshots/$f.tmp" "screenshots/$f"
      rm -f "screenshots/$f.tmp"
    fi
  done
}

( sleep 60; { echo "--- debug: run-as listing"; adb shell run-as $PKG ls -la files files/screens; } >> pull_debug.txt 2>&1
  while true; do sleep 15; pull; done ) &
PULLER=$!

# Let the freshly booted emulator settle (late config changes recreate the activity).
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 40
adb shell input keyevent 82 || true
adb shell settings put global window_animation_scale 0 || true

: > drive.txt
for attempt in 1 2 3; do
  echo "=== attempt $attempt" >> drive.txt
  timeout 900 flutter test integration_test/app_test.dart -d emulator-5554 -r expanded >> drive.txt 2>&1
  code=$?
  echo "flutter test exit $code" >> drive.txt
  if grep -q "UI_LOG DONE" drive.txt; then break; fi
  if grep -q "UI_LOG step" drive.txt; then break; fi  # ran but failed somewhere: keep the results
  sleep 20
done

pull
kill $PULLER 2>/dev/null || true

# Release build (minified by R8): text recognition must still work.
if [ -f release-x64.apk ]; then
  adb uninstall $PKG >/dev/null 2>&1 || true
  adb install -r release-x64.apk >> drive.txt 2>&1
  adb logcat -c || true
  adb shell am start -n $PKG/.MainActivity --ez ocrSelfTest true >> drive.txt 2>&1
  for i in $(seq 1 30); do
    if adb logcat -d -s STLVAGA:* | grep -q OCR_SELFTEST; then break; fi
    sleep 2
  done
  adb logcat -d -s STLVAGA:* | grep OCR_SELFTEST | sed 's/^/RELEASE /' >> drive.txt || echo "RELEASE OCR_SELFTEST_NO_RESULT" >> drive.txt
fi
adb logcat -d > logcat.txt 2>/dev/null || true
cp pull_debug.txt screenshots/ 2>/dev/null || true
ls -la screenshots
exit 0
