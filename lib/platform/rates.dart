import 'dart:convert';
import 'dart:io';

/// Official hryvnia rate from the National Bank of Ukraine:
/// hryvnias per one unit of [code] ('EUR', 'USD'), or null when offline.
Future<double?> nbuRate(String code) async {
  if (code == 'UAH') return 1;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    final req = await client.getUrl(
        Uri.parse('https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?valcode=$code&json'));
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(await res.transform(utf8.decoder).join());
    if (j is List && j.isNotEmpty && j.first is Map) {
      final r = (j.first as Map)['rate'];
      if (r is num && r > 0) return r.toDouble();
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
