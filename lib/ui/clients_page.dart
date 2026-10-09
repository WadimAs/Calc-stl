import 'package:flutter/material.dart';

import '../clients/clients.dart';
import '../data/records.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import '../platform/files.dart';
import '../platform/updates.dart';
import 'orders_page.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

/// Orders that belong to [c] (linked by id, or older ones by the same name).
List<Order> ordersOf(Client c, List<Order> all) => [
      for (final o in all)
        if (o.clientId == c.id ||
            (o.clientId == null && c.name.trim().isNotEmpty && o.client.trim().toLowerCase() == c.name.trim().toLowerCase()))
          o,
    ];

Future<void> openLink(BuildContext context, String? url) async {
  if (url == null) return;
  try {
    await Updates.open(url);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Немає застосунку, щоб це відкрити'))));
    }
  }
}

/// Contact buttons: call, Telegram, Viber.
class ContactButtons extends StatelessWidget {
  final Client client;

  const ContactButtons(this.client, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = client;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      if (c.callUrl != null)
        ActionChip(
          avatar: const Icon(Icons.call_outlined, size: 18),
          label: Text(tr('Подзвонити')),
          onPressed: () => openLink(context, c.callUrl),
        ),
      if (c.telegramUrl != null)
        ActionChip(
          avatar: const Icon(Icons.send_outlined, size: 18),
          label: const Text('Telegram'),
          onPressed: () => openLink(context, c.telegramUrl),
        ),
      if (c.viberUrl != null)
        ActionChip(
          avatar: const Icon(Icons.chat_outlined, size: 18),
          label: const Text('Viber'),
          onPressed: () => openLink(context, c.viberUrl),
        ),
    ]);
  }
}

Future<Client?> editClient(BuildContext context, [Client? c]) =>
    showDialog<Client>(context: context, builder: (_) => _ClientDialog(client: c));

/// Bottom sheet to choose a client for an order. Returns `Client(id: '')`
/// for "no client", null when dismissed.
Future<Client?> pickClient(BuildContext context) async {
  final list = await clientStore.load();
  if (!context.mounted) return null;
  return showModalBottomSheet<Client>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _ClientPicker(clients: list),
  );
}

class _ClientPicker extends StatefulWidget {
  final List<Client> clients;

  const _ClientPicker({required this.clients});

  @override
  State<_ClientPicker> createState() => _ClientPickerState();
}

class _ClientPickerState extends State<_ClientPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = [
      for (final c in widget.clients)
        if (q.isEmpty || c.name.toLowerCase().contains(q) || c.phone.contains(q)) c,
    ];
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: tr('Пошук клієнта')),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.person_add_alt_outlined),
          title: Text(tr('Новий клієнт')),
          onTap: () async {
            final c = await editClient(context, Client(id: newId(), name: _q));
            if (c == null) return;
            await clientStore.upsert(c);
            if (context.mounted) Navigator.pop(context, c);
          },
        ),
        ListTile(
          leading: const Icon(Icons.person_off_outlined),
          title: Text(tr('Без клієнта')),
          onTap: () => Navigator.pop(context, const Client(id: '', name: '')),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(children: [
            for (final c in list)
              ListTile(
                leading: CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name.characters.first.toUpperCase())),
                title: Text(c.name.isEmpty ? tr('Без імені') : c.name),
                subtitle: c.phone.isEmpty && c.telegram.isEmpty
                    ? null
                    : Text([c.phone, c.telegram].where((x) => x.isNotEmpty).join(' · ')),
                onTap: () => Navigator.pop(context, c),
              ),
          ]),
        ),
      ]),
    );
  }
}

class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  List<Client>? _clients;
  List<Order> _orders = [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final c = await clientStore.load();
    final o = await OrderStore.load();
    if (mounted) {
      setState(() {
        _clients = c;
        _orders = o;
      });
    }
  }

  Future<void> _add() async {
    final c = await editClient(context);
    if (c == null) return;
    await clientStore.upsert(c);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _clients;
    final q = _q.toLowerCase();
    final list = all == null
        ? null
        : [
            for (final c in all)
              if (q.isEmpty || c.name.toLowerCase().contains(q) || c.phone.contains(q)) c,
          ];
    return Scaffold(
      appBar: AppBar(title: Text(tr('Клієнти'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.person_add_alt),
        label: Text(tr('Клієнт')),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                if (all!.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: tr('Пошук')),
                      onChanged: (v) => setState(() => _q = v.trim()),
                    ),
                  ),
                if (all.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Збережіть клієнтів, щоб бачити історію їхніх замовлень і писати їм в один дотик.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                for (final c in list)
                  Builder(builder: (context) {
                    final mine = ordersOf(c, _orders);
                    final sum = mine.fold(0.0, (a, o) => a + o.totals.total);
                    return Card(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      child: ListTile(
                        leading:
                            CircleAvatar(child: Text(c.name.isEmpty ? '?' : c.name.characters.first.toUpperCase())),
                        title: Text(c.name.isEmpty ? tr('Без імені') : c.name),
                        subtitle: Text(mine.isEmpty
                            ? (c.phone.isEmpty ? tr('замовлень ще немає') : c.phone)
                            : trf('{0} зам. · {1}', [mine.length, fmtMoney(sum)])),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.of(context)
                              .push(MaterialPageRoute<void>(builder: (_) => ClientPage(client: c)));
                          _reload();
                        },
                      ),
                    );
                  }),
              ],
            ),
    );
  }
}

class ClientPage extends StatefulWidget {
  final Client client;

  const ClientPage({super.key, required this.client});

  @override
  State<ClientPage> createState() => _ClientPageState();
}

class _ClientPageState extends State<ClientPage> {
  late Client _c = widget.client;
  List<Order>? _orders;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final all = await OrderStore.load();
    if (mounted) setState(() => _orders = ordersOf(_c, all));
  }

  Future<void> _edit() async {
    final c = await editClient(context, _c);
    if (c == null) return;
    await clientStore.upsert(c);
    // Keep the name on linked orders in sync.
    final all = await OrderStore.load();
    var changed = false;
    for (final o in all) {
      if (o.clientId == c.id && o.client != c.name) {
        o.client = c.name;
        changed = true;
      }
    }
    if (changed) await OrderStore.saveAll(all);
    setState(() => _c = c);
    _reload();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Видалити клієнта?')),
        content: Text(tr('Його замовлення залишаться.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Скасувати'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Видалити'))),
        ],
      ),
    );
    if (ok != true) return;
    await clientStore.remove(_c.id);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _newOrder() async {
    final s = await PlatformFiles.loadSettings();
    final o = Order.create(s, client: _c.name)
      ..clientId = _c.id
      ..contact = _c.phone.isNotEmpty ? _c.phone : _c.telegram;
    await OrderStore.upsert(o);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: o.id)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orders = _orders;
    final c = _c;
    double total = 0, paid = 0;
    for (final o in orders ?? const <Order>[]) {
      total += o.totals.total;
      if (o.status == OrderStatus.paid) paid += o.totals.total;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(c.name.isEmpty ? tr('Клієнт') : c.name),
        actions: [
          IconButton(tooltip: tr('Редагувати'), onPressed: _edit, icon: const Icon(Icons.edit_outlined)),
          IconButton(tooltip: tr('Видалити'), onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newOrder,
        icon: const Icon(Icons.add),
        label: Text(tr('Замовлення')),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (c.phone.isNotEmpty) Text(c.phone, style: theme.textTheme.titleMedium),
                if (c.telegram.isNotEmpty) Text(c.telegram, style: theme.textTheme.bodyMedium),
                if (c.note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(c.note, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 10),
                ContactButtons(c),
                if (c.callUrl == null && c.telegramUrl == null)
                  TextButton.icon(
                    onPressed: _edit,
                    icon: const Icon(Icons.add),
                    label: Text(tr('Додати телефон або Telegram')),
                  ),
              ]),
            ),
          ),
          if (orders != null && orders.isNotEmpty) ...[
            Row(children: [
              Expanded(child: Stat(tr('замовлень'), '${orders.length}')),
              Expanded(child: Stat(tr('на суму'), fmtMoney(total))),
              Expanded(child: Stat(tr('оплачено'), fmtMoney(paid))),
            ]),
            const SizedBox(height: 8),
          ],
          for (final o in orders ?? const <Order>[])
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                leading: ItemThumb(o.items.isEmpty ? null : o.items.first.thumbPath),
                title: Text(formatDate(o.createdAt).split(' ').first),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    StatusChip(o.status),
                    const SizedBox(width: 8),
                    Expanded(child: Text(trf('{0} шт', [o.totals.pieces]), maxLines: 1)),
                  ]),
                ),
                trailing: Text(fmtMoney(o.totals.total), style: theme.textTheme.titleMedium),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: o.id)));
                  _reload();
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ClientDialog extends StatefulWidget {
  final Client? client;

  const _ClientDialog({this.client});

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  late final _name = TextEditingController(text: widget.client?.name ?? '');
  late final _phone = TextEditingController(text: widget.client?.phone ?? '');
  late final _tg = TextEditingController(text: widget.client?.telegram ?? '');
  late final _note = TextEditingController(text: widget.client?.note ?? '');

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _tg.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final old = widget.client;
    return AlertDialog(
      title: Text(old == null || old.name.isEmpty ? tr('Новий клієнт') : tr('Клієнт')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: tr('Ім\'я')),
          ),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: tr('Телефон'), hintText: '+380…'),
          ),
          TextField(
            controller: _tg,
            decoration: const InputDecoration(labelText: 'Telegram', hintText: '@username'),
          ),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr('Примітка'), hintText: tr('Нова Пошта №…, побажання')),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: () {
            final c = Client(
              id: old == null || old.id.isEmpty ? newId() : old.id,
              name: _name.text.trim(),
              phone: _phone.text.trim(),
              telegram: _tg.text.trim(),
              note: _note.text.trim(),
            );
            Navigator.pop(context, c);
          },
          child: Text(tr('Зберегти')),
        ),
      ],
    );
  }
}
