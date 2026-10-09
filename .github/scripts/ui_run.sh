#!/usr/bin/env bash
# Runs the UI test on the emulator; screenshots are written by the app into
# its private files/screens and pulled regularly (also if the test hangs).
set -u
PKG=com.printcalc.stl_weight
mkdir -p screenshots
adb logcat -c || true

pull() {
  adb exec-out run-as $PKG tar cf - -C files screens > screens.tmp.tar 2>/dev/null
  if [ -s screens.tmp.tar ]; then mv screens.tmp.tar screens.tar; fi
}

( while true; do sleep 15; pull; done ) &
PULLER=$!

timeout 1800 flutter test integration_test/app_test.dart -d emulator-5554 -r expanded > drive.txt 2>&1
echo "flutter test exit $?" >> drive.txt

pull
kill $PULLER 2>/dev/null || true
adb logcat -d > logcat.txt 2>/dev/null || true
if [ -s screens.tar ]; then tar xf screens.tar -C screenshots --strip-components=1 || true; fi
ls -la screenshots
exit 0
