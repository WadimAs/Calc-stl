import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import 'orders_page.dart';
import 'widgets.dart';

String priceListText(List<Product> list) {
  final b = StringBuffer('Прайс-лист 3D-друку\n');
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
        title: const Text('Виріб'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Назва'),
          ),
          TextField(
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: 'Ціна за штуку, $currency'),
          ),
          const SizedBox(height: 8),
          Text(
            'Собівартість ${fmtMoney(p.cost)} · ${fmtGrams(p.grams)} · ${formatDuration(p.hours)}',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Скасувати')),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              p.copyWith(
                name: name.text.trim().isEmpty ? p.name : name.text.trim(),
                price: double.tryParse(price.text.replaceAll(',', '.').replaceAll(' ', '')) ?? p.price,
              ),
            ),
            child: const Text('Зберегти'),
          ),
        ],
      ),
    );
    if (r == null) return;
    final list = await productStore.upsert(r);
    if (mounted) setState(() => _list = list);
  }

  Future<void> _delete(Product p) async {
    final list = await productStore.remove(p.id);
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
              decoration: const InputDecoration(labelText: 'Кількість, шт'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Нове замовлення'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final o in orders.take(8))
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(o.title),
              subtitle: Text('${o.totals.pieces} шт · ${fmtMoney(o.totals.total)}'),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Прайс-лист'),
        actions: [
          IconButton(
            tooltip: 'Надіслати прайс',
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
                      'Порахуйте модель і натисніть «У прайс-лист» — виріб збережеться з ціною, '
                      'і наступного разу його можна додати до замовлення в один дотик.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
                  children: [
                    for (final p in list)
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ListTile(
                          leading: ItemThumb(p.thumbPath),
                          title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${p.material} · ${fmtGrams(p.grams)} · собів. ${fmtMoney(p.cost)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _edit(p),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(fmtMoney(p.price), style: theme.textTheme.titleMedium),
                            PopupMenuButton<String>(
                              onSelected: (v) {
                                if (v == 'order') _toOrder(p);
                                if (v == 'edit') _edit(p);
                                if (v == 'del') _delete(p);
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(value: 'order', child: Text('До замовлення')),
                                PopupMenuItem(value: 'edit', child: Text('Змінити ціну')),
                                PopupMenuItem(value: 'del', child: Text('Видалити')),
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
