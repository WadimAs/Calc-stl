import 'dart:io';

import 'package:flutter/material.dart';

import '../history/history.dart';
import '../orders/orders.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import 'quote_page.dart';
import 'widgets.dart';

Color statusColor(OrderStatus s, ColorScheme c) => switch (s) {
      OrderStatus.fresh => c.tertiary,
      OrderStatus.inWork => c.primary,
      OrderStatus.done => const Color(0xFF2E7D32),
      OrderStatus.paid => c.outline,
    };

class StatusChip extends StatelessWidget {
  final OrderStatus status;

  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = statusColor(status, Theme.of(context).colorScheme);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(status.label, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class ItemThumb extends StatelessWidget {
  final String? path;
  final double size;

  const ItemThumb(this.path, {super.key, this.size = 48});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = path;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: p != null && File(p).existsSync()
            ? Image.file(File(p), width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true)
            : Icon(Icons.view_in_ar_outlined, color: theme.colorScheme.primary, size: size * 0.5),
      ),
    );
  }
}

/// List of orders with a status filter.
class OrdersPage extends StatefulWidget {
  final SliceSettings settings;

  const OrdersPage({super.key, required this.settings});

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  List<Order>? _orders;
  int _filter = 0; // 0 all, 1 active, 2 done, 3 paid

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await OrderStore.load();
    if (mounted) setState(() => _orders = list);
  }

  Future<void> _newOrder() async {
    final client = await askText(context, title: 'Нове замовлення', label: 'Клієнт (необов\'язково)');
    if (client == null) return;
    final o = Order.create(widget.settings, client: client);
    await OrderStore.upsert(o);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: o.id)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _orders;
    final list = all?.where((o) {
      switch (_filter) {
        case 1:
          return o.status == OrderStatus.fresh || o.status == OrderStatus.inWork;
        case 2:
          return o.status == OrderStatus.done;
        case 3:
          return o.status == OrderStatus.paid;
        default:
          return true;
      }
    }).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Замовлення')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        icon: const Icon(Icons.add),
        label: const Text('Нове'),
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(children: [
                  for (final (i, label) in [(0, 'Усі'), (1, 'Активні'), (2, 'Готові'), (3, 'Оплачені')])
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(label),
                        selected: _filter == i,
                        onSelected: (_) => setState(() => _filter = i),
                      ),
                    ),
                ]),
              ),
              Expanded(
                child: list!.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            all.isEmpty
                                ? 'Замовлень ще немає.\nДодайте розрахунок кнопкою «До замовлення» або створіть нове.'
                                : 'Тут порожньо',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final o = list[i];
                          final t = o.totals;
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              onTap: () async {
                                await Navigator.of(context)
                                    .push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: o.id)));
                                _reload();
                              },
                              leading: ItemThumb(o.items.isEmpty ? null : o.items.first.thumbPath),
                              title: Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(children: [
                                  StatusChip(o.status),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '${t.pieces} шт · ${fmtGrams(t.grams)} · ${formatDate(o.createdAt).split(' ').first}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ]),
                              ),
                              trailing: Text(fmtMoney(t.total), style: theme.textTheme.titleMedium),
                            ),
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

/// Simple text prompt; returns null when cancelled.
Future<String?> askText(BuildContext context,
    {required String title, required String label, String initial = '', TextInputType? keyboard}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: keyboard,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (_) => Navigator.pop(ctx, c.text.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Скасувати')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Готово')),
      ],
    ),
  );
}

/// One order: client, status, items, totals.
class OrderPage extends StatefulWidget {
  final String orderId;

  const OrderPage({super.key, required this.orderId});

  @override
  State<OrderPage> createState() => _OrderPageState();
}

class _OrderPageState extends State<OrderPage> {
  Order? _order;

  @override
  void initState() {
    super.initState();
    OrderStore.load().then((list) {
      final found = list.where((x) => x.id == widget.orderId);
      final o = found.isEmpty ? null : found.first;
      if (mounted) setState(() => _order = o);
    });
  }

  Future<void> _save() async {
    final o = _order;
    if (o != null) await OrderStore.upsert(o);
  }

  Future<void> _editField(String title, String current, void Function(String) apply,
      {TextInputType? keyboard}) async {
    final v = await askText(context, title: title, label: title, initial: current, keyboard: keyboard);
    if (v == null) return;
    setState(() => apply(v));
    _save();
  }

  Future<void> _setStatus(OrderStatus s) async {
    final o = _order!;
    if (s == o.status) return;
    final wasPrinted = o.status.printed;
    // Write the plastic off spools once the order is printed.
    if (s.printed && !wasPrinted && o.deducted.isEmpty) {
      final spools = await SpoolStore.load();
      if (spools.isNotEmpty && mounted) {
        final plan = await showDialog<Map<String, double>>(
          context: context,
          builder: (_) => _DeductDialog(order: o, spools: spools),
        );
        if (plan != null && plan.isNotEmpty) {
          await SpoolStore.adjust({for (final e in plan.entries) e.key: -e.value});
          o.deducted = plan;
        }
      }
    }
    // Back to "not printed": return the plastic.
    if (!s.printed && wasPrinted && o.deducted.isNotEmpty) {
      await SpoolStore.adjust(o.deducted);
      o.deducted = {};
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Пластик повернуто на котушки')));
      }
    }
    if (s.printed && o.doneAt == null) o.doneAt = DateTime.now();
    if (!s.printed) o.doneAt = null;
    setState(() => o.status = s);
    _save();
  }

  Future<void> _delete() async {
    final o = _order!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Видалити замовлення?'),
        content: Text(o.deducted.isNotEmpty ? 'Списаний пластик буде повернуто на котушки.' : o.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Видалити')),
        ],
      ),
    );
    if (ok != true) return;
    if (o.deducted.isNotEmpty) await SpoolStore.adjust(o.deducted);
    await OrderStore.remove(o.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final theme = Theme.of(context);
    if (o == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final t = o.totals;
    Widget row(String a, String b, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(a, style: strong ? theme.textTheme.titleSmall : theme.textTheme.bodyMedium)),
            Text(b, style: strong ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium),
          ]),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(o.title, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Пропозиція для клієнта',
            onPressed: o.items.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuotePage(order: o))),
            icon: const Icon(Icons.request_quote_outlined),
          ),
          IconButton(tooltip: 'Видалити', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          Card(
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(o.client.isEmpty ? 'Клієнт' : o.client),
                subtitle: o.contact.isEmpty ? null : Text(o.contact),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editField('Клієнт', o.client, (v) => o.client = v),
              ),
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(o.contact.isEmpty ? 'Контакт (телефон, Telegram)' : o.contact),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editField('Контакт', o.contact, (v) => o.contact = v),
              ),
              ListTile(
                leading: const Icon(Icons.notes_outlined),
                title: Text(o.note.isEmpty ? 'Примітка (колір, термін…)' : o.note),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editField('Примітка', o.note, (v) => o.note = v),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<OrderStatus>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
                    ),
                    showSelectedIcon: false,
                    segments: [
                      for (final s in OrderStatus.values) ButtonSegment(value: s, label: Text(s.label, maxLines: 1)),
                    ],
                    selected: {o.status},
                    onSelectionChanged: (v) => _setStatus(v.first),
                  ),
                ),
              ),
              if (o.deducted.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Списано з котушок: ${fmtGrams(o.deducted.values.fold(0.0, (a, b) => a + b))}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          if (o.items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Порожньо. Відкрийте модель і натисніть «До замовлення» під результатом.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          for (final it in o.items)
            Dismissible(
              key: ValueKey(it.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                color: theme.colorScheme.errorContainer,
                child: const Icon(Icons.delete_outline),
              ),
              onDismissed: (_) {
                setState(() => o.items.removeWhere((x) => x.id == it.id));
                _save();
              },
              child: Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [
                    ItemThumb(it.thumbPath, size: 52),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(it.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                        Text(
                          '${it.material} · ${fmtGrams(it.gramsEach)} · ${formatDuration(it.hoursEach)} / шт',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text('${fmtMoney(it.priceEach)} / шт', style: theme.textTheme.bodySmall),
                      ]),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: it.qty > 1
                          ? () {
                              setState(() => o.items[o.items.indexOf(it)] = it.copyWith(qty: it.qty - 1));
                              _save();
                            }
                          : null,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    Text('${it.qty}', style: theme.textTheme.titleMedium),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        setState(() => o.items[o.items.indexOf(it)] = it.copyWith(qty: it.qty + 1));
                        _save();
                      },
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  ]),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(children: [
                row('Деталі (${t.pieces} шт)', fmtMoney(t.subtotal)),
                if (t.discount > 0) row('Знижка від кількості', '−${fmtMoney(t.discount)}'),
                InkWell(
                  onTap: () => _editField(
                    'Доплата за замовлення, $currency',
                    o.extraCost == o.extraCost.roundToDouble() ? o.extraCost.toStringAsFixed(0) : fmtNum(o.extraCost, 2),
                    (v) => o.extraCost = double.tryParse(v.replaceAll(',', '.')) ?? o.extraCost,
                    keyboard: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  child: row('Доплата ✎', fmtMoney(t.extra)),
                ),
                if (t.minimumAdd > 0) row('До мінімальної ціни', fmtMoney(t.minimumAdd)),
                if (t.rounding > 0.004) row('Округлення', fmtMoney(t.rounding)),
                const Divider(),
                row('Разом', fmtMoney(t.total), strong: true),
                const SizedBox(height: 6),
                row('Собівартість', fmtMoney(t.cost)),
                row('Прибуток', fmtMoney(t.profit)),
                row('Пластик', fmtGrams(t.grams)),
                row('Час друку', formatDuration(t.hours)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: o.items.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuotePage(order: o))),
            icon: const Icon(Icons.send_outlined),
            label: const Text('Надіслати розрахунок клієнту'),
          ),
        ],
      ),
    );
  }
}

/// Which spool each material is written off from.
class _DeductDialog extends StatefulWidget {
  final Order order;
  final List<Spool> spools;

  const _DeductDialog({required this.order, required this.spools});

  @override
  State<_DeductDialog> createState() => _DeductDialogState();
}

class _DeductDialogState extends State<_DeductDialog> {
  late final Map<String, double> _need; // materialId -> grams
  final Map<String, String?> _choice = {}; // materialId -> spool id

  @override
  void initState() {
    super.initState();
    _need = {};
    for (final it in widget.order.items) {
      _need[it.materialId] = (_need[it.materialId] ?? 0) + it.gramsEach * it.qty;
    }
    for (final m in _need.keys) {
      final same = widget.spools.where((s) => s.materialId == m).toList()
        ..sort((a, b) => a.remainingGrams.compareTo(b.remainingGrams));
      final enough = same.where((s) => s.remainingGrams >= _need[m]!);
      _choice[m] = enough.isNotEmpty ? enough.first.id : (same.isEmpty ? null : same.last.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Списати пластик?'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final m in _need.keys) ...[
            Text('${materialById(m).name}: ${fmtGrams(_need[m]!)}', style: theme.textTheme.titleSmall),
            DropdownButton<String?>(
              isExpanded: true,
              value: _choice[m],
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Не списувати')),
                for (final s in widget.spools)
                  DropdownMenuItem<String?>(
                    value: s.id,
                    child: Row(children: [
                      CircleAvatar(radius: 7, backgroundColor: Color(s.colorArgb)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${s.name.isEmpty ? materialById(s.materialId).name : s.name} · ${fmtGrams(s.remainingGrams)}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: s.remainingGrams < _need[m]! ? theme.colorScheme.error : null),
                        ),
                      ),
                    ]),
                  ),
              ],
              onChanged: (v) => setState(() => _choice[m] = v),
            ),
            const SizedBox(height: 8),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, <String, double>{}), child: const Text('Пропустити')),
        FilledButton(
          onPressed: () {
            final plan = <String, double>{};
            _need.forEach((m, g) {
              final id = _choice[m];
              if (id != null) plan[id] = (plan[id] ?? 0) + g;
            });
            Navigator.pop(context, plan);
          },
          child: const Text('Списати'),
        ),
      ],
    );
  }
}
