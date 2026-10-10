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

( while true; do sleep 4; pull; done ) &
PULLER=$!

# Let the freshly booted emulator settle (late config changes recreate the activity).
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 8
adb shell input keyevent 82 || true
adb shell settings put global window_animation_scale 0 || true

# Warm-up launch: the very first app start after boot sometimes never gets a
# window; let that happen to a throw-away launch instead of the test.
if [ -f build/app/outputs/flutter-apk/app-debug.apk ]; then
  adb install -r build/app/outputs/flutter-apk/app-debug.apk >/dev/null 2>&1 || true
  adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  sleep 12
  adb shell am force-stop $PKG || true
  adb shell input keyevent KEYCODE_HOME || true
fi

: > drive.txt
for attempt in 1 2 3; do
  echo "=== attempt $attempt" >> drive.txt
  # Screen on and unlocked, otherwise the app may never draw a frame.
  adb shell input keyevent KEYCODE_WAKEUP || true
  adb shell wm dismiss-keyguard || true
  adb shell input keyevent 82 || true
  start=$(wc -l < drive.txt)
  timeout 600 flutter test integration_test/app_test.dart -d emulator-5554 -r expanded >> drive.txt 2>&1 &
  TEST=$!
  # Watchdog: if the walk-through has not started within 3 minutes the app is
  # stuck (rare first-launch hang) — stop and try again instead of waiting.
  started=0
  built=0
  for i in $(seq 1 120); do
    if ! kill -0 $TEST 2>/dev/null; then break; fi
    if tail -n +$((start + 1)) drive.txt | grep -q "UI_LOG step"; then started=1; break; fi
    # After the APK is installed the first step must appear within ~70 s.
    if [ $built = 0 ] && tail -n +$((start + 1)) drive.txt | grep -q "Built build"; then built=$i; fi
    if [ $built != 0 ] && [ $((i - built)) -gt 35 ]; then break; fi
    sleep 2
  done
  if [ $started = 0 ] && kill -0 $TEST 2>/dev/null; then
    echo "watchdog: no progress, restarting" >> drive.txt
    pkill -f "flutter test" || true
    kill $TEST 2>/dev/null || true
    wait $TEST 2>/dev/null
    adb shell am force-stop $PKG || true
    sleep 5
    continue
  fi
  wait $TEST
  code=$?
  echo "flutter test exit $code" >> drive.txt
  if tail -n +$((start + 1)) drive.txt | grep -q "UI_LOG DONE"; then break; fi
  if tail -n +$((start + 1)) drive.txt | grep -q "UI_LOG step"; then break; fi  # ran but failed: keep results
  sleep 5
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
ls -la screenshots
exit 0
