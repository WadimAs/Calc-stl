import 'dart:math' as math;
import 'dart:typed_data';

/// Merges coincident vertices of a triangle soup.
/// Returns an id per corner (3 per triangle) and the number of unique vertices.
(Int32List, int) weldVertices(Float32List t) {
  final nv0 = t.length ~/ 3;
  double maxAbs = 0;
  for (int i = 0; i < nv0 * 3; i++) {
    final v = t[i].abs();
    if (v > maxAbs) maxAbs = v;
  }
  // |v·q| ≤ 2^19 keeps every packed 21-bit field positive and the key below 2^63.
  final q = math.min(1000.0, (1 << 19) / math.max(1e-9, maxAbs));
  const off = 1 << 20;
  final keys = Int64List(nv0);
  for (int i = 0; i < nv0; i++) {
    final ix = (t[i * 3] * q).round() + off;
    final iy = (t[i * 3 + 1] * q).round() + off;
    final iz = (t[i * 3 + 2] * q).round() + off;
    keys[i] = (ix << 42) | (iy << 21) | iz;
  }
  final sorted = Int64List.fromList(keys)..sort();
  int nv = 0;
  for (int i = 0; i < nv0; i++) {
    if (nv == 0 || sorted[i] != sorted[nv - 1]) sorted[nv++] = sorted[i];
  }
  final vid = Int32List(nv0);
  for (int i = 0; i < nv0; i++) {
    final k = keys[i];
    int a = 0, b = nv - 1;
    while (a < b) {
      final m = (a + b) >> 1;
      if (sorted[m] < k) {
        a = m + 1;
      } else {
        b = m;
      }
    }
    vid[i] = a;
  }
  return (vid, nv);
}
