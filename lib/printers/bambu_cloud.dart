import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../data/json_store.dart';
import '../i18n/i18n.dart';

/// Bambu Lab account (the same cloud Bambu Handy uses). Unofficial API, as
/// used by Home Assistant / openHAB: login → token, MQTT at us.mqtt.bambulab.com
/// with username "u_<uid>" and the token as password.
class BambuCloudException implements Exception {
  final String message;

  const BambuCloudException(this.message);

  @override
  String toString() => message;
}

/// Stored login (no password is kept).
class BambuAccount {
  final String email;
  final String token;
  final String username; // u_123456
  final DateTime created;

  const BambuAccount({required this.email, required this.token, required this.username, required this.created});

  /// Tokens live about three months.
  bool get probablyExpired => DateTime.now().difference(created).inDays > 85;

  Map<String, dynamic> toJson() =>
      {'email': email, 'token': token, 'username': username, 'created': created.millisecondsSinceEpoch};

  static BambuAccount? fromJson(Object? raw) {
    if (raw is! Map || raw['token'] is! String || raw['username'] is! String) return null;
    return BambuAccount(
      email: raw['email'] is String ? raw['email'] as String : '',
      token: raw['token'] as String,
      username: raw['username'] as String,
      created: DateTime.fromMillisecondsSinceEpoch(raw['created'] is num ? (raw['created'] as num).toInt() : 0),
    );
  }

  static const _file = 'bambu_cloud.json';

  static Future<BambuAccount?> load() async => fromJson(await JsonStore.read(_file));

  Future<void> save() => JsonStore.write(_file, toJson());

  static Future<void> logout() => JsonStore.write(_file, <String, dynamic>{});
}

/// A printer bound to the account.
class CloudPrinter {
  final String serial;
  final String name;
  final String model;
  final bool online;
  final String accessCode;

  const CloudPrinter(this.serial, this.name, this.model, this.online, this.accessCode);
}

/// What the login needs next.
sealed class LoginStep {
  const LoginStep();
}

class LoginDone extends LoginStep {
  final BambuAccount account;

  const LoginDone(this.account);
}

/// A code was sent by e-mail.
class LoginNeedsEmailCode extends LoginStep {
  const LoginNeedsEmailCode();
}

/// Two-factor authentication app code.
class LoginNeedsTfa extends LoginStep {
  final String tfaKey;

  const LoginNeedsTfa(this.tfaKey);
}

class BambuCloud {
  static const mqttHost = 'us.mqtt.bambulab.com';
  static const _api = 'https://api.bambulab.com';

  static const _headers = {
    'User-Agent': 'bambu_network_agent/01.09.05.01',
    'X-BBL-Client-Name': 'OrcaSlicer',
    'X-BBL-Client-Type': 'slicer',
    'X-BBL-Client-Version': '01.09.05.51',
    'X-BBL-Language': 'en-US',
    'X-BBL-OS-Type': 'linux',
    'X-BBL-OS-Version': '6.2.0',
    'X-BBL-Agent-Version': '01.09.05.01',
    'X-BBL-Executable-info': '{}',
    'X-BBL-Agent-OS-Type': 'linux',
  };

  /// (status, json body or null, response cookies)
  static Future<(int, Object?, List<Cookie>)> _req(String method, String url,
      {Object? body, String? token, Map<String, String>? extra}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      _headers.forEach(req.headers.set);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      extra?.forEach(req.headers.set);
      if (token != null) req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        final b = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = b.length;
        req.add(b);
      }
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join();
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } catch (_) {
        json = null;
      }
      if (res.statusCode == 403 && json == null) {
        throw BambuCloudException(tr('Сервер Bambu відхилив запит. Спробуйте пізніше.'));
      }
      return (res.statusCode, json, res.cookies);
    } on SocketException {
      throw BambuCloudException(tr('Немає з\'єднання з інтернетом'));
    } on TimeoutException {
      throw BambuCloudException(tr('Сервер Bambu не відповідає'));
    } on HandshakeException {
      throw BambuCloudException(tr('Не вдалося встановити захищене з\'єднання'));
    } finally {
      client.close(force: true);
    }
  }

  static String _message(Object? json, int status) {
    if (json is Map) {
      for (final k in ['message', 'error', 'msg']) {
        if (json[k] is String && (json[k] as String).isNotEmpty) return json[k] as String;
      }
    }
    return trf('Помилка сервера Bambu ({0})', [status]);
  }

  /// Step 1: e-mail and password.
  static Future<LoginStep> login(String email, String password) async {
    final (st, j, _) = await _req('POST', '$_api/v1/user-service/user/login',
        body: {'account': email, 'password': password, 'apiError': ''});
    if (j is Map) {
      final token = j['accessToken'];
      if (token is String && token.isNotEmpty) return LoginDone(await _account(email, token));
      final type = j['loginType'];
      if (type == 'verifyCode') {
        await sendEmailCode(email);
        return const LoginNeedsEmailCode();
      }
      if (type == 'tfa' && j['tfaKey'] is String) return LoginNeedsTfa(j['tfaKey'] as String);
    }
    if (st == 400 || st == 401) throw BambuCloudException(tr('Неправильна пошта або пароль'));
    throw BambuCloudException(_message(j, st));
  }

  static Future<void> sendEmailCode(String email) async {
    final (st, j, _) = await _req('POST', '$_api/v1/user-service/user/sendemail/code',
        body: {'email': email, 'type': 'codeLogin'});
    if (st != 200) throw BambuCloudException(_message(j, st));
  }

  /// Step 2a: the 6-digit code from the e-mail.
  static Future<BambuAccount> loginWithCode(String email, String code) async {
    final (st, j, _) =
        await _req('POST', '$_api/v1/user-service/user/login', body: {'account': email, 'code': code.trim()});
    if (j is Map && j['accessToken'] is String && (j['accessToken'] as String).isNotEmpty) {
      return _account(email, j['accessToken'] as String);
    }
    if (st == 400 && j is Map && j['code'] == 1) {
      await sendEmailCode(email);
      throw BambuCloudException(tr('Код застарів — на пошту надіслано новий'));
    }
    if (st == 400) throw BambuCloudException(tr('Неправильний код'));
    throw BambuCloudException(_message(j, st));
  }

  /// Step 2b: two-factor code (authenticator app).
  static Future<BambuAccount> loginWithTfa(String email, String tfaKey, String code) async {
    // The site may or may not hand out a CSRF cookie; try with it, then without.
    String? csrf;
    try {
      final (_, __, cookies) = await _req('GET', 'https://bambulab.com/api/sign-in/csrf');
      final c = cookies.where((c) => c.name == 'bbl_csrf_token').map((c) => c.value);
      if (c.isNotEmpty) csrf = c.first;
    } catch (_) {}
    final (st, j, cookies2) = await _req('POST', 'https://bambulab.com/api/sign-in/tfa',
        body: {'tfaKey': tfaKey, 'tfaCode': code.trim()},
        extra: csrf == null ? null : {'x-bbl-csrf-token': csrf, 'Cookie': 'bbl_csrf_token=$csrf'});
    var token = cookies2.where((c) => c.name == 'token').map((c) => c.value);
    if (token.isEmpty && j is Map && j['accessToken'] is String) token = [j['accessToken'] as String];
    if (token.isEmpty && st != 400) throw BambuCloudException(tr('Не вдалося почати вхід із двофакторним кодом'));
    if (token.isEmpty) {
      throw BambuCloudException(st == 400 ? tr('Неправильний код') : _message(j, st));
    }
    return _account(email, token.first);
  }

  /// MQTT username from the token (JWT) or the profile.
  static Future<BambuAccount> _account(String email, String token) async {
    String? username;
    final parts = token.split('.');
    if (parts.length == 3) {
      try {
        final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
        if (payload is Map && payload['username'] is String) username = payload['username'] as String;
      } catch (_) {}
    }
    if (username == null) {
      final (st, j, _) = await _req('GET', '$_api/v1/design-user-service/my/preference', token: token);
      if (j is Map && j['uid'] != null) username = 'u_${j['uid']}';
      if (username == null) throw BambuCloudException(_message(j, st));
    }
    final acc = BambuAccount(email: email, token: token, username: username, created: DateTime.now());
    await acc.save();
    return acc;
  }

  /// Recent print jobs of a printer with the slicer's filament weights.
  static Future<List<CloudTask>> tasks(BambuAccount acc, String serial, {int limit = 10}) async {
    final (st, j, _) =
        await _req('GET', '$_api/v1/user-service/my/tasks?deviceId=$serial&limit=$limit', token: acc.token);
    if (j is! Map || j['hits'] is! List) throw BambuCloudException(_message(j, st));
    return (j['hits'] as List).map(CloudTask.fromJson).whereType<CloudTask>().toList();
  }

  /// Printers bound to the account.
  static Future<List<CloudPrinter>> printers(BambuAccount acc) async {
    final (st, j, _) = await _req('GET', '$_api/v1/iot-service/api/user/bind', token: acc.token);
    if (st == 401 || st == 403) throw BambuCloudException(tr('Вхід в акаунт Bambu застарів — увійдіть знову'));
    if (j is! Map || j['devices'] is! List) throw BambuCloudException(_message(j, st));
    return [
      for (final d in j['devices'] as List)
        if (d is Map && d['dev_id'] is String)
          CloudPrinter(
            d['dev_id'] as String,
            d['name'] is String ? d['name'] as String : d['dev_id'] as String,
            '${d['dev_product_name'] ?? d['dev_model_name'] ?? ''}',
            d['online'] == true,
            d['dev_access_code'] is String ? d['dev_access_code'] as String : '',
          ),
    ];
  }
}

/// One print job from the Bambu cloud.
class CloudTask {
  final String id;
  final String title;
  final double weight; // grams, whole job
  final DateTime? start, end;
  final int status;

  /// Per filament: AMS tray index (ams*4+tray, 254 = external) → grams.
  final Map<int, double> perTray;

  const CloudTask(this.id, this.title, this.weight, this.start, this.end, this.status, this.perTray);

  static CloudTask? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] == null) return null;
    double d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) ?? 0 : 0);
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v) : null;
    final per = <int, double>{};
    final m = raw['amsDetailMapping'];
    if (m is List) {
      for (final e in m) {
        if (e is Map && e['ams'] is num) {
          final k = (e['ams'] as num).toInt();
          per[k] = (per[k] ?? 0) + d(e['weight']);
        }
      }
    }
    return CloudTask(
      '${raw['id']}',
      '${raw['title'] ?? raw['designTitle'] ?? ''}',
      d(raw['weight']),
      t(raw['startTime']),
      t(raw['endTime']),
      raw['status'] is num ? (raw['status'] as num).toInt() : 0,
      per,
    );
  }
}
