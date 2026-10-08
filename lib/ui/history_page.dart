import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../history/history.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import 'widgets.dart';

String historySummary(HistoryEntry e) {
  final b = StringBuffer()
    ..writeln(e.name)
    ..writeln('Матеріал: ${e.material}, ${fmtNum(e.layerHeight, 2)} мм, заповнення ${fmtNum(e.infillPercent, 0)}%')
    ..writeln('Вага: ${fmtGrams(e.totalGrams)}${e.copies > 1 ? ' (${e.copies} шт.)' : ''}');
  if (e.supports) b.writeln('  у т.ч. підтримки: ${fmtGrams(e.supportGrams * e.copies)}');
  b.writeln('Вартість: ${fmtMoney(e.totalCost)}');
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
        title: const Text('Очистити історію?'),
        content: const Text('Усі збережені розрахунки буде видалено.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Очистити')),
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV збережено')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не вдалося зберегти: $e')));
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
        title: const Text('Історія'),
        actions: [
          IconButton(
            tooltip: 'Експорт у CSV',
            onPressed: (items?.isNotEmpty ?? false) ? _export : null,
            icon: const Icon(Icons.file_download_outlined),
          ),
          IconButton(
            tooltip: 'Очистити',
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
                      Text('Поки що порожньо', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(
                        'Натисніть «Зберегти» під результатом розрахунку, щоб він з\'явився тут.',
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
                          '${items.length} розрахунків · ${fmtGrams(grams)} · ${fmtMoney(sum)}',
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
                  '${e.material} · ${fmtNum(e.layerHeight, 2)} мм · ${fmtNum(e.infillPercent, 0)}%'
                  '${e.supports ? ' · підтримки' : ''}${e.copies > 1 ? ' · ${e.copies} шт.' : ''}',
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
          row('Матеріал', '${e.material}, ${fmtNum(e.density, 2)} г/см³'),
          row('Ціна пластику', '${fmtNum(e.pricePerKg, 0)} $currency/кг'),
          row('Шар / заповнення / стінки', '${fmtNum(e.layerHeight, 2)} мм / ${fmtNum(e.infillPercent, 0)}% / ${e.walls}'),
          row('Розмір', '${fmtNum(e.sizeX, 1)} × ${fmtNum(e.sizeY, 1)} × ${fmtNum(e.sizeZ, 1)} мм'),
          if (e.scalePercent != 100) row('Масштаб', '${fmtNum(e.scalePercent, 0)}%'),
          row('Кількість', '${e.copies} шт.'),
          const Divider(height: 20),
          row('Модель (1 шт.)', fmtGrams(e.modelGrams)),
          row('Підтримки (1 шт.)', e.supports ? fmtGrams(e.supportGrams) : 'вимкнено'),
          row('Разом', '${fmtGrams(e.totalGrams)} · ${fmtNum(e.filamentMeters, 2)} м'),
          const Divider(height: 20),
          row('Пластик', fmtMoney(e.materialCost)),
          if (e.markupPercent != 0) row('Націнка ${fmtNum(e.markupPercent, 0)}%', fmtMoney(e.materialCost * e.markupPercent / 100)),
          if (e.extraCost != 0) row('Доплата', fmtMoney(e.extraCost)),
          row('Разом', fmtMoney(e.totalCost)),
          const SizedBox(height: 16),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: 'Примітка (клієнт, колір…)', border: OutlineInputBorder()),
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
                label: const Text('Видалити'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: () => PlatformFiles.shareText(historySummary(e.withNote(_note.text.trim()))),
                icon: const Icon(Icons.share_outlined),
                label: const Text('Поділитися'),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
