import 'dart:convert';
import 'dart:typed_data';

import 'mesh.dart';
import '../i18n/i18n.dart';

/// Parses binary or ASCII STL. Units are assumed to be millimetres.
Mesh parseStl(Uint8List bytes) {
  if (bytes.length >= 84) {
    final bd = ByteData.sublistView(bytes);
    final n = bd.getUint32(80, Endian.little);
    if (84 + n * 50 == bytes.length) return _parseBinary(bd, n);
  }
  if (_looksAscii(bytes)) {
    final m = _parseAscii(bytes);
    if (m.triangleCount > 0) return m;
  }
  if (bytes.length >= 134) {
    // Binary file with a wrong triangle count or trailing bytes.
    final bd = ByteData.sublistView(bytes);
    final declared = bd.getUint32(80, Endian.little);
    final fit = (bytes.length - 84) ~/ 50;
    final n = declared > 0 && declared < fit ? declared : fit;
    return _parseBinary(bd, n);
  }
  throw FormatException(tr('Не вдалося розпізнати STL-файл'));
}

bool _looksAscii(Uint8List bytes) {
  int i = 0;
  while (i < bytes.length && (bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D)) {
    i++;
  }
  if (i + 5 > bytes.length) return false;
  final head = latin1.decode(Uint8List.sublistView(bytes, i, i + 5)).toLowerCase();
  if (head != 'solid') return false;
  final end = bytes.length < i + 2000 ? bytes.length : i + 2000;
  final probe = latin1.decode(Uint8List.sublistView(bytes, i, end)).toLowerCase();
  return probe.contains('facet') || probe.contains('endsolid');
}

Mesh _parseBinary(ByteData bd, int n) {
  final out = Float32List(n * 9);
  int o = 84;
  int k = 0;
  for (int t = 0; t < n; t++) {
    o += 12; // skip normal
    for (int v = 0; v < 9; v++) {
      out[k++] = bd.getFloat32(o, Endian.little);
      o += 4;
    }
    o += 2; // attribute byte count
  }
  return Mesh(out);
}

Mesh _parseAscii(Uint8List bytes) {
  final text = latin1.decode(bytes);
  final re = RegExp(r'vertex\s+(\S+)\s+(\S+)\s+(\S+)', caseSensitive: false);
  final buf = FloatBuf(1 << 16);
  for (final m in re.allMatches(text)) {
    buf.add(double.tryParse(m.group(1)!) ?? 0);
    buf.add(double.tryParse(m.group(2)!) ?? 0);
    buf.add(double.tryParse(m.group(3)!) ?? 0);
  }
  final all = buf.toList();
  final usable = all.length - all.length % 9;
  return Mesh(usable == all.length ? all : Float32List.fromList(Float32List.sublistView(all, 0, usable)));
}
