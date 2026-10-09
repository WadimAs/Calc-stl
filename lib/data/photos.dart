import 'dart:io';
import 'dart:typed_data';

import '../platform/files.dart';
import 'records.dart';

/// Photos of finished products, stored as JPEG in the app's private folder.
class Photos {
  static Future<String?> save(Uint8List jpeg) async {
    final dir = await PlatformFiles.filesDir();
    if (dir == null) return null;
    final d = Directory('$dir/photos');
    if (!await d.exists()) await d.create(recursive: true);
    final f = File('${d.path}/${newId()}.jpg');
    await f.writeAsBytes(jpeg);
    return f.path;
  }

  static Future<void> delete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
