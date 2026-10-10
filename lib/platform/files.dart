import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../data/json_store.dart';
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

  /// Photo from the gallery / files, downscaled to JPEG (≤1600 px).
  static Future<Uint8List?> pickImage() => _image('pickImage');

  /// Photo from the camera app, downscaled to JPEG.
  static Future<Uint8List?> takePhoto() => _image('takePhoto');

  /// Text on a photo (on-device ML Kit, Latin script), lines separated by \n.
  static Future<String> recognizeText(Uint8List image) async {
    final r = await _channel.invokeMethod<String>('recognizeText', {'bytes': image});
    return r ?? '';
  }

  /// UI tests: returned instead of opening the camera / gallery.
  static Uint8List? debugImage;

  static Future<Uint8List?> _image(String method) async {
    if (debugImage != null) return debugImage;
    final r = await _channel.invokeMethod<Object?>(method);
    return r is Uint8List ? r : null;
  }

  /// Link shared to the app as text (e.g. from a browser), if any.
  static Future<String?> initialLink() async {
    try {
      return await _channel.invokeMethod<String>('getInitialLink');
    } catch (_) {
      return null;
    }
  }

  /// Files (and shared links) that arrive while the app is already running.
  static void listen(void Function(PickedFile file) onFile, {void Function(String url)? onLink}) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fileOpened') {
        final f = _fromMap(call.arguments);
        if (f != null) onFile(f);
      } else if (call.method == 'linkShared' && call.arguments is String) {
        onLink?.call(call.arguments as String);
      }
      return null;
    });
  }

  /// Order deadline notification at [at].
  static Future<void> scheduleReminder(int id, DateTime at, String title, String text) async {
    try {
      await _channel.invokeMethod<bool>(
          'scheduleReminder', {'id': id, 'at': at.millisecondsSinceEpoch, 'title': title, 'text': text});
    } catch (_) {}
  }

  /// Shows a notification right away (e.g. a print finished).
  static Future<void> notifyNow(int id, String title, String text) async {
    try {
      await _channel.invokeMethod<bool>('notifyNow', {'id': id, 'title': title, 'text': text});
    } catch (_) {}
  }

  static Future<void> cancelReminder(int id) async {
    try {
      await _channel.invokeMethod<bool>('cancelReminder', {'id': id});
    } catch (_) {}
  }

  /// Asks for the notification permission (Android 13+).
  static Future<void> requestNotifications() async {
    try {
      await _channel.invokeMethod<bool>('requestNotifications');
    } catch (_) {}
  }

  /// Lets the user choose a file (Google Drive, local folder…) for automatic
  /// backups. Returns a persistent document URI.
  static Future<String?> pickBackupTarget(String name) async {
    try {
      return await _channel.invokeMethod<String>('pickBackupTarget', {'name': name});
    } catch (_) {
      return null;
    }
  }

  /// Overwrites a document chosen earlier with [pickBackupTarget].
  static Future<bool> writeUri(String uri, Uint8List bytes) async {
    try {
      return await _channel.invokeMethod<bool>('writeUri', {'uri': uri, 'bytes': bytes}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Lets the user pick where to save [bytes] (system "Save as" dialog).
  static Future<bool> saveFile(String name, String mime, Uint8List bytes) async {
    final r = await _channel.invokeMethod<bool>('saveFile', {'name': name, 'mime': mime, 'bytes': bytes});
    return r ?? false;
  }

  /// Shares a file (e.g. a PNG quote) through the Android share sheet.
  static Future<void> shareFile(String name, String mime, Uint8List bytes, {String? text}) async {
    await _channel.invokeMethod<bool>('shareFile', {'name': name, 'mime': mime, 'bytes': bytes, 'text': text});
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
      onJsonWrite?.call('settings.json');
    } catch (_) {}
  }
}
