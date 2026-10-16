import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/json_store.dart';
import '../i18n/i18n.dart';

/// Numbers from the public counter (author only).
class UsageStats {
  final int installs, now, today;
  final List<(DateTime, int)> days; // last 14 days, oldest first

  const UsageStats({required this.installs, required this.now, required this.today, required this.days});

  int get week => days.reversed.take(7).fold(0, (a, d) => a + d.$2);
}

/// One install as the author sees it: phone, Android, when installed and last used.
class DeviceRecord {
  final int n;
  final String maker, model, country;
  final int sdk;
  final DateTime? installed;
  final DateTime? lastSeen;
  final int build;

  const DeviceRecord({
    required this.n,
    required this.maker,
    required this.model,
    required this.country,
    required this.sdk,
    required this.installed,
    required this.lastSeen,
    required this.build,
  });

  /// "Xiaomi Redmi Note 12" without a doubled brand ("samsung SM-…").
  String get phone {
    final m = maker.trim(), d = model.trim();
    if (m.isEmpty) return d;
    if (d.toLowerCase().startsWith(m.toLowerCase())) return d;
    return '${m[0].toUpperCase()}${m.substring(1)} $d';
  }

  String get android => sdkName(sdk);

  /// Test emulators (CI runs before they were excluded).
  bool get emulator {
    final m = model.toLowerCase();
    return m.contains('sdk_gphone') || m.startsWith('sdk ') || m.contains('emulator') ||
        m.contains('android sdk built for');
  }
}

/// Android version for an API level.
String sdkName(int sdk) => switch (sdk) {
      >= 36 => 'Android 16',
      35 => 'Android 15',
      34 => 'Android 14',
      33 => 'Android 13',
      32 || 31 => 'Android 12',
      30 => 'Android 11',
      29 => 'Android 10',
      28 => 'Android 9',
      27 || 26 => 'Android 8',
      25 || 24 => 'Android 7',
      23 => 'Android 6',
      <= 0 => '?',
      _ => 'Android 5',
    };

/// Records are packed into numbers (the counter service stores only numbers):
/// header = sdk | install day << 6 | text length << 22 | country << 28,
/// text "maker|model" in 7-byte chunks, status = last day * 10000 + build.
class DeviceCodec {
  static final epoch = DateTime.utc(2024, 1, 1);
  static const chunk = 7, maxBytes = 49;

  static int day(DateTime t) => t.toUtc().difference(epoch).inDays.clamp(0, 65535).toInt();
  static DateTime fromDay(int d) => epoch.add(Duration(days: d));

  static int _cc(String c) {
    final u = c.toUpperCase();
    if (u.length != 2 || !RegExp(r'^[A-Z]{2}$').hasMatch(u)) return 0;
    return (u.codeUnitAt(0) - 64) * 32 + (u.codeUnitAt(1) - 64);
  }

  static String _ccBack(int v) =>
      v <= 0 ? '' : String.fromCharCodes([64 + (v ~/ 32), 64 + (v % 32)]);

  static List<int> text(String maker, String model) {
    var b = utf8.encode('${maker.trim()}|${model.trim()}');
    if (b.length > maxBytes) b = b.sublist(0, maxBytes);
    return b;
  }

  static int header({required int sdk, required int installDay, required int len, required String country}) =>
      (sdk.clamp(0, 63)) | (installDay << 6) | (len.clamp(0, 63) << 22) | (_cc(country) << 28);

  static List<int> chunks(List<int> bytes) => [
        for (int i = 0; i < bytes.length; i += chunk)
          bytes.sublist(i, (i + chunk).clamp(0, bytes.length)).fold<int>(0, (a, x) => a * 256 + x),
      ];

  static int status(DateTime day0, int build) => day(day0) * 10000 + build.clamp(0, 9999);

  static DeviceRecord decode(int n, int header, List<int> chunkValues, int? status) {
    final sdk = header & 63;
    final d = (header >> 6) & 0xffff;
    final len = (header >> 22) & 63;
    final cc = (header >> 28) & 0x3ff;
    final bytes = <int>[];
    for (int i = 0; i < chunkValues.length; i++) {
      final size = (len - i * chunk).clamp(0, chunk);
      var v = chunkValues[i];
      final part = List<int>.filled(size, 0);
      for (int j = size - 1; j >= 0; j--) {
        part[j] = v & 255;
        v >>= 8;
      }
      bytes.addAll(part);
    }
    final t = utf8.decode(bytes, allowMalformed: true);
    final i = t.indexOf('|');
    return DeviceRecord(
      n: n,
      maker: i < 0 ? '' : t.substring(0, i),
      model: i < 0 ? t : t.substring(i + 1),
      country: _ccBack(cc),
      sdk: sdk,
      installed: d == 0 ? null : fromDay(d),
      lastSeen: status == null || status < 10000 ? null : fromDay(status ~/ 10000),
      build: status == null ? 0 : status % 10000,
    );
  }

  static int chunkCount(int header) => (((header >> 22) & 63) + chunk - 1) ~/ chunk;
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
    Map<Object?, Object?>? info;
    try {
      info = await _app.invokeMethod<Map<Object?, Object?>>('appInfo');
    } catch (_) {}
    // Test runs (emulators, debug builds) are not users.
    if (kDebugMode || info == null || info['emulator'] == true) return;
    if (!await _register(now, info)) return; // offline: next tick
    final d = dayKey(now), h = hourKey(now);
    if (_state['day'] != d && await _hit(d)) _state['day'] = d;
    if (_state['hour'] != h && await _hit(h)) _state['hour'] = h;
    await _save();
    try {
      await _status(now, info);
    } catch (_) {}
  }

  static const _app = MethodChannel('stl_weight/files');

  /// Counts the phone once, ever: a reinstall or an update is not a new user.
  /// The phone is recognised by a one-way hash of Android's per-app ID (the
  /// same after a reinstall, says nothing about the person).
  /// Then saves the phone model, Android version and install date once.
  static Future<bool> _register(DateTime now, Map<Object?, Object?> info) async {
    final dev = info['device'] is String ? info['device'] as String : '';
    final dkey = dev.isEmpty ? null : 'd$dev';
    var n = _state['seq'] is int ? _state['seq'] as int : 0;
    if (n == 0) {
      // Known phone (reinstalled)? Its number is stored under its hash.
      final known = dkey == null ? 0 : await _get('get/$_ns/$dkey');
      if (known == null) return false;
      if (known is int && known > 0) {
        n = known;
        // New status key for this install (the old one's admin key is gone).
        final g = await _get('hit/$_ns/u${n}g');
        if (g is! int) return false;
        _state['skey'] = 'u${n}s$g';
        _state['installed'] = true; // counted before
      } else {
        final v = await _get('hit/$_ns/seq');
        if (v is! int || v <= 0) return false;
        n = v;
        if (_state['installed'] != true) {
          if (!await _hit('installs')) return false;
          _state['installed'] = true;
          await _save();
        }
        if (dkey != null && await _create(dkey, n) == null) return false;
      }
      _state['seq'] = n;
      _state['dev'] = true;
      await _save();
    } else if (_state['dev'] != true && dkey != null) {
      // Registered before phones were recognised: link the hash to the number.
      if (await _create(dkey, n) == null) return false;
      _state['dev'] = true;
      await _save();
    }
    if (_state['reg'] != true) {
      final build = info['versionCode'] is int ? info['versionCode'] as int : 0;
      final status = DeviceCodec.status(now, build);
      if (_state['sk'] == null) {
        final k = await _create(_state['skey'] is String ? _state['skey'] as String : 'u${n}s', status);
        if (k == null) return false;
        _state['sk'] = k;
        _state['st'] = status;
        await _save();
      }
      final bytes = DeviceCodec.text('${info['maker'] ?? ''}', '${info['model'] ?? ''}');
      final installedMs = info['installed'] is int ? info['installed'] as int : 0;
      final installed = installedMs > 0 ? DateTime.fromMillisecondsSinceEpoch(installedMs) : now;
      final header = DeviceCodec.header(
        sdk: info['sdk'] is int ? info['sdk'] as int : 0,
        installDay: DeviceCodec.day(installed),
        len: bytes.length,
        country: '${info['country'] ?? ''}',
      );
      final parts = DeviceCodec.chunks(bytes);
      for (int i = 0; i < parts.length; i++) {
        if (await _create('u${n}c$i', parts[i]) == null) return false;
      }
      if (await _create('u${n}h', header) == null) return false; // header last: marks a complete record
      _state['reg'] = true;
      await _save();
    }
    return true;
  }

  /// Last-used day and app version, once a day.
  static Future<void> _status(DateTime now, Map<Object?, Object?> info) async {
    final n = _state['seq'];
    final key = _state['sk'];
    if (n is! int || key is! String || key.isEmpty) return;
    final build = info['versionCode'] is int ? info['versionCode'] as int : 0;
    final status = DeviceCodec.status(now, build);
    final name = _state['skey'] is String ? _state['skey'] as String : 'u${n}s';
    if (_state['st'] != status && await _set(name, status, key)) {
      _state['st'] = status;
      await _save();
    }
  }

  /// Creates a counter with a value; the admin key ('' if it already existed), null on failure.
  static Future<String?> _create(String key, int value) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.getUrl(Uri.parse('$_base/create/$_ns/$key?initializer=$value'));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 409) return '';
      if (res.statusCode != 201 && res.statusCode != 200) return null;
      final j = jsonDecode(body);
      return j is Map && j['admin_key'] is String ? j['admin_key'] as String : '';
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<bool> _set(String key, int value, String admin) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.postUrl(Uri.parse('$_base/set/$_ns/$key?value=$value'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $admin');
      final res = await req.close().timeout(const Duration(seconds: 8));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  // ---- Author's view ----

  static const _cacheFile = 'usage_devices.json';

  /// Every install that sent its phone info. Records don't change except the
  /// status, so they are cached; [onProgress] reports done / total.
  /// The service allows ~30 requests per 10 s, so requests are paced.
  static Future<List<DeviceRecord>> devices({void Function(int done, int total)? onProgress}) async {
    final total = await _get('get/$_ns/seq');
    if (total == null) throw StateError(tr('Не вдалося отримати дані. Перевірте інтернет.'));
    final raw = await JsonStore.read(_cacheFile);
    final cache = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final out = <DeviceRecord>[];
    var calls = 0;
    final window = Stopwatch()..start();
    Future<int?> get(String key) async {
      // Stay under the limit: 25 requests, then wait for the next 10 s window.
      if (calls >= 25) {
        final left = const Duration(seconds: 10) - window.elapsed;
        if (left > Duration.zero) await Future<void>.delayed(left + const Duration(milliseconds: 300));
        calls = 0;
        window.reset();
      }
      calls++;
      final v = await _get('get/$_ns/$key');
      return v is int ? v : null;
    }

    final n = total as int;
    for (int i = 1; i <= n; i++) {
      onProgress?.call(i - 1, n);
      var rec = cache['$i'];
      if (rec is! Map || rec['h'] is! int) {
        final h = await get('u${i}h');
        if (h == null || h == 0) continue; // not registered (yet)
        final parts = <int>[];
        var ok = true;
        for (int c = 0; c < DeviceCodec.chunkCount(h); c++) {
          final v = await get('u${i}c$c');
          if (v == null) {
            ok = false;
            break;
          }
          parts.add(v);
        }
        if (!ok) continue;
        rec = {'h': h, 'c': parts};
        cache['$i'] = rec;
      }
      final g = await get('u${i}g');
      final st = await get(g == null || g == 0 ? 'u${i}s' : 'u${i}s$g');
      out.add(DeviceCodec.decode(
        i,
        rec['h'] as int,
        [for (final v in rec['c'] as List) v as int],
        st,
      ));
    }
    onProgress?.call(n, n);
    await JsonStore.write(_cacheFile, cache);
    return out;
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
