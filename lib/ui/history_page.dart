import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../history/history.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

String historySummary(HistoryEntry e) {
  final b = StringBuffer()
    ..writeln(e.name)
    ..writeln(trf('Матеріал: {0}, {1} мм, заповнення {2}%', [e.material, fmtNum(e.layerHeight, 2), fmtNum(e.infillPercent, 0)]))
    ..writeln(trf('Вага: {0}{1}', [fmtGrams(e.totalGrams), e.copies > 1 ? trf(' ({0} шт.)', [e.copies]) : '']));
  if (e.supports && e.supportGrams > 0) b.writeln(trf('  у т.ч. підтримки: {0}', [fmtGrams(e.supportGrams * e.copies)]));
  if (e.printHours > 0) b.writeln(trf('Час друку: {0}', [formatDuration(e.printHours)]));
  if (e.source.isNotEmpty) b.writeln(trf('Дані: {0}', [e.source]));
  b.writeln(trf('Ціна: {0}', [fmtMoney(e.totalCost)]));
  if (e.note.isNotEmpty) b.writeln(e.note);
  return b.toString().trim();
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<HistoryEntry>? _items;

  @override
  void initState() {
    super.initState();
    HistoryStore.load().then((v) {
      if (mounted) setState(() => _items = v);
    });
  }

  Future<void> _delete(HistoryEntry e) async {
    final list = await HistoryStore.remove(e.id);
    if (mounted) setState(() => _items = list);
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('Очистити історію?')),
        content: Text(tr('Усі збережені розрахунки буде видалено.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Скасувати'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Очистити'))),
        ],
      ),
    );
    if (ok != true) return;
    await HistoryStore.clear();
    if (mounted) setState(() => _items = []);
  }

  Future<void> _export() async {
    final items = _items;
    if (items == null || items.isEmpty) return;
    // BOM so Excel opens Cyrillic correctly.
    final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(HistoryStore.toCsv(items))]);
    try {
      final ok = await PlatformFiles.saveFile('stl-vaga-history.csv', 'text/csv', bytes);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('CSV збережено'))));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('Не вдалося зберегти: {0}', [e]))));
    }
  }

  void _open(HistoryEntry e) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (_) => _EntryDetails(
        entry: e,
        onChanged: (updated) async {
          final list = await HistoryStore.update(updated);
          if (mounted) setState(() => _items = list);
        },
        onDelete: () {
          Navigator.pop(context);
          _delete(e);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Історія')),
        actions: [
          IconButton(
            tooltip: tr('Експорт у CSV'),
            onPressed: (items?.isNotEmpty ?? false) ? _export : null,
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: tr('Очистити'),
            onPressed: (items?.isNotEmpty ?? false) ? _clear : null,
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.history, size: 72, color: theme.colorScheme.outline),
                      const SizedBox(height: 12),
                      Text(tr('Поки що порожньо'), style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(
                        tr('Натисніть «Зберегти» під результатом розрахунку, щоб він з\'явився тут.'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ]),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: items.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      final sum = items.fold<double>(0, (a, e) => a + e.totalCost);
                      final grams = items.fold<double>(0, (a, e) => a + e.totalGrams);
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                        child: Text(
                          trf('{0} розрахунків · {1} · {2}', [items.length, fmtGrams(grams), fmtMoney(sum)]),
                          style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                      );
                    }
                    final e = items[i - 1];
                    return Dismissible(
                      key: ValueKey(e.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 24),
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
                      ),
                      onDismissed: (_) => _delete(e),
                      child: _EntryTile(entry: e, onTap: () => _open(e)),
                    );
                  },
                ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String? path;
  final double size;

  const _Thumb(this.path, {this.size = 56});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = path;
    Widget child;
    if (p != null && File(p).existsSync()) {
      child = Image.file(File(p), fit: BoxFit.cover, width: size, height: size, gaplessPlayback: true);
    } else {
      child = Icon(Icons.view_in_ar_outlined, color: theme.colorScheme.primary);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: size,
        height: size,
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: child,
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final HistoryEntry entry;
  final VoidCallback onTap;

  const _EntryTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = entry;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            _Thumb(e.thumbPath),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  trf('{0} · {1} мм · {2}%{3}{4}', [e.material, fmtNum(e.layerHeight, 2), fmtNum(e.infillPercent, 0), e.supports ? tr(' · підтримки') : '', e.copies > 1 ? trf(' · {0} шт.', [e.copies]) : '']),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 2),
                Text(
                  e.note.isNotEmpty ? '${formatDate(e.date)} · ${e.note}' : formatDate(e.date),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(fmtMoney(e.totalCost), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(fmtGrams(e.totalGrams), style: theme.textTheme.bodySmall),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _EntryDetails extends StatefulWidget {
  final HistoryEntry entry;
  final ValueChanged<HistoryEntry> onChanged;
  final VoidCallback onDelete;

  const _EntryDetails({required this.entry, required this.onChanged, required this.onDelete});

  @override
  State<_EntryDetails> createState() => _EntryDetailsState();
}

class _EntryDetailsState extends State<_EntryDetails> {
  late final HistoryEntry _e = widget.entry;
  late final TextEditingController _note = TextEditingController(text: widget.entry.note);
  bool _deleted = false;

  @override
  void dispose() {
    if (!_deleted && _note.text.trim() != widget.entry.note) widget.onChanged(_e.withNote(_note.text.trim()));
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = _e;
    Widget row(String a, String b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(a, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
            const SizedBox(width: 12),
            Flexible(child: Text(b, textAlign: TextAlign.right, style: theme.textTheme.bodyMedium)),
          ]),
        );
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _Thumb(e.thumbPath, size: 72),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.name, style: theme.textTheme.titleMedium),
                Text(formatDate(e.date), style: theme.textTheme.bodySmall),
                const SizedBox(height: 4),
                Text(fmtMoney(e.totalCost),
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          row(tr('Матеріал'), trf('{0}, {1} г/см³', [e.material, fmtNum(e.density, 2)])),
          row(tr('Ціна пластику'), trf('{0} {1}/кг', [fmtNum(e.pricePerKg, 0), currency])),
          row(tr('Шар / заповнення / стінки'), trf('{0} мм / {1}% / {2}', [fmtNum(e.layerHeight, 2), fmtNum(e.infillPercent, 0), e.walls])),
          row(tr('Розмір'), trf('{0} × {1} × {2} мм', [fmtNum(e.sizeX, 1), fmtNum(e.sizeY, 1), fmtNum(e.sizeZ, 1)])),
          if (e.scalePercent != 100) row(tr('Масштаб'), '${fmtNum(e.scalePercent, 0)}%'),
          row(tr('Кількість'), trf('{0} шт.', [e.copies])),
          const Divider(height: 20),
          row(tr('Модель (1 шт.)'), fmtGrams(e.modelGrams)),
          row(tr('Підтримки (1 шт.)'), e.source.isNotEmpty ? tr('у вазі слайсера') : (e.supports ? fmtGrams(e.supportGrams) : tr('вимкнено'))),
          row(tr('Разом'), trf('{0} · {1} м', [fmtGrams(e.totalGrams), fmtNum(e.filamentMeters, 2)])),
          row(tr('Джерело цифр'), e.source.isEmpty ? tr('розрахунок додатка') : trf('точно, {0}', [e.source])),
          const Divider(height: 20),
          if (e.printHours > 0) row(tr('Час друку'), formatDuration(e.printHours)),
          row(tr('Пластик'), fmtMoney(e.materialCost)),
          if (e.electricityCost != 0) row(tr('Електроенергія'), fmtMoney(e.electricityCost)),
          if (e.amortizationCost != 0) row(tr('Амортизація'), fmtMoney(e.amortizationCost)),
          row(tr('Собівартість'), fmtMoney(e.costPrice)),
          if (e.markupPercent != 0) row(trf('Заробіток {0}%', [fmtNum(e.markupPercent, 0)]), fmtMoney(e.costPrice * e.markupPercent / 100)),
          if (e.extraCost != 0) row(tr('Доплата'), fmtMoney(e.extraCost)),
          row(tr('Ціна'), fmtMoney(e.totalCost)),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            decoration: InputDecoration(labelText: tr('Примітка (клієнт, колір…)'), border: OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  _deleted = true;
                  widget.onDelete();
                },
                icon: const Icon(Icons.delete_outline),
                label: Text(tr('Видалити')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => PlatformFiles.shareText(historySummary(e.withNote(_note.text.trim()))),
                icon: const Icon(Icons.share_outlined),
                label: Text(tr('Поділитися')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
