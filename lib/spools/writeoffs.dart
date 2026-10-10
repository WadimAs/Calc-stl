import '../data/records.dart';
import '../orders/orders.dart';
import 'spools.dart';

/// Filament used by one print, written off spools.
class WriteOff {
  final String id;
  final DateTime date;
  final String printer;
  final String job;

  /// 'order', 'self' or 'failed'.
  final String purpose;
  final String? orderId;
  final String orderTitle;

  /// spool id → grams.
  final Map<String, double> grams;

  const WriteOff({
    required this.id,
    required this.date,
    required this.printer,
    required this.job,
    required this.purpose,
    this.orderId,
    this.orderTitle = '',
    required this.grams,
  });

  double get total => grams.values.fold(0.0, (a, b) => a + b);

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.millisecondsSinceEpoch,
        'printer': printer,
        'job': job,
        'purpose': purpose,
        'orderId': orderId,
        'orderTitle': orderTitle,
        'grams': grams,
      };

  static WriteOff? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    final g = <String, double>{};
    if (raw['grams'] is Map) {
      (raw['grams'] as Map).forEach((k, v) {
        if (k is String && v is num) g[k] = v.toDouble();
      });
    }
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return WriteOff(
      id: raw['id'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(raw['date'] is num ? (raw['date'] as num).toInt() : 0),
      printer: s('printer'),
      job: s('job'),
      purpose: s('purpose').isEmpty ? 'self' : s('purpose'),
      orderId: raw['orderId'] is String ? raw['orderId'] as String : null,
      orderTitle: s('orderTitle'),
      grams: g,
    );
  }
}

const writeOffStore = RecordStore<WriteOff>('writeoffs.json', WriteOff.fromJson, _wJson, _wId);
Map<String, dynamic> _wJson(WriteOff w) => w.toJson();
String _wId(WriteOff w) => w.id;

/// Takes the plastic off the spools and, for an order, remembers it there so
/// marking the order "Done" does not write it off a second time.
Future<void> applyWriteOff(WriteOff w) async {
  final g = {for (final e in w.grams.entries) if (e.value > 0) e.key: e.value};
  if (g.isEmpty) return;
  await SpoolStore.adjust({for (final e in g.entries) e.key: -e.value});
  if (w.orderId != null) {
    final orders = await OrderStore.load();
    for (final o in orders) {
      if (o.id != w.orderId) continue;
      g.forEach((k, v) => o.deducted[k] = (o.deducted[k] ?? 0) + v);
      await OrderStore.upsert(o);
    }
  }
  await writeOffStore.upsert(w);
}

/// Puts the plastic back.
Future<void> undoWriteOff(WriteOff w) async {
  await SpoolStore.adjust(w.grams);
  if (w.orderId != null) {
    final orders = await OrderStore.load();
    for (final o in orders) {
      if (o.id != w.orderId) continue;
      w.grams.forEach((k, v) {
        final left = (o.deducted[k] ?? 0) - v;
        if (left > 0.01) {
          o.deducted[k] = left;
        } else {
          o.deducted.remove(k);
        }
      });
      await OrderStore.upsert(o);
    }
  }
  await writeOffStore.remove(w.id);
}

String newWriteOffId() => newId();
