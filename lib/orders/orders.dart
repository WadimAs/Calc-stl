import '../data/json_store.dart';
import '../slicer/settings.dart';

enum OrderStatus { fresh, inWork, done, paid }

extension OrderStatusInfo on OrderStatus {
  String get label => switch (this) {
        OrderStatus.fresh => 'Нове',
        OrderStatus.inWork => 'У роботі',
        OrderStatus.done => 'Готово',
        OrderStatus.paid => 'Оплачено',
      };

  /// Printed: plastic is spent, counts in the statistics.
  bool get printed => this == OrderStatus.done || this == OrderStatus.paid;
}

OrderStatus _status(Object? v) {
  for (final s in OrderStatus.values) {
    if (s.name == v) return s;
  }
  return OrderStatus.fresh;
}

/// One model in an order. Prices are per piece and frozen when added.
class OrderItem {
  final String id;
  final String name;
  final String material;
  final String materialId;
  final int qty;
  final double gramsEach;
  final double hoursEach;
  final double costEach; // cost price per piece
  final double priceEach; // cost + profit per piece, before quantity discount
  final String? thumbPath;
  final String source; // slicer name when the numbers were exact

  const OrderItem({
    required this.id,
    required this.name,
    required this.material,
    required this.materialId,
    required this.qty,
    required this.gramsEach,
    required this.hoursEach,
    required this.costEach,
    required this.priceEach,
    this.thumbPath,
    this.source = '',
  });

  OrderItem copyWith({int? qty, String? name}) => OrderItem(
        id: id,
        name: name ?? this.name,
        material: material,
        materialId: materialId,
        qty: qty ?? this.qty,
        gramsEach: gramsEach,
        hoursEach: hoursEach,
        costEach: costEach,
        priceEach: priceEach,
        thumbPath: thumbPath,
        source: source,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'material': material,
        'materialId': materialId,
        'qty': qty,
        'gramsEach': gramsEach,
        'hoursEach': hoursEach,
        'costEach': costEach,
        'priceEach': priceEach,
        'thumbPath': thumbPath,
        'source': source,
      };

  static OrderItem? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0.0;
    return OrderItem(
      id: raw['id'] as String,
      name: raw['name'] is String ? raw['name'] as String : 'модель',
      material: raw['material'] is String ? raw['material'] as String : '',
      materialId: raw['materialId'] is String ? raw['materialId'] as String : 'PLA',
      qty: raw['qty'] is num ? (raw['qty'] as num).toInt() : 1,
      gramsEach: d('gramsEach'),
      hoursEach: d('hoursEach'),
      costEach: d('costEach'),
      priceEach: d('priceEach'),
      thumbPath: raw['thumbPath'] is String ? raw['thumbPath'] as String : null,
      source: raw['source'] is String ? raw['source'] as String : '',
    );
  }
}

class Order {
  final String id;
  final DateTime createdAt;
  DateTime? doneAt;

  /// Deadline (date the client expects the order).
  DateTime? dueAt;
  String? clientId;
  String client;
  String contact;
  String note;
  OrderStatus status;
  List<OrderItem> items;

  // Pricing rules frozen when the order was created.
  double extraCost;
  double minPrice;
  double roundTo;
  List<QtyDiscount> discounts;

  /// Plastic written off spools when the order was printed: spool id → grams.
  Map<String, double> deducted;

  Order({
    required this.id,
    required this.createdAt,
    this.doneAt,
    this.dueAt,
    this.clientId,
    this.client = '',
    this.contact = '',
    this.note = '',
    this.status = OrderStatus.fresh,
    List<OrderItem>? items,
    this.extraCost = 0,
    this.minPrice = 0,
    this.roundTo = 0,
    this.discounts = const [],
    Map<String, double>? deducted,
  })  : items = items ?? [],
        deducted = deducted ?? {};

  factory Order.create(SliceSettings s, {String client = ''}) => Order(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt: DateTime.now(),
        client: client,
        extraCost: s.extraCost,
        minPrice: s.minOrderPrice,
        roundTo: s.roundTo,
        discounts: s.discounts,
      );

  String get title => client.trim().isNotEmpty ? client.trim() : 'Замовлення від ${_date(createdAt)}';

  /// Not printed yet and the deadline has passed.
  bool get overdue {
    final d = dueAt;
    if (d == null || status.printed) return false;
    final now = DateTime.now();
    return DateTime(d.year, d.month, d.day).isBefore(DateTime(now.year, now.month, now.day));
  }

  /// Invoice number derived from the creation time, e.g. 261009-1432.
  String get number {
    String two(int v) => v.toString().padLeft(2, '0');
    final d = createdAt;
    return '${two(d.year % 100)}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}';
  }

  /// Stable small id for notifications.
  int get reminderId => id.hashCode & 0x7fffffff;

  OrderTotals get totals {
    double sub = 0, disc = 0, cost = 0, grams = 0, hours = 0;
    int pieces = 0;
    for (final it in items) {
      final s = it.priceEach * it.qty;
      sub += s;
      disc += s * discountFor(discounts, it.qty) / 100;
      cost += it.costEach * it.qty;
      grams += it.gramsEach * it.qty;
      hours += it.hoursEach * it.qty;
      pieces += it.qty;
    }
    final before = items.isEmpty ? 0.0 : sub - disc + extraCost;
    final (minAdd, rounding) = items.isEmpty ? (0.0, 0.0) : finishPriceRaw(before, minPrice, roundTo);
    final total = before + minAdd + rounding;
    return OrderTotals(
      subtotal: sub,
      discount: disc,
      extra: items.isEmpty ? 0 : extraCost,
      minimumAdd: minAdd,
      rounding: rounding,
      total: total,
      cost: cost,
      grams: grams,
      hours: hours,
      pieces: pieces,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'doneAt': doneAt?.millisecondsSinceEpoch,
        'dueAt': dueAt?.millisecondsSinceEpoch,
        'clientId': clientId,
        'client': client,
        'contact': contact,
        'note': note,
        'status': status.name,
        'items': [for (final i in items) i.toJson()],
        'extraCost': extraCost,
        'minPrice': minPrice,
        'roundTo': roundTo,
        'discounts': [for (final d in discounts) d.toJson()],
        'deducted': deducted,
      };

  static Order? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0.0;
    final deducted = <String, double>{};
    if (raw['deducted'] is Map) {
      (raw['deducted'] as Map).forEach((k, v) {
        if (k is String && v is num) deducted[k] = v.toDouble();
      });
    }
    return Order(
      id: raw['id'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(raw['createdAt'] is num ? (raw['createdAt'] as num).toInt() : 0),
      doneAt: raw['doneAt'] is num ? DateTime.fromMillisecondsSinceEpoch((raw['doneAt'] as num).toInt()) : null,
      dueAt: raw['dueAt'] is num ? DateTime.fromMillisecondsSinceEpoch((raw['dueAt'] as num).toInt()) : null,
      clientId: raw['clientId'] is String ? raw['clientId'] as String : null,
      client: raw['client'] is String ? raw['client'] as String : '',
      contact: raw['contact'] is String ? raw['contact'] as String : '',
      note: raw['note'] is String ? raw['note'] as String : '',
      status: _status(raw['status']),
      items: raw['items'] is List
          ? (raw['items'] as List).map(OrderItem.fromJson).whereType<OrderItem>().toList()
          : <OrderItem>[],
      extraCost: d('extraCost'),
      minPrice: d('minPrice'),
      roundTo: d('roundTo'),
      discounts: [
        if (raw['discounts'] is List)
          for (final e in raw['discounts'] as List)
            if (e is List && e.length >= 2 && e[0] is num && e[1] is num)
              QtyDiscount((e[0] as num).toInt(), (e[1] as num).toDouble()),
      ],
      deducted: deducted,
    );
  }
}

class OrderTotals {
  final double subtotal, discount, extra, minimumAdd, rounding, total, cost, grams, hours;
  final int pieces;

  const OrderTotals({
    required this.subtotal,
    required this.discount,
    required this.extra,
    required this.minimumAdd,
    required this.rounding,
    required this.total,
    required this.cost,
    required this.grams,
    required this.hours,
    required this.pieces,
  });

  double get profit => total - cost;
}

String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

class OrderStore {
  static const _file = 'orders.json';

  static Future<List<Order>> load() async {
    final raw = await JsonStore.read(_file);
    if (raw is! List) return [];
    return raw.map(Order.fromJson).whereType<Order>().toList();
  }

  static Future<void> saveAll(List<Order> list) => JsonStore.write(_file, [for (final o in list) o.toJson()]);

  static Future<List<Order>> upsert(Order o) async {
    final list = await load();
    final i = list.indexWhere((x) => x.id == o.id);
    if (i >= 0) {
      list[i] = o;
    } else {
      list.insert(0, o);
    }
    await saveAll(list);
    return list;
  }

  static Future<List<Order>> remove(String id) async {
    final list = await load()
      ..removeWhere((x) => x.id == id);
    await saveAll(list);
    return list;
  }
}
