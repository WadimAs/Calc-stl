import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Triangles of an axis-aligned box (outward normals).
List<double> box(double x0, double y0, double z0, double x1, double y1, double z1) {
  final v = [
    [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], //
    [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1],
  ];
  const faces = [
    [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3], //
  ];
  final out = <double>[];
  for (final f in faces) {
    for (final t in [
      [f[0], f[1], f[2]],
      [f[0], f[2], f[3]],
    ]) {
      for (final i in t) {
        out.addAll(v[i]);
      }
    }
  }
  return out;
}

/// An L-bracket with an overhanging shelf (needs supports).
Uint8List bracketStl() {
  final tris = [
    ...box(0, 0, 0, 40, 20, 5),
    ...box(0, 0, 5, 6, 20, 30),
    ...box(0, 0, 30, 25, 20, 34),
  ];
  final n = tris.length ~/ 9;
  final bd = ByteData(84 + n * 50);
  bd.setUint32(80, n, Endian.little);
  int o = 84;
  for (int t = 0; t < n; t++) {
    o += 12;
    for (int k = 0; k < 9; k++) {
      bd.setFloat32(o, tris[t * 9 + k], Endian.little);
      o += 4;
    }
    o += 2;
  }
  return bd.buffer.asUint8List();
}

/// A printed spool label rendered as a PNG (for the on-device OCR check).
Future<Uint8List> labelPng() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 1000, 640), Paint()..color = Colors.white);
  final tp = TextPainter(
    text: const TextSpan(
      text: 'Bambu Lab\nPLA Basic Refill\nJade White\nNet Weight: 1kg',
      style: TextStyle(color: Colors.black, fontSize: 80, fontWeight: FontWeight.bold, height: 1.3),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 940);
  tp.paint(c, const Offset(30, 40));
  final img = await rec.endRecording().toImage(1000, 640);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bd!.buffer.asUint8List();
}

/// A spur gear with a centre hole (nicer demo model; also shows a hole).
Uint8List gearStl() {
  const teeth = 18, n = teeth * 8, h = 8.0, rIn = 6.0, rRoot = 24.0, rTip = 28.0;
  double rOut(int i) {
    final t = (i % 8) / 8.0; // position within one tooth
    if (t < 0.2) return rRoot;
    if (t < 0.35) return rRoot + (rTip - rRoot) * (t - 0.2) / 0.15;
    if (t < 0.65) return rTip;
    if (t < 0.8) return rTip - (rTip - rRoot) * (t - 0.65) / 0.15;
    return rRoot;
  }

  List<double> p(double r, int i, double z) {
    final a = 2 * math.pi * i / n;
    return [30 + r * math.cos(a), 30 + r * math.sin(a), z];
  }

  final tris = <double>[];
  void tri(List<double> a, List<double> b, List<double> c) => tris
    ..addAll(a)
    ..addAll(b)
    ..addAll(c);
  for (int i = 0; i < n; i++) {
    final j = (i + 1) % n;
    final oi = rOut(i), oj = rOut(j);
    // top (z = h) and bottom (z = 0) rings
    tri(p(rIn, i, h), p(oi, i, h), p(oj, j, h));
    tri(p(rIn, i, h), p(oj, j, h), p(rIn, j, h));
    tri(p(rIn, i, 0), p(oj, j, 0), p(oi, i, 0));
    tri(p(rIn, i, 0), p(rIn, j, 0), p(oj, j, 0));
    // outer wall
    tri(p(oi, i, 0), p(oj, j, 0), p(oj, j, h));
    tri(p(oi, i, 0), p(oj, j, h), p(oi, i, h));
    // hole wall (facing the axis)
    tri(p(rIn, i, 0), p(rIn, i, h), p(rIn, j, h));
    tri(p(rIn, i, 0), p(rIn, j, h), p(rIn, j, 0));
  }
  final nt = tris.length ~/ 9;
  final bd = ByteData(84 + nt * 50);
  bd.setUint32(80, nt, Endian.little);
  int o = 84;
  for (int t = 0; t < nt; t++) {
    o += 12;
    for (int k = 0; k < 9; k++) {
      bd.setFloat32(o, tris[t * 9 + k], Endian.little);
      o += 4;
    }
    o += 2;
  }
  return bd.buffer.asUint8List();
}

