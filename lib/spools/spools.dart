import '../data/json_store.dart';

/// A spool of filament with what is left on it.
class Spool {
  final String id;
  final String materialId;
  final String name; // brand / colour as the user writes it
  final int colorArgb;
  final double totalGrams;
  final double remainingGrams;
  final DateTime createdAt;

  /// What the whole spool cost (0 = unknown).
  final double price;

  const Spool({
    required this.id,
    required this.materialId,
    required this.name,
    required this.colorArgb,
    required this.totalGrams,
    required this.remainingGrams,
    required this.createdAt,
    this.price = 0,
  });

  /// Price per kilogram from the purchase, or null.
  double? get pricePerKg => price > 0 && totalGrams > 0 ? price / totalGrams * 1000 : null;

  double get fraction => totalGrams > 0 ? (remainingGrams / totalGrams).clamp(0.0, 1.0).toDouble() : 0;

  bool get isLow => remainingGrams < 150;

  Spool copyWith(
          {String? materialId, String? name, int? colorArgb, double? totalGrams, double? remainingGrams, double? price}) =>
      Spool(
        id: id,
        materialId: materialId ?? this.materialId,
        name: name ?? this.name,
        colorArgb: colorArgb ?? this.colorArgb,
        totalGrams: totalGrams ?? this.totalGrams,
        remainingGrams: remainingGrams ?? this.remainingGrams,
        createdAt: createdAt,
        price: price ?? this.price,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'materialId': materialId,
        'name': name,
        'color': colorArgb,
        'total': totalGrams,
        'remaining': remainingGrams,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'price': price,
      };

  static Spool? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    double d(String k, double def) => raw[k] is num ? (raw[k] as num).toDouble() : def;
    return Spool(
      id: raw['id'] as String,
      materialId: raw['materialId'] is String ? raw['materialId'] as String : 'PLA',
      name: raw['name'] is String ? raw['name'] as String : '',
      colorArgb: raw['color'] is num ? (raw['color'] as num).toInt() : 0xFFFF8A3D,
      totalGrams: d('total', 1000),
      remainingGrams: d('remaining', 1000),
      createdAt: DateTime.fromMillisecondsSinceEpoch(raw['createdAt'] is num ? (raw['createdAt'] as num).toInt() : 0),
      price: d('price', 0),
    );
  }
}

class SpoolStore {
  static const _file = 'spools.json';

  static Future<List<Spool>> load() async {
    final raw = await JsonStore.read(_file);
    if (raw is! List) return [];
    return raw.map(Spool.fromJson).whereType<Spool>().toList();
  }

  static Future<void> saveAll(List<Spool> list) => JsonStore.write(_file, [for (final s in list) s.toJson()]);

  static Future<List<Spool>> upsert(Spool s) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      list[i] = s;
    } else {
      list.add(s);
    }
    await saveAll(list);
    return list;
  }

  static Future<List<Spool>> remove(String id) async {
    final list = await load()
      ..removeWhere((x) => x.id == id);
    await saveAll(list);
    return list;
  }

  /// Adds [grams] (negative to write off) to each spool in [changes].
  static Future<List<Spool>> adjust(Map<String, double> changes) async {
    final list = await load();
    for (int i = 0; i < list.length; i++) {
      final d = changes[list[i].id];
      if (d == null) continue;
      final r = (list[i].remainingGrams + d).clamp(0.0, double.infinity).toDouble();
      list[i] = list[i].copyWith(remainingGrams: r);
    }
    await saveAll(list);
    return list;
  }
}
