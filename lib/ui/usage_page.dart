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
  List<DeviceRecord>? _devices;
  String? _devError;
  (int, int)? _progress;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _loadDevices());
  }

  Future<void> _loadDevices() async {
    if (_progress != null) return;
    setState(() {
      _progress = (0, 0);
      _devError = null;
    });
    try {
      final d = await Usage.devices(onProgress: (a, b) {
        if (mounted) setState(() => _progress = (a, b));
      });
      if (mounted) setState(() => _devices = d);
    } catch (e) {
      if (mounted) setState(() => _devError = e is StateError ? e.message : '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
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
          IconButton(
            tooltip: tr('Оновити'),
            onPressed: _loading || _progress != null ? null : () => _load().then((_) => _loadDevices()),
            icon: const Icon(Icons.refresh),
          ),
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
          const SizedBox(height: 8),
          Text(tr('Пристрої'), style: theme.textTheme.titleMedium),
          if (_progress != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                LinearProgressIndicator(value: _progress!.$2 == 0 ? null : _progress!.$1 / _progress!.$2),
                const SizedBox(height: 6),
                Text(
                  _progress!.$2 == 0
                      ? tr('Завантаження…')
                      : trf('Завантаження {0} з {1} (сервіс дозволяє небагато запитів, тож перший раз довго)', [_progress!.$1, _progress!.$2]),
                  style: theme.textTheme.bodySmall,
                ),
              ]),
            ),
          if (_devError != null)
            Card(
              color: cs.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(_devError!, style: TextStyle(color: cs.onErrorContainer)),
              ),
            ),
          if (_devices != null) ..._deviceSection(context, _devices!),
        ]),
      ),
    );
  }

  List<Widget> _deviceSection(BuildContext context, List<DeviceRecord> all) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (all.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(tr('Ще жоден телефон не надіслав дані — вони з\'являються після оновлення застосунку.'),
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.outline)),
        ),
      ];
    }
    final now = DateTime.now();
    bool within(DateTime? t, int days) => t != null && now.difference(t).inDays < days;
    final list = List.of(all)
      ..sort((a, b) => (b.installed ?? DateTime(2000)).compareTo(a.installed ?? DateTime(2000)));
    Map<String, int> count(String Function(DeviceRecord) key) {
      final m = <String, int>{};
      for (final d in all) {
        final k = key(d);
        m[k.isEmpty ? '?' : k] = (m[k.isEmpty ? '?' : k] ?? 0) + 1;
      }
      return Map.fromEntries(m.entries.toList()..sort((a, b) => b.value.compareTo(a.value)));
    }

    String brand(DeviceRecord d) {
      final m = d.maker.trim();
      return m.isEmpty ? '' : '${m[0].toUpperCase()}${m.substring(1).toLowerCase()}';
    }

    // Installs per day, last 14 days.
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (int i = 13; i >= 0; i--)
        (
          today.subtract(Duration(days: i)),
          all.where((d) {
            final t = d.installed?.toLocal();
            if (t == null) return false;
            final x = today.subtract(Duration(days: i));
            return t.year == x.year && t.month == x.month && t.day == x.day;
          }).length,
        ),
    ];
    Widget small(String label, int v) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$v', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                Text(label, style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        );
    return [
      Row(children: [
        small(tr('пристроїв'), all.length),
        small(tr('активні за 7 днів'), all.where((d) => within(d.lastSeen, 7)).length),
        small(tr('нові за 7 днів'), all.where((d) => within(d.installed, 7)).length),
      ]),
      _DailyChart(days, title: tr('Нові встановлення за днями')),
      _Breakdown(tr('Виробники'), count(brand)),
      _Breakdown(tr('Версії Android'), count((d) => d.android)),
      _Breakdown(tr('Версії застосунку'), count((d) => d.build == 0 ? '' : '1.3.${d.build}')),
      _Breakdown(tr('Країна (за мовою телефону)'), count((d) => d.country)),
      const SizedBox(height: 8),
      Text(tr('Усі пристрої'), style: theme.textTheme.titleSmall),
      for (final d in list)
        Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(radius: 16, child: Text('${d.n}', style: theme.textTheme.labelSmall)),
            title: Text(d.phone.isEmpty ? '?' : d.phone, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text([
              d.android,
              if (d.country.isNotEmpty) d.country,
              if (d.installed != null) trf('встановлено {0}', [_date(d.installed!)]),
              if (d.lastSeen != null) trf('востаннє {0}', [_date(d.lastSeen!)]),
              if (d.build > 0) '1.3.${d.build}',
            ].join(' · ')),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          tr('Лише модель телефону, версія Android, країна за мовою телефону, дата встановлення й останнього запуску та версія застосунку — без імен, номерів і ідентифікаторів.'),
          style: theme.textTheme.bodySmall?.copyWith(color: cs.outline),
        ),
      ),
    ];
  }

  static String _date(DateTime t) {
    final l = t.toLocal();
    return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}.${l.year % 100}';
  }
}

/// Counts per value (brand, Android version…) with bars.
class _Breakdown extends StatelessWidget {
  final String title;
  final Map<String, int> counts;

  const _Breakdown(this.title, this.counts);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = counts.values.fold<int>(1, (a, v) => v > a ? v : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final e in counts.entries.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                SizedBox(width: 110, child: Text(e.key, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        height: 10,
                        width: c.maxWidth * e.value / max,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text('${e.value}', style: theme.textTheme.labelMedium),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Active users per day, last 14 days.
class _DailyChart extends StatelessWidget {
  final List<(DateTime, int)> days;
  final String? title;

  const _DailyChart(this.days, {this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = days.fold<int>(1, (a, d) => d.$2 > a ? d.$2 : a);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title ?? tr('Активні за днями'), style: theme.textTheme.titleSmall),
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
