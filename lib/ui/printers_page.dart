import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/records.dart';
import '../history/history.dart';
import '../mesh/slicer_project.dart';
import '../printers/print_hub.dart';
import '../printers/bambu_cloud.dart';
import '../printers/moonraker.dart';
import '../printers/printers.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import 'spool_icon.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

/// Copies AMS trays into the spool list (remaining grams from the AMS gauge).
Future<int> syncAmsSpools(PrinterConn p, List<FilamentSlot> slots) async {
  final list = await SpoolStore.load();
  int n = 0;
  for (final s in slots) {
    final left = s.remainingGrams;
    if (left == null) continue;
    final id = 'ams:${p.id}:${s.key}';
    final i = list.indexWhere((x) => x.id == id);
    final name = '${p.name} ${s.label}${s.brand.isEmpty ? '' : ' · ${s.brand}'}';
    final mat = materialIdForType(s.type) ?? 'PLA';
    if (i >= 0) {
      list[i] = list[i].copyWith(
        materialId: mat,
        name: name,
        colorArgb: s.colorArgb,
        totalGrams: s.weightGrams,
        remainingGrams: left,
      );
    } else {
      list.add(Spool(
        id: id,
        materialId: mat,
        name: name,
        colorArgb: s.colorArgb,
        totalGrams: s.weightGrams,
        remainingGrams: left,
        createdAt: DateTime.now(),
      ));
    }
    n++;
  }
  await SpoolStore.saveAll(list);
  return n;
}

Future<PrinterConn?> editPrinter(BuildContext context, [PrinterConn? p, PrinterKind? kind]) =>
    showDialog<PrinterConn>(context: context, builder: (_) => _PrinterDialog(printer: p, kind: kind));

class PrintersPage extends StatefulWidget {
  const PrintersPage({super.key});

  @override
  State<PrintersPage> createState() => _PrintersPageState();
}

class _PrintersPageState extends State<PrintersPage> {
  List<PrinterConn>? _list;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await printerStore.load();
    if (mounted) setState(() => _list = l);
    PrinterHub.instance.start();
  }

  Future<void> _add() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(tr('Bambu Lab через інтернет')),
            subtitle: Text(tr('Вхід в акаунт Bambu — працює будь-де, як Bambu Handy')),
            onTap: () => Navigator.pop(ctx, 'cloud'),
          ),
          ListTile(
            leading: const Icon(Icons.wifi),
            title: Text(tr('Bambu Lab у локальній мережі')),
            subtitle: Text(tr('IP, серійний номер і код доступу')),
            onTap: () => Navigator.pop(ctx, 'lan'),
          ),
          ListTile(
            leading: const Icon(Icons.memory_outlined),
            title: const Text('Klipper (Moonraker)'),
            subtitle: Text(tr('Creality K1, Elegoo, Voron…')),
            onTap: () => Navigator.pop(ctx, 'klipper'),
          ),
        ]),
      ),
    );
    if (how == null || !mounted) return;
    if (how == 'cloud') {
      await _addFromCloud();
      return;
    }
    final p = await editPrinter(context, null, how == 'klipper' ? PrinterKind.moonraker : PrinterKind.bambu);
    if (p == null) return;
    await printerStore.upsert(p, atStart: false);
    _reload();
  }

  /// Logs in if needed and adds printers bound to the Bambu account.
  Future<void> _addFromCloud() async {
    var acc = await BambuAccount.load();
    if (!mounted) return;
    if (acc == null || acc.probablyExpired) {
      acc = await showDialog<BambuAccount>(context: context, builder: (_) => const BambuLoginDialog());
      if (acc == null || !mounted) return;
    }
    List<CloudPrinter> found;
    try {
      found = await BambuCloud.printers(acc);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      if (e is BambuCloudException) {
        acc = await showDialog<BambuAccount>(context: context, builder: (_) => const BambuLoginDialog());
        if (acc != null) _addFromCloud();
      }
      return;
    }
    if (!mounted) return;
    if (found.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('До акаунта не прив\'язано жодного принтера'))));
      return;
    }
    final existing = {for (final p in _list ?? const <PrinterConn>[]) if (p.cloud) p.serial};
    final chosen = await showDialog<List<CloudPrinter>>(
      context: context,
      builder: (_) => _CloudPickDialog(printers: found, existing: existing),
    );
    if (chosen == null || chosen.isEmpty) return;
    for (final c in chosen) {
      await printerStore.upsert(
        PrinterConn(
          id: newId(),
          name: c.name,
          kind: PrinterKind.bambu,
          host: '',
          serial: c.serial,
          accessCode: c.accessCode,
          cloud: true,
        ),
        atStart: false,
      );
    }
    _reload();
  }

  Future<void> _account() async {
    final acc = await BambuAccount.load();
    if (!mounted) return;
    if (acc == null) {
      final a = await showDialog<BambuAccount>(context: context, builder: (_) => const BambuLoginDialog());
      if (a != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Вхід виконано: {0}', [a.email]))));
      }
      return;
    }
    final out = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Акаунт Bambu')),
        content: Text(trf('Увійшли як {0}.', [acc.email])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Вийти'))),
          FilledButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Закрити'))),
        ],
      ),
    );
    if (out == true) await BambuAccount.logout();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Принтери')),
        actions: [
          IconButton(tooltip: tr('Акаунт Bambu'), onPressed: _account, icon: const Icon(Icons.account_circle_outlined)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: Text(tr('Принтер')),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Підключіть принтер, щоб бачити друк наживо, залишок пластику в AMS і списувати витрачене на котушки.\n\nBambu Lab — через акаунт Bambu (будь-де) або в локальній мережі.\nKlipper (Creality K1, Elegoo, Voron…) — за IP через Moonraker.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                if (list.isNotEmpty)
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    secondary: const Icon(Icons.auto_delete_outlined),
                    title: Text(tr('Пропонувати списання після друку')),
                    subtitle: Text(tr('Коли принтер закінчить друк, застосунок спитає, з якої котушки й для чого списати пластик')),
                    value: PrinterHub.instance.enabled,
                    onChanged: (v) async {
                      await PrinterHub.instance.setEnabled(v);
                      if (mounted) setState(() {});
                    },
                  ),
                for (final p in list)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(p.cloud
                          ? Icons.cloud_outlined
                          : (p.kind == PrinterKind.bambu ? Icons.print_outlined : Icons.memory_outlined)),
                      title: Text(p.name.isEmpty ? (p.host.isEmpty ? p.serial : p.host) : p.name),
                      subtitle: Text(p.cloud ? p.kindLabel : '${p.kindLabel} · ${p.host}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute<void>(builder: (_) => PrinterPage(printer: p)));
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}

class PrinterPage extends StatefulWidget {
  final PrinterConn printer;

  const PrinterPage({super.key, required this.printer});

  @override
  State<PrinterPage> createState() => _PrinterPageState();
}

class _PrinterPageState extends State<PrinterPage> {
  late PrinterConn _p = widget.printer;
  PrinterStatus? _status;
  String? _error;
  bool _connecting = false;
  StreamSubscription<PrinterStatus>? _sub;
  Timer? _poll;
  List<PrintJob>? _jobs;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  void _disconnect() {
    _poll?.cancel();
    _poll = null;
    _sub?.cancel();
    _sub = null;
  }

  Future<void> _connect() async {
    _disconnect();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      if (_p.kind == PrinterKind.bambu) {
        // Shared connection (also used to notice finished prints).
        final sub = PrinterHub.instance.bambuStatus(_p).listen(
          (s) {
            if (mounted) {
              setState(() {
                _status = s;
                _error = null;
              });
            }
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = '$e');
          },
        );
        _sub = sub;
        PrinterHub.instance.pushAll(_p);
        Timer(const Duration(seconds: 15), () {
          if (mounted && identical(_sub, sub) && _status == null && _error == null) {
            setState(() => _error = tr('Принтер підключився, але не надсилає дані. Перевірте серійний номер.'));
          }
        });
      } else {
        final c = MoonrakerClient(_p);
        final s = await c.status();
        if (!mounted) return;
        setState(() => _status = s);
        _loadJobs();
        _poll = Timer.periodic(const Duration(seconds: 4), (_) async {
          try {
            final s = await c.status();
            if (mounted) setState(() => _status = s);
          } catch (e) {
            if (mounted) setState(() => _error = '$e');
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _loadJobs() async {
    try {
      final j = await MoonrakerClient(_p).history();
      if (mounted) setState(() => _jobs = j);
    } catch (_) {}
  }

  Future<void> _edit() async {
    final p = await editPrinter(context, _p);
    if (p == null) return;
    await printerStore.upsert(p, atStart: false);
    setState(() {
      _p = p;
      _status = null;
    });
    PrinterHub.instance.reconnect(p);
    await PrinterHub.instance.refresh();
    _connect();
  }

  Future<void> _delete() async {
    await printerStore.remove(_p.id);
    await PrinterHub.instance.refresh();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _syncAms() async {
    final s = _status;
    if (s == null) return;
    final n = await syncAmsSpools(_p, s.slots);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == 0 ? tr('AMS не повідомляє залишок (сторонній пластик без RFID)') : trf('Оновлено котушок: {0}', [n])),
    ));
  }

  Future<void> _writeOff(PrintJob j) async {
    final spools = await SpoolStore.load();
    if (!mounted) return;
    if (spools.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Спершу додайте котушки'))));
      return;
    }
    final spool = await showDialog<Spool>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(trf('Списати {0}?', [fmtGrams(j.gramsFor(1.24))])),
        children: [
          for (final s in spools)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Row(children: [
                SpoolIcon.of(s, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${materialById(s.materialId).name}${s.title.isEmpty ? '' : ' · ${s.title}'} — '
                    '${fmtGrams(j.gramsFor(materialById(s.materialId).density))}',
                  ),
                ),
              ]),
            ),
        ],
      ),
    );
    if (spool == null) return;
    final g = j.gramsFor(materialById(spool.materialId).density);
    await SpoolStore.adjust({spool.id: -g});
    final p = _p.copyWith(writtenOff: [..._p.writtenOff, j.id]);
    await printerStore.upsert(p, atStart: false);
    if (!mounted) return;
    setState(() => _p = p);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Списано {0}', [fmtGrams(g)]))));
  }

  String _temp(double? t, double? target) {
    if (t == null) return '—';
    final a = '${t.toStringAsFixed(0)}°';
    return target != null && target > 0 ? '$a / ${target.toStringAsFixed(0)}°' : a;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _status;
    final p = _p;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name.isEmpty ? (p.host.isEmpty ? p.serial : p.host) : p.name),
        actions: [
          IconButton(
            tooltip: tr('Оновити'),
            onPressed: _connecting
                ? null
                : () {
                    if (_p.kind == PrinterKind.bambu) PrinterHub.instance.reconnect(_p);
                    _connect();
                  },
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _edit();
              if (v == 'login') {
                showDialog<BambuAccount>(context: context, builder: (_) => const BambuLoginDialog()).then((a) {
                  if (a != null) {
                    PrinterHub.instance.reconnect(_p);
                    _connect();
                  }
                });
              }
              if (v == 'del') _delete();
            },
            itemBuilder: (_) => [
              if (!p.cloud) PopupMenuItem(value: 'edit', child: Text(tr('Змінити'))),
              if (p.cloud) PopupMenuItem(value: 'login', child: Text(tr('Увійти в акаунт знову'))),
              PopupMenuItem(value: 'del', child: Text(tr('Видалити'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (p.kind == PrinterKind.bambu) {
            PrinterHub.instance.pushAll(p);
          } else {
            await _loadJobs();
          }
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
          children: [
            if (_connecting && s == null) const LinearProgressIndicator(),
            if (_error != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_error!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                    const SizedBox(height: 8),
                    Text(
                      p.cloud
                          ? tr('Перевірте інтернет і чи принтер увімкнений. Якщо вхід застарів — меню ⋮ → «Увійти в акаунт знову».')
                          : p.kind == PrinterKind.bambu
                          ? tr('Перевірте: телефон і принтер в одній мережі, правильні IP, серійний номер і код доступу (на принтері: Налаштування → WLAN). На новій прошивці може знадобитися увімкнути «LAN only» та «Developer mode».')
                          : tr('Перевірте IP і порт (зазвичай 7125, як у Mainsail / Fluidd).'),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ]),
                ),
              ),
            if (s == null && !_connecting && _error == null)
              Padding(padding: EdgeInsets.all(24), child: Center(child: Text(tr('Чекаю дані від принтера…')))),
            if (s != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(s.printing ? Icons.play_circle_outline : Icons.pause_circle_outline,
                          color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(s.state, style: theme.textTheme.titleLarge),
                    ]),
                    if (s.job.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(s.job, style: theme.textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    if (s.printing && s.progress != null) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                          value: s.progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                      const SizedBox(height: 6),
                      Row(children: [
                        Text('${(s.progress! * 100).toStringAsFixed(0)}%', style: theme.textTheme.titleMedium),
                        const Spacer(),
                        if (s.remaining != null)
                          Text(trf('залишилось {0}', [formatDuration(s.remaining!.inSeconds / 3600)]),
                              style: theme.textTheme.bodyMedium),
                      ]),
                      if (s.layer != null && s.totalLayers != null && s.totalLayers! > 0)
                        Text(trf('шар {0} з {1}', [s.layer, s.totalLayers]), style: theme.textTheme.bodySmall),
                      if (s.remaining != null)
                        Text(
                          trf('завершення ≈ {0}', [formatDate(DateTime.now().add(s.remaining!)).split(' ').last]),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                    if (s.error != null) ...[
                      const SizedBox(height: 8),
                      Text(s.error!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: Stat(tr('сопло'), _temp(s.nozzle, s.nozzleTarget))),
                      Expanded(child: Stat(tr('стіл'), _temp(s.bed, s.bedTarget))),
                    ]),
                  ]),
                ),
              ),
              if (s.slots.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text(tr('Пластик'), style: theme.textTheme.titleMedium)),
                  TextButton.icon(
                    onPressed: _syncAms,
                    icon: const Icon(Icons.sync),
                    label: Text(tr('У котушки')),
                  ),
                ]),
                for (final slot in s.slots)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      leading: Badge(
                        isLabelVisible: slot.active,
                        label: const Icon(Icons.play_arrow, size: 10, color: Colors.white),
                        child: SpoolIcon(
                          color: slot.colorArgb,
                          fraction: (slot.remainPercent ?? 100) / 100,
                          size: 40,
                        ),
                      ),
                      title: Text('${slot.type}${slot.brand.isEmpty ? '' : ' · ${slot.brand}'}'),
                      subtitle: Text(slot.label),
                      trailing: Text(
                        slot.remainPercent == null
                            ? '—'
                            : '${slot.remainPercent}% · ${fmtGrams(slot.remainingGrams!)}',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ),
              ],
            ],
            if (p.kind == PrinterKind.moonraker && _jobs != null) ...[
              const SizedBox(height: 12),
              Text(tr('Останні друки'), style: theme.textTheme.titleMedium),
              if (_jobs!.isEmpty) Padding(padding: EdgeInsets.all(12), child: Text(tr('Історія порожня'))),
              for (final j in _jobs!)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  child: ListTile(
                    title: Text(j.file, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${moonrakerStateLabel(j.status)}'
                      '${j.end != null ? ' · ${formatDate(j.end!)}' : ''}'
                      ' · ${formatDuration(j.seconds / 3600)} · ${fmtGrams(j.gramsFor(1.24))}',
                    ),
                    trailing: p.writtenOff.contains(j.id)
                        ? Tooltip(message: tr('Списано'), child: Icon(Icons.check_circle_outline))
                        : j.filamentMm > 0
                            ? TextButton(onPressed: () => _writeOff(j), child: Text(tr('Списати')))
                            : null,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Picks a Klipper printer and uploads G-code to it.
Future<void> sendGcodeToPrinter(BuildContext context, String name, Uint8List bytes) async {
  final printers = (await printerStore.load()).where((p) => p.kind == PrinterKind.moonraker).toList();
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  if (printers.isEmpty) {
    messenger.showSnackBar(SnackBar(
      content: Text(tr('Додайте принтер Klipper у меню «Принтери». Bambu приймає завдання лише з Bambu Studio / Handy.')),
    ));
    return;
  }
  bool start = false;
  final p = await showDialog<PrinterConn>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SimpleDialog(
        title: Text(tr('Надіслати на принтер')),
        children: [
          for (final p in printers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.name.isEmpty ? p.host : p.name),
            ),
          CheckboxListTile(
            value: start,
            onChanged: (v) => set(() => start = v ?? false),
            title: Text(tr('Одразу почати друк')),
          ),
        ],
      ),
    ),
  );
  if (p == null) return;
  messenger.showSnackBar(SnackBar(content: Text(tr('Надсилаю…'))));
  try {
    await MoonrakerClient(p).upload(name, bytes, start: start);
    messenger.showSnackBar(SnackBar(content: Text(start ? tr('Друк запущено') : tr('Файл на принтері'))));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(trf('Не вдалося: {0}', [e]))));
  }
}

class _PrinterDialog extends StatefulWidget {
  final PrinterConn? printer;
  final PrinterKind? kind;

  const _PrinterDialog({this.printer, this.kind});

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  late PrinterKind _kind = widget.printer?.kind ?? widget.kind ?? PrinterKind.bambu;
  late final _name = TextEditingController(text: widget.printer?.name ?? '');
  late final _host = TextEditingController(text: widget.printer?.host ?? '');
  late final _serial = TextEditingController(text: widget.printer?.serial ?? '');
  late final _code = TextEditingController(text: widget.printer?.accessCode ?? '');
  late final _port = TextEditingController(text: '${widget.printer?.port ?? 7125}');
  late final _key = TextEditingController(text: widget.printer?.apiKey ?? '');

  @override
  void dispose() {
    for (final c in [_name, _host, _serial, _code, _port, _key]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bambu = _kind == PrinterKind.bambu;
    return AlertDialog(
      title: Text(widget.printer == null ? tr('Новий принтер') : tr('Принтер')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SegmentedButton<PrinterKind>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: PrinterKind.bambu, label: Text('Bambu Lab')),
              ButtonSegment(value: PrinterKind.moonraker, label: Text('Klipper')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: tr('Назва'), hintText: bambu ? 'A1 mini' : 'K1 Max'),
          ),
          TextField(
            controller: _host,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: tr('IP-адреса'), hintText: '192.168.1.50'),
          ),
          if (bambu) ...[
            TextField(
              controller: _serial,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: tr('Серійний номер'), hintText: '0309DA…'),
            ),
            TextField(
              controller: _code,
              decoration: InputDecoration(labelText: tr('Код доступу (LAN)'), hintText: tr('8 символів')),
            ),
            const SizedBox(height: 8),
            Text(
              tr('IP і код доступу — на екрані принтера: Налаштування → WLAN (A1: значок шестерні → LAN). Серійний номер — у Bambu Handy або Налаштування → Пристрій.'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ] else ...[
            TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Порт Moonraker')),
            ),
            TextField(
              controller: _key,
              decoration: InputDecoration(labelText: tr('API-ключ'), hintText: tr('якщо ввімкнено авторизацію')),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: () {
            if (_host.text.trim().isEmpty) return;
            if (bambu && (_serial.text.trim().isEmpty || _code.text.trim().isEmpty)) return;
            Navigator.pop(
              context,
              PrinterConn(
                id: widget.printer?.id ?? newId(),
                name: _name.text.trim(),
                kind: _kind,
                host: _host.text.trim(),
                serial: _serial.text.trim().toUpperCase(),
                accessCode: _code.text.trim(),
                apiKey: _key.text.trim(),
                port: int.tryParse(_port.text.trim()) ?? 7125,
                writtenOff: widget.printer?.writtenOff ?? const [],
              ),
            );
          },
          child: Text(tr('Зберегти')),
        ),
      ],
    );
  }
}

/// Bambu account login: e-mail + password, then the e-mail / 2FA code.
class BambuLoginDialog extends StatefulWidget {
  const BambuLoginDialog({super.key});

  @override
  State<BambuLoginDialog> createState() => _BambuLoginDialogState();
}

class _BambuLoginDialogState extends State<BambuLoginDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  LoginStep? _step;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    BambuAccount.load().then((a) {
      if (a != null && mounted && _email.text.isEmpty) _email.text = a.email;
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      final step = _step;
      BambuAccount? acc;
      if (step is LoginNeedsEmailCode) {
        acc = await BambuCloud.loginWithCode(email, _code.text);
      } else if (step is LoginNeedsTfa) {
        acc = await BambuCloud.loginWithTfa(email, step.tfaKey, _code.text);
      } else {
        final r = await BambuCloud.login(email, _password.text);
        if (r is LoginDone) {
          acc = r.account;
        } else {
          if (mounted) setState(() => _step = r);
        }
      }
      if (acc != null && mounted) Navigator.pop(context, acc);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _step;
    final needCode = step is LoginNeedsEmailCode || step is LoginNeedsTfa;
    return AlertDialog(
      title: Text(tr('Акаунт Bambu')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!needCode) ...[
            Text(tr('Той самий акаунт, що в Bambu Handy і Bambu Studio. Пароль не зберігається.'),
                style: theme.textTheme.bodySmall),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: tr('Пошта')),
            ),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(labelText: tr('Пароль')),
              onSubmitted: (_) => _busy ? null : _go(),
            ),
          ] else ...[
            Text(
              step is LoginNeedsTfa
                  ? tr('Введіть код із застосунку двофакторної автентифікації.')
                  : trf('На {0} надіслано код підтвердження.', [_email.text.trim()]),
              style: theme.textTheme.bodyMedium,
            ),
            TextField(
              controller: _code,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: tr('Код')),
              onSubmitted: (_) => _busy ? null : _go(),
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 8),
          Text(
            tr('Неофіційний спосіб (як у Home Assistant): лише перегляд статусу; вхід діє близько 3 місяців.'),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: _busy ? null : _go,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(needCode ? tr('Підтвердити') : tr('Увійти')),
        ),
      ],
    );
  }
}

class _CloudPickDialog extends StatefulWidget {
  final List<CloudPrinter> printers;
  final Set<String> existing;

  const _CloudPickDialog({required this.printers, required this.existing});

  @override
  State<_CloudPickDialog> createState() => _CloudPickDialogState();
}

class _CloudPickDialogState extends State<_CloudPickDialog> {
  late final Set<String> _sel = {
    for (final p in widget.printers)
      if (!widget.existing.contains(p.serial)) p.serial,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Принтери в акаунті')),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(shrinkWrap: true, children: [
          for (final p in widget.printers)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _sel.contains(p.serial),
              onChanged: widget.existing.contains(p.serial)
                  ? null
                  : (v) => setState(() => v == true ? _sel.add(p.serial) : _sel.remove(p.serial)),
              title: Text(p.name),
              subtitle: Text([
                if (p.model.isNotEmpty) p.model,
                p.online ? tr('онлайн') : tr('офлайн'),
                if (widget.existing.contains(p.serial)) tr('уже додано'),
              ].join(' · ')),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: _sel.isEmpty
              ? null
              : () => Navigator.pop(context, [for (final p in widget.printers) if (_sel.contains(p.serial)) p]),
          child: Text(tr('Додати')),
        ),
      ],
    );
  }
}
