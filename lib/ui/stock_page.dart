import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../catalog/stock.dart';
import '../history/history.dart';
import '../i18n/i18n.dart';
import 'widgets.dart';

String stockKindLabel(String kind) => switch (kind) {
      'printed' => tr('Надруковано'),
      'sold' => tr('Продано'),
      'defect' => tr('Брак / списано'),
      _ => tr('Перерахунок'),
    };

IconData _icon(String kind) => switch (kind) {
      'printed' => Icons.add_box_outlined,
      'sold' => Icons.sell_outlined,
      'defect' => Icons.delete_outline,
      _ => Icons.tune,
    };

/// Log of stock moves: what was printed, sold or written off.
class StockPage extends StatefulWidget {
  const StockPage({super.key});

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  List<StockMove>? _moves;
  List<Product> _products = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await stockStore.load();
    final p = await productStore.load();
    m.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) {
      setState(() {
        _moves = m;
        _products = p;
      });
    }
  }

  Future<void> _undo(StockMove m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Скасувати запис?')),
        content: Text(tr('Залишок на складі повернеться, як було до цього запису.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Ні'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Скасувати запис'))),
        ],
      ),
    );
    if (ok != true) return;
    await undoStockMove(m);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final moves = _moves;
    final t = stockTotals(_products);
    final now = DateTime.now();
    final month = moves?.where((m) => m.kind == 'sold' && m.date.year == now.year && m.date.month == now.month) ?? [];
    final soldN = month.fold(0, (a, m) => a - m.qty);
    final soldSum = month.fold(0.0, (a, m) => a + m.amount);
    final soldProfit = month.fold(0.0, (a, m) => a + m.amount + m.qty * m.costEach);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Рух складу'))),
      body: moves == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
              children: [
                Card(
                  color: cs.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(trf('На складі: {0} шт', [t.pieces]),
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
                      Text(trf('Собівартість {0} · за цінами продажу {1}', [fmtMoney(t.cost), fmtMoney(t.value)]),
                          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
                      if (soldN > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          trf('Цього місяця продано {0} шт на {1} (прибуток {2})',
                              [soldN, fmtMoney(soldSum), fmtMoney(soldProfit)]),
                          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
                        ),
                      ],
                    ]),
                  ),
                ),
                if (moves.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Тут з\'являться надруковані, продані й списані вироби. Додавайте їх у прайс-листі (меню виробу) або у вікні «Друк завершено».'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                for (final m in moves)
                  Card(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    child: ListTile(
                      leading: Icon(_icon(m.kind), color: m.qty > 0 ? cs.primary : cs.onSurfaceVariant),
                      title: Text(m.productName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          stockKindLabel(m.kind),
                          formatDate(m.date),
                          if (m.kind == 'sold' && m.amount > 0) fmtMoney(m.amount),
                          if (m.note.isNotEmpty) m.note,
                        ].join(' · '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(m.qty > 0 ? '+${m.qty}' : '${m.qty}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: m.qty > 0 ? cs.primary : cs.error,
                              fontWeight: FontWeight.w700,
                            )),
                        IconButton(
                          tooltip: tr('Скасувати запис'),
                          onPressed: () => _undo(m),
                          icon: const Icon(Icons.undo),
                        ),
                      ]),
                    ),
                  ),
              ],
            ),
    );
  }
}
