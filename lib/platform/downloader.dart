import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../mesh/loader.dart';
import '../mesh/zip_reader.dart';
import 'files.dart';

class DownloadException implements Exception {
  final String message;

  const DownloadException(this.message);

  @override
  String toString() => message;
}

/// Sites that need a browser login / JavaScript to download.
const _browserOnly = {
  'makerworld.com': 'MakerWorld',
  'printables.com': 'Printables',
  'cults3d.com': 'Cults3D',
  'myminifactory.com': 'MyMiniFactory',
  'thangs.com': 'Thangs',
};

/// Turns a model page link into a direct download link when the site allows it.
Uri resolveModelUrl(String text) {
  final m = RegExp(r'https?://\S+').firstMatch(text.trim());
  if (m == null) throw const DownloadException('Це не схоже на посилання');
  var url = Uri.parse(m.group(0)!);
  final host = url.host.toLowerCase().replaceFirst('www.', '');
  for (final e in _browserOnly.entries) {
    if (host == e.key || host.endsWith('.${e.key}')) {
      throw DownloadException('${e.value} не дає завантажувати файли без входу в акаунт. '
          'Завантажте модель у браузері й відкрийте файл через «Поділитися» → STL Вага.');
    }
  }
  if (host == 'thingiverse.com') {
    final id = RegExp(r'thing:(\d+)').firstMatch(url.toString())?.group(1);
    if (id != null) url = Uri.parse('https://www.thingiverse.com/thing:$id/zip');
  }
  if (host == 'github.com' && url.pathSegments.contains('blob')) {
    // github.com/u/r/blob/main/x.stl → raw file
    url = url.replace(queryParameters: {'raw': 'true'});
  }
  return url;
}

String _nameFrom(HttpClientResponse res, Uri url) {
  final cd = res.headers.value('content-disposition');
  if (cd != null) {
    final star = RegExp(r"filename\*=(?:UTF-8'')?([^;]+)", caseSensitive: false).firstMatch(cd);
    if (star != null) return Uri.decodeComponent(star.group(1)!.replaceAll('"', '').trim());
    final plain = RegExp(r'filename="?([^";]+)"?', caseSensitive: false).firstMatch(cd);
    if (plain != null) return plain.group(1)!.trim();
  }
  final seg = url.pathSegments.where((s) => s.isNotEmpty);
  return seg.isEmpty ? 'model' : Uri.decodeComponent(seg.last);
}

/// Downloads [url] (max [maxBytes]); [onProgress] gets 0..1 when the size is known.
Future<PickedFile> download(Uri url, {int maxBytes = 200 << 20, void Function(double?)? onProgress}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'Mozilla/5.0 (Android) STL-Vaga';
  try {
    final req = await client.getUrl(url);
    req.followRedirects = true;
    req.maxRedirects = 8;
    final res = await req.close().timeout(const Duration(seconds: 30));
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const DownloadException('Сайт не дозволяє завантаження без входу. '
          'Завантажте файл у браузері й поділіться ним із застосунком.');
    }
    if (res.statusCode != 200) throw DownloadException('Сайт відповів помилкою ${res.statusCode}');
    final type = res.headers.contentType?.mimeType ?? '';
    final finalUrl = res.redirects.isEmpty ? url : res.redirects.last.location;
    var name = _nameFrom(res, finalUrl.hasScheme ? finalUrl : url);
    final total = res.contentLength;
    if (total > maxBytes) throw const DownloadException('Файл завеликий');
    final b = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(const Duration(seconds: 60))) {
      b.add(chunk);
      if (b.length > maxBytes) throw const DownloadException('Файл завеликий');
      onProgress?.call(total > 0 ? b.length / total : null);
    }
    final bytes = b.takeBytes();
    if (type == 'text/html' && !isSupportedFile(name)) {
      throw const DownloadException('За посиланням сторінка, а не файл моделі. '
          'Потрібне пряме посилання на .stl / .3mf або сторінка Thingiverse.');
    }
    if (!isSupportedFile(name) && !name.toLowerCase().endsWith('.zip')) {
      // Guess from content.
      if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
        name = '$name.zip';
      } else {
        name = '$name.stl';
      }
    }
    return PickedFile(name, bytes);
  } on DownloadException {
    rethrow;
  } on TimeoutException {
    throw const DownloadException('Немає відповіді від сайту');
  } on SocketException {
    throw const DownloadException('Немає з\'єднання з інтернетом');
  } on HandshakeException {
    throw const DownloadException('Не вдалося встановити захищене з\'єднання');
  } finally {
    client.close(force: true);
  }
}

/// True for a plain archive (not a 3MF package).
bool isArchive(PickedFile f) {
  final n = f.name.toLowerCase();
  if (n.endsWith('.3mf')) return false;
  if (n.endsWith('.zip')) return true;
  return false;
}

/// Model files inside a .zip (largest first).
List<PickedFile> modelsInZip(Uint8List bytes) {
  final zip = ZipReader(bytes);
  final out = <PickedFile>[];
  for (final n in zip.names) {
    if (n.endsWith('/') || n.contains('__MACOSX')) continue;
    if (!isSupportedFile(n)) continue;
    try {
      final data = zip.read(n);
      out.add(PickedFile(n.split('/').last, data));
    } catch (_) {}
  }
  out.sort((a, b) => b.bytes.length.compareTo(a.bytes.length));
  return out;
}
