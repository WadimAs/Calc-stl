import 'dart:io';

import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../clients/clients.dart';
import '../data/photos.dart';
import '../data/records.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import '../orders/reminders.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import 'clients_page.dart';
import 'photos_ui.dart';
import 'quote_page.dart';
import 'spool_icon.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

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

String shortDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}';

/// "до 12.10" chip; red when overdue, orange for today/tomorrow.
class DueChip extends StatelessWidget {
  final Order order;

  const DueChip(this.order, {super.key});

  @override
  Widget build(BuildContext context) {
    final d = order.dueAt;
    if (d == null || order.status.printed) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final days = DateTime(d.year, d.month, d.day).difference(DateTime(now.year, now.month, now.day)).inDays;
    final c = days < 0
        ? scheme.error
        : days <= 1
            ? const Color(0xFFE8681F)
            : scheme.onSurfaceVariant;
    final text = days < 0
        ? trf('прострочено {0}', [shortDate(d)])
        : days == 0
            ? tr('сьогодні')
            : days == 1
                ? tr('завтра')
                : trf('до {0}', [shortDate(d)]);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.event_outlined, size: 12, color: c),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
      ]),
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
    final client = await pickClient(context);
    if (client == null || !mounted) return;
    final o = Order.create(widget.settings, client: client.name);
    if (client.id.isNotEmpty) {
      o.clientId = client.id;
      o.contact = client.phone.isNotEmpty ? client.phone : client.telegram;
    }
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
    // Active orders: nearest deadline first.
    if (_filter == 1 && list != null) {
      list.sort((a, b) {
        final da = a.dueAt, db = b.dueAt;
        if (da == null && db == null) return b.createdAt.compareTo(a.createdAt);
        if (da == null) return 1;
        if (db == null) return -1;
        return da.compareTo(db);
      });
    }
    final overdue = all?.where((o) => o.overdue).length ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Замовлення')),
        actions: [
          IconButton(
            tooltip: tr('Клієнти'),
            icon: const Icon(Icons.people_outline),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ClientsPage()));
              _reload();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        icon: const Icon(Icons.add),
        label: Text(tr('Нове')),
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Row(children: [
                  for (final (i, label) in [(0, tr('Усі')), (1, tr('Активні')), (2, tr('Готові')), (3, tr('Оплачені'))])
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
              if (overdue > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
                    const SizedBox(width: 6),
                    Text(trf('Прострочено: {0}', [overdue]), style: TextStyle(color: theme.colorScheme.error)),
                  ]),
                ),
              Expanded(
                child: list!.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            all.isEmpty
                                ? tr('Замовлень ще немає.\nДодайте розрахунок кнопкою «До замовлення» або створіть нове.')
                                : tr('Тут порожньо'),
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
                              leading: ItemThumb(o.photos.isNotEmpty
                                  ? o.photos.first
                                  : (o.items.isEmpty ? null : o.items.first.thumbPath)),
                              title: Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(children: [
                                  StatusChip(o.status),
                                  const SizedBox(width: 6),
                                  DueChip(o),
                                  if (o.dueAt != null && !o.status.printed) const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      trf('{0} шт · {1} · {2}', [t.pieces, fmtGrams(t.grams), formatDate(o.createdAt).split(' ').first]),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ]),
                              ),
                              trailing: Text(fmtMoney(t.total, code: o.currency), style: theme.textTheme.titleMedium),
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
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Скасувати'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(tr('Готово'))),
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
      _loadClient();
    });
  }

  Client? _linked;

  Future<void> _save() async {
    final o = _order;
    if (o == null) return;
    await OrderStore.upsert(o);
    await OrderReminders.sync(o);
  }

  Future<void> _loadClient() async {
    final id = _order?.clientId;
    if (id == null) {
      if (mounted) setState(() => _linked = null);
      return;
    }
    final list = await clientStore.load();
    final found = list.where((c) => c.id == id);
    if (mounted) setState(() => _linked = found.isEmpty ? null : found.first);
  }

  Future<void> _chooseClient() async {
    final c = await pickClient(context);
    if (c == null || !mounted) return;
    final o = _order!;
    setState(() {
      if (c.id.isEmpty) {
        o.clientId = null;
        o.client = '';
      } else {
        o.clientId = c.id;
        o.client = c.name;
        if (o.contact.isEmpty) o.contact = c.phone.isNotEmpty ? c.phone : c.telegram;
      }
    });
    _save();
    _loadClient();
  }

  Future<void> _chooseDue() async {
    final o = _order!;
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: o.dueAt ?? now.add(const Duration(days: 3)),
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      helpText: tr('Коли віддати замовлення'),
    );
    if (d == null) return;
    await PlatformFiles.requestNotifications();
    setState(() => o.dueAt = d);
    _save();
  }

  Future<void> _addFromCatalog() async {
    final products = await productStore.load();
    if (!mounted) return;
    if (products.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('Прайс-лист порожній. Додайте вироби кнопкою «У прайс-лист» після розрахунку.')),
      ));
      return;
    }
    final p = await showModalBottomSheet<Product>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(children: [
        for (final p in products)
          ListTile(
            leading: ItemThumb(p.picture, size: 40),
            title: Text(p.name),
            subtitle: Text('${p.material} · ${fmtGrams(p.grams)}'),
            trailing: Text(fmtMoney(p.price)),
            onTap: () => Navigator.pop(ctx, p),
          ),
      ]),
    );
    if (p == null) return;
    setState(() => _order!.items.add(productToItem(p)));
    _save();
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
            .showSnackBar(SnackBar(content: Text(tr('Пластик повернуто на котушки'))));
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
        title: Text(tr('Видалити замовлення?')),
        content: Text(o.deducted.isNotEmpty ? tr('Списаний пластик буде повернуто на котушки.') : o.title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Скасувати'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Видалити'))),
        ],
      ),
    );
    if (ok != true) return;
    if (o.deducted.isNotEmpty) await SpoolStore.adjust(o.deducted);
    await OrderReminders.cancel(o);
    for (final p in o.photos) {
      await Photos.delete(p);
    }
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
            tooltip: tr('Пропозиція для клієнта'),
            onPressed: o.items.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuotePage(order: o))),
            icon: const Icon(Icons.request_quote_outlined),
          ),
          IconButton(tooltip: tr('Видалити'), onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          Card(
            child: Column(children: [
              ListTile(
                leading: Icon(o.clientId != null ? Icons.person : Icons.person_outline),
                title: Text(o.client.isEmpty ? tr('Вибрати клієнта') : o.client),
                subtitle: o.clientId != null ? Text(tr('з бази клієнтів')) : null,
                trailing: IconButton(
                  tooltip: tr('Ввести ім\'я вручну'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _editField(tr('Клієнт'), o.client, (v) => o.client = v),
                ),
                onTap: _chooseClient,
                onLongPress: _linked == null
                    ? null
                    : () => Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => ClientPage(client: _linked!))),
              ),
              if (_linked != null && (_linked!.callUrl != null || _linked!.telegramUrl != null))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Align(alignment: Alignment.centerLeft, child: ContactButtons(_linked!)),
                ),
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Text(o.contact.isEmpty ? tr('Контакт (телефон, Telegram)') : o.contact),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editField(tr('Контакт'), o.contact, (v) => o.contact = v),
              ),
              ListTile(
                leading: Icon(Icons.event_outlined, color: o.overdue ? theme.colorScheme.error : null),
                title: Text(o.dueAt == null ? tr('Термін (нагадаю о 9:00)') : trf('Термін: {0}', [formatDate(o.dueAt!).split(' ').first]),
                    style: o.overdue ? TextStyle(color: theme.colorScheme.error) : null),
                subtitle: o.overdue ? Text(tr('прострочено')) : null,
                trailing: o.dueAt == null
                    ? const Icon(Icons.edit_calendar_outlined, size: 18)
                    : IconButton(
                        tooltip: tr('Прибрати термін'),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          setState(() => o.dueAt = null);
                          _save();
                        },
                      ),
                onTap: _chooseDue,
              ),
              ListTile(
                leading: const Icon(Icons.notes_outlined),
                title: Text(o.note.isEmpty ? tr('Примітка (колір, термін…)') : o.note),
                trailing: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => _editField(tr('Примітка'), o.note, (v) => o.note = v),
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
                    trf('Списано з котушок: {0}', [fmtGrams(o.deducted.values.fold(0.0, (a, b) => a + b))]),
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
                tr('Порожньо. Відкрийте модель і натисніть «До замовлення» під результатом.'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _addFromCatalog,
              icon: const Icon(Icons.storefront_outlined),
              label: Text(tr('Додати з прайс-листа')),
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
                          trf('{0} · {1} · {2} / шт', [it.material, fmtGrams(it.gramsEach), formatDuration(it.hoursEach)]),
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(trf('{0} / шт', [fmtMoney(it.priceEach, code: o.currency)]), style: theme.textTheme.bodySmall),
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
                row(trf('Деталі ({0} шт)', [t.pieces]), fmtMoney(t.subtotal, code: o.currency)),
                if (t.discount > 0) row(tr('Знижка від кількості'), '−${fmtMoney(t.discount, code: o.currency)}'),
                InkWell(
                  onTap: () => _editField(
                    trf('Доплата за замовлення, {0}', [currencySymbol(o.currency)]),
                    o.extraCost == o.extraCost.roundToDouble() ? o.extraCost.toStringAsFixed(0) : fmtNum(o.extraCost, 2),
                    (v) => o.extraCost = double.tryParse(v.replaceAll(',', '.')) ?? o.extraCost,
                    keyboard: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  child: row(tr('Доплата ✎'), fmtMoney(t.extra, code: o.currency)),
                ),
                if (t.minimumAdd > 0) row(tr('До мінімальної ціни'), fmtMoney(t.minimumAdd, code: o.currency)),
                if (t.rounding > 0.004) row(tr('Округлення'), fmtMoney(t.rounding, code: o.currency)),
                const Divider(),
                row(tr('Разом'), fmtMoney(t.total, code: o.currency), strong: true),
                const SizedBox(height: 6),
                row(tr('Собівартість'), fmtMoney(t.cost, code: o.currency)),
                row(tr('Прибуток'), fmtMoney(t.profit, code: o.currency)),
                row(tr('Пластик'), fmtGrams(t.grams)),
                row(tr('Час друку'), formatDuration(t.hours)),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          Text(tr('Фото готового виробу'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          PhotoStrip(
            photos: o.photos,
            onAdd: () async {
              final path = await addPhoto(context);
              if (path == null || !mounted) return;
              setState(() => o.photos.add(path));
              _save();
            },
            onOpen: (i) => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => PhotoViewer(
                photos: List.of(o.photos),
                initial: i,
                onDelete: (path) async {
                  await Photos.delete(path);
                  if (!mounted) return;
                  setState(() => o.photos.remove(path));
                  _save();
                },
              ),
            )),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: o.items.isEmpty
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuotePage(order: o))),
            icon: const Icon(Icons.send_outlined),
            label: Text(tr('Надіслати розрахунок клієнту')),
          ),
        ],
      ),
    );
  }
}

OrderItem productToItem(Product p, {int qty = 1}) => OrderItem(
      id: newId(),
      name: p.name,
      material: p.material,
      materialId: p.materialId,
      qty: qty,
      gramsEach: p.grams,
      hoursEach: p.hours,
      costEach: p.cost,
      priceEach: p.price,
      thumbPath: p.picture,
      source: tr('прайс'),
    );

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
      title: Text(tr('Списати пластик?')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final m in _need.keys) ...[
            Text('${materialById(m).name}: ${fmtGrams(_need[m]!)}', style: theme.textTheme.titleSmall),
            DropdownButton<String?>(
              isExpanded: true,
              value: _choice[m],
              items: [
                DropdownMenuItem<String?>(value: null, child: Text(tr('Не списувати'))),
                for (final s in widget.spools)
                  DropdownMenuItem<String?>(
                    value: s.id,
                    child: Row(children: [
                      SpoolIcon.of(s, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${s.title.isEmpty ? materialById(s.materialId).name : s.title} · ${fmtGrams(s.remainingGrams)}',
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
        TextButton(onPressed: () => Navigator.pop(context, <String, double>{}), child: Text(tr('Пропустити'))),
        FilledButton(
          onPressed: () {
            final plan = <String, double>{};
            _need.forEach((m, g) {
              final id = _choice[m];
              if (id != null) plan[id] = (plan[id] ?? 0) + g;
            });
            Navigator.pop(context, plan);
          },
          child: Text(tr('Списати')),
        ),
      ],
    );
  }
}
