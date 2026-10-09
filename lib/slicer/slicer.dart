import 'dart:math' as math;
import 'dart:typed_data';

import '../mesh/mesh.dart';
import 'settings.dart';
import '../i18n/i18n.dart';

/// Geometry-only result of a slice. Weight/length depend on material and are
/// derived with [grams] / [filamentMeters].
class SliceResult {
  /// Extruded plastic volume of the model for one copy, mm³.
  final double volumeMm3;

  /// Support material volume for one copy, mm³ (0 when supports are off).
  final double supportVolumeMm3;

  /// Brim + skirt on the first layer, mm³.
  final double brimVolumeMm3;

  /// Extrusion path lengths for the time estimate.
  final PathLengths lengths;

  /// Classified layers for the sliced view (null for an empty model).
  final SlicePreview? preview;

  /// Volume of the (scaled) model if printed 100% solid, mm³.
  final double solidVolumeMm3;
  final int layers;
  final double cellSize;
  final int millis;
  final double sizeX, sizeY, sizeZ;

  const SliceResult({
    required this.volumeMm3,
    required this.supportVolumeMm3,
    this.brimVolumeMm3 = 0,
    required this.lengths,
    this.preview,
    required this.solidVolumeMm3,
    required this.layers,
    required this.cellSize,
    required this.millis,
    required this.sizeX,
    required this.sizeY,
    required this.sizeZ,
  });

  double get totalVolumeMm3 => volumeMm3 + supportVolumeMm3 + brimVolumeMm3;

  /// Seconds of extrusion moves for one copy (no layer changes, no start-up).
  double movingSeconds(SliceSettings s) => printSeconds(s) - layerOverheadSeconds(layers, s);

  /// Estimated print time of one copy (without heating / start sequence).
  double printSeconds(SliceSettings s) => estimatePrintSeconds(
        outer: lengths.outer,
        inner: lengths.inner,
        solid: lengths.solid,
        sparse: lengths.sparse,
        support: lengths.support,
        firstLayer: lengths.firstLayer,
        layers: layers,
        settings: s,
      );

  /// Model + supports, for [copies] copies.
  double grams(double density, {int copies = 1}) => totalVolumeMm3 * density / 1000.0 * copies;

  double modelGrams(double density) => volumeMm3 * density / 1000.0;

  double supportGrams(double density) => supportVolumeMm3 * density / 1000.0;

  double brimGrams(double density) => brimVolumeMm3 * density / 1000.0;

  double solidGrams(double density) => solidVolumeMm3 * density / 1000.0;

  double filamentMeters(double diameter, {int copies = 1}) {
    final r = diameter / 2;
    return totalVolumeMm3 / (math.pi * r * r) / 1000.0 * copies;
  }

  Map<String, dynamic> toMap() => {
        'volumeMm3': volumeMm3,
        'supportVolumeMm3': supportVolumeMm3,
        'brimVolumeMm3': brimVolumeMm3,
        'lengths': lengths.toList(),
        if (preview != null) 'preview': preview!.toMap(),
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
        supportVolumeMm3: (m['supportVolumeMm3'] as num? ?? 0).toDouble(),
        brimVolumeMm3: (m['brimVolumeMm3'] as num? ?? 0).toDouble(),
        lengths: PathLengths.fromList(m['lengths']),
        preview: m['preview'] is Map ? SlicePreview.fromMap(m['preview'] as Map) : null,
        solidVolumeMm3: (m['solidVolumeMm3'] as num).toDouble(),
        layers: (m['layers'] as num).toInt(),
        cellSize: (m['cellSize'] as num).toDouble(),
        millis: (m['millis'] as num).toInt(),
        sizeX: (m['sizeX'] as num).toDouble(),
        sizeY: (m['sizeY'] as num).toDouble(),
        sizeZ: (m['sizeZ'] as num).toDouble(),
      );
}

/// Total extrusion path lengths of one copy, mm.
class PathLengths {
  final double outer, inner, solid, sparse, support, firstLayer;

  const PathLengths({
    this.outer = 0,
    this.inner = 0,
    this.solid = 0,
    this.sparse = 0,
    this.support = 0,
    this.firstLayer = 0,
  });

  double get total => outer + inner + solid + sparse + support + firstLayer;

  List<double> toList() => [outer, inner, solid, sparse, support, firstLayer];

  static PathLengths fromList(Object? raw) {
    if (raw is! List || raw.length < 6) return const PathLengths();
    double v(int i) => raw[i] is num ? (raw[i] as num).toDouble() : 0.0;
    return PathLengths(outer: v(0), inner: v(1), solid: v(2), sparse: v(3), support: v(4), firstLayer: v(5));
  }
}

/// Feature classes stored in [SlicePreview.classes].
class SliceClass {
  static const outerWall = 1;
  static const innerWall = 2;
  static const solid = 3;
  static const sparse = 4;
  static const support = 5;
  static const supportInterface = 6;
  static const adhesion = 7; // brim / skirt
}

/// Per-layer rectangles (slicer coordinates: scaled mm, bed at z = 0).
class SlicePreview {
  final Float32List rects; // x0, y0, x1, y1 per rectangle
  final Uint8List classes; // SliceClass per rectangle
  final Int32List layerStart; // rectangles of layer l: [layerStart[l], layerStart[l + 1])
  final Float32List zBottom, zTop;
  final double cell;

  const SlicePreview({
    required this.rects,
    required this.classes,
    required this.layerStart,
    required this.zBottom,
    required this.zTop,
    required this.cell,
  });

  int get layers => zTop.length;

  Map<String, Object> toMap() => {
        'rects': rects,
        'classes': classes,
        'layerStart': layerStart,
        'zBottom': zBottom,
        'zTop': zTop,
        'cell': cell,
      };

  static SlicePreview? fromMap(Map m) {
    final r = m['rects'], c = m['classes'], ls = m['layerStart'], zb = m['zBottom'], zt = m['zTop'];
    if (r is! Float32List || c is! Uint8List || ls is! Int32List || zb is! Float32List || zt is! Float32List) {
      return null;
    }
    return SlicePreview(
      rects: r,
      classes: c,
      layerStart: ls,
      zBottom: zb,
      zTop: zt,
      cell: (m['cell'] as num).toDouble(),
    );
  }
}

typedef ProgressCallback = void Function(double fraction);

/// Support model constants.
const double kSupportXyGapMm = 0.6;
const int kSupportInterfaceLayers = 2;
const double kSupportInterfaceDensity = 0.7;

/// Gap between the model (or its brim) and the skirt, mm.
const double kSkirtGapMm = 2.0;

/// Tree supports (Orca/Bambu style): tips under every overhang, branches
/// lean towards their neighbours by up to the branch angle per layer, merge
/// into thicker trunks, keep clear of the model and end on the bed (or on the
/// model). Branches are printed as hollow tubes of two walls.
const double kTreeTipSpacingMm = 3.0;
const double kTreeTipRadiusMm = 0.6;
const double kTreeMaxRadiusMm = 2.5;
const double kTreeGrowth = 0.0875; // tan(5°): radius gained per mm going down
const double kTreeBranchAngle = 40; // degrees from vertical
const double kTreeMergeSearchMm = 10.0;

class _TreeNode {
  double x, y, r;
  int born; // layer of the overhang it supports
  bool alive = true;

  _TreeNode(this.x, this.y, this.r, this.born);
}

/// Branch nodes of the tree support pass.
class _TreeSupport {
  final List<_TreeNode> nodes = [];

  int _key(double x, double y, double cell) =>
      ((x / cell).floor() + 100000) * 200003 + (y / cell).floor() + 100000;

  /// Adds tips over the overhang cells of a layer (Poisson-like sampling).
  void addTips(List<double> xs, List<double> ys, int born) {
    if (xs.isEmpty) return;
    const cell = kTreeTipSpacingMm;
    final grid = <int, List<_TreeNode>>{};
    for (final n in nodes) {
      grid.putIfAbsent(_key(n.x, n.y, cell), () => []).add(n);
    }
    const min2 = kTreeTipSpacingMm * kTreeTipSpacingMm * 0.64;
    for (int i = 0; i < xs.length; i++) {
      final x = xs[i], y = ys[i];
      final cx = (x / cell).floor(), cy = (y / cell).floor();
      bool near = false;
      for (int dx = -1; dx <= 1 && !near; dx++) {
        for (int dy = -1; dy <= 1 && !near; dy++) {
          final list = grid[(cx + dx + 100000) * 200003 + cy + dy + 100000];
          if (list == null) continue;
          for (final n in list) {
            final ex = n.x - x, ey = n.y - y;
            if (ex * ex + ey * ey < min2) {
              near = true;
              break;
            }
          }
        }
      }
      if (near) continue;
      final n = _TreeNode(x, y, kTreeTipRadiusMm, born);
      nodes.add(n);
      grid.putIfAbsent(_key(x, y, cell), () => []).add(n);
    }
  }

  /// Moves older nodes towards their nearest neighbour and merges touching ones.
  void moveAndMerge(int layer, double maxMove) {
    const cell = kTreeMergeSearchMm;
    final grid = <int, List<_TreeNode>>{};
    for (final n in nodes) {
      grid.putIfAbsent(_key(n.x, n.y, cell), () => []).add(n);
    }
    for (final n in nodes) {
      if (n.born - layer <= kSupportInterfaceLayers) continue; // tips hang straight first
      final cx = (n.x / cell).floor(), cy = (n.y / cell).floor();
      _TreeNode? best;
      double bestD = kTreeMergeSearchMm * kTreeMergeSearchMm;
      for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
          final list = grid[(cx + dx + 100000) * 200003 + cy + dy + 100000];
          if (list == null) continue;
          for (final o in list) {
            if (identical(o, n)) continue;
            final ex = o.x - n.x, ey = o.y - n.y;
            final d = ex * ex + ey * ey;
            if (d < bestD) {
              bestD = d;
              best = o;
            }
          }
        }
      }
      if (best == null) continue;
      final d = math.sqrt(bestD);
      if (d < 1e-6) continue;
      final step = math.min(maxMove, d / 2);
      n.x += (best.x - n.x) / d * step;
      n.y += (best.y - n.y) / d * step;
    }
    // Merge nodes whose branches overlap.
    for (int i = 0; i < nodes.length; i++) {
      final a = nodes[i];
      if (!a.alive) continue;
      for (int j = i + 1; j < nodes.length; j++) {
        final b = nodes[j];
        if (!b.alive) continue;
        final ex = a.x - b.x, ey = a.y - b.y;
        final lim = math.max(a.r, b.r) * 0.8;
        if (ex * ex + ey * ey > lim * lim) continue;
        final wa = a.r * a.r, wb = b.r * b.r;
        a.x = (a.x * wa + b.x * wb) / (wa + wb);
        a.y = (a.y * wa + b.y * wb) / (wa + wb);
        a.r = math.min(kTreeMaxRadiusMm, math.max(a.r, b.r));
        a.born = math.min(a.born, b.born);
        b.alive = false;
      }
    }
    nodes.removeWhere((n) => !n.alive);
  }
}

/// Bounding box and fill statistics of one rasterised layer.
class _LayerInfo {
  int x0 = 0, y0 = 0, x1 = -1, y1 = -1;
  int count = 0;
  double area = 0;

  void copyFrom(_LayerInfo o) {
    x0 = o.x0;
    y0 = o.y0;
    x1 = o.x1;
    y1 = o.y1;
    count = o.count;
    area = o.area;
  }
}

/// Layer-by-layer slicer.
///
/// Every layer is cut from the mesh, rasterised with the non-zero winding rule
/// and split into: perimeters (distance to the outline < walls × line width),
/// solid top/bottom skin (area not covered by the N layers above/below) and
/// sparse infill (the rest, multiplied by the infill density). The raster
/// area is corrected to the exact polygon area of each layer.
///
/// Supports (optional) are computed in a second, top-down pass: a cell of
/// layer i+1 overhangs when no model cell of layer i is within
/// layerHeight × tan(angle). Overhangs start a support column that runs down
/// until it meets the model (or, for "build plate only", only exists where
/// nothing of the model is below it).
SliceResult sliceMesh(
  Float32List source,
  SliceSettings st, {
  ProgressCallback? onProgress,
  int maxCellsPerSide = 500,
}) {
  final watch = Stopwatch()..start();
  if (st.vaseMode) {
    st = st.copyWith(walls: 1, topLayers: 0, infillPercent: 0, ensureVerticalShell: false);
  }
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
    return const SliceResult(
      volumeMm3: 0,
      supportVolumeMm3: 0,
      lengths: PathLengths(),
      solidVolumeMm3: 0,
      layers: 0,
      cellSize: 0,
      millis: 0,
      sizeX: 0,
      sizeY: 0,
      sizeZ: 0,
    );
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
    if (nL > 50000) throw StateError(tr('Забагато шарів — перевірте масштаб моделі'));
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
  final brimW = st.brimWidth > 0 ? st.brimWidth : 0.0;
  final skirtW = st.skirtLoops > 0 ? st.skirtLoops * lineW : 0.0;
  final adhesion = brimW + (skirtW > 0 ? kSkirtGapMm + skirtW : 0.0);
  final s = math.max(0.1, math.max(lineW * 0.5, (side + 2 * adhesion) / maxCellsPerSide));
  final pad = 3 * s + adhesion;
  final ox = minX - pad, oy = minY - pad;
  final nx = ((maxX - minX + 2 * pad) / s).ceil() + 1;
  final ny = ((maxY - minY + 2 * pad) / s).ceil() + 1;
  final nCells = nx * ny;

  // Triangles bucketed by the layers whose cutting plane they cross,
  // so any layer can be generated in any order.
  int firstLayerAtOrAbove(double z) {
    int lo = 0, hi = nL;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (mids[m] < z) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  final triLo = Int32List(nT), triHi = Int32List(nT);
  final layerStart = Int32List(nL + 1);
  for (int k = 0; k < nT; k++) {
    final b = k * 9;
    final zl = math.min(t[b + 2], math.min(t[b + 5], t[b + 8]));
    final zh = math.max(t[b + 2], math.max(t[b + 5], t[b + 8]));
    final lo = firstLayerAtOrAbove(zl);
    final hi = firstLayerAtOrAbove(zh) - 1; // last layer with mid < zh
    triLo[k] = lo;
    triHi[k] = hi;
    for (int l = lo; l <= hi; l++) {
      layerStart[l + 1]++;
    }
  }
  for (int l = 0; l < nL; l++) {
    layerStart[l + 1] += layerStart[l];
  }
  final totalRefs = layerStart[nL];
  if (totalRefs > 60000000) throw StateError(tr('Модель надто складна для телефона'));
  final layerTris = Int32List(totalRefs);
  {
    final fill = Int32List.fromList(Int32List.sublistView(layerStart, 0, nL));
    for (int k = 0; k < nT; k++) {
      for (int l = triLo[k]; l <= triHi[k]; l++) {
        layerTris[fill[l]++] = k;
      }
    }
  }

  // Scratch buffers.
  var seg = Float64List(4096); // x1,y1,x2,y2
  var crossX = Float64List(4096);
  var crossW = Int8List(4096);
  final rowStart = Int32List(ny + 1);
  final rowFill = Int32List(ny);

  /// Cuts layer [li] and rasterises it into [mask]; fills [info].
  void genLayer(int li, Uint8List mask, _LayerInfo info) {
    mask.fillRange(0, nCells, 0);
    final z = mids[li];
    int nSeg = 0;
    double area2 = 0;
    double sMinX = double.infinity, sMinY = double.infinity;
    double sMaxX = -double.infinity, sMaxY = -double.infinity;

    for (int r = layerStart[li]; r < layerStart[li + 1]; r++) {
      final b = layerTris[r] * 9;
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

    info.area = area2.abs() / 2;
    info.count = 0;
    if (nSeg == 0) {
      info.x0 = 0;
      info.y0 = 0;
      info.x1 = -1;
      info.y1 = -1;
      return;
    }
    final cx0 = math.max(0, ((sMinX - ox) / s).floor() - 1);
    final cy0 = math.max(0, ((sMinY - oy) / s).floor() - 1);
    final cx1 = math.min(nx - 1, ((sMaxX - ox) / s).floor() + 1);
    final cy1 = math.min(ny - 1, ((sMaxY - oy) / s).floor() + 1);
    info.x0 = cx0;
    info.y0 = cy0;
    info.x1 = cx1;
    info.y1 = cy1;

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
    info.count = count;
  }

  final top = st.topLayers < 0 ? 0 : st.topLayers;
  final bottom = st.bottomLayers < 0 ? 0 : st.bottomLayers;
  final ringSize = top + bottom + 1;
  final ring = List<Uint8List>.generate(ringSize, (_) => Uint8List(nCells));
  final ringInfo = List<_LayerInfo>.generate(ringSize, (_) => _LayerInfo());

  final ringDist = List<Float32List>.generate(ringSize, (_) => Float32List(nCells));

  final supports = st.supportsEnabled;
  // Lowest model layer per cell (for "build plate only" supports).
  final firstModelLayer = supports && st.supportPlateOnly ? (Int32List(nCells)..fillRange(0, nCells, 1 << 30)) : null;

  const r2 = 1.41421356;

  /// Chamfer distance (in cells) from every filled cell to the outside.
  void distanceToOutside(Uint8List mask, _LayerInfo info, Float32List dist) {
    final x0 = info.x0, y0 = info.y0, x1 = info.x1, y1 = info.y1;
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
  }

  // Coarser grid for the layer preview: each preview cell samples the
  // full-resolution cell under its centre.
  double pc = math.max(s, side / 200);
  int pnx = 1, pny = 1;
  while (true) {
    pnx = math.max(1, (nx * s / pc).floor());
    pny = math.max(1, (ny * s / pc).floor());
    if (nL * pnx * pny <= 30000000) break;
    pc *= 1.25;
  }
  final pn = pnx * pny;
  final previewCls = Uint8List(nL * pn);
  final centerMap = Int32List(nCells)..fillRange(0, nCells, -1);
  for (int py = 0; py < pny; py++) {
    final fy = ((py + 0.5) * pc / s).floor();
    if (fy >= ny) continue;
    for (int px = 0; px < pnx; px++) {
      final fx = ((px + 0.5) * pc / s).floor();
      if (fx >= nx) continue;
      centerMap[fy * nx + fx] = py * pnx + px;
    }
  }

  // Sparse infill / support are drawn as line patterns when the preview grid
  // is fine enough, otherwise as filled areas.
  final linesVisible = pc <= lineW * 0.8;
  bool onGrid(int pIdx, double spacing, bool bothAxes) {
    if (!linesVisible || spacing <= 0 || spacing.isInfinite) return true;
    final xc = ox + (pIdx % pnx + 0.5) * pc;
    final yc = oy + (pIdx ~/ pnx + 0.5) * pc;
    if (yc % spacing < lineW) return true;
    return bothAxes && xc % spacing < lineW;
  }

  final wallCells = st.walls * lineW / s + 0.5;
  final outerCells = lineW / s + 0.5;
  final ensureVertical = st.ensureVerticalShell;
  final double infill = (st.infillPercent / 100.0).clamp(0.0, 1.0).toDouble();
  double volume = 0;
  double outerLen = 0, innerLen = 0, solidLen = 0, sparseLen = 0, supportLen = 0, firstLen = 0;
  int generated = 0;
  final progressStep = math.max(1, nL ~/ 100);
  final modelShare = supports ? 0.6 : 1.0;

  for (int i = 0; i < nL; i++) {
    final want = math.min(i + top, nL - 1);
    while (generated <= want) {
      final gs = generated % ringSize;
      genLayer(generated, ring[gs], ringInfo[gs]);
      if (ringInfo[gs].count > 0) distanceToOutside(ring[gs], ringInfo[gs], ringDist[gs]);
      final fm = firstModelLayer;
      if (fm != null) {
        final inf = ringInfo[gs];
        final m = ring[gs];
        for (int y = inf.y0; y <= inf.y1; y++) {
          final row = y * nx;
          for (int x = inf.x0; x <= inf.x1; x++) {
            if (m[row + x] != 0 && fm[row + x] > generated) fm[row + x] = generated;
          }
        }
      }
      generated++;
    }
    final slot = i % ringSize;
    final info = ringInfo[slot];
    final nIn = info.count;
    if (onProgress != null && i % progressStep == 0) onProgress(i / nL * modelShare);
    if (nIn == 0) continue;
    final mask = ring[slot];
    final dist = ringDist[slot];
    final x0 = info.x0, y0 = info.y0;
    final x1 = info.x1, y1 = info.y1;
    final pBase = i * pn;

    int shell = 0, outer = 0, solid = 0, sparse = 0;
    for (int y = y0; y <= y1; y++) {
      final row = y * nx;
      for (int x = x0; x <= x1; x++) {
        final idx = row + x;
        if (mask[idx] == 0) continue;
        int cls;
        final d = dist[idx];
        if (d < wallCells) {
          shell++;
          if (d < outerCells) {
            outer++;
            cls = 1;
          } else {
            cls = 2;
          }
        } else {
          // Solid where the cell is not deep inside the model in every one of
          // the neighbouring top/bottom layers ("ensure vertical shell
          // thickness" also counts the neighbours' perimeters as surface).
          bool isSolid = false;
          for (int k = 1; k <= top && !isSolid; k++) {
            final l = i + k;
            if (l >= nL) {
              isSolid = true;
            } else {
              final ls = l % ringSize;
              if (ring[ls][idx] == 0 || (ensureVertical && ringDist[ls][idx] < wallCells)) isSolid = true;
            }
          }
          for (int k = 1; k <= bottom && !isSolid; k++) {
            final l = i - k;
            if (l < 0) {
              isSolid = true;
            } else {
              final ls = l % ringSize;
              if (ring[ls][idx] == 0 || (ensureVertical && ringDist[ls][idx] < wallCells)) isSolid = true;
            }
          }
          if (isSolid) {
            solid++;
            cls = 3;
          } else {
            sparse++;
            cls = 4;
          }
        }
        final pIdx = centerMap[idx];
        if (pIdx >= 0) {
          if (cls == 4) {
            // Grid infill: two line directions share the density.
            if (infill <= 0 || (infill < 0.99 && !onGrid(pIdx, 2 * lineW / infill, true))) cls = 0;
          }
          previewCls[pBase + pIdx] = cls;
        }
      }
    }

    final rasterArea = nIn * s * s;
    double corr = info.area / rasterArea;
    if (!(corr > 0.7 && corr < 1.4)) corr = 1.0;
    final cellArea = s * s * corr;
    volume += heights[i] * cellArea * (shell + solid + infill * sparse);
    if (i == 0) {
      firstLen += cellArea * (shell + solid + infill * sparse) / lineW;
    } else {
      outerLen += cellArea * outer / lineW;
      innerLen += cellArea * (shell - outer) / lineW;
      solidLen += cellArea * solid / lineW;
      sparseLen += cellArea * sparse * infill / lineW;
    }
  }

  // ---- Supports: top-down pass. ----
  double supportVolume = 0;
  if (supports && nL > 1) {
    final angle = st.supportAngle.clamp(5.0, 89.0).toDouble() * math.pi / 180.0;
    final double density = (st.supportDensity / 100.0).clamp(0.0, 1.0).toDouble();
    final gapCells = kSupportXyGapMm / s;
    final tree = st.isTreeSupport;
    final treeNodes = _TreeSupport();
    final mark = tree ? (Int32List(nCells)..fillRange(0, nCells, -1)) : null;
    final maxMove = h * math.tan(kTreeBranchAngle * math.pi / 180);
    final wallBand = 2 * lineW;
    // "Build plate only" trees must also steer clear of everything below.
    final avoidPlate = tree && firstModelLayer != null ? Float32List(nCells) : null;

    void chamfer(Float32List d, int x0, int y0, int x1, int y1) {
      for (int y = y0; y <= y1; y++) {
        final row = y * nx;
        for (int x = x0; x <= x1; x++) {
          final idx = row + x;
          double v = d[idx];
          if (v == 0) continue;
          if (x > x0 && d[idx - 1] + 1 < v) v = d[idx - 1] + 1;
          if (y > y0) {
            if (d[idx - nx] + 1 < v) v = d[idx - nx] + 1;
            if (x > x0 && d[idx - nx - 1] + r2 < v) v = d[idx - nx - 1] + r2;
            if (x < x1 && d[idx - nx + 1] + r2 < v) v = d[idx - nx + 1] + r2;
          }
          d[idx] = v;
        }
      }
      for (int y = y1; y >= y0; y--) {
        final row = y * nx;
        for (int x = x1; x >= x0; x--) {
          final idx = row + x;
          double v = d[idx];
          if (v == 0) continue;
          if (x < x1 && d[idx + 1] + 1 < v) v = d[idx + 1] + 1;
          if (y < y1) {
            if (d[idx + nx] + 1 < v) v = d[idx + nx] + 1;
            if (x < x1 && d[idx + nx + 1] + r2 < v) v = d[idx + nx + 1] + r2;
            if (x > x0 && d[idx + nx - 1] + r2 < v) v = d[idx + nx - 1] + r2;
          }
          d[idx] = v;
        }
      }
    }
    final inColumn = Uint8List(nCells);
    final srcLayer = Int32List(nCells); // layer where the column's overhang is
    final dist = Float32List(nCells);
    var maskUp = ring[0];
    var maskHere = ringSize > 1 ? ring[1] : Uint8List(nCells);
    final infoUp = _LayerInfo(), infoHere = _LayerInfo();
    int sx0 = nx, sy0 = ny, sx1 = -1, sy1 = -1; // bbox of active columns
    genLayer(nL - 1, maskUp, infoUp);

    for (int k = nL - 2; k >= 0; k--) {
      if (onProgress != null && k % progressStep == 0) {
        onProgress(modelShare + (1 - modelShare) * (nL - 1 - k) / nL);
      }
      genLayer(k, maskHere, infoHere);

      // Region where distances are needed.
      int rx0 = nx, ry0 = ny, rx1 = -1, ry1 = -1;
      void grow(int ax0, int ay0, int ax1, int ay1) {
        if (ax1 < ax0 || ay1 < ay0) return;
        if (ax0 < rx0) rx0 = ax0;
        if (ay0 < ry0) ry0 = ay0;
        if (ax1 > rx1) rx1 = ax1;
        if (ay1 > ry1) ry1 = ay1;
      }

      grow(infoHere.x0, infoHere.y0, infoHere.x1, infoHere.y1);
      grow(infoUp.x0, infoUp.y0, infoUp.x1, infoUp.y1);
      grow(sx0, sy0, sx1, sy1);
      if (tree && treeNodes.nodes.isNotEmpty) grow(0, 0, nx - 1, ny - 1);

      if (rx1 >= rx0 && ry1 >= ry0) {
        // Distance (cells) to the nearest model cell of layer k.
        for (int y = ry0; y <= ry1; y++) {
          final row = y * nx;
          for (int x = rx0; x <= rx1; x++) {
            dist[row + x] = maskHere[row + x] != 0 ? 0.0 : 1e9;
          }
        }
        for (int y = ry0; y <= ry1; y++) {
          final row = y * nx;
          for (int x = rx0; x <= rx1; x++) {
            final idx = row + x;
            double v = dist[idx];
            if (v == 0) continue;
            if (x > rx0) {
              final c = dist[idx - 1] + 1;
              if (c < v) v = c;
            }
            if (y > ry0) {
              double c = dist[idx - nx] + 1;
              if (c < v) v = c;
              if (x > rx0) {
                c = dist[idx - nx - 1] + r2;
                if (c < v) v = c;
              }
              if (x < rx1) {
                c = dist[idx - nx + 1] + r2;
                if (c < v) v = c;
              }
            }
            dist[idx] = v;
          }
        }
        for (int y = ry1; y >= ry0; y--) {
          final row = y * nx;
          for (int x = rx1; x >= rx0; x--) {
            final idx = row + x;
            double v = dist[idx];
            if (v == 0) continue;
            if (x < rx1) {
              final c = dist[idx + 1] + 1;
              if (c < v) v = c;
            }
            if (y < ry1) {
              double c = dist[idx + nx] + 1;
              if (c < v) v = c;
              if (x < rx1) {
                c = dist[idx + nx + 1] + r2;
                if (c < v) v = c;
              }
              if (x > rx0) {
                c = dist[idx + nx - 1] + r2;
                if (c < v) v = c;
              }
            }
            dist[idx] = v;
          }
        }

        // Overhangs of layer k+1 start new support columns.
        final reach = heights[k + 1] * math.tan(angle) / s + 0.5;
        if (tree) {
          final tipsX = <double>[], tipsY = <double>[];
          for (int y = infoUp.y0; y <= infoUp.y1; y++) {
            final row = y * nx;
            for (int x = infoUp.x0; x <= infoUp.x1; x++) {
              final idx = row + x;
              if (maskUp[idx] != 0 && dist[idx] > reach) {
                tipsX.add(ox + (x + 0.5) * s);
                tipsY.add(oy + (y + 0.5) * s);
              }
            }
          }
          treeNodes.addTips(tipsX, tipsY, k + 1);
          treeNodes.moveAndMerge(k, maxMove);
          int ringCells = 0, denseCells = 0;
          final fm = firstModelLayer;
          // Distance used for steering: to the model at this layer, or (bed
          // only) to anything of the model at or below this layer.
          Float32List avoid = dist;
          final ap = avoidPlate;
          if (ap != null && fm != null) {
            for (int i = 0; i < nCells; i++) {
              ap[i] = (maskHere[i] != 0 || fm[i] <= k) ? 0.0 : 1e9;
            }
            chamfer(ap, 0, 0, nx - 1, ny - 1);
            avoid = ap;
          }
          final gapMm = kSupportXyGapMm;
          for (final n in treeNodes.nodes) {
            // Keep clear of the model: step towards larger distance.
            int ci = ((n.x - ox) / s).floor(), cj = ((n.y - oy) / s).floor();
            if (ci < 0 || cj < 0 || ci >= nx || cj >= ny) {
              n.alive = false;
              continue;
            }
            if (avoid[cj * nx + ci] * s < n.r + gapMm) {
              final steps = math.max(1, (maxMove * 2 / s).ceil());
              double bestD = avoid[cj * nx + ci];
              int bi = ci, bj = cj;
              for (int dj = -steps; dj <= steps; dj++) {
                for (int di = -steps; di <= steps; di++) {
                  final ii = ci + di, jj = cj + dj;
                  if (ii < 0 || jj < 0 || ii >= nx || jj >= ny) continue;
                  final v = avoid[jj * nx + ii];
                  if (v > bestD) {
                    bestD = v;
                    bi = ii;
                    bj = jj;
                  }
                }
              }
              ci = bi;
              cj = bj;
              n.x = ox + (ci + 0.5) * s;
              n.y = oy + (cj + 0.5) * s;
            }
            final cidx = cj * nx + ci;
            // Landed on the model (or blocked when only the bed may be used).
            if (maskHere[cidx] != 0 || avoid[cidx] * s < n.r * 0.5) {
              n.alive = false;
              continue;
            }
            final depth = n.born - k;
            final dense = depth <= kSupportInterfaceLayers;
            final rc = (n.r / s).ceil();
            final rr2 = n.r * n.r;
            final mk = mark!;
            final inner = n.r - wallBand;
            final inner2 = inner > 0 ? inner * inner : -1.0;
            for (int j = math.max(0, cj - rc); j <= math.min(ny - 1, cj + rc); j++) {
              final yy = oy + (j + 0.5) * s - n.y;
              for (int i = math.max(0, ci - rc); i <= math.min(nx - 1, ci + rc); i++) {
                final xx = ox + (i + 0.5) * s - n.x;
                final d2 = xx * xx + yy * yy;
                if (d2 > rr2) continue;
                final idx = j * nx + i;
                if (maskHere[idx] != 0 || dist[idx] <= gapCells) continue;
                if (fm != null && fm[idx] <= k) continue;
                if (mk[idx] == k) continue;
                if (!dense && d2 < inner2) continue; // hollow branch
                mk[idx] = k;
                if (dense) {
                  denseCells++;
                } else {
                  ringCells++;
                }
                final pIdx = centerMap[idx];
                if (pIdx >= 0) previewCls[k * pn + pIdx] = dense ? 6 : 5;
              }
            }
            n.r = math.min(kTreeMaxRadiusMm, n.r + h * kTreeGrowth);
          }
          treeNodes.nodes.removeWhere((n) => !n.alive);
          final supArea = s * s * (ringCells + denseCells * kSupportInterfaceDensity);
          supportVolume += heights[k] * supArea;
          if (k == 0) {
            firstLen += supArea / lineW;
          } else {
            supportLen += supArea / lineW;
          }
        } else {
        for (int y = infoUp.y0; y <= infoUp.y1; y++) {
          final row = y * nx;
          for (int x = infoUp.x0; x <= infoUp.x1; x++) {
            final idx = row + x;
            if (maskUp[idx] != 0 && dist[idx] > reach) {
              inColumn[idx] = 1;
              srcLayer[idx] = k + 1;
              if (x < sx0) sx0 = x;
              if (y < sy0) sy0 = y;
              if (x > sx1) sx1 = x;
              if (y > sy1) sy1 = y;
            }
          }
        }

        // Count support cells of layer k.
        int sparseCells = 0, denseCells = 0;
        final fm = firstModelLayer;
        for (int y = sy0; y <= sy1; y++) {
          final row = y * nx;
          for (int x = sx0; x <= sx1; x++) {
            final idx = row + x;
            if (inColumn[idx] == 0) continue;
            if (maskHere[idx] != 0) {
              inColumn[idx] = 0; // column lands on the model
              continue;
            }
            if (dist[idx] <= gapCells) continue;
            if (fm != null && fm[idx] <= k) continue;
            final dense = srcLayer[idx] - k <= kSupportInterfaceLayers;
            if (dense) {
              denseCells++;
            } else {
              sparseCells++;
            }
            final pIdx = centerMap[idx];
            if (pIdx >= 0 && (dense || (density > 0 && onGrid(pIdx, lineW / density, false)))) {
              previewCls[k * pn + pIdx] = dense ? 6 : 5;
            }
          }
        }
        final supArea = s * s * (sparseCells * density + denseCells * kSupportInterfaceDensity);
        supportVolume += heights[k] * supArea;
        if (k == 0) {
          firstLen += supArea / lineW;
        } else {
          supportLen += supArea / lineW;
        }
        }
      }

      // Layer k becomes the "upper" layer for k-1.
      final tm = maskUp;
      maskUp = maskHere;
      maskHere = tm;
      infoUp.copyFrom(infoHere);
    }
  }
  // ---- Brim and skirt around the first layer. ----
  double brimVolume = 0;
  if (adhesion > 0) {
    final base = Uint8List(nCells);
    final info0 = _LayerInfo();
    genLayer(0, base, info0);
    if (info0.count > 0) {
      // Outside cells reachable from the border (no brim inside holes).
      final outside = Uint8List(nCells);
      final queue = Int32List(nCells);
      int qh = 0, qt = 0;
      void seed(int idx) {
        if (base[idx] == 0 && outside[idx] == 0) {
          outside[idx] = 1;
          queue[qt++] = idx;
        }
      }

      for (int x = 0; x < nx; x++) {
        seed(x);
        seed((ny - 1) * nx + x);
      }
      for (int y = 0; y < ny; y++) {
        seed(y * nx);
        seed(y * nx + nx - 1);
      }
      while (qh < qt) {
        final idx = queue[qh++];
        final x = idx % nx, y = idx ~/ nx;
        if (x > 0) seed(idx - 1);
        if (x < nx - 1) seed(idx + 1);
        if (y > 0) seed(idx - nx);
        if (y < ny - 1) seed(idx + nx);
      }
      // Distance (cells) from the model.
      final d = Float32List(nCells);
      for (int i = 0; i < nCells; i++) {
        d[i] = base[i] != 0 ? 0.0 : 1e9;
      }
      for (int y = 0; y < ny; y++) {
        final row = y * nx;
        for (int x = 0; x < nx; x++) {
          final idx = row + x;
          double v = d[idx];
          if (v == 0) continue;
          if (x > 0 && d[idx - 1] + 1 < v) v = d[idx - 1] + 1;
          if (y > 0) {
            if (d[idx - nx] + 1 < v) v = d[idx - nx] + 1;
            if (x > 0 && d[idx - nx - 1] + r2 < v) v = d[idx - nx - 1] + r2;
            if (x < nx - 1 && d[idx - nx + 1] + r2 < v) v = d[idx - nx + 1] + r2;
          }
          d[idx] = v;
        }
      }
      for (int y = ny - 1; y >= 0; y--) {
        final row = y * nx;
        for (int x = nx - 1; x >= 0; x--) {
          final idx = row + x;
          double v = d[idx];
          if (v == 0) continue;
          if (x < nx - 1 && d[idx + 1] + 1 < v) v = d[idx + 1] + 1;
          if (y < ny - 1) {
            if (d[idx + nx] + 1 < v) v = d[idx + nx] + 1;
            if (x < nx - 1 && d[idx + nx + 1] + r2 < v) v = d[idx + nx + 1] + r2;
            if (x > 0 && d[idx + nx - 1] + r2 < v) v = d[idx + nx - 1] + r2;
          }
          d[idx] = v;
        }
      }
      final skirtFrom = brimW + kSkirtGapMm, skirtTo = skirtFrom + skirtW;
      int cells = 0;
      for (int idx = 0; idx < nCells; idx++) {
        if (outside[idx] == 0) continue;
        final mm = (d[idx] - 0.5) * s;
        final inBrim = brimW > 0 && mm < brimW;
        final inSkirt = skirtW > 0 && mm >= skirtFrom && mm < skirtTo;
        if (!inBrim && !inSkirt) continue;
        cells++;
        final pIdx = centerMap[idx];
        if (pIdx >= 0) previewCls[pIdx] = SliceClass.adhesion;
      }
      final area = cells * s * s;
      brimVolume = area * heights[0];
      firstLen += area / lineW;
    }
  }

  // ---- Layer preview: merge equal cells into rectangles. ----
  final rects = FloatBuf(1 << 14);
  final rectCls = IntBuf(1 << 12);
  final layerRectStart = Int32List(nL + 1);
  final zBottom = Float32List(nL), zTopArr = Float32List(nL);
  {
    final open = <int, int>{};
    final next = <int, int>{};
    double zb = 0;
    for (int l = 0; l < nL; l++) {
      zBottom[l] = zb;
      zb += heights[l];
      zTopArr[l] = zb;
      layerRectStart[l] = rectCls.length;
      open.clear();
      final base = l * pn;
      for (int py = 0; py < pny; py++) {
        next.clear();
        final row = base + py * pnx;
        int px = 0;
        while (px < pnx) {
          final c = previewCls[row + px];
          if (c == 0) {
            px++;
            continue;
          }
          final start = px;
          while (px < pnx && previewCls[row + px] == c) {
            px++;
          }
          final key = (start * 8192 + px) * 8 + c;
          final existing = open[key];
          if (existing != null) {
            rects.setAt(existing * 4 + 3, oy + (py + 1) * pc);
            next[key] = existing;
          } else {
            final id = rectCls.length;
            rects.add(ox + start * pc);
            rects.add(oy + py * pc);
            rects.add(ox + px * pc);
            rects.add(oy + (py + 1) * pc);
            rectCls.add(c);
            next[key] = id;
          }
        }
        open
          ..clear()
          ..addAll(next);
      }
    }
    layerRectStart[nL] = rectCls.length;
  }
  final preview = SlicePreview(
    rects: rects.toList(),
    classes: Uint8List.fromList(rectCls.toList()),
    layerStart: layerRectStart,
    zBottom: zBottom,
    zTop: zTopArr,
    cell: pc,
  );

  onProgress?.call(1.0);

  return SliceResult(
    volumeMm3: volume,
    supportVolumeMm3: supportVolume,
    brimVolumeMm3: brimVolume,
    lengths: PathLengths(
      outer: outerLen,
      inner: innerLen,
      solid: solidLen,
      sparse: sparseLen,
      support: supportLen,
      firstLayer: firstLen,
    ),
    preview: preview,
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
