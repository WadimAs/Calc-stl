import '../data/records.dart';

/// Stored as these Ukrainian keys; shown through tr().
const expenseCategories = ['Пластик', 'Запчастини', 'Ремонт', 'Обладнання', 'Пакування', 'Доставка', 'Інше']; // no-tr

class Expense {
  final String id;
  final DateTime date;
  final String category;
  final double amount;
  final String note;

  const Expense({required this.id, required this.date, required this.category, required this.amount, this.note = ''});

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.millisecondsSinceEpoch,
        'category': category,
        'amount': amount,
        'note': note,
      };

  static Expense? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    return Expense(
      id: raw['id'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(raw['date'] is num ? (raw['date'] as num).toInt() : 0),
      category: raw['category'] is String ? raw['category'] as String : 'Інше', // no-tr
      amount: raw['amount'] is num ? (raw['amount'] as num).toDouble() : 0,
      note: raw['note'] is String ? raw['note'] as String : '',
    );
  }
}

const expenseStore = RecordStore<Expense>('expenses.json', Expense.fromJson, _expenseJson, _expenseId);
Map<String, dynamic> _expenseJson(Expense e) => e.toJson();
String _expenseId(Expense e) => e.id;
