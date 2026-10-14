import '../data/records.dart';
import 'catalog.dart';

/// One change of a product's stock: printed, sold, defect or a manual count.
class StockMove {
  final String id;
  final String productId;
  final String productName;
  final DateTime date;

  /// Pieces added (+) or taken (−).
  final int qty;

  /// 'printed', 'sold', 'defect' or 'adjust'.
  final String kind;

  /// Money received for a sale (whole move).
  final double amount;

  /// Cost price per piece at the time.
  final double costEach;
  final String note;

  const StockMove({
    required this.id,
    required this.productId,
    required this.productName,
    required this.date,
    required this.qty,
    required this.kind,
    this.amount = 0,
    this.costEach = 0,
    this.note = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'product': productId,
        'name': productName,
        'date': date.millisecondsSinceEpoch,
        'qty': qty,
        'kind': kind,
        if (amount != 0) 'amount': amount,
        if (costEach != 0) 'cost': costEach,
        if (note.isNotEmpty) 'note': note,
      };

  static StockMove? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['product'] is! String) return null;
    double d(String k) => raw[k] is num ? (raw[k] as num).toDouble() : 0.0;
    return StockMove(
      id: raw['id'] as String,
      productId: raw['product'] as String,
      productName: raw['name'] is String ? raw['name'] as String : '',
      date: DateTime.fromMillisecondsSinceEpoch(raw['date'] is num ? (raw['date'] as num).toInt() : 0),
      qty: raw['qty'] is num ? (raw['qty'] as num).toInt() : 0,
      kind: raw['kind'] is String ? raw['kind'] as String : 'adjust',
      amount: d('amount'),
      costEach: d('cost'),
      note: raw['note'] is String ? raw['note'] as String : '',
    );
  }
}

const stockStore = RecordStore<StockMove>('stock.json', StockMove.fromJson, _json, _id);
Map<String, dynamic> _json(StockMove m) => m.toJson();
String _id(StockMove m) => m.id;

/// Changes the product's stock by [qty] and logs it. Returns the new price list.
Future<List<Product>> moveStock(Product p, int qty, String kind, {double amount = 0, String note = ''}) async {
  final list = await productStore.load();
  final cur = list.where((x) => x.id == p.id).firstOrNull ?? p;
  final next = cur.copyWith(stock: (cur.stock + qty).clamp(0, 1 << 30).toInt());
  await stockStore.upsert(StockMove(
    id: newId(),
    productId: p.id,
    productName: cur.name,
    date: DateTime.now(),
    qty: next.stock - cur.stock,
    kind: kind,
    amount: amount,
    costEach: cur.cost,
    note: note,
  ));
  return productStore.upsert(next, atStart: false);
}

/// Undoes a move (deleted from the log): the stock goes back.
Future<List<Product>> undoStockMove(StockMove m) async {
  await stockStore.remove(m.id);
  final list = await productStore.load();
  final p = list.where((x) => x.id == m.productId).firstOrNull;
  if (p == null) return list;
  return productStore.upsert(p.copyWith(stock: (p.stock - m.qty).clamp(0, 1 << 30).toInt()), atStart: false);
}

/// What lies in stock: pieces, cost value and value at selling prices.
({int pieces, double cost, double value}) stockTotals(List<Product> list) {
  int n = 0;
  double c = 0, v = 0;
  for (final p in list) {
    if (p.stock <= 0) continue;
    n += p.stock;
    c += p.stock * p.cost;
    v += p.stock * p.price;
  }
  return (pieces: n, cost: c, value: v);
}
