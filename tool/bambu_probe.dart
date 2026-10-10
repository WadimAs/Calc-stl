// Checks that the Bambu cloud login API answers a plain Dart HttpClient
// (no Cloudflare block). Uses a non-existent account on purpose.
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final client = HttpClient();
  for (final (method, url, body) in [
    ('POST', 'https://api.bambulab.com/v1/user-service/user/login',
        {'account': 'stl-vaga-probe@example.com', 'password': 'wrong-password', 'apiError': ''}),
    ('GET', 'https://bambulab.com/api/sign-in/csrf', null),
  ]) {
    try {
      final req = await client.openUrl(method, Uri.parse(url));
      req.headers.set('User-Agent', 'bambu_network_agent/01.09.05.01');
      req.headers.set('X-BBL-Client-Name', 'OrcaSlicer');
      req.headers.set('X-BBL-Client-Type', 'slicer');
      if (body != null) {
        final b = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = b.length;
        req.add(b);
      }
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      print('PROBE $method $url -> ${res.statusCode} cookies=${res.cookies.map((c) => c.name).toList()}');
      print('PROBE body: ${text.length > 300 ? text.substring(0, 300) : text}');
    } catch (e) {
      print('PROBE $url failed: $e');
    }
  }
  client.close(force: true);
}
