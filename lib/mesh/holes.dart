import 'dart:math' as math;
import 'dart:typed_data';

import 'weld.dart';

/// A round hole whose axis is parallel to X, Y or Z.
class HoleFeature {
  final int axis; // 0 = X, 1 = Y, 2 = Z
  final double cu, cv; // centre on axes (axis + 1) % 3 and (axis + 2) % 3
  final double w0, w1; // extent along the axis
  final double radius;
  final double chamferRadius; // largest entry chamfer/countersink, 0 if none
  final int slices;

  const HoleFeature({
    required this.axis,
    required this.cu,
    required this.cv,
    required this.w0,
    required this.w1,
    required this.radius,
    this.chamferRadius = 0,
    required this.slices,
  });

  double get diameter => radius * 2;
  double get depth => w1 - w0;
  String get axisName => const ['X', 'Y', 'Z'][axis];

  /// Absolute point on the axis at axial coordinate [w].
  List<double> pointAt(double w) {
    final p = List<double>.filled(3, 0);
    p[axis] = w;
    p[(axis + 1) % 3] = cu;
    p[(axis + 2) % 3] = cv;
    return p;
  }

  /// Distance of an absolute point from the hole wall, or null when the point
  /// is beyond the hole's ends.
  double? wallDistance(double x, double y, double z) {
    final p = [x, y, z];
    final w = p[axis];
    final margin = math.max(0.5, radius * 0.3);
    if (w < w0 - margin || w > w1 + margin) return null;
    final du = p[(axis + 1) % 3] - cu, dv = p[(axis + 2) % 3] - cv;
    final d = math.sqrt(du * du + dv * dv);
    final outer = chamferRadius > radius ? chamferRadius : radius;
    if (d >= radius && d <= outer) return 0;
    return (d - radius).abs();
  }
}

class _Circle {
  final double z, cu, cv, r;

  _Circle(this.z, this.cu, this.cv, this.r);
}

class _Cluster {
  final int axis;
  final double step;
  double cu, cv, r, z0, z1;
  int n = 1;
  final List<double> radii;
  double chamfer = 0;
  bool dropped = false;

  _Cluster(this.axis, this.step, _Circle c)
      : cu = c.cu,
        cv = c.cv,
        r = c.r,
        z0 = c.z,
        z1 = c.z,
        radii = [c.r];
}

/// Finds round holes parallel to the X, Y and Z axes.
///
/// The model is cut by planes across each axis; closed contours of every cut
/// that run clockwise (material outside) and fit a circle are hole sections.
/// Sections lined up on consecutive cuts form one hole; short wider sections
/// at its ends are reported as entry chamfers.
List<HoleFeature> findHoles(Float32List t, {bool inverted = false, int maxSlicesPerAxis = 150}) {
  final n = t.length ~/ 9;
  if (n == 0) return const [];
  final nv0 = n * 3;

  final lo = [double.infinity, double.infinity, double.infinity];
  final hi = [-double.infinity, -double.infinity, -double.infinity];
  for (int i = 0; i < nv0; i++) {
    for (int a = 0; a < 3; a++) {
      final v = t[i * 3 + a];
      if (v < lo[a]) lo[a] = v;
      if (v > hi[a]) hi[a] = v;
    }
  }

  // Weld vertices so contour pieces can be chained through shared edges.
  final (vid, nv) = weldVertices(t);

  final flip = inverted ? -1.0 : 1.0;
  final nrm = Float64List(n * 3);
  for (int k = 0; k < n; k++) {
    final b = k * 9;
    final ux = t[b + 3] - t[b], uy = t[b + 4] - t[b + 1], uz = t[b + 5] - t[b + 2];
    final vx = t[b + 6] - t[b], vy = t[b + 7] - t[b + 1], vz = t[b + 8] - t[b + 2];
    nrm[k * 3] = (uy * vz - uz * vy) * flip;
    nrm[k * 3 + 1] = (uz * vx - ux * vz) * flip;
    nrm[k * 3 + 2] = (ux * vy - uy * vx) * flip;
  }

  final features = <HoleFeature>[];
  for (int ax = 0; ax < 3; ax++) {
    final iu = (ax + 1) % 3, iv = (ax + 2) % 3;
    final size = hi[ax] - lo[ax];
    if (!(size > 0)) continue;
    final step = math.max(0.4, size / maxSlicesPerAxis);
    final base = lo[ax] + step / 2 + 1.37e-4;
    final ns = ((hi[ax] - base) / step).floor() + 1;
    if (ns <= 0) continue;

    // Triangles bucketed by the cuts they cross.
    final start = Int32List(ns + 1);
    final kLo = Int32List(n), kHi = Int32List(n);
    for (int k = 0; k < n; k++) {
      final b = k * 9 + ax;
      final a0 = t[b], a1 = t[b + 3], a2 = t[b + 6];
      final mn = math.min(a0, math.min(a1, a2)), mx = math.max(a0, math.max(a1, a2));
      final s0 = math.max(0, ((mn - base) / step).ceil());
      final s1 = math.min(ns - 1, ((mx - base) / step).floor());
      kLo[k] = s0;
      kHi[k] = s1;
      for (int s = s0; s <= s1; s++) {
        start[s + 1]++;
      }
    }
    for (int s = 0; s < ns; s++) {
      start[s + 1] += start[s];
    }
    final refs = Int32List(start[ns]);
    final fill = Int32List.fromList(Int32List.sublistView(start, 0, ns));
    for (int k = 0; k < n; k++) {
      for (int s = kLo[k]; s <= kHi[k]; s++) {
        refs[fill[s]++] = k;
      }
    }

    final circles = <_Circle>[];
    final sx0 = <double>[], sy0 = <double>[];
    final sKey0 = <int>[], sKey1 = <int>[];
    final byStart = <int, int>{};
    for (int s = 0; s < ns; s++) {
      final z = base + s * step;
      sx0.clear();
      sy0.clear();
      sKey0.clear();
      sKey1.clear();
      byStart.clear();
      for (int r = start[s]; r < start[s + 1]; r++) {
        final k = refs[r];
        final b = k * 9;
        double px = 0, py = 0, qx = 0, qy = 0;
        int k0 = 0, k1 = 0, found = 0;
        for (int e = 0; e < 3; e++) {
          final ea = e, eb = (e + 1) % 3;
          final za = t[b + ea * 3 + ax], zb = t[b + eb * 3 + ax];
          if ((za < z) != (zb < z)) {
            final f = (z - za) / (zb - za);
            final x = t[b + ea * 3 + iu] + f * (t[b + eb * 3 + iu] - t[b + ea * 3 + iu]);
            final y = t[b + ea * 3 + iv] + f * (t[b + eb * 3 + iv] - t[b + ea * 3 + iv]);
            final va = vid[k * 3 + ea], vb = vid[k * 3 + eb];
            final key = va < vb ? va * nv + vb : vb * nv + va;
            if (found == 0) {
              px = x;
              py = y;
              k0 = key;
            } else {
              qx = x;
              qy = y;
              k1 = key;
            }
            found++;
          }
        }
        if (found != 2) continue;
        // Orient so that the material is on the left (outer contours CCW).
        final nu = nrm[k * 3 + iu], nvv = nrm[k * 3 + iv];
        if ((qx - px) * (-nvv) + (qy - py) * nu < 0) {
          final tx = px, ty = py, tk = k0;
          px = qx;
          py = qy;
          k0 = k1;
          qx = tx;
          qy = ty;
          k1 = tk;
        }
        byStart[k0] = sx0.length;
        sx0.add(px);
        sy0.add(py);
        sKey0.add(k0);
        sKey1.add(k1);
      }
      final m = sx0.length;
      if (m < 8) continue;
      final used = Uint8List(m);
      final lx = <double>[], ly = <double>[];
      for (int i = 0; i < m; i++) {
        if (used[i] != 0) continue;
        lx.clear();
        ly.clear();
        int j = i;
        bool closed = false;
        while (true) {
          used[j] = 1;
          lx.add(sx0[j]);
          ly.add(sy0[j]);
          final nk = sKey1[j];
          if (nk == sKey0[i]) {
            closed = true;
            break;
          }
          final nj = byStart[nk];
          if (nj == null || used[nj] != 0) break;
          j = nj;
        }
        if (!closed || lx.length < 8) continue;
        double area2 = 0;
        for (int p = 0; p < lx.length; p++) {
          final p2 = (p + 1) % lx.length;
          area2 += lx[p] * ly[p2] - lx[p2] * ly[p];
        }
        if (area2 >= 0) continue; // outer contour or boss, not a hole
        final c = _fitCircle(lx, ly);
        if (c == null) continue;
        circles.add(_Circle(z, c.$1, c.$2, c.$3));
      }
    }

    // Line up sections of consecutive cuts.
    final clusters = <_Cluster>[];
    for (final c in circles) {
      _Cluster? hit;
      for (final g in clusters) {
        if ((g.r - c.r).abs() < 0.03 + 0.01 * c.r &&
            _hyp(g.cu - c.cu, g.cv - c.cv) < 0.05 + 0.02 * c.r &&
            c.z - g.z1 < step * 1.5 &&
            c.z > g.z1) {
          hit = g;
          break;
        }
      }
      if (hit != null) {
        hit.z1 = c.z;
        hit.n++;
        hit.radii.add(c.r);
        hit.cu += (c.cu - hit.cu) / hit.n;
        hit.cv += (c.cv - hit.cv) / hit.n;
      } else {
        clusters.add(_Cluster(ax, step, c));
      }
    }
    for (final g in clusters) {
      g.radii.sort();
      g.r = g.radii[g.radii.length ~/ 2];
    }
    // Short, wider, coaxial sections at a hole's end are its chamfer.
    for (final f in clusters) {
      if (f.n > 2) continue;
      for (final g in clusters) {
        if (identical(f, g) || g.dropped || g.n <= f.n) continue;
        if (f.r <= g.r) continue;
        if (_hyp(f.cu - g.cu, f.cv - g.cv) > 0.1 + 0.03 * g.r) continue;
        if (f.z0 > g.z1 + step * 2.5 || f.z1 < g.z0 - step * 2.5) continue;
        g.chamfer = math.max(g.chamfer, f.r);
        f.dropped = true;
        break;
      }
    }
    for (final g in clusters) {
      if (g.dropped) continue;
      features.add(HoleFeature(
        axis: ax,
        cu: g.cu,
        cv: g.cv,
        w0: math.max(lo[ax], g.z0 - step / 2),
        w1: math.min(hi[ax], g.z1 + step / 2),
        radius: g.r,
        chamferRadius: g.chamfer,
        slices: g.n,
      ));
    }
  }
  return features;
}

double _hyp(double a, double b) => math.sqrt(a * a + b * b);

/// Least-squares circle (Kåsa) through a closed contour; null if the
/// contour is not round enough or leaves gaps.
(double, double, double)? _fitCircle(List<double> xs, List<double> ys) {
  final m = xs.length;
  double mx = 0, my = 0;
  for (int i = 0; i < m; i++) {
    mx += xs[i];
    my += ys[i];
  }
  mx /= m;
  my /= m;
  double sxx = 0, sxy = 0, syy = 0, sxz = 0, syz = 0, sz = 0;
  for (int i = 0; i < m; i++) {
    final x = xs[i] - mx, y = ys[i] - my;
    final zz = x * x + y * y;
    sxx += x * x;
    sxy += x * y;
    syy += y * y;
    sxz += x * zz;
    syz += y * zz;
    sz += zz;
  }
  final det = sxx * syy - sxy * sxy;
  if (det.abs() < 1e-18) return null;
  // Solve [sxx sxy; sxy syy] [D; E] = -[sxz; syz]
  final d = (-sxz * syy + syz * sxy) / det;
  final e = (-syz * sxx + sxz * sxy) / det;
  final f = -sz / m;
  final cx = -d / 2, cy = -e / 2;
  final r2 = cx * cx + cy * cy - f;
  if (r2 <= 0) return null;
  final r = math.sqrt(r2);
  if (r < 0.3) return null;
  double res = 0;
  final angles = List<double>.filled(m, 0);
  for (int i = 0; i < m; i++) {
    final x = xs[i] - mx - cx, y = ys[i] - my - cy;
    final dd = math.sqrt(x * x + y * y) - r;
    res += dd * dd;
    angles[i] = math.atan2(y, x);
  }
  res = math.sqrt(res / m);
  if (res > 0.025 * r + 0.01) return null;
  angles.sort();
  double gap = angles.first + 2 * math.pi - angles.last;
  for (int i = 1; i < m; i++) {
    final g = angles[i] - angles[i - 1];
    if (g > gap) gap = g;
  }
  if (gap > math.pi / 3) return null;
  return (cx + mx, cy + my, r);
}
