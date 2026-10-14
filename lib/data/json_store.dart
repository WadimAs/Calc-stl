import 'dart:convert';
import 'dart:io';

import '../platform/files.dart';

/// Called after every write (auto backup hooks in here).
void Function(String name)? onJsonWrite;

/// JSON documents in the app's private directory.
class JsonStore {
  static Future<File?> _file(String name) async {
    final dir = await PlatformFiles.filesDir();
    return dir == null ? null : File('$dir/$name');
  }

  static Future<Object?> read(String name) async {
    try {
      final f = await _file(name);
      if (f == null || !await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  /// Writes atomically (temp file + rename).
  static Future<void> write(String name, Object? value) async {
    final f = await _file(name);
    if (f == null) return;
    // Unique temp name: the app, the background check and the print service
    // may write the same file at once.
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}${identityHashCode(value)}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(value));
      await tmp.rename(f.path);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
    onJsonWrite?.call(name);
  }
}
