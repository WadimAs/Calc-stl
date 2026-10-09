import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/records.dart';
import '../history/history.dart';
import '../mesh/slicer_project.dart';
import '../printers/bambu.dart';
import '../printers/moonraker.dart';
import '../printers/printers.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
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

Future<PrinterConn?> editPrinter(BuildContext context, [PrinterConn? p]) =>
    showDialog<PrinterConn>(context: context, builder: (_) => _PrinterDialog(printer: p));

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
  }

  Future<void> _add() async {
    final p = await editPrinter(context);
    if (p == null) return;
    await printerStore.upsert(p, atStart: false);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Принтери'))),
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
                      tr('Підключіть принтер у тій самій Wi-Fi мережі, щоб бачити друк наживо, залишок пластику в AMS і списувати витрачене на котушки.\n\nBambu Lab — за IP, серійним номером і кодом доступу LAN.\nKlipper (Creality K1, Elegoo, Voron…) — за IP через Moonraker.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                for (final p in list)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      leading: Icon(p.kind == PrinterKind.bambu ? Icons.print_outlined : Icons.memory_outlined),
                      title: Text(p.name.isEmpty ? p.host : p.name),
                      subtitle: Text('${p.kindLabel} · ${p.host}'),
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
  BambuClient? _bambu;
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
    _bambu?.close();
    _bambu = null;
  }

  Future<void> _connect() async {
    _disconnect();
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      if (_p.kind == PrinterKind.bambu) {
        final c = BambuClient(_p);
        await c.connect();
        if (!mounted) {
          c.close();
          return;
        }
        _bambu = c;
        _sub = c.status.listen(
          (s) {
            if (mounted) setState(() => _status = s);
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = '$e');
          },
        );
        Timer(const Duration(seconds: 12), () {
          if (mounted && identical(_bambu, c) && _status == null && _error == null) {
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
    _connect();
  }

  Future<void> _delete() async {
    await printerStore.remove(_p.id);
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
                CircleAvatar(radius: 8, backgroundColor: Color(s.colorArgb)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${materialById(s.materialId).name}${s.name.isEmpty ? '' : ' · ${s.name}'} — '
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
        title: Text(p.name.isEmpty ? p.host : p.name),
        actions: [
          IconButton(tooltip: tr('Оновити'), onPressed: _connecting ? null : _connect, icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'edit') _edit();
              if (v == 'del') _delete();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(tr('Змінити'))),
              PopupMenuItem(value: 'del', child: Text(tr('Видалити'))),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (p.kind == PrinterKind.bambu) {
            _bambu?.pushAll();
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
                      p.kind == PrinterKind.bambu
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
                      leading: CircleAvatar(
                        backgroundColor: Color(slot.colorArgb),
                        child: slot.active ? const Icon(Icons.play_arrow, color: Colors.white, size: 18) : null,
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

  const _PrinterDialog({this.printer});

  @override
  State<_PrinterDialog> createState() => _PrinterDialogState();
}

class _PrinterDialogState extends State<_PrinterDialog> {
  late PrinterKind _kind = widget.printer?.kind ?? PrinterKind.bambu;
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
