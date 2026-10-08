import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../mesh/loader.dart';

/// Interactive 3D preview: drag to rotate, pinch to zoom/pan, double tap to reset.
class ModelViewer extends StatefulWidget {
  final LoadedModel model;
  final Color color;

  const ModelViewer({super.key, required this.model, required this.color});

  @override
  State<ModelViewer> createState() => _ModelViewerState();
}

class _ModelViewerState extends State<ModelViewer> {
  static const _defaultYaw = -0.7;
  static const _defaultPitch = 0.5;

  double _yaw = _defaultYaw;
  double _pitch = _defaultPitch;
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  double _zoomAtStart = 1.0;
  late _ViewCache _cache;

  @override
  void initState() {
    super.initState();
    _cache = _ViewCache(widget.model.viewTris.length ~/ 9);
  }

  @override
  void didUpdateWidget(covariant ModelViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      _cache = _ViewCache(widget.model.viewTris.length ~/ 9);
      _reset();
    }
  }

  void _reset() {
    _yaw = _defaultYaw;
    _pitch = _defaultPitch;
    _zoom = 1.0;
    _pan = Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => setState(_reset),
      onScaleStart: (d) => _zoomAtStart = _zoom,
      onScaleUpdate: (d) {
        setState(() {
          if (d.pointerCount >= 2) {
            _zoom = (_zoomAtStart * d.scale).clamp(0.2, 30.0).toDouble();
            _pan += d.focalPointDelta;
          } else {
            _yaw += d.focalPointDelta.dx * 0.01;
            _pitch = (_pitch + d.focalPointDelta.dy * 0.01).clamp(-1.55, 1.55).toDouble();
          }
        });
      },
      child: ClipRect(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ModelPainter(
            model: widget.model,
            cache: _cache,
            yaw: _yaw,
            pitch: _pitch,
            zoom: _zoom,
            pan: _pan,
            color: widget.color,
            gridColor: scheme.onSurface.withValues(alpha: 0.12),
          ),
        ),
      ),
    );
  }
}

class _ViewCache {
  final Float32List proj; // 3 screen vertices per triangle (x, y)
  final Float32List depth;
  final Int32List shade; // ARGB per triangle
  final Int32List visible;
  final Int32List order;
  final Float32List positions;
  final Int32List colors;
  final Int32List buckets = Int32List(_buckets + 1);
  static const _buckets = 8192;

  _ViewCache(int n)
      : proj = Float32List(n * 6),
        depth = Float32List(n),
        shade = Int32List(n),
        visible = Int32List(n),
        order = Int32List(n),
        positions = Float32List(n * 6),
        colors = Int32List(n * 3);
}

class _ModelPainter extends CustomPainter {
  final LoadedModel model;
  final _ViewCache cache;
  final double yaw, pitch, zoom;
  final Offset pan;
  final Color color;
  final Color gridColor;

  _ModelPainter({
    required this.model,
    required this.cache,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.pan,
    required this.color,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final b = model.bounds;
    final radius = math.max(1e-3, math.sqrt(b.sizeX * b.sizeX + b.sizeY * b.sizeY + b.sizeZ * b.sizeZ) / 2);
    final scale = math.min(size.width, size.height) * 0.46 / radius * zoom;
    final cx = size.width / 2 + pan.dx;
    final cy = size.height / 2 + pan.dy;
    final cyw = math.cos(yaw), syw = math.sin(yaw);
    final cp = math.cos(pitch), sp = math.sin(pitch);

    Offset project(double x, double y, double z) {
      final x1 = x * cyw - y * syw;
      final y1 = x * syw + y * cyw;
      final up = z * cp + y1 * sp;
      return Offset(cx + x1 * scale, cy - up * scale);
    }

    // Bed grid under the model.
    final zBed = -b.sizeZ / 2;
    final span = math.max(b.sizeX, b.sizeY) * 0.8 + 5;
    final step = _niceStep(span * 2 / 12);
    final half = (span / step).ceil() * step;
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (double v = -half; v <= half + 1e-6; v += step) {
      canvas.drawLine(project(v, -half, zBed), project(v, half, zBed), gridPaint);
      canvas.drawLine(project(-half, v, zBed), project(half, v, zBed), gridPaint);
    }

    final tris = model.viewTris;
    final normals = model.viewNormals;
    final n = tris.length ~/ 9;
    final cull = model.outwardNormals;
    final flip = cull ? 1.0 : -1.0;
    final proj = cache.proj, depth = cache.depth, shade = cache.shade, vis = cache.visible;
    final br = color.r, bg = color.g, bb = color.b; // 0..1

    // Light direction in view space (right, up, towards viewer).
    const lr = -0.35, lu = 0.55, lt = 0.76;
    int vc = 0;
    double minD = double.infinity, maxD = -double.infinity;
    for (int t = 0; t < n; t++) {
      final nx = normals[t * 3] * flip, ny = normals[t * 3 + 1] * flip, nz = normals[t * 3 + 2] * flip;
      final nx1 = nx * cyw - ny * syw;
      final ny1 = nx * syw + ny * cyw;
      final nu = nz * cp + ny1 * sp;
      final nd = ny1 * cp - nz * sp; // >0 points away from the viewer
      if (cull && nd > 1e-4) continue;
      double dot = nx1 * lr + nu * lu - nd * lt;
      if (!cull) dot = dot.abs();
      final light = 0.30 + 0.70 * (dot > 0 ? dot : 0);
      final r = _channel(br * light);
      final g = _channel(bg * light);
      final bl = _channel(bb * light);
      shade[t] = (0xFF << 24) | (r << 16) | (g << 8) | bl;

      double dsum = 0;
      final o = t * 9;
      for (int v = 0; v < 3; v++) {
        final x = tris[o + v * 3], y = tris[o + v * 3 + 1], z = tris[o + v * 3 + 2];
        final x1 = x * cyw - y * syw;
        final y1 = x * syw + y * cyw;
        final up = z * cp + y1 * sp;
        dsum += y1 * cp - z * sp;
        proj[t * 6 + v * 2] = cx + x1 * scale;
        proj[t * 6 + v * 2 + 1] = cy - up * scale;
      }
      depth[t] = dsum;
      if (dsum < minD) minD = dsum;
      if (dsum > maxD) maxD = dsum;
      vis[vc++] = t;
    }
    if (vc == 0) return;

    // Bucket sort, far triangles first (painter's algorithm).
    const nb = _ViewCache._buckets;
    final buckets = cache.buckets;
    buckets.fillRange(0, nb + 1, 0);
    final inv = maxD > minD ? (nb - 1) / (maxD - minD) : 0.0;
    for (int k = 0; k < vc; k++) {
      final key = nb - 1 - ((depth[vis[k]] - minD) * inv).toInt();
      buckets[key + 1]++;
    }
    for (int k = 0; k < nb; k++) {
      buckets[k + 1] += buckets[k];
    }
    final order = cache.order;
    for (int k = 0; k < vc; k++) {
      final t = vis[k];
      final key = nb - 1 - ((depth[t] - minD) * inv).toInt();
      order[buckets[key]++] = t;
    }

    final pos = cache.positions, cols = cache.colors;
    for (int k = 0; k < vc; k++) {
      final t = order[k];
      pos.setRange(k * 6, k * 6 + 6, proj, t * 6);
      final c = shade[t];
      cols[k * 3] = c;
      cols[k * 3 + 1] = c;
      cols[k * 3 + 2] = c;
    }
    final vertices = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.sublistView(pos, 0, vc * 6),
      colors: Int32List.sublistView(cols, 0, vc * 3),
    );
    canvas.drawVertices(vertices, BlendMode.dst, Paint());
    vertices.dispose();
  }

  static int _channel(double v) {
    final x = (v * 255).round();
    return x < 0 ? 0 : (x > 255 ? 255 : x);
  }

  static double _niceStep(double raw) {
    if (raw <= 0) return 10;
    final p = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final f = raw / p;
    final m = f < 1.5 ? 1 : (f < 3.5 ? 2 : (f < 7.5 ? 5 : 10));
    return m * p;
  }

  @override
  bool shouldRepaint(covariant _ModelPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.pan != pan ||
      !identical(old.model, model) ||
      old.color != color ||
      old.gridColor != gridColor;
}
