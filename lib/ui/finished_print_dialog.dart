import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../mesh/slicer_project.dart';
import '../orders/orders.dart';
import '../printers/print_hub.dart';
import '../printers/printers.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import '../spools/writeoffs.dart';
import 'spool_picker.dart';
import 'widgets.dart';

String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\.(gcode\.3mf|3mf|gcode|stl)$'), '')
    .replaceAll(RegExp(r'[_\-]+'), ' ')
    .trim();

/// Order whose item name matches the printed job, if any.
Order? matchOrder(String job, List<Order> orders) {
  final j = _norm(job);
  if (j.isEmpty) return null;
  for (final o in orders) {
    for (final it in o.items) {
      final n = _norm(it.name);
      if (n.isNotEmpty && (j.contains(n) || n.contains(j))) return o;
    }
  }
  return null;
}

/// Spool that most likely fed this line: the synced AMS spool, else the same
/// material with the nearest colour.
String? guessSpool(PrinterConn p, UsageLine l, List<Spool> spools) {
  if (spools.isEmpty) return null;
  if (l.slotKey != null) {
    final id = 'ams:${p.id}:${l.slotKey}';
    if (spools.any((s) => s.id == id)) return id;
  }
  final mat = materialIdForType(l.type);
  var cands = mat == null ? spools : spools.where((s) => s.materialId == mat).toList();
  if (cands.isEmpty) cands = spools;
  if (l.color != null) {
    int dist(int a, int b) {
      final dr = ((a >> 16) & 255) - ((b >> 16) & 255);
      final dg = ((a >> 8) & 255) - ((b >> 8) & 255);
      final db = (a & 255) - (b & 255);
      return dr * dr + dg * dg + db * db;
    }

    cands = List.of(cands)..sort((a, b) => dist(a.colorArgb, l.color!).compareTo(dist(b.colorArgb, l.color!)));
  }
  return cands.length == 1 || l.color != null || mat != null ? cands.first.id : null;
}

/// Asks where the filament of a finished print goes and writes it off.
Future<void> showFinishedPrint(BuildContext context, FinishedPrint f) async {
  final spools = await SpoolStore.load();
  final orders = (await OrderStore.load()).where((o) => !o.status.printed).toList();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FinishedPrintDialog(print: f, spools: spools, orders: orders),
  );
}

class _Line {
  String? spoolId;
  final TextEditingController grams;
  final UsageLine source;

  _Line(this.spoolId, this.grams, this.source);
}

class _FinishedPrintDialog extends StatefulWidget {
  final FinishedPrint print;
  final List<Spool> spools;
  final List<Order> orders;

  const _FinishedPrintDialog({required this.print, required this.spools, required this.orders});

  @override
  State<_FinishedPrintDialog> createState() => _FinishedPrintDialogState();
}

class _FinishedPrintDialogState extends State<_FinishedPrintDialog> {
  late final List<_Line> _lines;
  late String _purpose; // 'self', 'failed' or an order id
  bool _busy = false;

  FinishedPrint get f => widget.print;

  static String _g(double v) => fmtNum(v, v >= 100 ? 0 : 1);

  @override
  void initState() {
    super.initState();
    _lines = [
      for (final l in f.lines)
        _Line(guessSpool(f.printer, l, widget.spools), TextEditingController(), l),
    ];
    for (final l in _lines) {
      _fillGrams(l);
    }
    final match = matchOrder(f.job, widget.orders);
    _purpose = f.failed ? 'failed' : (match?.id ?? 'self');
    if (match != null) _fillFromOrder(match);
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.grams.dispose();
    }
    super.dispose();
  }

  Spool? _spool(String? id) {
    for (final s in widget.spools) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Known weight, or Klipper's filament length converted with the spool's density.
  void _fillGrams(_Line l) {
    final g = l.source.grams;
    if (g != null) {
      l.grams.text = _g(g);
      return;
    }
    final mm = l.source.filamentMm;
    if (mm != null && mm > 0) {
      final density = materialById(_spool(l.spoolId)?.materialId ?? 'PLA').density;
      const r = 1.75 / 2;
      l.grams.text = _g(mm * 3.141592653589793 * r * r * density / 1000);
    }
  }

  /// No weight from the printer: suggest the order's calculated weight.
  void _fillFromOrder(Order o) {
    if (_lines.length != 1 || _lines.first.grams.text.isNotEmpty) return;
    final j = _norm(f.job);
    double? g;
    for (final it in o.items) {
      final n = _norm(it.name);
      if (n.isNotEmpty && (j.contains(n) || n.contains(j))) g = it.gramsEach * it.qty;
    }
    g ??= o.totals.grams;
    if (g > 0) _lines.first.grams.text = _g(g);
  }

  Future<void> _writeOff() async {
    final grams = <String, double>{};
    for (final l in _lines) {
      final id = l.spoolId;
      final g = double.tryParse(l.grams.text.replaceAll(',', '.').replaceAll(' ', ''));
      if (id == null || g == null || g <= 0) continue;
      grams[id] = (grams[id] ?? 0) + g;
    }
    if (grams.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('Виберіть котушку й вкажіть вагу'))));
      return;
    }
    setState(() => _busy = true);
    final order = widget.orders.where((o) => o.id == _purpose);
    await applyWriteOff(WriteOff(
      id: newWriteOffId(),
      date: DateTime.now(),
      printer: f.printer.name,
      job: f.job,
      purpose: order.isNotEmpty ? 'order' : _purpose,
      orderId: order.isNotEmpty ? order.first.id : null,
      orderTitle: order.isNotEmpty ? order.first.title : '',
      grams: grams,
    ));
    final mj = f.moonrakerJob;
    if (mj != null) {
      final all = await printerStore.load();
      for (final p in all) {
        if (p.id == f.printer.id) await printerStore.upsert(p.copyWith(writtenOff: [...p.writtenOff, mj]), atStart: false);
      }
    }
    await PrinterHub.instance.resolve(f);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    final total = grams.values.fold(0.0, (a, b) => a + b);
    messenger.showSnackBar(SnackBar(content: Text(trf('Списано {0}', [fmtGrams(total)]))));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(f.failed ? Icons.error_outline : Icons.check_circle_outline,
          color: f.failed ? theme.colorScheme.error : theme.colorScheme.primary),
      title: Text(f.failed ? tr('Друк перервано') : tr('Друк завершено')),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(f.job.isEmpty ? tr('Без назви') : f.job, style: theme.textTheme.titleSmall),
            Text(
              [f.printer.name, if (f.source.isNotEmpty) f.source].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Text(tr('Списати пластик з котушки?'), style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            for (final l in _lines)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(
                    flex: 3,
                    child: SpoolDropdown(
                      spools: widget.spools,
                      value: l.spoolId,
                      need: double.tryParse(l.grams.text.replaceAll(',', '.')),
                      onChanged: (v) => setState(() {
                        l.spoolId = v;
                        if (l.source.grams == null && l.source.filamentMm != null) _fillGrams(l);
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: l.grams,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(suffixText: tr('г'), isDense: true, hintText: '?'),
                    ),
                  ),
                ]),
              ),
            if (widget.spools.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Спершу додайте котушки'), style: TextStyle(color: theme.colorScheme.error)),
              ),
            if (_lines.every((l) => l.grams.text.isEmpty))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(tr('Принтер не повідомив вагу — введіть її (є в слайсері) або виберіть замовлення.'),
                    style: theme.textTheme.bodySmall),
              ),
            const SizedBox(height: 14),
            Text(tr('Для чого був друк'), style: theme.textTheme.bodyMedium),
            DropdownButton<String>(
              isExpanded: true,
              value: _purpose,
              items: [
                DropdownMenuItem(value: 'self', child: Text(tr('Для себе'))),
                DropdownMenuItem(value: 'failed', child: Text(tr('Невдалий друк (брак)'))),
                for (final o in widget.orders)
                  DropdownMenuItem(
                    value: o.id,
                    child: Text(trf('Замовлення: {0}', [o.title]), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() {
                _purpose = v ?? 'self';
                final o = widget.orders.where((x) => x.id == _purpose);
                if (o.isNotEmpty) _fillFromOrder(o.first);
              }),
            ),
            if (widget.orders.any((o) => o.id == _purpose))
              Text(tr('Замовлення запам\'ятає списане, і при статусі «Готово» пластик не спишеться вдруге.'),
                  style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  await PrinterHub.instance.resolve(f);
                  if (context.mounted) Navigator.pop(context);
                },
          child: Text(tr('Не списувати')),
        ),
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(tr('Пізніше'))),
        FilledButton(onPressed: _busy ? null : _writeOff, child: Text(tr('Списати'))),
      ],
    );
  }
}
