import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stl_weight/mesh/mesh.dart';
import 'package:stl_weight/mesh/stl_parser.dart';
import 'package:stl_weight/mesh/threemf_parser.dart';
import 'package:stl_weight/slicer/settings.dart';
import 'package:stl_weight/slicer/slicer.dart';

/// Axis-aligned box with outward-facing triangles.
Float32List box(double sx, double sy, double sz) {
  List<double> v(int x, int y, int z) => [x * sx, y * sy, z * sz];
  int i(int x, int y, int z) => x * 4 + y * 2 + z;
  final verts = <List<double>>[
    for (final x in [0, 1])
      for (final y in [0, 1])
        for (final z in [0, 1]) v(x, y, z)
  ];
  final quads = [
    [i(0, 0, 0), i(0, 1, 0), i(1, 1, 0), i(1, 0, 0)],
    [i(0, 0, 1), i(1, 0, 1), i(1, 1, 1), i(0, 1, 1)],
    [i(0, 0, 0), i(1, 0, 0), i(1, 0, 1), i(0, 0, 1)],
    [i(0, 1, 0), i(0, 1, 1), i(1, 1, 1), i(1, 1, 0)],
    [i(0, 0, 0), i(0, 0, 1), i(0, 1, 1), i(0, 1, 0)],
    [i(1, 0, 0), i(1, 1, 0), i(1, 1, 1), i(1, 0, 1)],
  ];
  final out = <double>[];
  for (final q in quads) {
    for (final t in [
      [q[0], q[1], q[2]],
      [q[0], q[2], q[3]]
    ]) {
      for (final k in t) {
        out.addAll(verts[k]);
      }
    }
  }
  return Float32List.fromList(out);
}

Uint8List binaryStl(Float32List tris) {
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

/// Tiny ZIP writer (deflate) for building a test 3MF.
Uint8List zip(Map<String, String> files) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  int count = 0;
  files.forEach((name, text) {
    final raw = utf8.encode(text);
    final comp = ZLibEncoder(raw: true).convert(raw);
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    final lh = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, 8, Endian.little)
      ..setUint32(18, comp.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    out.add(lh.buffer.asUint8List());
    out.add(nameBytes);
    out.add(comp);
    final ch = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, 8, Endian.little)
      ..setUint32(20, comp.length, Endian.little)
      ..setUint32(24, raw.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central.add(ch.buffer.asUint8List());
    central.add(nameBytes);
    count++;
  });
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, cd.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.toBytes();
}

void main() {
  test('20 mm cube: volume matches the analytic estimate', () {
    final mesh = Mesh(box(20, 20, 20));
    expect(mesh.signedVolume(), closeTo(8000, 1e-3));
    const st = SliceSettings(
      layerHeight: 0.4,
      firstLayerHeight: 0.4,
      lineWidth: 0.45,
      walls: 2,
      topLayers: 4,
      bottomLayers: 4,
      infillPercent: 20,
    );
    final r = sliceMesh(mesh.tris, st);
    // 8 solid layers + 42 layers of walls and 20 % infill.
    const a = 400.0, inner = 18.2 * 18.2, wall = a - inner;
    const expected = 8 * a * 0.4 + 42 * 0.4 * (wall + 0.2 * inner);
    expect(r.layers, 50);
    expect(r.volumeMm3, closeTo(expected, expected * 0.03));
    expect(r.grams(1.24), closeTo(expected * 1.24 / 1000, 0.2));
  });

  test('100% infill equals the solid volume', () {
    final r = sliceMesh(box(10, 12, 8), const SliceSettings(infillPercent: 100));
    expect(r.volumeMm3, closeTo(960, 960 * 0.03));
  });

  test('scale changes volume cubically', () {
    final a = sliceMesh(box(10, 10, 10), const SliceSettings(infillPercent: 100));
    final b = sliceMesh(box(10, 10, 10), const SliceSettings(infillPercent: 100, scalePercent: 200));
    expect(b.volumeMm3 / a.volumeMm3, closeTo(8, 0.3));
  });

  test('binary STL round trip', () {
    final tris = box(5, 6, 7);
    final m = parseStl(binaryStl(tris));
    expect(m.triangleCount, 12);
    expect(m.signedVolume(), closeTo(210, 1e-3));
  });

  test('ASCII STL', () {
    final tris = box(2, 3, 4);
    final sb = StringBuffer('solid test\n');
    for (int t = 0; t < 12; t++) {
      sb.writeln(' facet normal 0 0 0\n  outer loop');
      for (int v = 0; v < 3; v++) {
        final o = t * 9 + v * 3;
        sb.writeln('   vertex ${tris[o]} ${tris[o + 1]} ${tris[o + 2]}');
      }
      sb.writeln('  endloop\n endfacet');
    }
    sb.writeln('endsolid test');
    final m = parseStl(Uint8List.fromList(utf8.encode(sb.toString())));
    expect(m.triangleCount, 12);
    expect(m.signedVolume(), closeTo(24, 1e-3));
  });

  test('3MF with components, build transforms and external object file', () {
    const objectFile = '''<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
 <resources>
  <object id="1" type="model">
   <mesh>
    <vertices>
     <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
    </vertices>
    <triangles>
     <triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/>
    </triangles>
   </mesh>
  </object>
 </resources>
</model>''';
    const root = '''<?xml version="1.0" encoding="UTF-8"?>
<model unit="centimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
 <metadata name="Title">a > b</metadata>
 <resources>
  <object id="5" type="model">
   <components>
    <component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
    <component p:path="/3D/Objects/object_1.model" objectid="1" transform="2 0 0 0 2 0 0 0 2 50 0 0"/>
   </components>
  </object>
 </resources>
 <build>
  <item objectid="5" transform="1 0 0 0 1 0 0 0 1 100 100 0"/>
 </build>
</model>''';
    const rels = '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
</Relationships>''';
    final bytes = zip({
      '_rels/.rels': rels,
      '3D/3dmodel.model': root,
      '3D/Objects/object_1.model': objectFile,
    });
    final m = parse3mf(bytes);
    expect(m.triangleCount, 8);
    // Tetra 10³/6 cm units -> (1 + 8) * 166.67 * 1000 mm³
    expect(m.signedVolume(), closeTo(9 * 1000 / 6 * 1000, 1));
    final b = Bounds.of(m.tris);
    expect(b.minX, closeTo(1000, 1e-3));
  });
}
