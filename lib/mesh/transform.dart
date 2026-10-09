import 'dart:math' as math;
import 'dart:typed_data';

/// 3×3 rotation matrices, row-major: p' = M · p.
typedef Mat3 = List<double>;

const Mat3 identity3 = [1, 0, 0, 0, 1, 0, 0, 0, 1];

bool isIdentity(Mat3 m) {
  for (int i = 0; i < 9; i++) {
    if ((m[i] - identity3[i]).abs() > 1e-9) return false;
  }
  return true;
}

/// a · b (apply b first, then a).
Mat3 mul3(Mat3 a, Mat3 b) {
  final out = List<double>.filled(9, 0);
  for (int r = 0; r < 3; r++) {
    for (int c = 0; c < 3; c++) {
      double v = 0;
      for (int k = 0; k < 3; k++) {
        v += a[r * 3 + k] * b[k * 3 + c];
      }
      out[r * 3 + c] = v.abs() < 1e-12 ? 0 : v;
    }
  }
  return out;
}

/// Rotation by 90° about axis 0 = X, 1 = Y, 2 = Z (right-hand rule).
Mat3 rot90(int axis) => switch (axis) {
      0 => const [1, 0, 0, 0, 0, -1, 0, 1, 0],
      1 => const [0, 0, 1, 0, 1, 0, -1, 0, 0],
      _ => const [0, -1, 0, 1, 0, 0, 0, 0, 1],
    };

/// Rotation that turns the unit vector [n] to point straight down (−Z).
Mat3 rotateToDown(double nx, double ny, double nz) {
  final len = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (len < 1e-12) return identity3;
  nx /= len;
  ny /= len;
  nz /= len;
  // Axis = n × (0,0,-1), angle = acos(n · (0,0,-1)).
  final c = -nz;
  if (c > 1 - 1e-9) return identity3;
  if (c < -1 + 1e-9) return const [1, 0, 0, 0, -1, 0, 0, 0, -1]; // 180° about X
  double ax = -ny, ay = nx;
  const az = 0.0;
  final al = math.sqrt(ax * ax + ay * ay);
  ax /= al;
  ay /= al;
  final s = math.sqrt(1 - c * c);
  final t = 1 - c;
  return [
    t * ax * ax + c, t * ax * ay - s * az, t * ax * az + s * ay,
    t * ax * ay + s * az, t * ay * ay + c, t * ay * az - s * ax,
    t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c,
  ];
}

Float32List applyMat3(Float32List t, Mat3 m) {
  if (isIdentity(m)) return t;
  final out = Float32List(t.length);
  for (int i = 0; i + 2 < t.length; i += 3) {
    final x = t[i], y = t[i + 1], z = t[i + 2];
    out[i] = m[0] * x + m[1] * y + m[2] * z;
    out[i + 1] = m[3] * x + m[4] * y + m[5] * z;
    out[i + 2] = m[6] * x + m[7] * y + m[8] * z;
  }
  return out;
}

/// Unit normal of triangle [k] (zero vector for degenerate faces).
(double, double, double) triNormal(Float32List t, int k) {
  final b = k * 9;
  final ux = t[b + 3] - t[b], uy = t[b + 4] - t[b + 1], uz = t[b + 5] - t[b + 2];
  final vx = t[b + 6] - t[b], vy = t[b + 7] - t[b + 1], vz = t[b + 8] - t[b + 2];
  final nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
  final l = math.sqrt(nx * nx + ny * ny + nz * nz);
  return l > 0 ? (nx / l, ny / l, nz / l) : (0.0, 0.0, 0.0);
}

/// Orientation lying on the largest flat face that can touch the bed.
/// [outward] = false flips normals of inside-out meshes.
Mat3 autoOrient(Float32List t, {bool outward = true}) {
  final n = t.length ~/ 9;
  if (n == 0) return identity3;
  final flip = outward ? 1.0 : -1.0;
  // Area per quantised normal direction.
  final area = <int, double>{};
  final dirs = <int, (double, double, double)>{};
  for (int k = 0; k < n; k++) {
    final b = k * 9;
    final ux = t[b + 3] - t[b], uy = t[b + 4] - t[b + 1], uz = t[b + 5] - t[b + 2];
    final vx = t[b + 6] - t[b], vy = t[b + 7] - t[b + 1], vz = t[b + 8] - t[b + 2];
    double nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final l = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (l <= 0) continue;
    nx = nx / l * flip;
    ny = ny / l * flip;
    nz = nz / l * flip;
    final key = ((nx * 50).round() + 64) * 16384 + ((ny * 50).round() + 64) * 128 + ((nz * 50).round() + 64);
    area[key] = (area[key] ?? 0) + l / 2;
    dirs.putIfAbsent(key, () => (nx, ny, nz));
  }
  final candidates = area.keys.toList()..sort((a, b) => area[b]!.compareTo(area[a]!));

  double bestContact = -1;
  Mat3 best = identity3;
  for (final key in candidates.take(12)) {
    final (dx, dy, dz) = dirs[key]!;
    // Lowest plane in the direction of the normal (it will face down).
    double extreme = -double.infinity;
    for (int i = 0; i + 2 < t.length; i += 3) {
      final d = t[i] * dx + t[i + 1] * dy + t[i + 2] * dz;
      if (d > extreme) extreme = d;
    }
    double contact = 0;
    for (int k = 0; k < n; k++) {
      final b = k * 9;
      bool onPlane = true;
      for (int v = 0; v < 3 && onPlane; v++) {
        final d = t[b + v * 3] * dx + t[b + v * 3 + 1] * dy + t[b + v * 3 + 2] * dz;
        if (d < extreme - 0.05) onPlane = false;
      }
      if (!onPlane) continue;
      final (nx, ny, nz) = triNormal(t, k);
      if ((nx * dx + ny * dy + nz * dz) * flip < 0.995) continue;
      final ux = t[b + 3] - t[b], uy = t[b + 4] - t[b + 1], uz = t[b + 5] - t[b + 2];
      final vx = t[b + 6] - t[b], vy = t[b + 7] - t[b + 1], vz = t[b + 8] - t[b + 2];
      final cx = uy * vz - uz * vy, cy = uz * vx - ux * vz, cz = ux * vy - uy * vx;
      contact += math.sqrt(cx * cx + cy * cy + cz * cz) / 2;
    }
    if (contact > bestContact * 1.02) {
      bestContact = contact;
      best = rotateToDown(dx, dy, dz);
    }
  }
  return best;
}
