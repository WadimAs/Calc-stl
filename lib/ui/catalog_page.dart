import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../catalog/stock.dart';
import '../data/photos.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import 'orders_page.dart';
import 'photos_ui.dart';
import 'stock_page.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

String priceListText(List<Product> list) {
  final b = StringBuffer(tr('Прайс-лист 3D-друку\n'));
  for (final p in list) {
    b.writeln('• ${p.name} (${p.material}) — ${fmtMoney(p.price)}');
  }
  return b.toString().trim();
}

/// Ready products with fixed prices: sell again without re-slicing.
class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key});

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  List<Product>? _list;
  bool _inStock = false;

  @override
  void initState() {
    super.initState();
    productStore.load().then((v) {
      if (mounted) setState(() => _list = v);
    });
  }

  Future<void> _edit(Product p) async {
    final name = TextEditingController(text: p.name);
    final price = TextEditingController(text: fmtNum(p.price, 2));
    final r = await showDialog<Product>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Виріб')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr('Назва')),
          ),
          TextField(
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: trf('Ціна за штуку, {0}', [currency])),
          ),
          const SizedBox(height: 8),
          Text(
            trf('Собівартість {0} · {1} · {2}', [fmtMoney(p.cost), fmtGrams(p.grams), formatDuration(p.hours)]),
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Скасувати'))),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              p.copyWith(
                name: name.text.trim().isEmpty ? p.name : name.text.trim(),
                price: double.tryParse(price.text.replaceAll(',', '.').replaceAll(' ', '')) ?? p.price,
              ),
            ),
            child: Text(tr('Зберегти')),
          ),
        ],
      ),
    );
    if (r == null) return;
    final list = await productStore.upsert(r);
    if (mounted) setState(() => _list = list);
  }

  Future<void> _setPhoto(Product p) async {
    final path = await addPhoto(context);
    if (path == null) return;
    if (p.photoPath != null) await Photos.delete(p.photoPath!);
    final list = await productStore.upsert(p.copyWith(photoPath: path));
    if (mounted) setState(() => _list = list);
  }

  void _viewPhoto(Product p) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => PhotoViewer(
          photos: [p.photoPath!],
          onDelete: (path) async {
            await Photos.delete(path);
            final list = await productStore.upsert(p.copyWith(clearPhoto: true));
            if (mounted) setState(() => _list = list);
          },
        ),
      ));

  Future<void> _delete(Product p) async {
    if (p.photoPath != null) await Photos.delete(p.photoPath!);
    final list = await productStore.remove(p.id);
    if (mounted) setState(() => _list = list);
  }

  /// Asks how many pieces (and the price for a sale).
  Future<(int, double)?> _askQty(Product p, String title, {int initial = 1, int? max, bool price = false, String? hint}) {
    final qty = TextEditingController(text: '$initial');
    final each = TextEditingController(text: fmtNum(p.price, 2));
    return showDialog<(int, double)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(p.name, style: Theme.of(ctx).textTheme.titleSmall),
          Text(trf('На складі: {0} шт', [p.stock]), style: Theme.of(ctx).textTheme.bodySmall),
          TextField(
            controller: qty,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Кількість, шт'), helperText: hint),
          ),
          if (price)
            TextField(
              controller: each,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: trf('Ціна за штуку, {0}', [currency])),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Скасувати'))),
          FilledButton(
            onPressed: () {
              var n = int.tryParse(qty.text.trim()) ?? -1;
              if (n < 0) return;
              if (max != null && n > max) n = max;
              final e = double.tryParse(each.text.replaceAll(',', '.').replaceAll(' ', '')) ?? p.price;
              Navigator.pop(ctx, (n, e));
            },
            child: Text(tr('Зберегти')),
          ),
        ],
      ),
    );
  }

  Future<void> _stock(Product p, String kind) async {
    final title = switch (kind) {
      'printed' => tr('Надруковано на склад'),
      'sold' => tr('Продано зі складу'),
      'defect' => tr('Списати зі складу'),
      _ => tr('Залишок на складі'),
    };
    final taking = kind == 'sold' || kind == 'defect';
    final r = await _askQty(p, title,
        initial: kind == 'adjust' ? p.stock : 1,
        max: taking ? p.stock : null,
        price: kind == 'sold',
        hint: kind == 'adjust' ? tr('Скільки штук є зараз') : null);
    if (r == null) return;
    final (n, each) = r;
    final delta = switch (kind) {
      'printed' => n,
      'adjust' => n - p.stock,
      _ => -n,
    };
    if (delta == 0) return;
    final list = await moveStock(p, delta, kind, amount: kind == 'sold' ? n * each : 0);
    if (!mounted) return;
    setState(() => _list = list);
    if (kind == 'sold') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(trf('Продано {0} шт на {1}', [n, fmtMoney(n * each)])),
      ));
    }
  }

  Future<void> _openLog() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StockPage()));
    final list = await productStore.load();
    if (mounted) setState(() => _list = list);
  }

  Future<void> _toOrder(Product p) async {
    final qtyCtl = TextEditingController(text: '1');
    final orders = (await OrderStore.load()).where((o) => !o.status.printed).toList();
    if (!mounted) return;
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: qtyCtl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Кількість, шт')),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(tr('Нове замовлення')),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final o in orders.take(8))
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(o.title),
              subtitle: Text(trf('{0} шт · {1}', [o.totals.pieces, fmtMoney(o.totals.total)])),
              onTap: () => Navigator.pop(ctx, o.id),
            ),
        ]),
      ),
    );
    if (target == null) return;
    final qty = (int.tryParse(qtyCtl.text.trim()) ?? 1).clamp(1, 100000).toInt();
    Order o;
    if (target.isEmpty) {
      o = Order.create(await PlatformFiles.loadSettings());
    } else {
      final all = await OrderStore.load();
      o = all.firstWhere((x) => x.id == target);
    }
    o.items.add(productToItem(p, qty: qty));
    await OrderStore.upsert(o);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: o.id)));
  }

  /// Stock totals and the "in stock only" filter.
  Widget _summary(List<Product> list) {
    final t = stockTotals(list);
    if (t.pieces == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      color: cs.primaryContainer,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.inventory_2_outlined, color: cs.onPrimaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(trf('На складі: {0} шт', [t.pieces]),
                  style: theme.textTheme.titleMedium?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            trf('Собівартість {0} · за цінами продажу {1}', [fmtMoney(t.cost), fmtMoney(t.value)]),
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              label: Text(tr('Лише в наявності')),
              selected: _inStock,
              onSelected: (v) => setState(() => _inStock = v),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Прайс-лист')),
        actions: [
          IconButton(
            tooltip: tr('Рух складу'),
            onPressed: _openLog,
            icon: const Icon(Icons.inventory_2_outlined),
          ),
          IconButton(
            tooltip: tr('Надіслати прайс'),
            onPressed: list == null || list.isEmpty
                ? null
                : () => PlatformFiles.shareText(priceListText(list)).catchError((Object _) {}),
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Порахуйте модель і натисніть «У прайс-лист» — виріб збережеться з ціною, і наступного разу його можна додати до замовлення в один дотик.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                  children: [
                    _summary(list),
                    for (final p in list.where((p) => !_inStock || p.stock > 0))
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: GestureDetector(
                            onTap: p.photoPath == null ? null : () => _viewPhoto(p),
                            child: ItemThumb(p.picture),
                          ),
                          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(
                              trf('{0} · {1} · собів. {2}', [p.material, fmtGrams(p.grams), fmtMoney(p.cost)]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (p.stock > 0)
                              Text(
                                trf('На складі: {0} шт', [p.stock]),
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                          ]),
                          onTap: () => _edit(p),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(fmtMoney(p.price), style: theme.textTheme.titleMedium),
                            PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'order') _toOrder(p);
                                if (v == 'edit') _edit(p);
                                if (v == 'del') _delete(p);
                                if (v == 'photo') _setPhoto(p);
                                if (v == 'share') sharePhoto(p.photoPath!).catchError((Object _) {});
                                if (const ['printed', 'sold', 'defect', 'adjust'].contains(v)) _stock(p, v);
                              },
                              itemBuilder: (_) => [
                                PopupMenuItem(value: 'order', child: Text(tr('До замовлення'))),
                                PopupMenuItem(value: 'printed', child: Text(tr('Надруковано на склад'))),
                                if (p.stock > 0) ...[
                                  PopupMenuItem(value: 'sold', child: Text(tr('Продано зі складу'))),
                                  PopupMenuItem(value: 'defect', child: Text(tr('Списати зі складу'))),
                                ],
                                PopupMenuItem(value: 'adjust', child: Text(tr('Залишок на складі'))),
                                const PopupMenuDivider(),
                                PopupMenuItem(value: 'edit', child: Text(tr('Змінити ціну'))),
                                PopupMenuItem(
                                    value: 'photo',
                                    child: Text(p.photoPath == null ? tr('Додати фото') : tr('Замінити фото'))),
                                if (p.photoPath != null)
                                  PopupMenuItem(value: 'share', child: Text(tr('Надіслати фото'))),
                                PopupMenuItem(value: 'del', child: Text(tr('Видалити'))),
                              ],
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
    );
  }
}
