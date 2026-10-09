import 'package:flutter/material.dart';

import '../history/history.dart';
import '../orders/orders.dart';
import 'widgets.dart';

const _months = [
  'Січень', 'Лютий', 'Березень', 'Квітень', 'Травень', 'Червень', //
  'Липень', 'Серпень', 'Вересень', 'Жовтень', 'Листопад', 'Грудень',
];

class _Month {
  final int year, month;
  int orders = 0;
  double revenue = 0, cost = 0, grams = 0, hours = 0, paid = 0;

  _Month(this.year, this.month);

  double get profit => revenue - cost;
  String get label => '${_months[month - 1]} $year';
}

/// Revenue, profit and plastic per month from printed orders.
class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<_Month>? _months2;
  int _open = 0;
  double _openTotal = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final orders = await OrderStore.load();
    final map = <int, _Month>{};
    int open = 0;
    double openTotal = 0;
    for (final o in orders) {
      final t = o.totals;
      if (!o.status.printed) {
        open++;
        openTotal += t.total;
        continue;
      }
      final d = o.doneAt ?? o.createdAt;
      final key = d.year * 12 + d.month - 1;
      final m = map.putIfAbsent(key, () => _Month(d.year, d.month));
      m.orders++;
      m.revenue += t.total;
      m.cost += t.cost;
      m.grams += t.grams;
      m.hours += t.hours;
      if (o.status == OrderStatus.paid) m.paid += t.total;
    }
    final list = map.entries.toList()..sort((a, b) => b.key.compareTo(a.key));
    if (mounted) {
      setState(() {
        _months2 = [for (final e in list) e.value];
        _open = open;
        _openTotal = openTotal;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final months = _months2;
    Widget tile(String label, String value, IconData icon) => Expanded(
          child: Card(
            margin: const EdgeInsets.all(4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(height: 6),
                Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(label, style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Статистика')),
      body: months == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (months.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Статистика з\'явиться, коли замовлення отримають статус «Готово» або «Оплачено».',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                else ...[
                  Text(months.first.label, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Row(children: [
                    tile('виручка', fmtMoney(months.first.revenue), Icons.payments_outlined),
                    tile('прибуток', fmtMoney(months.first.profit), Icons.trending_up),
                  ]),
                  Row(children: [
                    tile('замовлень', '${months.first.orders}', Icons.receipt_long_outlined),
                    tile('пластику', fmtGrams(months.first.grams), Icons.circle_outlined),
                    tile('друку', formatDuration(months.first.hours), Icons.schedule),
                  ]),
                ],
                if (_open > 0)
                  Card(
                    margin: const EdgeInsets.all(4),
                    child: ListTile(
                      leading: const Icon(Icons.pending_actions_outlined),
                      title: Text('В роботі: $_open'),
                      trailing: Text(fmtMoney(_openTotal), style: theme.textTheme.titleSmall),
                    ),
                  ),
                if (months.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text('По місяцях', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  for (final m in months.take(12))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(m.label, style: theme.textTheme.bodyMedium)),
                          Text(fmtMoney(m.revenue), style: theme.textTheme.titleSmall),
                        ]),
                        const SizedBox(height: 4),
                        LayoutBuilder(builder: (context, c) {
                          final max = months.take(12).fold(0.0, (a, x) => x.revenue > a ? x.revenue : a);
                          final w = max > 0 ? c.maxWidth * m.revenue / max : 0.0;
                          final pw = max > 0 ? c.maxWidth * (m.profit < 0 ? 0.0 : m.profit) / max : 0.0;
                          return Stack(children: [
                            Container(height: 10, width: w, decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(5),
                            )),
                            Container(height: 10, width: pw, decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(5),
                            )),
                          ]);
                        }),
                        const SizedBox(height: 2),
                        Text(
                          'прибуток ${fmtMoney(m.profit)} · ${m.orders} зам. · ${fmtGrams(m.grams)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ]),
                    ),
                ],
              ],
            ),
    );
  }
}
