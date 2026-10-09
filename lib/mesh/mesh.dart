import 'dart:math' as math;
import 'dart:typed_data';

/// Growable buffer of 32-bit floats.
class FloatBuf {
  Float32List _data;
  int length = 0;

  FloatBuf([int capacity = 1024]) : _data = Float32List(capacity < 16 ? 16 : capacity);

  void add(double v) {
    if (length == _data.length) {
      final n = Float32List(_data.length * 2);
      n.setRange(0, length, _data);
      _data = n;
    }
    _data[length++] = v;
  }

  double operator [](int i) => _data[i];

  void setAt(int i, double v) => _data[i] = v;

  Float32List toList() => Float32List.fromList(Float32List.sublistView(_data, 0, length));
}

/// Growable buffer of 32-bit ints.
class IntBuf {
  Int32List _data;
  int length = 0;

  IntBuf([int capacity = 1024]) : _data = Int32List(capacity < 16 ? 16 : capacity);

  void add(int v) {
    if (length == _data.length) {
      final n = Int32List(_data.length * 2);
      n.setRange(0, length, _data);
      _data = n;
    }
    _data[length++] = v;
  }

  int operator [](int i) => _data[i];

  Int32List toList() => Int32List.fromList(Int32List.sublistView(_data, 0, length));
}

class Bounds {
  final double minX, minY, minZ, maxX, maxY, maxZ;

  const Bounds(this.minX, this.minY, this.minZ, this.maxX, this.maxY, this.maxZ);

  double get sizeX => maxX - minX;
  double get sizeY => maxY - minY;
  double get sizeZ => maxZ - minZ;
  double get centerX => (minX + maxX) / 2;
  double get centerY => (minY + maxY) / 2;
  double get centerZ => (minZ + maxZ) / 2;
  double get maxSide => math.max(sizeX, math.max(sizeY, sizeZ));

  static Bounds of(Float32List tris) {
    if (tris.isEmpty) return const Bounds(0, 0, 0, 0, 0, 0);
    double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (int i = 0; i + 2 < tris.length; i += 3) {
      final x = tris[i], y = tris[i + 1], z = tris[i + 2];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (z < minZ) minZ = z;
      if (z > maxZ) maxZ = z;
    }
    return Bounds(minX, minY, minZ, maxX, maxY, maxZ);
  }
}

/// A named part of a mesh: triangles [start, end).
class MeshObject {
  final String name;
  final int start;
  final int end;

  /// Filament slot (1-based) assigned in the slicer project.
  final int extruder;

  const MeshObject(this.name, this.start, this.end, {this.extruder = 1});

  int get triangles => end - start;
}

/// Triangle soup: 9 floats (3 vertices x XYZ, millimetres) per triangle.
class Mesh {
  final Float32List tris;

  /// Separate objects (3MF build items); empty means one object.
  final List<MeshObject> objects;

  const Mesh(this.tris, [this.objects = const []]);

  int get triangleCount => tris.length ~/ 9;

  /// Signed volume in mm³ (positive for outward-facing triangles).
  double signedVolume() {
    double v = 0;
    for (int b = 0; b + 8 < tris.length; b += 9) {
      final ax = tris[b], ay = tris[b + 1], az = tris[b + 2];
      final bx = tris[b + 3], by = tris[b + 4], bz = tris[b + 5];
      final cx = tris[b + 6], cy = tris[b + 7], cz = tris[b + 8];
      v += ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx);
    }
    return v / 6.0;
  }

  double surfaceArea() {
    double a = 0;
    for (int b = 0; b + 8 < tris.length; b += 9) {
      final ux = tris[b + 3] - tris[b], uy = tris[b + 4] - tris[b + 1], uz = tris[b + 5] - tris[b + 2];
      final vx = tris[b + 6] - tris[b], vy = tris[b + 7] - tris[b + 1], vz = tris[b + 8] - tris[b + 2];
      final nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      a += math.sqrt(nx * nx + ny * ny + nz * nz) / 2;
    }
    return a;
  }
}
