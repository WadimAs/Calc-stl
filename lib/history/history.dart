import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../data/json_store.dart';
import '../platform/files.dart';
import '../i18n/i18n.dart';

/// One saved calculation.
class HistoryEntry {
  final String id;
  final DateTime date;
  final String name;
  final String material;
  final double density;
  final double pricePerKg;
  final double layerHeight;
  final double infillPercent;
  final int walls;
  final bool supports;
  final bool supportPlateOnly;
  final double scalePercent;
  final int copies;
  final double modelGrams; // one copy
  final double supportGrams; // one copy
  final double filamentMeters; // all copies
  final double materialCost;
  final double printHours; // all copies
  final double electricityCost;
  final double amortizationCost;
  final double costPrice; // plastic + electricity + amortization
  final double markupPercent;
  final double extraCost;
  final double totalCost; // selling price
  final double sizeX, sizeY, sizeZ;
  final String note;
  final String? thumbPath;

  /// Slicer whose exact numbers were used ('' = our estimate).
  final String source;

  HistoryEntry({
    required this.id,
    required this.date,
    required this.name,
    required this.material,
    required this.density,
    required this.pricePerKg,
    required this.layerHeight,
    required this.infillPercent,
    required this.walls,
    required this.supports,
    required this.supportPlateOnly,
    required this.scalePercent,
    required this.copies,
    required this.modelGrams,
    required this.supportGrams,
    required this.filamentMeters,
    required this.materialCost,
    this.printHours = 0,
    this.electricityCost = 0,
    this.amortizationCost = 0,
    double? costPrice,
    required this.markupPercent,
    required this.extraCost,
    required this.totalCost,
    required this.sizeX,
    required this.sizeY,
    required this.sizeZ,
    this.note = '',
    this.thumbPath,
    this.source = '',
  }) : costPrice = costPrice ?? materialCost + electricityCost + amortizationCost;

  double get totalGrams => (modelGrams + supportGrams) * copies;

  HistoryEntry withNote(String n) => HistoryEntry(
        id: id,
        date: date,
        name: name,
        material: material,
        density: density,
        pricePerKg: pricePerKg,
        layerHeight: layerHeight,
        infillPercent: infillPercent,
        walls: walls,
        supports: supports,
        supportPlateOnly: supportPlateOnly,
        scalePercent: scalePercent,
        copies: copies,
        modelGrams: modelGrams,
        supportGrams: supportGrams,
        filamentMeters: filamentMeters,
        materialCost: materialCost,
        printHours: printHours,
        electricityCost: electricityCost,
        amortizationCost: amortizationCost,
        costPrice: costPrice,
        markupPercent: markupPercent,
        extraCost: extraCost,
        totalCost: totalCost,
        sizeX: sizeX,
        sizeY: sizeY,
        sizeZ: sizeZ,
        note: n,
        thumbPath: thumbPath,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.millisecondsSinceEpoch,
        'name': name,
        'material': material,
        'density': density,
        'pricePerKg': pricePerKg,
        'layerHeight': layerHeight,
        'infillPercent': infillPercent,
        'walls': walls,
        'supports': supports,
        'supportPlateOnly': supportPlateOnly,
        'scalePercent': scalePercent,
        'copies': copies,
        'modelGrams': modelGrams,
        'supportGrams': supportGrams,
        'filamentMeters': filamentMeters,
        'materialCost': materialCost,
        'printHours': printHours,
        'electricityCost': electricityCost,
        'amortizationCost': amortizationCost,
        'costPrice': costPrice,
        'markupPercent': markupPercent,
        'extraCost': extraCost,
        'totalCost': totalCost,
        'sizeX': sizeX,
        'sizeY': sizeY,
        'sizeZ': sizeZ,
        'note': note,
        'thumbPath': thumbPath,
        'source': source,
      };

  static HistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0.0;
    int i(String k, int def) => raw[k] is num ? (raw[k] as num).toInt() : def;
    final id = raw['id'];
    if (id is! String) return null;
    return HistoryEntry(
      id: id,
      date: DateTime.fromMillisecondsSinceEpoch(i('date', 0)),
      name: raw['name'] is String ? raw['name'] as String : tr('модель'),
      material: raw['material'] is String ? raw['material'] as String : '',
      density: d('density'),
      pricePerKg: d('pricePerKg'),
      layerHeight: d('layerHeight'),
      infillPercent: d('infillPercent'),
      walls: i('walls', 0),
      supports: raw['supports'] == true,
      supportPlateOnly: raw['supportPlateOnly'] == true,
      scalePercent: raw['scalePercent'] is num ? d('scalePercent') : 100,
      copies: i('copies', 1),
      modelGrams: d('modelGrams'),
      supportGrams: d('supportGrams'),
      filamentMeters: d('filamentMeters'),
      materialCost: d('materialCost'),
      printHours: d('printHours'),
      electricityCost: d('electricityCost'),
      amortizationCost: d('amortizationCost'),
      costPrice: raw['costPrice'] is num ? d('costPrice') : null,
      markupPercent: d('markupPercent'),
      extraCost: d('extraCost'),
      totalCost: d('totalCost'),
      sizeX: d('sizeX'),
      sizeY: d('sizeY'),
      sizeZ: d('sizeZ'),
      note: raw['note'] is String ? raw['note'] as String : '',
      thumbPath: raw['thumbPath'] is String ? raw['thumbPath'] as String : null,
      source: raw['source'] is String ? raw['source'] as String : '',
    );
  }
}

/// Persists history as JSON in the app's private directory (newest first).
class HistoryStore {
  static Future<File?> _file() async {
    final dir = await PlatformFiles.filesDir();
    return dir == null ? null : File('$dir/history.json');
  }

  static Future<List<HistoryEntry>> load() async {
    try {
      final f = await _file();
      if (f == null || !await f.exists()) return [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return [];
      return raw.map(HistoryEntry.fromJson).whereType<HistoryEntry>().toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<HistoryEntry> list) async {
    final f = await _file();
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final e in list) e.toJson()]));
    await tmp.rename(f.path);
    onJsonWrite?.call('history.json');
  }

  /// Saves a thumbnail PNG and returns its path.
  static Future<String?> saveThumb(String id, Uint8List png) async {
    try {
      final dir = await PlatformFiles.filesDir();
      if (dir == null) return null;
      final d = Directory('$dir/thumbs');
      if (!await d.exists()) await d.create(recursive: true);
      final f = File('${d.path}/$id.png');
      await f.writeAsBytes(png);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  static Future<void> replaceAll(List<HistoryEntry> list) => _save(list);

  static Future<List<HistoryEntry>> add(HistoryEntry e) async {
    final list = await load();
    list.insert(0, e);
    await _save(list);
    return list;
  }

  static Future<List<HistoryEntry>> update(HistoryEntry e) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == e.id);
    if (i >= 0) list[i] = e;
    await _save(list);
    return list;
  }

  static Future<List<HistoryEntry>> remove(String id) async {
    final list = await load();
    final removed = list.where((x) => x.id == id).toList();
    list.removeWhere((x) => x.id == id);
    await _save(list);
    for (final e in removed) {
      await _deleteThumb(e);
    }
    return list;
  }

  static Future<void> clear() async {
    final list = await load();
    await _save([]);
    for (final e in list) {
      await _deleteThumb(e);
    }
  }

  static Future<void> _deleteThumb(HistoryEntry e) async {
    final p = e.thumbPath;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// CSV of the whole history (for sharing / Excel).
  static String toCsv(List<HistoryEntry> list) {
    String q(String v) => '"${v.replaceAll('"', '""')}"';
    final b = StringBuffer();
    b.writeln(tr('Дата;Модель;Матеріал;Копій;Вага моделі, г;Підтримки, г;Разом, г;Філамент, м;Час, год;Ціна за кг;Пластик, грн;Електроенергія, грн;Амортизація, грн;Собівартість, грн;Націнка %;Доплата;Ціна, грн;Примітка'));
    for (final e in list) {
      String n(double v, [int f = 2]) => v.toStringAsFixed(f).replaceAll('.', ',');
      b.writeln([
        q(formatDate(e.date)),
        q(e.name),
        q(e.material),
        '${e.copies}',
        n(e.modelGrams),
        n(e.supportGrams),
        n(e.totalGrams),
        n(e.filamentMeters),
        n(e.printHours),
        n(e.pricePerKg, 0),
        n(e.materialCost),
        n(e.electricityCost),
        n(e.amortizationCost),
        n(e.costPrice),
        n(e.markupPercent, 0),
        n(e.extraCost),
        n(e.totalCost),
        q(e.note),
      ].join(';'));
    }
    return b.toString();
  }
}

String formatDate(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

String formatDuration(double hours) {
  final totalMin = (hours * 60).round();
  final h = totalMin ~/ 60, m = totalMin % 60;
  if (h == 0) return trf('{0} хв', [m]);
  return trf('{0} год {1} хв', [h, m.toString().padLeft(2, '0')]);
}
