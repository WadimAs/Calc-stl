import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../slicer/settings.dart';

class PickedFile {
  final String name;
  final Uint8List bytes;

  const PickedFile(this.name, this.bytes);
}

/// Bridge to MainActivity.kt: system file picker, "Open with…" intents,
/// and the app's private directory for settings.
class PlatformFiles {
  static const _channel = MethodChannel('stl_weight/files');

  static PickedFile? _fromMap(Object? r) {
    if (r is! Map) return null;
    final bytes = r['bytes'];
    if (bytes is! Uint8List) return null;
    return PickedFile((r['name'] as String?) ?? 'model.stl', bytes);
  }

  /// Opens the system document picker.
  static Future<PickedFile?> pick() async {
    final r = await _channel.invokeMethod<Object?>('pickFile');
    return _fromMap(r);
  }

  /// File the app was launched with ("Open with" / "Share"), if any.
  static Future<PickedFile?> initialFile() async {
    try {
      final r = await _channel.invokeMethod<Object?>('getInitialFile');
      return _fromMap(r);
    } on MissingPluginException {
      return null;
    }
  }

  /// Files that arrive while the app is already running.
  static void listen(void Function(PickedFile file) onFile) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fileOpened') {
        final f = _fromMap(call.arguments);
        if (f != null) onFile(f);
      }
      return null;
    });
  }

  /// Lets the user pick where to save [bytes] (system "Save as" dialog).
  static Future<bool> saveFile(String name, String mime, Uint8List bytes) async {
    final r = await _channel.invokeMethod<bool>('saveFile', {'name': name, 'mime': mime, 'bytes': bytes});
    return r ?? false;
  }

  /// Opens the Android share sheet with plain text.
  static Future<void> shareText(String text) async {
    await _channel.invokeMethod<bool>('shareText', {'text': text});
  }

  static String? _filesDir;

  /// App-private directory (null when not running on Android).
  static Future<String?> filesDir() async {
    if (_filesDir != null) return _filesDir;
    try {
      _filesDir = await _channel.invokeMethod<String>('filesDir');
    } on MissingPluginException {
      _filesDir = null;
    }
    return _filesDir;
  }

  static Future<File?> _settingsFile() async {
    final dir = await filesDir();
    return dir == null ? null : File('$dir/settings.json');
  }

  static Future<SliceSettings> loadSettings() async {
    try {
      final f = await _settingsFile();
      if (f == null || !await f.exists()) return const SliceSettings();
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic>) return SliceSettings.fromJson(j);
    } catch (_) {}
    return const SliceSettings();
  }

  static Future<void> saveSettings(SliceSettings s) async {
    try {
      final f = await _settingsFile();
      await f?.writeAsString(jsonEncode(s.toJson()));
    } catch (_) {}
  }
}
