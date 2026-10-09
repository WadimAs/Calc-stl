import 'dart:convert';
import 'dart:typed_data';

import '../data/json_store.dart';
import '../history/history.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';

/// Everything the user entered, as one JSON file.
class Backup {
  static Future<Uint8List> export(SliceSettings settings) async {
    final history = await HistoryStore.load();
    final data = {
      'app': 'stl_weight',
      'version': 1,
      'created': DateTime.now().toIso8601String(),
      'settings': settings.toJson(),
      'history': [for (final e in history) e.toJson()],
      'orders': await JsonStore.read('orders.json') ?? [],
      'spools': await JsonStore.read('spools.json') ?? [],
    };
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
    if (raw['orders'] is List) await JsonStore.write('orders.json', raw['orders']);
    if (raw['spools'] is List) await JsonStore.write('spools.json', raw['spools']);
    return settings;
  }
}
