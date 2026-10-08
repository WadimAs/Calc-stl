import 'dart:math' as math;
import 'dart:typed_data';

import 'settings.dart';

/// Geometry-only result of a slice. Weight/length depend on material and are
/// derived in [SliceResult.grams] / [SliceResult.filamentMeters].
class SliceResult {
  /// Extruded plastic volume for one copy, mm³.
  final double volumeMm3;

  /// Volume of the (scaled) model if printed 100% solid, mm³.
  final double solidVolumeMm3;
  final int layers;
  final double cellSize;
  final int millis;
  final double sizeX, sizeY, sizeZ;

  const SliceResult({
    required this.volumeMm3,
    required this.solidVolumeMm3,
    required this.layers,
    required this.cellSize,
    required this.millis,
    required this.sizeX,
    required this.sizeY,
    required this.sizeZ,
  });

  double grams(double density, {int copies = 1}) => volumeMm3 * density / 1000.0 * copies;

  double solidGrams(double density) => solidVolumeMm3 * density / 1000.0;

  double filamentMeters(double diameter, {int copies = 1}) {
    final r = diameter / 2;
    return volumeMm3 / (math.pi * r * r) / 1000.0 * copies;
  }

  Map<String, dynamic> toMap() => {
        'volumeMm3': volumeMm3,
        'solidVolumeMm3': solidVolumeMm3,
        'layers': layers,
        'cellSize': cellSize,
        'millis': millis,
        'sizeX': sizeX,
        'sizeY': sizeY,
        'sizeZ': sizeZ,
      };

  static SliceResult fromMap(Map m) => SliceResult(
        volumeMm3: (m['volumeMm3'] as num).toDouble(),
        solidVolumeMm3: (m['solidVolumeMm3'] as num).toDouble(),
        layers: (m['layers'] as num).toInt(),
        cellSize: (m['cellSize'] as num).toDouble(),
        millis: (m['millis'] as num).toInt(),
        sizeX: (m['sizeX'] as num).toDouble(),
        sizeY: (m['sizeY'] as num).toDouble(),
        sizeZ: (m['sizeZ'] as num).toDouble(),
      );
}

typedef ProgressCallback = void Function(double fraction);

/// Layer-by-layer slicer.
///
/// Every layer is cut from the mesh, rasterised with the non-zero winding rule
/// and split into: perimeters (distance to the outline < walls × line width),
/// solid top/bottom skin (area not covered by the N layers above/below) and
/// sparse infill (the rest, multiplied by the infill density). The raster
/// area is corrected to the exact polygon area of each layer.
SliceResult sliceMesh(
  Float32List source,
  SliceSettings st, {
  ProgressCallback? onProgress,
  int maxCellsPerSide = 500,
}) {
  final watch = Stopwatch()..start();
  final scale = st.scalePercent / 100.0;
  final nT = source.length ~/ 9;
  final t = Float64List(nT * 9);
  double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
  double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
  for (int k = 0; k < nT * 3; k++) {
    final x = source[k * 3] * scale;
    final y = source[k * 3 + 1] * scale;
    final z = source[k * 3 + 2] * scale;
    t[k * 3] = x;
    t[k * 3 + 1] = y;
    t[k * 3 + 2] = z;
    if (x < minX) minX = x;
    if (x > maxX) maxX = x;
    if (y < minY) minY = y;
    if (y > maxY) maxY = y;
    if (z < minZ) minZ = z;
    if (z > maxZ) maxZ = z;
  }
  if (nT == 0 || !(maxZ > minZ)) {
    return SliceResult(
        volumeMm3: 0, solidVolumeMm3: 0, layers: 0, cellSize: 0, millis: 0, sizeX: 0, sizeY: 0, sizeZ: 0);
  }

  // Put the model on the bed and compute its solid volume.
  double vol6 = 0;
  for (int b = 0; b < nT * 9; b += 9) {
    t[b + 2] -= minZ;
    t[b + 5] -= minZ;
    t[b + 8] -= minZ;
    final ax = t[b], ay = t[b + 1], az = t[b + 2];
    final bx = t[b + 3], by = t[b + 4], bz = t[b + 5];
    final cx = t[b + 6], cy = t[b + 7], cz = t[b + 8];
    vol6 += ax * (by * cz - bz * cy) - ay * (bx * cz - bz * cx) + az * (bx * cy - by * cx);
  }
  final solidVolume = (vol6 / 6.0).abs();
  final zTop = maxZ - minZ;

  // Layers.
  final h = st.layerHeight.clamp(0.02, 2.0).toDouble();
  final h0 = st.firstLayerHeight.clamp(0.02, 2.0).toDouble();
  int nL = 1;
  double zAcc = h0;
  while (zAcc < zTop - 1e-6) {
    zAcc += h;
    nL++;
    if (nL > 50000) throw StateError('Забагато шарів — перевірте масштаб моделі');
  }
  final heights = Float64List(nL);
  final mids = Float64List(nL);
  {
    double zb = 0;
    for (int i = 0; i < nL; i++) {
      final hi = i == 0 ? h0 : h;
      heights[i] = hi;
      mids[i] = zb + hi / 2 + 1.37e-5;
      zb += hi;
    }
  }

  // Raster grid.
  final lineW = st.lineWidth.clamp(0.1, 2.0).toDouble();
  final side = math.max(maxX - minX, maxY - minY);
  final s = math.max(0.1, math.max(lineW * 0.5, side / maxCellsPerSide));
  final ox = minX - 2 * s, oy = minY - 2 * s;
  final nx = ((maxX - minX) / s).ceil() + 4;
  final ny = ((maxY - minY) / s).ceil() + 4;
  final nCells = nx * ny;

  // Triangles sorted by lowest Z for a sweep.
  final tzMin = Float64List(nT), tzMax = Float64List(nT);
  for (int k = 0; k < nT; k++) {
    final b = k * 9;
    tzMin[k] = math.min(t[b + 2], math.min(t[b + 5], t[b + 8]));
    tzMax[k] = math.max(t[b + 2], math.max(t[b + 5], t[b + 8]));
  }
  final order = List<int>.generate(nT, (i) => i)..sort((a, b) => tzMin[a].compareTo(tzMin[b]));
  int nextTri = 0;
  var active = <int>[];

  // Scratch buffers.
  var seg = Float64List(4096); // x1,y1,x2,y2
  var crossX = Float64List(4096);
  var crossW = Int8List(4096);
  final rowStart = Int32List(ny + 1);
  final rowFill = Int32List(ny);

  final top = st.topLayers < 0 ? 0 : st.topLayers;
  final bottom = st.bottomLayers < 0 ? 0 : st.bottomLayers;
  final ringSize = top + bottom + 1;
  final ring = List<Uint8List>.generate(ringSize, (_) => Uint8List(nCells));
  final ringArea = Float64List(ringSize);
  final ringCount = Int32List(ringSize);
  final ringCrop = Int32List(ringSize * 4); // x0, y0, x1, y1

  /// Cuts layer [li] and rasterises it into ring slot li % ringSize.
  void genLayer(int li) {
    final slot = li % ringSize;
    final mask = ring[slot];
    mask.fillRange(0, nCells, 0);
    final z = mids[li];

    while (nextTri < nT && tzMin[order[nextTri]] <= z) {
      active.add(order[nextTri]);
      nextTri++;
    }
    final still = <int>[];
    int nSeg = 0;
    double area2 = 0;
    double sMinX = double.infinity, sMinY = double.infinity;
    double sMaxX = -double.infinity, sMaxY = -double.infinity;

    for (final k in active) {
      if (tzMax[k] < z) continue;
      still.add(k);
      final b = k * 9;
      double px = 0, py = 0, qx = 0, qy = 0;
      int found = 0;
      for (int e = 0; e < 3; e++) {
        final a = b + e * 3;
        final c = b + ((e + 1) % 3) * 3;
        final za = t[a + 2], zc = t[c + 2];
        if ((za < z) != (zc < z)) {
          final f = (z - za) / (zc - za);
          final x = t[a] + f * (t[c] - t[a]);
          final y = t[a + 1] + f * (t[c + 1] - t[a + 1]);
          if (found == 0) {
            px = x;
            py = y;
          } else {
            qx = x;
            qy = y;
          }
          found++;
        }
      }
      if (found != 2) continue;
      // Orientation from the face normal: outline runs counter-clockwise.
      final ux = t[b + 3] - t[b], uy = t[b + 4] - t[b + 1], uz = t[b + 5] - t[b + 2];
      final vx = t[b + 6] - t[b], vy = t[b + 7] - t[b + 1], vz = t[b + 8] - t[b + 2];
      final nxn = uy * vz - uz * vy;
      final nyn = uz * vx - ux * vz;
      if ((qx - px) * (-nyn) + (qy - py) * nxn < 0) {
        final tx = px, ty = py;
        px = qx;
        py = qy;
        qx = tx;
        qy = ty;
      }
      if (nSeg * 4 + 4 > seg.length) {
        final ns = Float64List(seg.length * 2);
        ns.setRange(0, nSeg * 4, seg);
        seg = ns;
      }
      final o = nSeg * 4;
      seg[o] = px;
      seg[o + 1] = py;
      seg[o + 2] = qx;
      seg[o + 3] = qy;
      nSeg++;
      area2 += px * qy - qx * py;
      if (px < sMinX) sMinX = px;
      if (qx < sMinX) sMinX = qx;
      if (px > sMaxX) sMaxX = px;
      if (qx > sMaxX) sMaxX = qx;
      if (py < sMinY) sMinY = py;
      if (qy < sMinY) sMinY = qy;
      if (py > sMaxY) sMaxY = py;
      if (qy > sMaxY) sMaxY = qy;
    }
    active = still;

    ringArea[slot] = area2.abs() / 2;
    ringCount[slot] = 0;
    if (nSeg == 0) {
      ringCrop[slot * 4] = 0;
      ringCrop[slot * 4 + 1] = 0;
      ringCrop[slot * 4 + 2] = -1;
      ringCrop[slot * 4 + 3] = -1;
      return;
    }
    final cx0 = math.max(0, ((sMinX - ox) / s).floor() - 1);
    final cy0 = math.max(0, ((sMinY - oy) / s).floor() - 1);
    final cx1 = math.min(nx - 1, ((sMaxX - ox) / s).floor() + 1);
    final cy1 = math.min(ny - 1, ((sMaxY - oy) / s).floor() + 1);
    ringCrop[slot * 4] = cx0;
    ringCrop[slot * 4 + 1] = cy0;
    ringCrop[slot * 4 + 2] = cx1;
    ringCrop[slot * 4 + 3] = cy1;

    // Pass 1: count crossings of every row centre.
    for (int j = cy0; j <= cy1 + 1 && j <= ny; j++) {
      rowStart[j] = 0;
    }
    for (int k = 0; k < nSeg; k++) {
      final y1 = seg[k * 4 + 1], y2 = seg[k * 4 + 3];
      if (y1 == y2) continue;
      final ya = y1 < y2 ? y1 : y2, yb = y1 < y2 ? y2 : y1;
      final j0 = math.max(cy0, ((ya - oy) / s - 0.5).ceil());
      final j1 = math.min(cy1 + 1, ((yb - oy) / s - 0.5).ceil());
      for (int j = j0; j < j1; j++) {
        rowStart[j + 1]++;
      }
    }
    // Prefix sums (rowStart[j] = first index of row j).
    rowStart[cy0] = 0;
    for (int j = cy0; j <= cy1; j++) {
      rowStart[j + 1] += rowStart[j];
    }
    final total = rowStart[cy1 + 1];
    if (total > crossX.length) {
      crossX = Float64List(total * 2);
      crossW = Int8List(total * 2);
    }
    for (int j = cy0; j <= cy1; j++) {
      rowFill[j] = rowStart[j];
    }
    // Pass 2: store crossings.
    for (int k = 0; k < nSeg; k++) {
      final x1 = seg[k * 4], y1 = seg[k * 4 + 1], x2 = seg[k * 4 + 2], y2 = seg[k * 4 + 3];
      if (y1 == y2) continue;
      final w = y2 > y1 ? 1 : -1;
      final ya = y1 < y2 ? y1 : y2, yb = y1 < y2 ? y2 : y1;
      final j0 = math.max(cy0, ((ya - oy) / s - 0.5).ceil());
      final j1 = math.min(cy1 + 1, ((yb - oy) / s - 0.5).ceil());
      final slope = (x2 - x1) / (y2 - y1);
      for (int j = j0; j < j1; j++) {
        final yc = oy + (j + 0.5) * s;
        final p = rowFill[j]++;
        crossX[p] = x1 + (yc - y1) * slope;
        crossW[p] = w;
      }
    }
    // Fill rows using the non-zero winding rule.
    int count = 0;
    for (int j = cy0; j <= cy1; j++) {
      final a = rowStart[j], e = rowStart[j + 1];
      if (e - a < 2) continue;
      _sortCrossings(crossX, crossW, a, e);
      int wind = 0;
      final rowBase = j * nx;
      for (int k = a; k < e - 1; k++) {
        wind += crossW[k];
        if (wind == 0) continue;
        int i0 = ((crossX[k] - ox) / s - 0.5).ceil();
        int i1 = ((crossX[k + 1] - ox) / s - 0.5).ceil();
        if (i0 < 0) i0 = 0;
        if (i1 > nx) i1 = nx;
        for (int i = i0; i < i1; i++) {
          if (mask[rowBase + i] == 0) {
            mask[rowBase + i] = 1;
            count++;
          }
        }
      }
    }
    ringCount[slot] = count;
  }

  final dist = Float32List(nCells);
  const r2 = 1.41421356;
  final wallCells = st.walls * lineW / s + 0.5;
  final double infill = (st.infillPercent / 100.0).clamp(0.0, 1.0).toDouble();
  double volume = 0;
  int generated = 0;
  final progressStep = math.max(1, nL ~/ 100);

  for (int i = 0; i < nL; i++) {
    final want = math.min(i + top, nL - 1);
    while (generated <= want) {
      genLayer(generated);
      generated++;
    }
    final slot = i % ringSize;
    final nIn = ringCount[slot];
    if (onProgress != null && i % progressStep == 0) onProgress(i / nL);
    if (nIn == 0) continue;
    final mask = ring[slot];
    final x0 = ringCrop[slot * 4], y0 = ringCrop[slot * 4 + 1];
    final x1 = ringCrop[slot * 4 + 2], y1 = ringCrop[slot * 4 + 3];

    // Chamfer distance transform (in cells) inside the crop.
    for (int y = y0; y <= y1; y++) {
      final row = y * nx;
      for (int x = x0; x <= x1; x++) {
        dist[row + x] = mask[row + x] != 0 ? 1e9 : 0.0;
      }
    }
    for (int y = y0 + 1; y < y1; y++) {
      final row = y * nx;
      for (int x = x0 + 1; x < x1; x++) {
        final idx = row + x;
        double v = dist[idx];
        if (v == 0) continue;
        double c = dist[idx - 1] + 1;
        if (c < v) v = c;
        c = dist[idx - nx] + 1;
        if (c < v) v = c;
        c = dist[idx - nx - 1] + r2;
        if (c < v) v = c;
        c = dist[idx - nx + 1] + r2;
        if (c < v) v = c;
        dist[idx] = v;
      }
    }
    for (int y = y1 - 1; y > y0; y--) {
      final row = y * nx;
      for (int x = x1 - 1; x > x0; x--) {
        final idx = row + x;
        double v = dist[idx];
        if (v == 0) continue;
        double c = dist[idx + 1] + 1;
        if (c < v) v = c;
        c = dist[idx + nx] + 1;
        if (c < v) v = c;
        c = dist[idx + nx + 1] + r2;
        if (c < v) v = c;
        c = dist[idx + nx - 1] + r2;
        if (c < v) v = c;
        dist[idx] = v;
      }
    }

    int shell = 0, solid = 0, sparse = 0;
    for (int y = y0; y <= y1; y++) {
      final row = y * nx;
      for (int x = x0; x <= x1; x++) {
        final idx = row + x;
        if (mask[idx] == 0) continue;
        if (dist[idx] < wallCells) {
          shell++;
          continue;
        }
        bool isSolid = false;
        for (int k = 1; k <= top && !isSolid; k++) {
          final l = i + k;
          if (l >= nL || ring[l % ringSize][idx] == 0) isSolid = true;
        }
        for (int k = 1; k <= bottom && !isSolid; k++) {
          final l = i - k;
          if (l < 0 || ring[l % ringSize][idx] == 0) isSolid = true;
        }
        if (isSolid) {
          solid++;
        } else {
          sparse++;
        }
      }
    }

    final rasterArea = nIn * s * s;
    double corr = ringArea[slot] / rasterArea;
    if (!(corr > 0.7 && corr < 1.4)) corr = 1.0;
    volume += heights[i] * s * s * corr * (shell + solid + infill * sparse);
  }
  onProgress?.call(1.0);

  return SliceResult(
    volumeMm3: volume,
    solidVolumeMm3: solidVolume,
    layers: nL,
    cellSize: s,
    millis: watch.elapsedMilliseconds,
    sizeX: maxX - minX,
    sizeY: maxY - minY,
    sizeZ: zTop,
  );
}

/// Sorts crossings [a, e) by x, keeping winding signs aligned.
void _sortCrossings(Float64List xs, Int8List ws, int a, int e) {
  final n = e - a;
  if (n <= 48) {
    for (int i = a + 1; i < e; i++) {
      final x = xs[i];
      final w = ws[i];
      int j = i - 1;
      while (j >= a && xs[j] > x) {
        xs[j + 1] = xs[j];
        ws[j + 1] = ws[j];
        j--;
      }
      xs[j + 1] = x;
      ws[j + 1] = w;
    }
    return;
  }
  final idx = List<int>.generate(n, (k) => a + k)..sort((p, q) => xs[p].compareTo(xs[q]));
  final sx = Float64List(n);
  final sw = Int8List(n);
  for (int k = 0; k < n; k++) {
    sx[k] = xs[idx[k]];
    sw[k] = ws[idx[k]];
  }
  xs.setRange(a, e, sx);
  ws.setRange(a, e, sw);
}
