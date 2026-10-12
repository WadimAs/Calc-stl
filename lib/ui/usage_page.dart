import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../platform/usage.dart';

/// Asks for the author's stats key; returns true when one was saved.
Future<bool> askUsageKey(BuildContext context) async {
  final c = TextEditingController(text: await Usage.adminKey());
  if (!context.mounted) return false;
  final key = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('Ключ статистики')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(tr('Лише для автора застосунку: відкриває кількість користувачів.'),
            style: Theme.of(ctx).textTheme.bodySmall),
        TextField(
          controller: c,
          autofocus: true,
          obscureText: true,
          decoration: InputDecoration(labelText: tr('Ключ')),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Скасувати'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(tr('Зберегти'))),
      ],
    ),
  );
  if (key == null) return false;
  await Usage.setAdminKey(key);
  return key.trim().isNotEmpty;
}

class UsagePage extends StatefulWidget {
  const UsagePage({super.key});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  UsageStats? _s;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await Usage.stats();
      if (mounted) setState(() => _s = s);
    } catch (e) {
      if (mounted) setState(() => _error = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final s = _s;
    Widget tile(String label, int v, {bool big = false}) => Card(
          color: big ? cs.primaryContainer : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$v',
                  style: (big ? theme.textTheme.displayMedium : theme.textTheme.headlineMedium)
                      ?.copyWith(fontWeight: FontWeight.w700, color: big ? cs.onPrimaryContainer : null)),
              Text(label, style: theme.textTheme.bodyMedium),
            ]),
          ),
        );
    Widget rows(String title, List<(String, int)> items, String Function(String) name) {
      final max = items.fold<int>(1, (a, r) => r.$2 > a ? r.$2 : a);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final r in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 120, child: Text(name(r.$1), overflow: TextOverflow.ellipsis)),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: r.$2 / max,
                      minHeight: 8,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  SizedBox(width: 44, child: Text('${r.$2}', textAlign: TextAlign.end)),
                ]),
              ),
            if (items.isEmpty) Text('—', style: theme.textTheme.bodySmall),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Користувачі')),
        actions: [
          IconButton(
            tooltip: tr('Ключ статистики'),
            onPressed: () async {
              if (await askUsageKey(context)) _load();
            },
            icon: const Icon(Icons.key_outlined),
          ),
          IconButton(tooltip: tr('Оновити'), onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          if (_loading && s == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
          if (_error != null)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          if (s != null) ...[
            tile(tr('зараз у застосунку'), s.online, big: true),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              children: [
                tile(tr('за добу'), s.day),
                tile(tr('за тиждень'), s.week),
                tile(tr('за місяць'), s.month),
                tile(tr('усього встановлень'), s.total),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text(trf('Нових за тиждень: {0}', [s.newWeek]), style: theme.textTheme.bodyMedium),
            ),
            _DailyChart(s.daily),
            rows(tr('Версії (за місяць)'), s.versions, (v) => v.isEmpty ? '?' : v),
            rows(tr('Країни (за місяць)'), s.countries, (c) => c.isEmpty ? '?' : c),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                tr('«Зараз» — хто відкривав застосунок за останні 10 хвилин. Рахуються лише анонімні номери встановлень.'),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Active users per day, last 14 days.
class _DailyChart extends StatelessWidget {
  final List<(String, int)> daily;

  const _DailyChart(this.daily);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byDay = {for (final d in daily) d.$1: d.$2};
    final today = DateTime.now().toUtc();
    final days = [for (int i = 13; i >= 0; i--) today.subtract(Duration(days: i))];
    String key(DateTime d) => d.toIso8601String().substring(0, 10);
    final max = days.fold<int>(1, (a, d) => (byDay[key(d)] ?? 0) > a ? byDay[key(d)]! : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('Активні за днями'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 10),
          SizedBox(
            height: 130,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final d in days)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text('${byDay[key(d)] ?? 0}', style: theme.textTheme.labelSmall),
                      const SizedBox(height: 2),
                      Container(
                        height: 4 + 90 * (byDay[key(d)] ?? 0) / max,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('${d.day}', style: theme.textTheme.labelSmall),
                    ]),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
