import 'package:flutter/material.dart';

import '../data/records.dart';
import '../expenses/expenses.dart';
import '../history/history.dart';
import '../slicer/settings.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

IconData expenseIcon(String c) => switch (c) {
      'Пластик' => Icons.circle_outlined,
      'Запчастини' => Icons.build_outlined,
      'Ремонт' => Icons.handyman_outlined,
      'Обладнання' => Icons.print_outlined,
      'Пакування' => Icons.inventory_2_outlined,
      'Доставка' => Icons.local_shipping_outlined,
      _ => Icons.more_horiz,
    };

Future<Expense?> editExpense(BuildContext context, [Expense? e]) =>
    showDialog<Expense>(context: context, builder: (_) => _ExpenseDialog(expense: e));

/// Purchases and other costs, so statistics can show net profit.
class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key});

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  List<Expense>? _list;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final l = await expenseStore.load();
    l.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() => _list = l);
  }

  Future<void> _edit([Expense? e]) async {
    final r = await editExpense(context, e);
    if (r == null) return;
    await expenseStore.upsert(r);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    final now = DateTime.now();
    final month = list
            ?.where((e) => e.date.year == now.year && e.date.month == now.month)
            .fold(0.0, (a, e) => a + e.amount) ??
        0;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Витрати'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(tr('Витрата')),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(tr('Цього місяця')),
                    trailing: Text(fmtMoney(month), style: theme.textTheme.titleMedium),
                  ),
                ),
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Записуйте покупки пластику, запчастини, пакування — у статистиці буде чистий прибуток.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                for (final e in list) ...[
                  if (_firstOfMonth(list, e))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
                      child: Row(children: [
                        Expanded(child: Text(monthName(e.date), style: theme.textTheme.titleSmall)),
                        Text(
                          fmtMoney(list
                              .where((x) => x.date.year == e.date.year && x.date.month == e.date.month)
                              .fold(0.0, (a, x) => a + x.amount)),
                          style: theme.textTheme.titleSmall,
                        ),
                      ]),
                    ),
                  Dismissible(
                    key: ValueKey(e.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: theme.colorScheme.errorContainer,
                      child: const Icon(Icons.delete_outline),
                    ),
                    onDismissed: (_) async {
                      await expenseStore.remove(e.id);
                      _reload();
                    },
                    child: Card(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      child: ListTile(
                        leading: Icon(expenseIcon(e.category)),
                        title: Text(e.note.isEmpty ? tr(e.category) : e.note, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${tr(e.category)} · ${formatDate(e.date).split(' ').first}'),
                        trailing: Text(fmtMoney(e.amount), style: theme.textTheme.titleSmall),
                        onTap: () => _edit(e),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

bool _firstOfMonth(List<Expense> list, Expense e) {
  final i = list.indexOf(e);
  if (i <= 0) return true;
  final p = list[i - 1].date;
  return p.year != e.date.year || p.month != e.date.month;
}

List<String> get _monthNames => [
  tr('Січень'), tr('Лютий'), tr('Березень'), tr('Квітень'), tr('Травень'), tr('Червень'), //
  tr('Липень'), tr('Серпень'), tr('Вересень'), tr('Жовтень'), tr('Листопад'), tr('Грудень'),
];

String monthName(DateTime d) => '${_monthNames[d.month - 1]} ${d.year}';

class _ExpenseDialog extends StatefulWidget {
  final Expense? expense;

  const _ExpenseDialog({this.expense});

  @override
  State<_ExpenseDialog> createState() => _ExpenseDialogState();
}

class _ExpenseDialogState extends State<_ExpenseDialog> {
  late String _cat = widget.expense?.category ?? expenseCategories.first;
  late DateTime _date = widget.expense?.date ?? DateTime.now();
  late final _amount =
      TextEditingController(text: widget.expense == null ? '' : fmtNum(widget.expense!.amount, 2));
  late final _note = TextEditingController(text: widget.expense?.note ?? '');

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.expense == null ? tr('Нова витрата') : tr('Витрата')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in expenseCategories)
              ChoiceChip(
                avatar: Icon(expenseIcon(c), size: 16),
                label: Text(tr(c)),
                selected: _cat == c,
                onSelected: (_) => setState(() => _cat = c),
              ),
          ]),
          TextField(
            controller: _amount,
            autofocus: widget.expense == null,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: trf('Сума, {0}', [currency])),
          ),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr('Що саме'), hintText: tr('PETG 2 кг, сопло 0.4…')),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2015),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (d != null) setState(() => _date = d);
            },
            icon: const Icon(Icons.event_outlined),
            label: Text(formatDate(_date).split(' ').first),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: () {
            final a = double.tryParse(_amount.text.replaceAll(',', '.').replaceAll(' ', ''));
            if (a == null || a <= 0) return;
            Navigator.pop(
              context,
              Expense(
                id: widget.expense?.id ?? newId(),
                date: _date,
                category: _cat,
                amount: a,
                note: _note.text.trim(),
              ),
            );
          },
          child: Text(tr('Зберегти')),
        ),
      ],
    );
  }
}
