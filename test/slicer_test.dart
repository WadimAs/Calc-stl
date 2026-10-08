import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stl_weight/history/history.dart';
import 'package:stl_weight/mesh/mesh.dart';
import 'package:stl_weight/mesh/stl_parser.dart';
import 'package:stl_weight/mesh/threemf_parser.dart';
import 'package:stl_weight/slicer/settings.dart';
import 'package:stl_weight/slicer/slicer.dart';

/// Axis-aligned box with outward-facing triangles.
Float32List box(double sx, double sy, double sz, [double ox = 0, double oy = 0, double oz = 0]) {
  List<double> v(int x, int y, int z) => [x * sx + ox, y * sy + oy, z * sz + oz];
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

  test('supports: overhanging slab on a pillar', () {
    final mushroom = Float32List.fromList([...box(4, 4, 10.5, 8, 8, 0), ...box(20, 20, 2, 0, 0, 10)]);
    const st = SliceSettings(supportsEnabled: true);
    final r = sliceMesh(mushroom, st);
    // ~373 mm² under the slab, 50 layers: 2 interface (70 %) + 48 sparse (15 %).
    expect(r.supportVolumeMm3, closeTo(641, 641 * 0.08));
    final off = sliceMesh(mushroom, const SliceSettings());
    expect(off.supportVolumeMm3, 0);
    expect(r.volumeMm3, closeTo(off.volumeMm3, 1e-6));
  });

  test('supports: build plate only skips columns that land on the model', () {
    final floating = Float32List.fromList([...box(20, 20, 3), ...box(20, 20, 2, 0, 0, 8)]);
    final everywhere = sliceMesh(floating, const SliceSettings(supportsEnabled: true));
    final plate = sliceMesh(floating, const SliceSettings(supportsEnabled: true, supportPlateOnly: true));
    expect(everywhere.supportVolumeMm3, closeTo(388, 388 * 0.08));
    expect(plate.supportVolumeMm3, 0);
  });

  test('tree supports use less material than normal ones on tall overhangs', () {
    final tall = Float32List.fromList([...box(4, 4, 40.5, 8, 8, 0), ...box(20, 20, 2, 0, 0, 40)]);
    final normal = sliceMesh(tall, const SliceSettings(supportsEnabled: true));
    final tree = sliceMesh(tall, const SliceSettings(supportsEnabled: true, supportType: 'tree'));
    expect(tree.supportVolumeMm3, greaterThan(0));
    expect(tree.supportVolumeMm3, lessThan(normal.supportVolumeMm3 * 0.6));
    // Branches merge lower down: fewer nodes on a coarser grid.
    expect(treeBranchAt(6, 6, 2), isTrue);
    expect(treeBranchAt(6, 6, 30), isFalse);
    expect(treeBranchAt(0, 0, 30), isTrue);
  });

  test('printer profiles: unique ids, brands grouped, defaults reset', () {
    final ids = printers.map((p) => p.id).toSet();
    expect(ids.length, printers.length);
    expect(printerBrands, containsAll(['Bambu Lab', 'Creality', 'Anycubic', 'Elegoo']));
    expect(printerById('missing').id, printers.first.id);
    const s = SliceSettings(walls: 5, pricesPerKg: {'PLA': 900}, supportType: 'tree');
    expect(s.resetAll().walls, 2);
    expect(s.resetAll().pricePerKg, 900);
    expect(s.resetAll(prices: true).pricePerKg, 600);
    expect(s.withoutPriceOverride().pricePerKg, 600);
    expect(SliceSettings.fromJson(s.toJson()).supportType, 'tree');
  });

  test('a plain cube needs no supports', () {
    final r = sliceMesh(box(20, 20, 20), const SliceSettings(supportsEnabled: true));
    expect(r.supportVolumeMm3, 0);
  });

  test('cost breakdown: cost price and price with profit', () {
    const s = SliceSettings(
      pricesPerKg: {'PLA': 800},
      powerW: 200,
      tariff: 5,
      amortizationPerHour: 10,
      markupPercent: 50,
      extraCost: 20,
    );
    final c = CostBreakdown.of(250, 2, s);
    expect(c.material, closeTo(200, 1e-9)); // 250 g × 800 / 1000
    expect(c.electricity, closeTo(2, 1e-9)); // 2 h × 0.2 kW × 5
    expect(c.amortization, closeTo(20, 1e-9)); // 2 h × 10
    expect(c.costPrice, closeTo(222, 1e-9));
    expect(c.profit, closeTo(111, 1e-9));
    expect(c.price, closeTo(353, 1e-9));
    expect(s.copyWith(materialId: 'PETG').pricePerKg, 650);
    expect(s.withPrice(900).pricePerKg, 900);
  });

  test('print time estimate grows with the model and respects flow limits', () {
    final small = sliceMesh(box(10, 10, 10), const SliceSettings());
    final big = sliceMesh(box(30, 30, 30), const SliceSettings());
    final tSmall = small.printSeconds(const SliceSettings());
    final tBig = big.printSeconds(const SliceSettings());
    expect(tSmall, greaterThan(60));
    expect(tBig, greaterThan(tSmall * 4));
    // TPU (low flow) is slower than PLA on the same printer.
    expect(big.printSeconds(const SliceSettings(materialId: 'TPU')), greaterThan(tBig * 2));
    // A classic printer is slower than a Bambu.
    expect(big.printSeconds(const SliceSettings(printerId: 'classic')), greaterThan(tBig));
  });

  test('layer preview covers every layer with classified rectangles', () {
    final r = sliceMesh(box(20, 20, 4), const SliceSettings());
    final p = r.preview!;
    expect(p.layers, r.layers);
    expect(p.layerStart.length, r.layers + 1);
    for (int l = 0; l < p.layers; l++) {
      expect(p.layerStart[l + 1], greaterThan(p.layerStart[l]), reason: 'layer $l is empty');
    }
    final classes = p.classes.toSet();
    expect(classes, containsAll([SliceClass.outerWall, SliceClass.innerWall, SliceClass.solid]));
    expect(p.zTop.last, closeTo(4, 0.21));
  });

  test('ensure vertical shell adds solid infill on slopes only', () {
    // Cube: vertical walls, no change.
    final cubeOn = sliceMesh(box(20, 20, 20), const SliceSettings());
    final cubeOff = sliceMesh(box(20, 20, 20), const SliceSettings(ensureVerticalShell: false));
    expect(cubeOn.volumeMm3, closeTo(cubeOff.volumeMm3, cubeOff.volumeMm3 * 0.01));
  });

  test('old settings migrate from 4 to 5 top layers', () {
    final s = SliceSettings.fromJson({'topLayers': 4});
    expect(s.topLayers, 5);
    final keep = SliceSettings.fromJson({'topLayers': 4, 'v': 2});
    expect(keep.topLayers, 4);
  });

  test('settings and history survive JSON round trip', () {
    const s = SliceSettings(supportsEnabled: true, supportAngle: 55, pricesPerKg: {'PETG': 700}, markupPercent: 10);
    final back = SliceSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.geometryKey, s.geometryKey);
    expect(back.pricesPerKg['PETG'], 700);
    expect(back.markupPercent, 10);

    final e = HistoryEntry(
      id: '1',
      date: DateTime(2026, 10, 8, 21, 5),
      name: 'cube.stl',
      material: 'PLA',
      density: 1.24,
      pricePerKg: 600,
      layerHeight: 0.2,
      infillPercent: 15,
      walls: 2,
      supports: true,
      supportPlateOnly: false,
      scalePercent: 100,
      copies: 2,
      modelGrams: 10,
      supportGrams: 2,
      filamentMeters: 8,
      materialCost: 14.4,
      printHours: 1.5,
      electricityCost: 0.9,
      amortizationCost: 12,
      markupPercent: 0,
      extraCost: 0,
      totalCost: 14.4,
      sizeX: 20,
      sizeY: 20,
      sizeZ: 20,
      note: 'Іван; синій',
    );
    final e2 = HistoryEntry.fromJson(jsonDecode(jsonEncode(e.toJson())))!;
    expect(e2.totalGrams, 24);
    expect(e2.costPrice, closeTo(27.3, 1e-9));
    expect(e2.printHours, 1.5);
    expect(e2.note, 'Іван; синій');
    expect(formatDate(e2.date), '08.10.2026 21:05');
    final csv = HistoryStore.toCsv([e2]);
    expect(csv.split('\n')[1], contains('"Іван; синій"'));
  });
}
