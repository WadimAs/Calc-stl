import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../data/json_store.dart';
import '../i18n/i18n.dart';
import 'updates.dart';

/// Numbers from the stats server (author only).
class UsageStats {
  final int online, day, week, month, total, newWeek;
  final List<(String, int)> daily, versions, countries;
  final DateTime at;

  const UsageStats({
    required this.online,
    required this.day,
    required this.week,
    required this.month,
    required this.total,
    required this.newWeek,
    required this.daily,
    required this.versions,
    required this.countries,
    required this.at,
  });

  static UsageStats? fromJson(Object? j) {
    if (j is! Map || j['total'] is! num) return null;
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    List<(String, int)> rows(String k, String name) => [
          for (final r in (j[k] as List? ?? const []))
            if (r is Map) ('${r[name] ?? ''}', (r['n'] as num?)?.toInt() ?? 0),
        ];
    return UsageStats(
      online: n('online'),
      day: n('day'),
      week: n('week'),
      month: n('month'),
      total: n('total'),
      newWeek: n('newWeek'),
      daily: rows('daily', 'day'),
      versions: rows('versions', 'v'),
      countries: rows('countries', 'c'),
      at: DateTime.fromMillisecondsSinceEpoch(n('at')),
    );
  }
}

/// Anonymous usage counter: a random install id and the app version are sent
/// when the app starts and every few minutes while it is open. Nothing else.
class Usage {
  static const _file = 'usage.json';
  static const _interval = Duration(minutes: 5);
  static String? _url;
  static Map<String, dynamic> _state = {};
  static Timer? _timer;

  /// Tests: never contact the server.
  static bool disabled = false;

  static Future<void> _load() async {
    if (_url == null) {
      try {
        _url = (await rootBundle.loadString('assets/stats_url.txt')).trim();
      } catch (_) {
        _url = '';
      }
    }
    final raw = await JsonStore.read(_file);
    _state = raw is Map ? Map<String, dynamic>.from(raw) : {};
    if (_state['id'] is! String) {
      final r = Random.secure();
      _state['id'] = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await JsonStore.write(_file, _state);
    }
  }

  static bool get configured => (_url ?? '').isNotEmpty;

  static Future<bool> enabled() async {
    await _load();
    return _state['off'] != true;
  }

  static Future<void> setEnabled(bool on) async {
    await _load();
    _state['off'] = !on;
    await JsonStore.write(_file, _state);
    if (on) {
      start();
    } else {
      _timer?.cancel();
    }
  }

  /// Author's key for the stats screen ('' = not set).
  static Future<String> adminKey() async {
    await _load();
    return _state['admin'] is String ? _state['admin'] as String : '';
  }

  static Future<void> setAdminKey(String key) async {
    await _load();
    _state['admin'] = key.trim();
    await JsonStore.write(_file, _state);
  }

  /// Starts pinging (call once when the app opens).
  static Future<void> start() async {
    if (disabled) return;
    await _load();
    if (!configured || _state['off'] == true) return;
    _timer?.cancel();
    unawaited(_ping());
    _timer = Timer.periodic(_interval, (_) => _ping());
  }

  static void pause() => _timer?.cancel();

  static Future<void> _ping() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final v = await Updates.installedName();
      final req = await client.postUrl(Uri.parse('$_url/ping'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'id': _state['id'], 'v': v, 'lang': lang}));
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
    } catch (_) {
      // offline: next time
    } finally {
      client.close(force: true);
    }
  }

  /// Stats for the author; throws a readable message on errors.
  static Future<UsageStats> stats() async {
    await _load();
    if (!configured) throw StateError(tr('Сервер статистики ще не налаштовано.'));
    final key = await adminKey();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$_url/stats'));
      req.headers.set('x-admin-key', key);
      final res = await req.close().timeout(const Duration(seconds: 12));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 403) throw StateError(tr('Невірний ключ статистики.'));
      if (res.statusCode != 200) throw StateError('HTTP ${res.statusCode}');
      final s = UsageStats.fromJson(jsonDecode(body));
      if (s == null) throw StateError(tr('Сервер повернув незрозумілу відповідь.'));
      return s;
    } on SocketException {
      throw StateError(tr('Немає з\'єднання з інтернетом.'));
    } on TimeoutException {
      throw StateError(tr('Сервер не відповідає.'));
    } finally {
      client.close(force: true);
    }
  }
}
