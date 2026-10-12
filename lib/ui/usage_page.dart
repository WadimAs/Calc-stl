import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../platform/usage.dart';

/// How many people use the app (author only).
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
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Користувачі')),
        actions: [
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
            tile(tr('у застосунку цієї години'), s.now, big: true),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.9,
              children: [
                tile(tr('сьогодні'), s.today),
                tile(tr('усього встановлень'), s.installs),
              ],
            ),
            _DailyChart(s.days),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                tr('Кожен телефон рахується один раз на день і один раз на годину. Дні й години — за UTC (київський час мінус 2–3 год).'),
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
  final List<(DateTime, int)> days;

  const _DailyChart(this.days);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = days.fold<int>(1, (a, d) => d.$2 > a ? d.$2 : a);
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
                      Text('${d.$2}', style: theme.textTheme.labelSmall),
                      const SizedBox(height: 2),
                      Container(
                        height: 4 + 90 * d.$2 / max,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('${d.$1.day}', style: theme.textTheme.labelSmall),
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
