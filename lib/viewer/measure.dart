import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../mesh/holes.dart';

/// Point in model coordinates (mm, relative to the model's bounding-box centre).
class P3 {
  final double x, y, z;

  const P3(this.x, this.y, this.z);

  P3 operator +(P3 o) => P3(x + o.x, y + o.y, z + o.z);
  P3 operator -(P3 o) => P3(x - o.x, y - o.y, z - o.z);
  P3 operator *(double k) => P3(x * k, y * k, z * k);

  double dot(P3 o) => x * o.x + y * o.y + z * o.z;

  P3 cross(P3 o) => P3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  P3 get normalized {
    final l = length;
    return l > 0 ? this * (1 / l) : this;
  }
}

enum MeasureTool { none, distance, circle, angle, holes }

extension MeasureToolInfo on MeasureTool {
  int get points => switch (this) {
        MeasureTool.none => 0,
        MeasureTool.distance => 2,
        MeasureTool.circle => 3,
        MeasureTool.angle => 3,
        MeasureTool.holes => 1,
      };

  String get label => switch (this) {
        MeasureTool.none => '',
        MeasureTool.distance => 'Відстань',
        MeasureTool.circle => 'Коло',
        MeasureTool.angle => 'Кут',
        MeasureTool.holes => 'Отвори',
      };
}

class CircleFit {
  final P3 center;
  final double radius;
  final P3 normal;

  const CircleFit(this.center, this.radius, this.normal);
}

/// Circle through three points, or null when they are (almost) collinear.
CircleFit? circleThrough(P3 p0, P3 p1, P3 p2) {
  final a = p1 - p0, b = p2 - p0;
  final n = a.cross(b);
  final n2 = n.dot(n);
  if (n2 < 1e-12 * math.max(1.0, a.dot(a) * b.dot(b))) return null;
  final offset = (n.cross(a) * b.dot(b) + b.cross(n) * a.dot(a)) * (1 / (2 * n2));
  final c = p0 + offset;
  return CircleFit(c, offset.length, n.normalized);
}

/// Angle at [vertex] between the rays to [a] and [b], degrees.
double angleAt(P3 a, P3 vertex, P3 b) {
  final u = a - vertex, v = b - vertex;
  final lu = u.length, lv = v.length;
  if (lu < 1e-12 || lv < 1e-12) return 0;
  final c = (u.dot(v) / (lu * lv)).clamp(-1.0, 1.0);
  return math.acos(c) * 180 / math.pi;
}

class Measurement {
  final MeasureTool tool;
  final List<P3> points;

  const Measurement(this.tool, this.points);

  P3 get delta => points[1] - points[0];

  double get distance => delta.length;

  CircleFit? get circle => tool == MeasureTool.circle && points.length == 3 ? circleThrough(points[0], points[1], points[2]) : null;

  double get angle => tool == MeasureTool.angle && points.length == 3 ? angleAt(points[0], points[1], points[2]) : 0;
}

/// Measuring state shared by the 3D view (taps, drawing) and the tool panel.
class MeasureController extends ChangeNotifier {
  MeasureTool _tool = MeasureTool.none;
  bool _snap = true;
  final List<P3> pending = [];
  final List<Measurement> done = [];

  MeasureTool get tool => _tool;
  bool get active => _tool != MeasureTool.none;
  bool get snap => _snap;

  set tool(MeasureTool t) {
    if (t == _tool) return;
    _tool = t;
    pending.clear();
    notifyListeners();
    if (t == MeasureTool.holes) _findHoles();
  }

  // ---- Automatic holes ----
  Float32List? _tris;
  bool _inverted = false;
  int _generation = 0;

  /// Holes of the current model (null until the first analysis finishes).
  List<HoleFeature>? holes;
  bool holesBusy = false;
  String? holesError;
  HoleFeature? selectedHole;

  /// The last tap in holes mode did not hit a hole wall.
  bool holeMiss = false;

  /// New model: forget everything computed for the previous one.
  void attachModel(Float32List tris, {required bool inverted}) {
    _tris = tris;
    _inverted = inverted;
    _generation++;
    holes = null;
    holesBusy = false;
    holesError = null;
    selectedHole = null;
    holeMiss = false;
    reset();
  }

  Future<void> _findHoles() async {
    final tris = _tris;
    if (tris == null || holes != null || holesBusy) return;
    final gen = _generation;
    final inverted = _inverted;
    holesBusy = true;
    holesError = null;
    notifyListeners();
    try {
      final found = await Isolate.run(() => findHoles(tris, inverted: inverted));
      if (gen != _generation) return;
      holes = found;
    } catch (e) {
      if (gen != _generation) return;
      holesError = 'Не вдалося проаналізувати модель: $e';
    } finally {
      if (gen == _generation) {
        holesBusy = false;
        notifyListeners();
      }
    }
  }

  /// Selects the hole whose wall is at the absolute point, if any.
  void selectHoleAt(double? x, double? y, double? z) {
    final list = holes;
    if (list == null) return;
    HoleFeature? best;
    if (x != null && y != null && z != null) {
      double bestD = double.infinity;
      for (final h in list) {
        final d = h.wallDistance(x, y, z);
        if (d == null) continue;
        final tol = math.max(0.3, h.radius * 0.2);
        if (d <= tol && d < bestD) {
          bestD = d;
          best = h;
        }
      }
    }
    selectedHole = best;
    holeMiss = best == null;
    notifyListeners();
  }

  set snap(bool v) {
    _snap = v;
    notifyListeners();
  }

  void add(P3 p) {
    if (!active || _tool == MeasureTool.holes) return;
    pending.add(p);
    if (pending.length >= _tool.points) {
      done.add(Measurement(_tool, List.of(pending)));
      pending.clear();
    }
    notifyListeners();
  }

  void undo() {
    if (pending.isNotEmpty) {
      pending.removeLast();
    } else if (done.isNotEmpty) {
      done.removeLast();
    }
    notifyListeners();
  }

  void clear() {
    pending.clear();
    done.clear();
    notifyListeners();
  }

  /// Forget everything (new model loaded).
  void reset() {
    pending.clear();
    done.clear();
    _tool = MeasureTool.none;
    selectedHole = null;
    holeMiss = false;
    notifyListeners();
  }
}
