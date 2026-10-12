import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/json_store.dart';
import '../i18n/i18n.dart';

/// Numbers from the public counter (author only).
class UsageStats {
  final int installs, now, today;
  final List<(DateTime, int)> days; // last 14 days, oldest first

  const UsageStats({required this.installs, required this.now, required this.today, required this.days});

  int get week => days.reversed.take(7).fold(0, (a, d) => a + d.$2);
}

/// Anonymous usage counter on the free public Abacus service (no account,
/// no personal data): every install adds +1 to "installs" once, to the
/// day's counter once a day and to the hour's counter once an hour while open.
class Usage {
  static const _base = 'https://abacus.jasoncameron.dev';
  static const _ns = 'stl-vaga-wadimas';
  static const _file = 'usage.json';
  static Map<String, dynamic> _state = {};
  static bool _loaded = false;
  static Timer? _timer;

  static Future<void> _load() async {
    if (_loaded) return;
    final raw = await JsonStore.read(_file);
    _state = raw is Map ? Map<String, dynamic>.from(raw) : {};
    _loaded = true;
  }

  static Future<void> _save() => JsonStore.write(_file, _state);

  static String _d(DateTime t) => t.toIso8601String().substring(0, 10);
  static String dayKey(DateTime t) => 'd-${_d(t.toUtc())}';
  static String hourKey(DateTime t) {
    final u = t.toUtc();
    return 'h-${_d(u)}-${u.hour.toString().padLeft(2, '0')}';
  }

  static Future<bool> enabled() async {
    await _load();
    return _state['off'] != true;
  }

  static Future<void> setEnabled(bool on) async {
    await _load();
    _state['off'] = !on;
    await _save();
    if (on) {
      start();
    } else {
      _timer?.cancel();
    }
  }

  /// The "Users" screen is shown in the menu (author only, 7 taps on the version).
  static Future<bool> admin() async {
    await _load();
    return _state['admin'] == true;
  }

  static Future<void> setAdmin(bool on) async {
    await _load();
    _state['admin'] = on;
    await _save();
  }

  /// Call when the app opens or comes back to the foreground.
  static Future<void> start() async {
    await _load();
    if (_state['off'] == true) return;
    _timer?.cancel();
    unawaited(_tick());
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => _tick());
  }

  static void pause() => _timer?.cancel();

  static Future<void> _tick() async {
    final now = DateTime.now();
    if (_state['installed'] != true && await _hit('installs')) _state['installed'] = true;
    final d = dayKey(now), h = hourKey(now);
    if (_state['day'] != d && await _hit(d)) _state['day'] = d;
    if (_state['hour'] != h && await _hit(h)) _state['hour'] = h;
    await _save();
  }

  static Future<Object?> _get(String path) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('$_base/$path'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 404) return 0;
      if (res.statusCode != 200) return null;
      final j = jsonDecode(body);
      return j is Map && j['value'] is num ? (j['value'] as num).toInt() : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _hit(String key) async => await _get('hit/$_ns/$key') != null;

  static Future<int> _value(String key) async {
    final v = await _get('get/$_ns/$key');
    if (v == null) throw StateError(tr('Не вдалося отримати дані. Перевірте інтернет.'));
    return v as int;
  }

  static Future<UsageStats> stats() async {
    final now = DateTime.now();
    final dates = [for (int i = 13; i >= 0; i--) now.toUtc().subtract(Duration(days: i))];
    final values = await Future.wait([
      _value('installs'),
      _value(hourKey(now)),
      for (final d in dates) _value(dayKey(d)),
    ]);
    final days = [for (int i = 0; i < dates.length; i++) (dates[i], values[i + 2])];
    return UsageStats(installs: values[0], now: values[1], today: days.last.$2, days: days);
  }
}
