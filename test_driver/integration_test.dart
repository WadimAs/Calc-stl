import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await Directory('screenshots').create(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      await File('screenshots/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
}
