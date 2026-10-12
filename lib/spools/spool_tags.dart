import 'dart:convert';
import 'dart:typed_data';

import '../mesh/slicer_project.dart';
import '../platform/nfc.dart';
import 'label_parser.dart';
import 'spools.dart';

/// What a spool NFC tag says, in the same shape as a recognised label.
class SpoolTagInfo {
  final String format; // "Bambu Lab", "OpenSpool", "OpenPrintTag"
  final SpoolLabel label;
  final double? diameter;
  final int? minTemp, maxTemp;

  /// Grams already used (OpenPrintTag keeps it on the tag).
  final double? consumed;

  /// Spool id written by this app (OpenSpool extension).
  final String? spoolId;

  const SpoolTagInfo(this.format, this.label,
      {this.diameter, this.minTemp, this.maxTemp, this.consumed, this.spoolId});
}

const openSpoolMime = 'application/json';
const openPrintTagMime = 'application/vnd.openprinttag';

/// Reads any supported spool format from [tag]; null when the tag has none.
SpoolTagInfo? parseSpoolTag(NfcTag tag) {
  for (final r in tag.records) {
    final type = r.type.toLowerCase();
    if (type == openPrintTagMime) {
      final i = parseOpenPrintTag(r.payload);
      if (i != null) return i;
    }
    if (type == openSpoolMime || type.endsWith('+json') || type == 'text/plain') {
      final i = parseOpenSpool(r.payload);
      if (i != null) return i;
    }
  }
  final blocks = tag.mifareBlocks;
  if (blocks != null && blocks.length >= 17) return parseBambuBlocks(blocks);
  return null;
}

// ---------------------------------------------------------------- Bambu Lab

String _ascii(Uint8List? b, [int from = 0, int to = 16]) {
  if (b == null) return '';
  final s = String.fromCharCodes(b.sublist(from, to.clamp(from, b.length)).where((c) => c >= 32 && c < 127));
  return s.trim();
}

int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);

double _f32(Uint8List b, int o) => ByteData.sublistView(b, o, o + 4).getFloat32(0, Endian.little);

/// Bambu Lab tag blocks (layout by the Bambu Research Group RFID guide).
SpoolTagInfo? parseBambuBlocks(List<Uint8List?> blocks) {
  Uint8List? blk(int i) => i < blocks.length ? blocks[i] : null;
  final type = _ascii(blk(2));
  final detailed = _ascii(blk(4));
  final b5 = blk(5);
  if (type.isEmpty && detailed.isEmpty) return null;
  int? color;
  double? weight, diameter;
  if (b5 != null && b5.length >= 12) {
    final a = b5[3] == 0 ? 0xFF : b5[3];
    color = (a << 24) | (b5[0] << 16) | (b5[1] << 8) | b5[2];
    color = color | 0xFF000000; // the app shows spools opaque
    final w = _u16(b5, 4);
    if (w > 0 && w < 10000) weight = w.toDouble();
    final d = _f32(b5, 8);
    if (d > 1 && d < 4) diameter = (d * 100).roundToDouble() / 100;
  }
  int? minT, maxT;
  final b6 = blk(6);
  if (b6 != null && b6.length >= 12) {
    maxT = _u16(b6, 8);
    minT = _u16(b6, 10);
    if (maxT == 0) maxT = null;
    if (minT == 0) minT = null;
  }
  final extra = <int>[];
  final b16 = blk(16);
  if (b16 != null && b16.length >= 8 && _u16(b16, 0) == 2 && _u16(b16, 2) >= 2) {
    // Second colour, stored ABGR.
    extra.add(0xFF000000 | (b16[7] << 16) | (b16[6] << 8) | b16[5]);
  }
  final text = detailed.isNotEmpty ? detailed : type;
  String? materialId = materialIdForType(text);
  if (materialId == 'custom') materialId = materialIdForType(type);
  return SpoolTagInfo(
    'Bambu Lab',
    SpoolLabel(
      brand: 'Bambu Lab',
      materialId: materialId,
      materialText: text,
      colorName: color == null ? null : _colorTitle(text, color, extra),
      colorArgb: color,
      extraColors: extra,
      weightGrams: weight,
    ),
    diameter: diameter,
    minTemp: minT,
    maxTemp: maxT,
  );
}

/// "PLA Silk White / Blue" style name from the type and colours.
String _colorTitle(String type, int color, List<int> extra) {
  final names = [nearestColorName(color), for (final c in extra) nearestColorName(c)];
  final sub = type.split(RegExp(r'\s+')).skip(1).where((w) => w.toLowerCase() != 'basic').join(' ');
  return [if (sub.isNotEmpty) sub, names.join(' / ')].join(' ');
}

// ----------------------------------------------------------------- OpenSpool

int? _hexColor(Object? v) {
  if (v is! String) return null;
  final h = v.replaceAll('#', '').trim();
  if (h.length != 6 && h.length != 8) return null;
  final n = int.tryParse(h.substring(0, 6), radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

int? _int(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v.trim()) : null);
double? _num(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v.trim()) : null);

/// OpenSpool JSON ({"protocol":"openspool","type":"PLA","color_hex":"FFAABB",…}).
SpoolTagInfo? parseOpenSpool(Uint8List payload) {
  Object? j;
  try {
    j = jsonDecode(utf8.decode(payload, allowMalformed: true));
  } catch (_) {
    return null;
  }
  if (j is! Map || '${j['protocol']}'.toLowerCase() != 'openspool') return null;
  final type = '${j['type'] ?? ''}'.trim();
  final sub = '${j['subtype'] ?? ''}'.trim();
  final text = [type, if (sub.isNotEmpty && sub.toLowerCase() != 'basic') sub].join(' ');
  final color = _hexColor(j['color_hex']);
  final extra = <int>[
    for (final c in (j['additional_color_hexes'] is List ? j['additional_color_hexes'] as List : const []))
      if (_hexColor(c) != null) _hexColor(c)!,
  ];
  String? materialId = materialIdForType(text);
  if (materialId == 'custom') materialId = materialIdForType(type);
  final name = '${j['name'] ?? ''}'.trim();
  final brand = '${j['brand'] ?? ''}'.trim();
  return SpoolTagInfo(
    'OpenSpool',
    SpoolLabel(
      brand: brand.isEmpty || brand.toLowerCase() == 'generic' ? null : brand,
      materialId: materialId,
      materialText: text.isEmpty ? null : text,
      colorName: name.isNotEmpty ? name : (color == null ? null : nearestColorName(color)),
      colorArgb: color,
      extraColors: extra,
      weightGrams: _num(j['weight']),
    ),
    diameter: _num(j['diameter']),
    minTemp: _int(j['min_temp']),
    maxTemp: _int(j['max_temp']),
    consumed: _num(j['consumed']),
    spoolId: j['spool_id'] is String ? j['spool_id'] as String : null,
  );
}

String _hex(int argb) => (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// OpenSpool record for [s] (with this app's extras: weight, colours, id).
Uint8List openSpoolPayload(Spool s, {String? typeName}) {
  final m = typeName ?? s.materialId;
  final base = m.split('-').first;
  final sub = m.contains('-') ? m.split('-').skip(1).join(' ') : '';
  return Uint8List.fromList(utf8.encode(jsonEncode({
    'protocol': 'openspool',
    'version': '1.0',
    'type': base,
    if (sub.isNotEmpty) 'subtype': sub[0] + sub.substring(1).toLowerCase(),
    'color_hex': _hex(s.colorArgb),
    if (s.extraColors.isNotEmpty) 'additional_color_hexes': [for (final c in s.extraColors) _hex(c)],
    'brand': s.brand.isEmpty ? 'Generic' : s.brand,
    if (s.name.isNotEmpty) 'name': s.name,
    'weight': s.totalGrams.round(),
    'diameter': 1.75,
    'spool_id': s.id,
  })));
}

// -------------------------------------------------------------- OpenPrintTag

const _optTypes = {
  0: 'PLA', 1: 'PETG', 2: 'TPU', 3: 'ABS', 4: 'ASA', 5: 'PC', 6: 'PCTG', 7: 'PP', 8: 'PA6', 9: 'PA11',
  10: 'PA12', 11: 'PA66', 12: 'CPE', 13: 'TPE', 14: 'HIPS', 15: 'PHA', 16: 'PET', 17: 'PEI', 18: 'PBT',
  19: 'PVB', 20: 'PVA', 21: 'PEKK', 22: 'PEEK', 23: 'BVOH', 24: 'TPC', 25: 'PPS', 26: 'PPSU', 27: 'PVC',
  28: 'PEBA', 29: 'PVDF', 30: 'PPA', 31: 'PCL', 32: 'PES', 33: 'PMMA', 34: 'POM', 35: 'PPE', 36: 'PS',
  37: 'PSU', 38: 'TPI', 39: 'SBS', 40: 'OBC', 41: 'EVA', 42: 'PA612',
};

int? _rgba(Object? v) {
  if (v is! Uint8List || v.length < 3) return null;
  return 0xFF000000 | (v[0] << 16) | (v[1] << 8) | v[2];
}

/// OpenPrintTag (Prusa) NDEF payload: CBOR meta, main and auxiliary sections.
SpoolTagInfo? parseOpenPrintTag(Uint8List p) {
  try {
    final metaR = Cbor.decode(p, 0);
    final meta = metaR.$1 is Map ? metaR.$1 as Map : const {};
    final mainOff = _int(meta[0]) ?? metaR.$2;
    final main = Cbor.decode(p, mainOff).$1;
    if (main is! Map) return null;
    Map aux = const {};
    final auxOff = _int(meta[2]);
    if (auxOff != null && auxOff < p.length) {
      final a = Cbor.decode(p, auxOff).$1;
      if (a is Map) aux = a;
    }
    final abbr = main[52] is String ? main[52] as String : _optTypes[_int(main[9])];
    final name = main[10] is String ? (main[10] as String).trim() : '';
    final brand = main[11] is String ? (main[11] as String).trim() : null;
    final text = [abbr, if (name.toLowerCase().contains('silk')) 'Silk'].whereType<String>().join(' ');
    final color = _rgba(main[19]);
    final extra = <int>[
      for (int k = 20; k <= 24; k++)
        if (_rgba(main[k]) != null) _rgba(main[k])!,
    ];
    final weight = _num(main[17]) ?? _num(main[16]);
    double? diameter = _num(main[30]);
    if (diameter == null && _num(main[61]) != null) diameter = _num(main[61])! / 1000;
    String? materialId = materialIdForType(text);
    if (materialId == 'custom' && abbr != null) materialId = materialIdForType(abbr);
    return SpoolTagInfo(
      'OpenPrintTag',
      SpoolLabel(
        brand: brand,
        materialId: materialId,
        materialText: abbr,
        colorName: name.isNotEmpty ? name : (color == null ? null : nearestColorName(color)),
        colorArgb: color,
        extraColors: extra,
        weightGrams: weight,
      ),
      diameter: diameter,
      minTemp: _int(main[34]),
      maxTemp: _int(main[35]),
      consumed: _num(aux[0]),
    );
  } catch (_) {
    return null;
  }
}

/// Minimal CBOR (RFC 8949) decoder: ints, strings, bytes, arrays, maps,
/// tags (skipped), floats, true/false/null; definite and indefinite lengths.
class Cbor {
  static (Object?, int) decode(Uint8List b, int o) {
    final ib = b[o];
    final major = ib >> 5, ai = ib & 31;
    o++;
    int arg = 0;
    if (ai < 24) {
      arg = ai;
    } else if (ai >= 24 && ai <= 27) {
      final n = 1 << (ai - 24);
      if (major == 7) {
        final bd = ByteData.sublistView(b, o, o + n);
        final v = n == 2 ? _half(bd.getUint16(0)) : (n == 4 ? bd.getFloat32(0) : (n == 8 ? bd.getFloat64(0) : b[o].toDouble()));
        return (n == 1 ? b[o] : v, o + n);
      }
      for (int i = 0; i < n; i++) {
        arg = (arg << 8) | b[o + i];
      }
      o += n;
    } else if (ai != 31) {
      throw const FormatException('cbor');
    }
    final indefinite = ai == 31;
    switch (major) {
      case 0:
        return (arg, o);
      case 1:
        return (-1 - arg, o);
      case 2:
      case 3:
        if (indefinite) {
          final out = BytesBuilder();
          while (b[o] != 0xFF) {
            final (part, no) = decode(b, o);
            out.add(part is String ? utf8.encode(part) : part as Uint8List);
            o = no;
          }
          final bytes = out.toBytes();
          return (major == 3 ? utf8.decode(bytes, allowMalformed: true) : bytes, o + 1);
        }
        final bytes = Uint8List.sublistView(b, o, o + arg);
        return (major == 3 ? utf8.decode(bytes, allowMalformed: true) : Uint8List.fromList(bytes), o + arg);
      case 4:
        final list = <Object?>[];
        if (indefinite) {
          while (b[o] != 0xFF) {
            final (v, no) = decode(b, o);
            list.add(v);
            o = no;
          }
          return (list, o + 1);
        }
        for (int i = 0; i < arg; i++) {
          final (v, no) = decode(b, o);
          list.add(v);
          o = no;
        }
        return (list, o);
      case 5:
        final map = <Object?, Object?>{};
        int i = 0;
        while (indefinite ? b[o] != 0xFF : i < arg) {
          final (k, o1) = decode(b, o);
          final (v, o2) = decode(b, o1);
          map[k] = v;
          o = o2;
          i++;
        }
        return (map, indefinite ? o + 1 : o);
      case 6:
        return decode(b, o); // tag: value only
      default:
        return (switch (arg) { 20 => false, 21 => true, _ => null }, o);
    }
  }

  static double _half(int h) {
    final s = (h >> 15) != 0 ? -1.0 : 1.0;
    final e = (h >> 10) & 0x1F, f = h & 0x3FF;
    if (e == 0) return s * f * 5.960464477539063e-8;
    if (e == 31) return f == 0 ? s * double.infinity : double.nan;
    return s * (1 + f / 1024) * (1 << e) / 32768;
  }
}
