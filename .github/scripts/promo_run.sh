#!/usr/bin/env bash
# Records the emulator screen while integration_test/promo_test.dart walks
# through the app. Output: promo-clips/ with rec_<epoch ms>.mp4 + marks.txt.
set -u
PKG=com.printcalc.stl_weight
mkdir -p promo-clips
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 2; done
sleep 8
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell input keyevent 82 || true
# Clean status bar (demo mode): 12:00, full battery and signal, no notifications.
adb shell settings put global sysui_demo_allowed 1
for c in "clock -e hhmm 1200" "battery -e level 100 -e plugged false" "network -e wifi show -e level 4 -e mobile show -e datatype none -e level 4" "notifications -e visible false"; do
  adb shell am broadcast -a com.android.systemui.demo -e command $c >/dev/null 2>&1 || true
done
adb shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null 2>&1 || true

# Warm-up launch (first start after boot sometimes never draws).
adb install -r build/app/outputs/flutter-apk/app-debug.apk >/dev/null 2>&1 || true
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 12
adb shell am force-stop $PKG || true

now_ms() {
  local t
  t=$(adb shell date +%s%3N | tr -d '\r')
  case "$t" in *N*|"") t="$(adb shell date +%s | tr -d '\r')000" ;; esac
  echo "$t"
}

touch rec.on
(
  while [ -f rec.on ]; do
    t=$(now_ms)
    adb shell screenrecord --size 720x1600 --bit-rate 8000000 --time-limit 170 /sdcard/rec_$t.mp4 >> rec.log 2>&1
  done
) &
REC=$!
sleep 2

: > drive.txt
timeout 900 flutter test integration_test/promo_test.dart -d emulator-5554 -r expanded >> drive.txt 2>&1
echo "flutter test exit $?" >> drive.txt

rm -f rec.on
adb shell pkill -INT screenrecord || true
sleep 4
kill $REC 2>/dev/null || true
for f in $(adb shell ls /sdcard/ | tr -d '\r' | grep '^rec_.*\.mp4$'); do
  adb pull /sdcard/$f promo-clips/$f >/dev/null 2>&1 || true
done
grep -o 'PROMO_[A-Z]*.*' drive.txt > promo-clips/marks.txt || true
cp drive.txt rec.log promo-clips/ 2>/dev/null || true
ls -la promo-clips
cat promo-clips/marks.txt
exit 0
