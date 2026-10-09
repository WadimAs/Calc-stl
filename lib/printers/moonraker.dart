import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'printers.dart';
import '../i18n/i18n.dart';

class MoonrakerException implements Exception {
  final String message;

  const MoonrakerException(this.message);

  @override
  String toString() => message;
}

/// Klipper printers through the Moonraker HTTP API (Mainsail / Fluidd).
class MoonrakerClient {
  final PrinterConn printer;

  MoonrakerClient(this.printer);

  Uri _uri(String path) {
    final h = printer.host.trim().replaceFirst(RegExp(r'^https?://'), '').replaceAll(RegExp(r'/+$'), '');
    final hasPort = RegExp(r':\d+$').hasMatch(h);
    return Uri.parse('http://${hasPort ? h : '$h:${printer.port}'}$path');
  }

  Future<Object?> _request(String method, String path, {List<int>? body, String? contentType}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client.openUrl(method, _uri(path));
      if (printer.apiKey.isNotEmpty) req.headers.set('X-Api-Key', printer.apiKey);
      if (contentType != null) req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      final res = await req.close().timeout(const Duration(seconds: 60));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw MoonrakerException(tr('Moonraker просить API-ключ або доступ заборонено'));
      }
      if (res.statusCode != 200 && res.statusCode != 201) {
        throw MoonrakerException(trf('Moonraker відповів {0}', [res.statusCode]));
      }
      final j = jsonDecode(text);
      return j is Map ? j['result'] : null;
    } on SocketException catch (e) {
      throw MoonrakerException(trf('Немає з\'єднання з {0}: {1}', [printer.host, e.osError?.message ?? e.message]));
    } on TimeoutException {
      throw MoonrakerException(tr('Принтер не відповідає'));
    } on FormatException {
      throw MoonrakerException(tr('Це не схоже на Moonraker'));
    } finally {
      client.close(force: true);
    }
  }

  Future<PrinterStatus> status() async {
    final r = await _request('GET', '/printer/objects/query?print_stats&virtual_sdcard&display_status&extruder&heater_bed');
    final st = r is Map && r['status'] is Map ? Map<String, dynamic>.from(r['status'] as Map) : <String, dynamic>{};
    return moonrakerStatus(st);
  }

  Future<List<PrintJob>> history({int limit = 20}) async {
    final r = await _request('GET', '/server/history/list?limit=$limit&order=desc');
    final jobs = r is Map && r['jobs'] is List ? r['jobs'] as List : const [];
    return jobs.map(PrintJob.fromJson).whereType<PrintJob>().toList();
  }

  /// Uploads G-code to the printer; optionally starts printing it.
  Future<void> upload(String name, Uint8List bytes, {bool start = false}) async {
    final boundary = 'stlvaga${DateTime.now().microsecondsSinceEpoch}';
    final safe = name.replaceAll(RegExp(r'[\\/"\r\n]'), '_');
    final b = BytesBuilder(copy: false)
      ..add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="file"; filename="$safe"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n'))
      ..add(bytes)
      ..add(utf8.encode('\r\n'));
    if (start) {
      b.add(utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="print"\r\n\r\ntrue\r\n'));
    }
    b.add(utf8.encode('--$boundary--\r\n'));
    await _request('POST', '/server/files/upload',
        body: b.takeBytes(), contentType: 'multipart/form-data; boundary=$boundary');
  }
}
