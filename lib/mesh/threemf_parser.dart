import 'dart:convert';
import 'dart:typed_data';

import 'mesh.dart';
import 'zip_reader.dart';

/// 3MF affine transform in the spec's row-vector form:
/// x' = x*m00 + y*m10 + z*m20 + m30 (stored row-major as 12 values).
typedef Transform3 = List<double>;

const Transform3 _identity = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0];

Transform3 _parseTransform(String? s) {
  if (s == null) return _identity;
  final parts = s.trim().split(RegExp(r'\s+'));
  if (parts.length != 12) return _identity;
  final out = <double>[];
  for (final p in parts) {
    final v = double.tryParse(p);
    if (v == null) return _identity;
    out.add(v);
  }
  return out;
}

/// Combined transform that applies [a] first, then [b].
Transform3 _compose(Transform3 a, Transform3 b) {
  final out = List<double>.filled(12, 0);
  for (int r = 0; r < 4; r++) {
    for (int c = 0; c < 3; c++) {
      double v = 0;
      for (int k = 0; k < 3; k++) {
        v += a[r * 3 + k] * b[k * 3 + c];
      }
      if (r == 3) v += b[9 + c];
      out[r * 3 + c] = v;
    }
  }
  return out;
}

class _Ref {
  final String? path;
  final String id;
  final Transform3 t;

  _Ref(this.path, this.id, this.t);
}

class _Obj {
  String? name;
  Float32List? verts;
  Int32List? idx;
  final List<_Ref> comps = [];
}

class _ModelFile {
  final Map<String, _Obj> objects = {};
  final List<_Ref> build = [];
  final List<String> objectOrder = [];
  double unitScale = 1.0;
}

double _unitScale(String? unit) {
  switch ((unit ?? 'millimeter').toLowerCase()) {
    case 'micron':
      return 0.001;
    case 'centimeter':
      return 10.0;
    case 'inch':
      return 25.4;
    case 'foot':
      return 304.8;
    case 'meter':
      return 1000.0;
    default:
      return 1.0;
  }
}

String _local(String name) {
  final c = name.indexOf(':');
  return (c >= 0 ? name.substring(c + 1) : name).toLowerCase();
}

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// Finds the '>' closing the tag opened at [start], honouring quoted values.
int _tagEnd(String s, int start) {
  int quote = 0;
  for (int i = start; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (quote != 0) {
      if (c == quote) quote = 0;
    } else if (c == 0x22 || c == 0x27) {
      quote = c;
    } else if (c == 0x3E) {
      return i;
    }
  }
  return -1;
}

/// Parses attributes in s[from, to) into a map keyed by lower-case local name.
Map<String, String> _attrs(String s, int from, int to) {
  final out = <String, String>{};
  int i = from;
  while (i < to) {
    while (i < to && (_isSpace(s.codeUnitAt(i)) || s.codeUnitAt(i) == 0x2F)) {
      i++;
    }
    if (i >= to) break;
    final ns = i;
    while (i < to && s.codeUnitAt(i) != 0x3D && !_isSpace(s.codeUnitAt(i))) {
      i++;
    }
    if (i == ns) {
      i++;
      continue;
    }
    final name = s.substring(ns, i);
    while (i < to && _isSpace(s.codeUnitAt(i))) {
      i++;
    }
    if (i >= to || s.codeUnitAt(i) != 0x3D) {
      continue;
    }
    i++; // '='
    while (i < to && _isSpace(s.codeUnitAt(i))) {
      i++;
    }
    if (i >= to) break;
    final q = s.codeUnitAt(i);
    if (q != 0x22 && q != 0x27) {
      final vs = i;
      while (i < to && !_isSpace(s.codeUnitAt(i))) {
        i++;
      }
      out[_local(name)] = s.substring(vs, i);
      continue;
    }
    final vs = i + 1;
    int ve = s.indexOf(String.fromCharCode(q), vs);
    if (ve < 0 || ve > to) ve = to;
    out[_local(name)] = s.substring(vs, ve);
    i = ve + 1;
  }
  return out;
}

_ModelFile _parseModel(String s) {
  final model = _ModelFile();
  _Obj? cur;
  String? curId;
  FloatBuf? verts;
  IntBuf? idx;
  bool inBuild = false;

  int i = 0;
  final n = s.length;
  while (i < n) {
    final lt = s.indexOf('<', i);
    if (lt < 0 || lt + 1 >= n) break;
    if (s.startsWith('<!--', lt)) {
      final e = s.indexOf('-->', lt + 4);
      i = e < 0 ? n : e + 3;
      continue;
    }
    final c1 = s.codeUnitAt(lt + 1);
    if (c1 == 0x3F || c1 == 0x21) {
      // <?...?> or <!...>
      final e = s.indexOf('>', lt);
      i = e < 0 ? n : e + 1;
      continue;
    }
    final gt = _tagEnd(s, lt + 1);
    if (gt < 0) break;
    final closing = c1 == 0x2F;
    final selfClosing = s.codeUnitAt(gt - 1) == 0x2F;
    final nameStart = lt + (closing ? 2 : 1);
    int j = nameStart;
    while (j < gt && !_isSpace(s.codeUnitAt(j)) && s.codeUnitAt(j) != 0x2F) {
      j++;
    }
    final name = _local(s.substring(nameStart, j));
    i = gt + 1;

    if (closing) {
      if (name == 'object' && cur != null && curId != null) {
        if (verts != null && idx != null && idx.length > 0) {
          cur.verts = verts.toList();
          cur.idx = idx.toList();
        }
        model.objects[curId] = cur;
        model.objectOrder.add(curId);
        cur = null;
        curId = null;
        verts = null;
        idx = null;
      } else if (name == 'build') {
        inBuild = false;
      }
      continue;
    }

    switch (name) {
      case 'vertex':
        if (verts != null) {
          final a = _attrs(s, j, gt);
          verts.add(double.tryParse(a['x'] ?? '') ?? 0);
          verts.add(double.tryParse(a['y'] ?? '') ?? 0);
          verts.add(double.tryParse(a['z'] ?? '') ?? 0);
        }
        break;
      case 'triangle':
        if (idx != null) {
          final a = _attrs(s, j, gt);
          final v1 = int.tryParse(a['v1'] ?? '');
          final v2 = int.tryParse(a['v2'] ?? '');
          final v3 = int.tryParse(a['v3'] ?? '');
          if (v1 != null && v2 != null && v3 != null) {
            idx.add(v1);
            idx.add(v2);
            idx.add(v3);
          }
        }
        break;
      case 'model':
        model.unitScale = _unitScale(_attrs(s, j, gt)['unit']);
        break;
      case 'object':
        {
        final a = _attrs(s, j, gt);
        final type = (a['type'] ?? 'model').toLowerCase();
        if (type == 'other') {
          cur = null;
          curId = null;
        } else {
          cur = _Obj()..name = a['name'];
          curId = a['id'];
        }
        verts = null;
        idx = null;
        if (selfClosing && cur != null && curId != null) {
          model.objects[curId] = cur;
          cur = null;
          curId = null;
        }
        }
        break;
      case 'vertices':
        if (cur != null) verts = FloatBuf(1 << 12);
        break;
      case 'triangles':
        if (cur != null) idx = IntBuf(1 << 12);
        break;
      case 'component':
        if (cur != null) {
          final a = _attrs(s, j, gt);
          final id = a['objectid'];
          if (id != null) cur.comps.add(_Ref(a['path'], id, _parseTransform(a['transform'])));
        }
        break;
      case 'build':
        inBuild = !selfClosing;
        break;
      case 'item':
        if (inBuild) {
          final a = _attrs(s, j, gt);
          final id = a['objectid'];
          final printable = (a['printable'] ?? '1').toLowerCase();
          if (id != null && printable != '0' && printable != 'false') {
            model.build.add(_Ref(a['path'], id, _parseTransform(a['transform'])));
          }
        }
        break;
    }
  }
  return model;
}

String _norm(String p) {
  var s = p.replaceAll('\\', '/');
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  return s.toLowerCase();
}

/// Parses a 3MF package (all printable build items merged into one mesh).
Mesh parse3mf(Uint8List bytes) {
  final zip = ZipReader(bytes);
  final byLower = <String, String>{for (final n in zip.names) _norm(n): n};

  String? root;
  final relsName = byLower['_rels/.rels'];
  if (relsName != null) {
    final rels = utf8.decode(zip.read(relsName), allowMalformed: true);
    final re = RegExp(r'<\s*(?:\w+:)?Relationship\b[^>]*>', caseSensitive: false);
    for (final m in re.allMatches(rels)) {
      final tag = m.group(0)!;
      final a = _attrs(tag, 1, tag.length - 1);
      final type = a['type'] ?? '';
      final target = a['target'];
      if (target != null && type.toLowerCase().endsWith('/3dmodel')) {
        final key = _norm(target);
        if (byLower.containsKey(key)) {
          root = key;
          break;
        }
      }
    }
  }
  root ??= byLower.containsKey('3d/3dmodel.model') ? '3d/3dmodel.model' : null;
  final String rootKey = root ?? byLower.keys.firstWhere((k) => k.endsWith('.model'), orElse: () => '');
  if (rootKey.isEmpty) throw const FormatException('У 3MF не знайдено 3D-моделі');

  final cache = <String, _ModelFile?>{};
  _ModelFile? load(String key) {
    if (cache.containsKey(key)) return cache[key];
    final real = byLower[key];
    _ModelFile? mf;
    if (real != null) {
      mf = _parseModel(utf8.decode(zip.read(real), allowMalformed: true));
    }
    cache[key] = mf;
    return mf;
  }

  final rootModel = load(rootKey)!;
  final scale = rootModel.unitScale;
  final out = FloatBuf(1 << 16);

  void emit(String fileKey, String id, Transform3 t, int depth) {
    if (depth > 32) return;
    final mf = load(fileKey);
    final obj = mf?.objects[id];
    if (obj == null) return;
    final v = obj.verts;
    final ix = obj.idx;
    if (v != null && ix != null) {
      final nv = v.length ~/ 3;
      for (int k = 0; k + 2 < ix.length; k += 3) {
        final a = ix[k], b = ix[k + 1], c = ix[k + 2];
        if (a < 0 || b < 0 || c < 0 || a >= nv || b >= nv || c >= nv) continue;
        for (final vi in [a, b, c]) {
          final x = v[vi * 3], y = v[vi * 3 + 1], z = v[vi * 3 + 2];
          out.add((x * t[0] + y * t[3] + z * t[6] + t[9]) * scale);
          out.add((x * t[1] + y * t[4] + z * t[7] + t[10]) * scale);
          out.add((x * t[2] + y * t[5] + z * t[8] + t[11]) * scale);
        }
      }
    }
    for (final c in obj.comps) {
      final key = c.path != null ? _norm(c.path!) : fileKey;
      emit(key, c.id, _compose(c.t, t), depth + 1);
    }
  }

  // Bambu/Orca keep object names in model_settings.config.
  final settingsNames = <String, String>{};
  final settingsExtruders = <String, int>{};
  final ms = byLower['metadata/model_settings.config'];
  if (ms != null) {
    final text = utf8.decode(zip.read(ms), allowMalformed: true);
    for (final m in RegExp(r'<object\s+id="([^"]+)"\s*>([\s\S]*?)</object>').allMatches(text)) {
      final name = RegExp(r'<metadata\s+key="name"\s+value="([^"]*)"').firstMatch(m.group(2)!)?.group(1);
      if (name != null && name.isNotEmpty) settingsNames[m.group(1)!] = name;
      final ex = RegExp(r'<metadata\s+key="extruder"\s+value="(\d+)"').firstMatch(m.group(2)!)?.group(1);
      if (ex != null) settingsExtruders[m.group(1)!] = int.tryParse(ex) ?? 1;
    }
  }
  final objects = <MeshObject>[];
  void emitObject(String fileKey, String id, Transform3 t) {
    final start = out.length ~/ 9;
    emit(fileKey, id, t, 0);
    final end = out.length ~/ 9;
    if (end > start) {
      final name = settingsNames[id] ?? load(fileKey)?.objects[id]?.name ?? 'Об\'єкт ${objects.length + 1}';
      objects.add(MeshObject(name, start, end, extruder: settingsExtruders[id] ?? 1));
    }
  }

  if (rootModel.build.isNotEmpty) {
    for (final item in rootModel.build) {
      final key = item.path != null ? _norm(item.path!) : rootKey;
      emitObject(key, item.id, item.t);
    }
  } else {
    for (final id in rootModel.objectOrder) {
      emitObject(rootKey, id, _identity);
    }
  }

  final tris = out.toList();
  if (tris.isEmpty) throw const FormatException('3MF не містить трикутників');
  return Mesh(tris, objects.length > 1 ? objects : const []);
}
