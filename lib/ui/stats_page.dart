import 'package:flutter/material.dart';

import '../expenses/expenses.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import 'expenses_page.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

List<String> get _months => [
  tr('Січень'), tr('Лютий'), tr('Березень'), tr('Квітень'), tr('Травень'), tr('Червень'), //
  tr('Липень'), tr('Серпень'), tr('Вересень'), tr('Жовтень'), tr('Листопад'), tr('Грудень'),
];

class _Month {
  final int year, month;
  int orders = 0;
  double revenue = 0, cost = 0, grams = 0, hours = 0, paid = 0, expenses = 0;

  _Month(this.year, this.month);

  double get profit => revenue - cost;

  /// Revenue minus all recorded expenses (purchases replace the per-order cost
  /// estimate once the user tracks them).
  double get net => revenue - expenses;
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
    for (final e in await expenseStore.load()) {
      final key = e.date.year * 12 + e.date.month - 1;
      map.putIfAbsent(key, () => _Month(e.date.year, e.date.month)).expenses += e.amount;
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
      appBar: AppBar(
        title: Text(tr('Статистика')),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ExpensesPage()));
              _load();
            },
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: Text(tr('Витрати')),
          ),
        ],
      ),
      body: months == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                if (months.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      tr('Статистика з\'явиться, коли замовлення отримають статус «Готово» або «Оплачено».'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  )
                else ...[
                  Text(months.first.label, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Row(children: [
                    tile(tr('виручка'), fmtMoney(months.first.revenue), Icons.payments_outlined),
                    tile(tr('прибуток'), fmtMoney(months.first.profit), Icons.trending_up),
                  ]),
                  if (months.first.expenses > 0)
                    Row(children: [
                      tile(tr('витрати'), fmtMoney(months.first.expenses), Icons.account_balance_wallet_outlined),
                      tile(tr('чистий (виручка − витрати)'), fmtMoney(months.first.net), Icons.savings_outlined),
                    ]),
                  Row(children: [
                    tile(tr('замовлень'), '${months.first.orders}', Icons.receipt_long_outlined),
                    tile(tr('пластику'), fmtGrams(months.first.grams), Icons.circle_outlined),
                    tile(tr('друку'), formatDuration(months.first.hours), Icons.schedule),
                  ]),
                ],
                if (_open > 0)
                  Card(
                    margin: const EdgeInsets.all(4),
                    child: ListTile(
                      leading: const Icon(Icons.pending_actions_outlined),
                      title: Text(trf('В роботі: {0}', [_open])),
                      trailing: Text(fmtMoney(_openTotal), style: theme.textTheme.titleSmall),
                    ),
                  ),
                if (months.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(tr('По місяцях'), style: theme.textTheme.titleMedium),
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
                          trf('прибуток {0} · {1} зам. · {2}{3}', [fmtMoney(m.profit), m.orders, fmtGrams(m.grams), m.expenses > 0 ? trf('\nвитрати {0} · чистий {1}', [fmtMoney(m.expenses), fmtMoney(m.net)]) : '']),
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
