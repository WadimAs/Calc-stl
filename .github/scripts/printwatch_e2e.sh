#!/usr/bin/env bash
# End-to-end: a (fake) Klipper printer prints, the app is sent to the
# background, the print finishes → the "print finished" notification must
# appear without opening the app. Results go to drive.txt as "E2E ..." lines.
set -u
PKG=com.printcalc.stl_weight
APK=${1:-debug-app.apk}
log() { echo "E2E $*" | tee -a drive.txt; }
[ -f "$APK" ] || { log "no $APK"; exit 0; }

adb uninstall $PKG >/dev/null 2>&1 || true
adb install -r "$APK" >/dev/null 2>&1 || { log "install failed"; exit 0; }
adb shell pm grant $PKG android.permission.POST_NOTIFICATIONS || true

put() { # file content
  local b64
  b64=$(printf '%s' "$2" | base64 -w0)
  adb shell "run-as $PKG sh -c 'mkdir -p files && echo $b64 | base64 -d > files/$1'"
}
CL=$(python3 -c "import json;print(json.load(open('assets/changelog.json'))[0]['id'])")
put settings.json "{\"language\":\"uk\",\"seenIntro\":true,\"seenChangelog\":\"$CL\"}"
adb shell "run-as $PKG ls -la files" | sed 's/^/E2E files: /' | tee -a drive.txt
put printers.json '[{"id":"mr1","name":"Fake K1","kind":"moonraker","host":"10.0.2.2","serial":"","accessCode":"","apiKey":"","port":7125,"writtenOff":[],"cloud":false}]'

FINISH_AFTER=150 python3 .github/scripts/fake_moonraker.py 2> fake_moonraker.log &
FAKE=$!
sleep 1
T0=$(date +%s)

adb shell input keyevent KEYCODE_WAKEUP || true
adb shell wm dismiss-keyguard || true
adb shell am start -n $PKG/.MainActivity >/dev/null
sleep 45
mkdir -p screenshots
adb exec-out screencap -p > screenshots/e2e_1_app.png || true
if adb shell dumpsys alarm | grep -E "RTC_WAKEUP|ELAPSED" -A3 | grep -q "$PKG"; then
  log "check set for the end of the print: OK"
else
  log "check set for the end of the print: FAIL"
fi
adb shell dumpsys alarm | grep -B2 -A3 "$PKG" | head -16 | sed 's/^/E2E alarm: /' | tee -a drive.txt
if adb shell dumpsys notification --noredact | grep -qE "android\.title=.*(Друкується|Printing)"; then
  log "shade stays clean while printing: FAIL"
else
  log "shade stays clean while printing: OK"
fi

# Leave the app and let Android trim it, like a user going away.
adb shell input keyevent KEYCODE_HOME
sleep 3
adb shell cmd statusbar expand-notifications || true
sleep 2
adb exec-out screencap -p > screenshots/e2e_2_shade_printing.png 2>/dev/null || true
adb shell cmd statusbar collapse || true
adb shell am kill $PKG || true
adb shell input keyevent KEYCODE_SLEEP || true
sleep 20
adb shell "run-as $PKG cat files/printwatch.json" | head -c 600 | sed 's/^/E2E printwatch: /' | tee -a drive.txt
echo >> drive.txt

ok=0
for i in $(seq 1 60); do
  if adb shell dumpsys notification --noredact | grep -qE "android\.title=.*(Друк завершено|Print finished)"; then ok=1; break; fi
  sleep 5
done
NOW=$(date +%s)
if [ $ok = 1 ]; then
  log "finished notification with the app in background: OK ($((NOW - T0 - 150)) s after the print ended)"
else
  log "finished notification with the app in background: FAIL"
fi
adb shell input keyevent KEYCODE_WAKEUP || true
adb shell cmd statusbar expand-notifications || true
sleep 2
adb exec-out screencap -p > screenshots/e2e_3_shade_finished.png 2>/dev/null || true
adb shell cmd statusbar collapse || true
adb shell dumpsys notification --noredact | grep -E "android\.(title|text)=" | grep -vE "^\s*$" | head -12 | sed 's/^/E2E notif: /' | tee -a drive.txt

adb shell input keyevent KEYCODE_WAKEUP || true

kill $FAKE 2>/dev/null || true
head -3 fake_moonraker.log | sed 's/^/E2E /' >> drive.txt
tail -5 fake_moonraker.log | sed 's/^/E2E /' >> drive.txt
grep -c FAKE fake_moonraker.log | sed 's/^/E2E fake requests: /' >> drive.txt
adb logcat -d | grep -iE "PrintAlarm|PrintCheck|JobScheduler.*stl_weight|flutter" | tail -30 | sed 's/^/E2E log: /' >> drive.txt
exit 0
