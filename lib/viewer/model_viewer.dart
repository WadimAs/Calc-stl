import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../mesh/holes.dart';
import '../mesh/loader.dart';
import '../mesh/mesh.dart';
import '../slicer/slicer.dart';
import 'measure.dart';

/// Orthographic camera shared by drawing and picking.
class _View {
  final double scale, cx, cy, cyw, syw, cp, sp;

  const _View(this.scale, this.cx, this.cy, this.cyw, this.syw, this.cp, this.sp);

  factory _View.of(Bounds b, Size size, double yaw, double pitch, double zoom, Offset pan) {
    final radius = math.max(1e-3, math.sqrt(b.sizeX * b.sizeX + b.sizeY * b.sizeY + b.sizeZ * b.sizeZ) / 2);
    return _View(
      math.min(size.width, size.height) * 0.46 / radius * zoom,
      size.width / 2 + pan.dx,
      size.height / 2 + pan.dy,
      math.cos(yaw),
      math.sin(yaw),
      math.cos(pitch),
      math.sin(pitch),
    );
  }

  Offset project(double x, double y, double z) {
    final x1 = x * cyw - y * syw;
    final y1 = x * syw + y * cyw;
    return Offset(cx + x1 * scale, cy - (z * cp + y1 * sp) * scale);
  }

  Offset p(P3 q) => project(q.x, q.y, q.z);
}

/// Colours of the sliced view, by [SliceClass] (index 0 unused).
const sliceColors = <Color>[
  Color(0x00000000),
  Color(0xFFFF7F00), // outer wall
  Color(0xFFFFD54A), // inner wall
  Color(0xFFB04CE0), // solid infill / top / bottom
  Color(0xFFC0392B), // sparse infill
  Color(0xFF2ECC71), // support
  Color(0xFF138D4B), // support interface
];

const sliceClassNames = <String>[
  '',
  'Зовнішня стінка',
  'Внутрішня стінка',
  'Суцільне заповнення',
  'Заповнення',
  'Підтримки',
  'Контакт підтримок',
];

/// Interactive 3D preview: drag to rotate, pinch to zoom/pan, double tap to reset.
///
/// With [showLayers] and a [preview], draws the sliced layers 0..[maxLayer]
/// coloured by feature type instead of the mesh.
class ModelViewer extends StatefulWidget {
  final LoadedModel model;
  final Color color;
  final SlicePreview? preview;
  final double previewScale; // slicer scale (settings.scalePercent / 100)
  final bool showLayers;
  final int maxLayer;
  final MeasureController? measure;

  const ModelViewer({
    super.key,
    required this.model,
    required this.color,
    this.preview,
    this.previewScale = 1,
    this.showLayers = false,
    this.maxLayer = 1 << 30,
    this.measure,
  });

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
  _LayerMeshes? _layers;
  Size _size = Size.zero;

  bool get _measuring => widget.measure?.active == true && !widget.showLayers;

  /// Point of the model surface under [pos], snapped to a vertex if close.
  P3? _pick(Offset pos, {bool? snap}) {
    final m = widget.model;
    final b = m.bounds;
    final v = _View.of(b, _size, _yaw, _pitch, _zoom, _pan);
    final t = m.mesh.tris;
    final n = t.length ~/ 9;
    final bx = b.centerX, by = b.centerY, bz = b.centerZ;
    final px = pos.dx, py = pos.dy;
    final sx = Float64List(3), sy = Float64List(3), sd = Float64List(3);
    double best = double.infinity;
    int bestT = -1;
    double b0 = 0, b1 = 0, b2 = 0;
    for (int k = 0; k < n; k++) {
      final o = k * 9;
      for (int j = 0; j < 3; j++) {
        final x = t[o + j * 3] - bx, y = t[o + j * 3 + 1] - by, z = t[o + j * 3 + 2] - bz;
        final x1 = x * v.cyw - y * v.syw;
        final y1 = x * v.syw + y * v.cyw;
        sx[j] = v.cx + x1 * v.scale;
        sy[j] = v.cy - (z * v.cp + y1 * v.sp) * v.scale;
        sd[j] = y1 * v.cp - z * v.sp;
      }
      if ((sx[0] < px && sx[1] < px && sx[2] < px) ||
          (sx[0] > px && sx[1] > px && sx[2] > px) ||
          (sy[0] < py && sy[1] < py && sy[2] < py) ||
          (sy[0] > py && sy[1] > py && sy[2] > py)) {
        continue;
      }
      final den = (sy[1] - sy[2]) * (sx[0] - sx[2]) + (sx[2] - sx[1]) * (sy[0] - sy[2]);
      if (den.abs() < 1e-12) continue;
      final l0 = ((sy[1] - sy[2]) * (px - sx[2]) + (sx[2] - sx[1]) * (py - sy[2])) / den;
      final l1 = ((sy[2] - sy[0]) * (px - sx[2]) + (sx[0] - sx[2]) * (py - sy[2])) / den;
      final l2 = 1 - l0 - l1;
      if (l0 < 0 || l1 < 0 || l2 < 0) continue;
      final d = l0 * sd[0] + l1 * sd[1] + l2 * sd[2];
      if (d < best) {
        best = d;
        bestT = k;
        b0 = l0;
        b1 = l1;
        b2 = l2;
      }
    }
    if (bestT < 0) return null;
    final o = bestT * 9;
    P3 vert(int j) => P3(t[o + j * 3] - bx, t[o + j * 3 + 1] - by, t[o + j * 3 + 2] - bz);
    final v0 = vert(0), v1 = vert(1), v2 = vert(2);
    if (snap ?? widget.measure?.snap ?? false) {
      P3? snapped;
      double bestPx = 18;
      for (final q in [v0, v1, v2]) {
        final d = (v.p(q) - pos).distance;
        if (d < bestPx) {
          bestPx = d;
          snapped = q;
        }
      }
      if (snapped != null) return snapped;
    }
    return v0 * b0 + v1 * b1 + v2 * b2;
  }

  void _onTap(TapUpDetails d) {
    if (!_measuring) return;
    final mc = widget.measure!;
    if (mc.tool == MeasureTool.holes) {
      final p = _pick(d.localPosition, snap: false);
      final b = widget.model.bounds;
      mc.selectHoleAt(
        p == null ? null : p.x + b.centerX,
        p == null ? null : p.y + b.centerY,
        p == null ? null : p.z + b.centerZ,
      );
      return;
    }
    final p = _pick(d.localPosition);
    if (p != null) mc.add(p);
  }

  bool _wasMeasuring = false;

  // Rebuild only when measuring starts/stops (double tap is switched off then).
  void _onMeasure() {
    final now = widget.measure?.active ?? false;
    if (now != _wasMeasuring && mounted) setState(() => _wasMeasuring = now);
  }

  @override
  void initState() {
    super.initState();
    _cache = _ViewCache(widget.model.viewTris.length ~/ 9);
    _layers = _buildLayers(widget.preview);
    widget.measure?.addListener(_onMeasure);
    _wasMeasuring = widget.measure?.active ?? false;
  }

  @override
  void didUpdateWidget(covariant ModelViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.model, widget.model)) {
      _cache = _ViewCache(widget.model.viewTris.length ~/ 9);
      _reset();
    }
    if (!identical(oldWidget.preview, widget.preview)) {
      _layers?.dispose();
      _layers = _buildLayers(widget.preview);
    }
    if (!identical(oldWidget.measure, widget.measure)) {
      oldWidget.measure?.removeListener(_onMeasure);
      widget.measure?.addListener(_onMeasure);
    }
  }

  @override
  void dispose() {
    widget.measure?.removeListener(_onMeasure);
    _layers?.dispose();
    super.dispose();
  }

  static _LayerMeshes? _buildLayers(SlicePreview? p) => p == null ? null : _LayerMeshes(p);

  void _reset() {
    _yaw = _defaultYaw;
    _pitch = _defaultPitch;
    _zoom = 1.0;
    _pan = Offset.zero;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      _size = Size(c.maxWidth, c.maxHeight);
      return _gestures(context, scheme);
    });
  }

  Widget _gestures(BuildContext context, ColorScheme scheme) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTap,
      // Double tap delays single taps, so it is off while measuring.
      onDoubleTap: _measuring ? null : () => setState(_reset),
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
            layers: widget.showLayers ? _layers : null,
            previewScale: widget.previewScale,
            maxLayer: widget.maxLayer,
            measure: widget.showLayers ? null : widget.measure,
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

/// GPU-ready triangles of every layer (top colour and a darker side colour).
class _LayerMeshes {
  final SlicePreview preview;
  final List<ui.Vertices?> top;
  final List<ui.Vertices?> side;

  _LayerMeshes(this.preview)
      : top = List<ui.Vertices?>.filled(preview.layers, null),
        side = List<ui.Vertices?>.filled(preview.layers, null) {
    final colors = [for (final c in sliceColors) c.toARGB32()];
    for (int l = 0; l < preview.layers; l++) {
      final a = preview.layerStart[l], e = preview.layerStart[l + 1];
      final n = e - a;
      if (n <= 0) continue;
      final pos = Float32List(n * 12);
      final cTop = Int32List(n * 6);
      final cSide = Int32List(n * 6);
      final shade = l.isOdd ? 0.9 : 1.0;
      for (int r = 0; r < n; r++) {
        final o = (a + r) * 4;
        final x0 = preview.rects[o], y0 = preview.rects[o + 1];
        final x1 = preview.rects[o + 2], y1 = preview.rects[o + 3];
        final q = r * 12;
        pos[q] = x0;
        pos[q + 1] = y0;
        pos[q + 2] = x1;
        pos[q + 3] = y0;
        pos[q + 4] = x1;
        pos[q + 5] = y1;
        pos[q + 6] = x0;
        pos[q + 7] = y0;
        pos[q + 8] = x1;
        pos[q + 9] = y1;
        pos[q + 10] = x0;
        pos[q + 11] = y1;
        final cls = preview.classes[a + r];
        final base = colors[cls < colors.length ? cls : 0];
        final ct = _scale(base, shade);
        final cs = _scale(base, 0.6);
        for (int k = 0; k < 6; k++) {
          cTop[r * 6 + k] = ct;
          cSide[r * 6 + k] = cs;
        }
      }
      top[l] = ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: cTop);
      side[l] = ui.Vertices.raw(ui.VertexMode.triangles, pos, colors: cSide);
    }
  }

  static int _scale(int argb, double f) {
    int ch(int shift) {
      final v = (((argb >> shift) & 0xFF) * f).round();
      return v > 255 ? 255 : v;
    }

    return (0xFF << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0);
  }

  void dispose() {
    for (final v in top) {
      v?.dispose();
    }
    for (final v in side) {
      v?.dispose();
    }
  }
}

class _ModelPainter extends CustomPainter {
  final LoadedModel model;
  final _ViewCache cache;
  final double yaw, pitch, zoom;
  final Offset pan;
  final Color color;
  final Color gridColor;
  final _LayerMeshes? layers;
  final double previewScale;
  final int maxLayer;
  final MeasureController? measure;

  _ModelPainter({
    required this.model,
    required this.cache,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.pan,
    required this.color,
    required this.gridColor,
    required this.layers,
    required this.previewScale,
    required this.maxLayer,
    required this.measure,
  }) : super(repaint: measure);

  static const _measureColor = Color(0xFF00B8D9);

  void _label(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromCenter(center: at, width: tp.width + 12, height: tp.height + 6);
    canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(6)), Paint()..color = const Color(0xE6202833));
    tp.paint(canvas, Offset(r.left + 6, r.top + 3));
  }

  void _paintHoles(Canvas canvas, _View v, MeasureController mc) {
    final list = mc.holes;
    if (list == null || list.isEmpty) return;
    final b = model.bounds;
    final k = previewScale;
    P3 rel(List<double> p) => P3(p[0] - b.centerX, p[1] - b.centerY, p[2] - b.centerZ);
    final normal = Paint()
      ..color = _measureColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final picked = Paint()
      ..color = const Color(0xFFFFC107)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    void ring(HoleFeature h, double w, double r, Paint paint) {
      final c = rel(h.pointAt(w));
      final u = List<double>.filled(3, 0)..[(h.axis + 1) % 3] = 1;
      final ww = List<double>.filled(3, 0)..[(h.axis + 2) % 3] = 1;
      final pu = P3(u[0], u[1], u[2]), pw = P3(ww[0], ww[1], ww[2]);
      final path = Path();
      for (int i = 0; i <= 48; i++) {
        final a = i / 48 * 2 * math.pi;
        final o = v.p(c + pu * (r * math.cos(a)) + pw * (r * math.sin(a)));
        if (i == 0) {
          path.moveTo(o.dx, o.dy);
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, paint);
    }

    for (final h in list) {
      if (identical(h, mc.selectedHole)) continue;
      ring(h, h.w0, h.radius, normal);
      ring(h, h.w1, h.radius, normal);
    }
    final sel = mc.selectedHole;
    if (sel != null) {
      ring(sel, sel.w0, sel.radius, picked);
      ring(sel, sel.w1, sel.radius, picked);
      canvas.drawLine(v.p(rel(sel.pointAt(sel.w0))), v.p(rel(sel.pointAt(sel.w1))), picked);
    }
    // Labels last so they stay readable.
    for (final h in list) {
      final top = v.p(rel(h.pointAt(h.w1)));
      final bottom = v.p(rel(h.pointAt(h.w0)));
      final at = top.dy < bottom.dy ? top : bottom;
      _label(canvas, at + const Offset(0, -16), '⌀${(h.diameter * k).toStringAsFixed(2).replaceAll('.', ',')}');
    }
  }

  void _paintMeasure(Canvas canvas, Size size) {
    final mc = measure;
    if (mc == null) return;
    final v = _View.of(model.bounds, size, yaw, pitch, zoom, pan);
    if (mc.tool == MeasureTool.holes) _paintHoles(canvas, v, mc);
    if (mc.done.isEmpty && mc.pending.isEmpty) return;
    final k = previewScale;
    final line = Paint()
      ..color = _measureColor
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    final dot = Paint()..color = Colors.white;
    final ring = Paint()
      ..color = _measureColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    void marker(P3 q) {
      final o = v.p(q);
      canvas.drawCircle(o, 5, dot);
      canvas.drawCircle(o, 5, ring);
    }

    String mm(double x) => '${(x * k).toStringAsFixed(2).replaceAll('.', ',')} мм';

    for (final m in mc.done) {
      final pts = m.points;
      switch (m.tool) {
        case MeasureTool.distance:
          canvas.drawLine(v.p(pts[0]), v.p(pts[1]), line);
          _label(canvas, (v.p(pts[0]) + v.p(pts[1])) / 2, mm(m.distance));
        case MeasureTool.circle:
          final c = m.circle;
          if (c != null) {
            final u = (pts[0] - c.center).normalized;
            final w = c.normal.cross(u);
            final path = Path();
            for (int i = 0; i <= 72; i++) {
              final a = i / 72 * 2 * math.pi;
              final q = c.center + u * (c.radius * math.cos(a)) + w * (c.radius * math.sin(a));
              final o = v.p(q);
              if (i == 0) {
                path.moveTo(o.dx, o.dy);
              } else {
                path.lineTo(o.dx, o.dy);
              }
            }
            canvas.drawPath(path, line);
            canvas.drawCircle(v.p(c.center), 3, Paint()..color = _measureColor);
            _label(canvas, v.p(c.center) + const Offset(0, -16), '⌀ ${mm(c.radius * 2)}');
          }
        case MeasureTool.angle:
          canvas.drawLine(v.p(pts[1]), v.p(pts[0]), line);
          canvas.drawLine(v.p(pts[1]), v.p(pts[2]), line);
          _label(canvas, v.p(pts[1]) + const Offset(0, -18), '${m.angle.toStringAsFixed(1).replaceAll('.', ',')}°');
        case MeasureTool.none:
        case MeasureTool.holes:
          break;
      }
      for (final q in pts) {
        marker(q);
      }
    }
    final pend = mc.pending;
    for (int i = 0; i + 1 < pend.length; i++) {
      canvas.drawLine(v.p(pend[i]), v.p(pend[i + 1]), line..color = _measureColor.withValues(alpha: 0.6));
    }
    line.color = _measureColor;
    for (final q in pend) {
      marker(q);
    }
  }

  /// Draws the sliced layers. Every layer is a flat slab: its darker copy at
  /// the bottom plane shows as the slab's edge, the normal copy at the top.
  void _paintLayers(Canvas canvas, _LayerMeshes lm, double scale, double cx, double cy, double cyw, double syw,
      double cp, double sp) {
    final b = model.bounds;
    final k = previewScale > 0 ? 1 / previewScale : 1.0;
    final p = lm.preview;
    final last = math.min(maxLayer, p.layers - 1);
    final a = scale * cyw, c = -scale * syw;
    final bq = -scale * sp * syw, d = -scale * sp * cyw;
    final tx = -b.centerX, ty = -b.centerY;
    final paint = Paint();

    void drawAt(ui.Vertices v, double zSlicer) {
      final z = zSlicer * k - b.sizeZ / 2;
      final f = cy - scale * z * cp;
      final m = Float64List(16);
      m[0] = a * k;
      m[1] = bq * k;
      m[4] = c * k;
      m[5] = d * k;
      m[10] = 1;
      m[12] = a * tx + c * ty + cx;
      m[13] = bq * tx + d * ty + f;
      m[15] = 1;
      canvas.save();
      canvas.transform(m);
      canvas.drawVertices(v, BlendMode.dst, paint);
      canvas.restore();
    }

    final fromAbove = pitch >= 0;
    for (int n = 0; n <= last; n++) {
      final l = fromAbove ? n : last - n;
      final top = lm.top[l], side = lm.side[l];
      if (top == null || side == null) continue;
      if (fromAbove) {
        drawAt(side, p.zBottom[l]);
        drawAt(top, p.zTop[l]);
      } else {
        drawAt(side, p.zTop[l]);
        drawAt(top, p.zBottom[l]);
      }
    }
  }

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

    final lm = layers;
    if (lm != null) {
      _paintLayers(canvas, lm, scale, cx, cy, cyw, syw, cp, sp);
      return;
    }
    _paintMesh(canvas, scale, cx, cy, cyw, syw, cp, sp);
    _paintMeasure(canvas, size);
  }

  void _paintMesh(Canvas canvas, double scale, double cx, double cy, double cyw, double syw, double cp, double sp) {
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
      old.gridColor != gridColor ||
      !identical(old.layers, layers) ||
      old.maxLayer != maxLayer ||
      old.previewScale != previewScale ||
      !identical(old.measure, measure);
}
