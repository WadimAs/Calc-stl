import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../data/json_store.dart';
import '../history/history.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';

/// Everything the user entered, as one JSON file.
class Backup {
  /// Plain JSON documents copied as they are.
  static const files = {
    'orders': 'orders.json',
    'spools': 'spools.json',
    'clients': 'clients.json',
    'expenses': 'expenses.json',
    'catalog': 'catalog.json',
    'business': 'business.json',
    'printers': 'printers.json',
  };

  static Future<Uint8List> export(SliceSettings settings) async {
    final history = await HistoryStore.load();
    final data = <String, Object?>{
      'app': 'stl_weight',
      'version': 2,
      'created': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'history': [for (final e in history) e.toJson()],
    };
    for (final e in files.entries) {
      final v = await JsonStore.read(e.value);
      if (v != null) data[e.key] = v;
    }
    return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(data)));
  }

  /// Restores a backup; returns the restored settings.
  static Future<SliceSettings> restore(Uint8List bytes) async {
    final raw = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (raw is! Map || raw['app'] != 'stl_weight') {
      throw const FormatException('Це не резервна копія STL Вага');
    }
    final settings = raw['settings'] is Map
        ? SliceSettings.fromJson(Map<String, dynamic>.from(raw['settings'] as Map))
        : const SliceSettings();
    await PlatformFiles.saveSettings(settings);
    if (raw['history'] is List) {
      final list = (raw['history'] as List).map(HistoryEntry.fromJson).whereType<HistoryEntry>().toList();
      await HistoryStore.replaceAll(list);
    }
    for (final e in files.entries) {
      final v = raw[e.key];
      if (v is List || v is Map) await JsonStore.write(e.value, v);
    }
    return settings;
  }
}

/// Copies the backup into a file the user picked once (Google Drive, Files…),
/// a few seconds after data changes.
class AutoBackup {
  static const _cfg = 'autobackup.json';
  static String? _uri;
  static DateTime? lastOk;
  static bool lastFailed = false;
  static Timer? _timer;
  static SliceSettings Function()? settingsSource;
  static bool _loaded = false;

  static Future<String?> target() async {
    if (!_loaded) {
      final raw = await JsonStore.read(_cfg);
      if (raw is Map) {
        _uri = raw['uri'] is String ? raw['uri'] as String : null;
        lastOk = raw['last'] is num ? DateTime.fromMillisecondsSinceEpoch((raw['last'] as num).toInt()) : null;
      }
      _loaded = true;
    }
    return _uri;
  }

  static Future<void> _saveCfg() =>
      JsonStore.write(_cfg, {'uri': _uri, 'last': lastOk?.millisecondsSinceEpoch});

  /// Asks where to keep the copy. Returns true when set up.
  static Future<bool> setup() async {
    final uri = await PlatformFiles.pickBackupTarget('stl-vaga-autobackup.json');
    if (uri == null) return false;
    _uri = uri;
    _loaded = true;
    await _saveCfg();
    return runNow();
  }

  static Future<void> disable() async {
    _uri = null;
    lastOk = null;
    _timer?.cancel();
    await _saveCfg();
  }

  /// Debounced: call after any change.
  static void schedule() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 4), () => runNow());
  }

  static Future<bool> runNow() async {
    final uri = await target();
    final src = settingsSource;
    if (uri == null || src == null) return false;
    final ok = await PlatformFiles.writeUri(uri, await Backup.export(src()));
    lastFailed = !ok;
    if (ok) {
      lastOk = DateTime.now();
      await _saveCfg();
    }
    return ok;
  }
}
