import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

class UpdateInfo {
  final int build;
  final String downloadUrl;
  final String pageUrl;

  const UpdateInfo(this.build, this.downloadUrl, this.pageUrl);
}

/// Checks the latest GitHub release (tags "build-N", N = versionCode).
class Updates {
  static const _channel = MethodChannel('stl_weight/files');
  static const _repo = 'WadimAs/Calc-stl';

  static Future<int?> installedBuild() async {
    try {
      final info = await _channel.invokeMethod<Map<Object?, Object?>>('appInfo');
      final code = info?['versionCode'];
      return code is int ? code : null;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _is64() async {
    try {
      final info = await _channel.invokeMethod<Map<Object?, Object?>>('appInfo');
      return info?['is64'] != false;
    } catch (_) {
      return true;
    }
  }

  static Future<String> installedName() async {
    try {
      final info = await _channel.invokeMethod<Map<Object?, Object?>>('appInfo');
      return '${info?['versionName'] ?? ''} (${info?['versionCode'] ?? ''})';
    } catch (_) {
      return '';
    }
  }

  /// Returns a newer release, or null when up to date / offline.
  static Future<UpdateInfo?> check() async {
    final current = await installedBuild();
    if (current == null) return null;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'stl-weight-app');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = jsonDecode(await res.transform(utf8.decoder).join());
      if (body is! Map) return null;
      final tag = body['tag_name'];
      if (tag is! String) return null;
      final m = RegExp(r'(\d+)$').firstMatch(tag);
      final build = m == null ? null : int.tryParse(m.group(1)!);
      if (build == null || build <= current) return null;
      // 64-bit phones get stl-weight.apk, old 32-bit ones stl-weight-arm32.apk.
      final want = await _is64() ? 'stl-weight.apk' : 'stl-weight-arm32.apk';
      String? apk, anyApk;
      final assets = body['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map || a['name'] is! String) continue;
          final n = a['name'] as String;
          if (!n.endsWith('.apk')) continue;
          anyApk ??= a['browser_download_url'] as String?;
          if (n == want) apk = a['browser_download_url'] as String?;
        }
      }
      apk ??= anyApk;
      final page = body['html_url'] is String ? body['html_url'] as String : 'https://github.com/$_repo/releases/latest';
      return UpdateInfo(build, apk ?? page, page);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> open(String url) async {
    await _channel.invokeMethod<bool>('openUrl', {'url': url});
  }
}
