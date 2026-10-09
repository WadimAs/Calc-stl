import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'mesh.dart';
import 'slicer_project.dart';
import 'stl_parser.dart';
import 'threemf_parser.dart';

/// Everything the UI needs about an opened model.
class LoadedModel {
  final String name;
  final Mesh mesh;
  final Bounds bounds;
  final double volume; // mm³, solid
  final double area; // mm²

  /// Simplified copy for the 3D view, centred at the origin (Z up).
  final Float32List viewTris;

  /// Unit normal per view triangle.
  final Float32List viewNormals;
  final bool outwardNormals;

  /// Settings / exact results from the slicer that produced the file.
  final SlicerProject? project;

  const LoadedModel({
    required this.name,
    required this.mesh,
    required this.bounds,
    required this.volume,
    required this.area,
    required this.viewTris,
    required this.viewNormals,
    required this.outwardNormals,
    this.project,
  });

  /// False for G-code and sliced files that carry no 3D geometry.
  bool get hasMesh => mesh.triangleCount > 0;
}

bool isSupportedFile(String name) {
  final n = name.toLowerCase();
  return n.endsWith('.stl') || n.endsWith('.3mf') || n.endsWith('.gcode') || n.endsWith('.gco') || n.endsWith('.g');
}

/// Parses the file in a background isolate.
Future<LoadedModel> loadModel(String name, Uint8List bytes) {
  return Isolate.run(() => _load(name, bytes));
}

LoadedModel _load(String name, Uint8List bytes) {
  final lower = name.toLowerCase();
  Mesh mesh;
  SlicerProject? project;
  if (lower.endsWith('.gcode') || lower.endsWith('.gco') || lower.endsWith('.g') || _looksLikeGcode(bytes)) {
    project = readGcode(bytes);
    if (project == null) {
      throw const FormatException('У G-code немає даних про вагу чи час друку');
    }
    mesh = Mesh(Float32List(0));
  } else if (lower.endsWith('.3mf') || _isZip(bytes)) {
    project = readProjectFrom3mf(bytes);
    try {
      mesh = parse3mf(bytes);
    } on FormatException {
      // Sliced files (.gcode.3mf) may hold only the G-code.
      if (project == null || !project.isSliced) rethrow;
      mesh = Mesh(Float32List(0));
    }
  } else {
    mesh = parseStl(bytes);
  }
  if (mesh.triangleCount == 0 && !(project?.isSliced ?? false)) {
    throw const FormatException('Модель порожня');
  }
  final b = Bounds.of(mesh.tris);
  final signed = mesh.signedVolume();
  final view = _simplify(mesh.tris, b, 120000);
  final centred = Float32List(view.length);
  for (int i = 0; i < view.length; i += 3) {
    centred[i] = view[i] - b.centerX;
    centred[i + 1] = view[i + 1] - b.centerY;
    centred[i + 2] = view[i + 2] - b.centerZ;
  }
  final normals = Float32List(view.length ~/ 3);
  for (int t = 0, k = 0; t + 8 < centred.length; t += 9, k += 3) {
    final ux = centred[t + 3] - centred[t], uy = centred[t + 4] - centred[t + 1], uz = centred[t + 5] - centred[t + 2];
    final vx = centred[t + 6] - centred[t], vy = centred[t + 7] - centred[t + 1], vz = centred[t + 8] - centred[t + 2];
    double nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 0) {
      nx /= len;
      ny /= len;
      nz /= len;
    }
    normals[k] = nx;
    normals[k + 1] = ny;
    normals[k + 2] = nz;
  }
  return LoadedModel(
    name: name,
    mesh: mesh,
    bounds: b,
    volume: signed.abs(),
    area: mesh.surfaceArea(),
    viewTris: centred,
    viewNormals: normals,
    outwardNormals: signed >= 0,
    project: project,
  );
}

bool _looksLikeGcode(Uint8List b) {
  if (b.isEmpty || b[0] != 0x3B) return false; // ';'
  final n = b.length < 4096 ? b.length : 4096;
  final head = String.fromCharCodes(Uint8List.sublistView(b, 0, n)).toLowerCase();
  return head.contains('gcode') || head.contains('flavor') || head.contains('generated');
}

bool _isZip(Uint8List b) => b.length > 4 && b[0] == 0x50 && b[1] == 0x4B && b[2] == 0x03 && b[3] == 0x04;

/// Vertex-clustering decimation used only for display.
Float32List _simplify(Float32List tris, Bounds b, int maxTris) {
  final n = tris.length ~/ 9;
  if (n <= maxTris) return tris;
  double grid = 512;
  Float32List result = tris;
  for (int attempt = 0; attempt < 8; attempt++) {
    final cell = b.maxSide / grid;
    if (cell <= 0) return tris;
    final rep = <int, int>{}; // cluster key -> representative vertex index
    final out = FloatBuf(maxTris * 9 + 9);
    int kept = 0;
    final keys = List<int>.filled(3, 0);
    final reps = Int32List(3);
    for (int t = 0; t < n; t++) {
      for (int v = 0; v < 3; v++) {
        final o = t * 9 + v * 3;
        final ix = ((tris[o] - b.minX) / cell).floor();
        final iy = ((tris[o + 1] - b.minY) / cell).floor();
        final iz = ((tris[o + 2] - b.minZ) / cell).floor();
        final key = (ix * 4096 + iy) * 4096 + iz;
        keys[v] = key;
        reps[v] = rep.putIfAbsent(key, () => o);
      }
      if (keys[0] == keys[1] || keys[1] == keys[2] || keys[0] == keys[2]) continue;
      for (int v = 0; v < 3; v++) {
        final o = reps[v];
        out.add(tris[o]);
        out.add(tris[o + 1]);
        out.add(tris[o + 2]);
      }
      kept++;
    }
    result = out.toList();
    if (kept <= maxTris) return result;
    grid *= 0.7;
  }
  return result;
}
