import 'dart:math' as math;
import 'dart:convert';
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:stl_weight/clients/clients.dart';
import 'package:stl_weight/history/history.dart';
import 'package:stl_weight/orders/reminders.dart';
import 'package:stl_weight/platform/downloader.dart';
import 'package:stl_weight/platform/pdf.dart';
import 'package:stl_weight/printers/mqtt.dart';
import 'package:stl_weight/spools/label_parser.dart';
import 'package:stl_weight/ui/widgets.dart' show fmtMoney;
import 'package:stl_weight/printers/printers.dart';
import 'package:stl_weight/mesh/holes.dart';
import 'package:stl_weight/mesh/loader.dart';
import 'package:stl_weight/mesh/mesh_check.dart';
import 'package:stl_weight/mesh/transform.dart';
import 'package:stl_weight/orders/orders.dart';
import 'package:stl_weight/spools/spools.dart';
import 'package:stl_weight/mesh/slicer_project.dart';
import 'package:stl_weight/mesh/mesh.dart';
import 'package:stl_weight/mesh/stl_parser.dart';
import 'package:stl_weight/mesh/threemf_parser.dart';
import 'package:stl_weight/slicer/settings.dart';
import 'package:stl_weight/slicer/slicer.dart';
import 'package:stl_weight/viewer/measure.dart';

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

  test('tree supports: branches under overhangs, less than normal on tall columns', () {
    final tall = Float32List.fromList([...box(4, 4, 40.5, 8, 8, 0), ...box(20, 20, 2, 0, 0, 40)]);
    final normal = sliceMesh(tall, const SliceSettings(supportsEnabled: true));
    final tree = sliceMesh(tall, const SliceSettings(supportsEnabled: true, supportType: 'tree'));
    expect(tree.supportVolumeMm3, greaterThan(0));
    expect(tree.supportVolumeMm3, lessThan(normal.supportVolumeMm3));
    // Branches are drawn in the sliced view.
    expect(tree.preview!.classes.contains(SliceClass.support), isTrue);
    // Floating slab over a block: build-plate-only trees that hit the block stop.
    final floating = Float32List.fromList([...box(20, 20, 3), ...box(20, 20, 2, 0, 0, 8)]);
    final plate = sliceMesh(
        floating, const SliceSettings(supportsEnabled: true, supportType: 'tree', supportPlateOnly: true));
    final anywhere = sliceMesh(floating, const SliceSettings(supportsEnabled: true, supportType: 'tree'));
    expect(plate.supportVolumeMm3, lessThanOrEqualTo(anywhere.supportVolumeMm3));
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

  test('measuring: distance, circle through 3 points, angle, controller flow', () {
    const a = P3(0, 0, 0), b = P3(3, 4, 12);
    expect(const Measurement(MeasureTool.distance, [a, b]).distance, closeTo(13, 1e-9));

    // Points on a circle of radius 5 around (10, -2, 3) in a tilted plane.
    const c = P3(10, -2, 3);
    final u = const P3(1, 1, 0).normalized, w = const P3(-1, 1, 1).normalized;
    final ww = w - u * w.dot(u);
    final wn = ww.normalized;
    P3 on(double t) => c + u * (5 * math.cos(t)) + wn * (5 * math.sin(t));
    final fit = circleThrough(on(0.2), on(2.0), on(4.1))!;
    expect(fit.radius, closeTo(5, 1e-9));
    expect((fit.center - c).length, closeTo(0, 1e-9));
    expect(circleThrough(a, const P3(1, 1, 1), const P3(2, 2, 2)), isNull);

    expect(angleAt(const P3(1, 0, 0), a, const P3(0, 5, 0)), closeTo(90, 1e-9));
    expect(angleAt(const P3(1, 0, 0), a, const P3(1, 1, 0)), closeTo(45, 1e-9));

    final mc = MeasureController();
    mc.add(a); // ignored while no tool is active
    expect(mc.pending, isEmpty);
    mc.tool = MeasureTool.distance;
    mc.add(a);
    mc.add(b);
    expect(mc.done.single.distance, closeTo(13, 1e-9));
    mc.tool = MeasureTool.angle;
    mc.add(a);
    mc.undo();
    expect(mc.pending, isEmpty);
    mc.undo();
    expect(mc.done, isEmpty);
  });

  test('automatic holes: tube along Z and X, chamfer, no holes in a box', () {
    // Tube: outer R10, hole R4, 12 mm tall, 48 segments, outward winding.
    List<double> tube({double rOut = 10, double rIn = 4, double h = 12, int seg = 48}) {
      final out = <double>[];
      void tri(List<double> a, List<double> b, List<double> c) => out
        ..addAll(a)
        ..addAll(b)
        ..addAll(c);
      for (int i = 0; i < seg; i++) {
        final a0 = 2 * math.pi * i / seg, a1 = 2 * math.pi * (i + 1) / seg;
        List<double> p(double r, double a, double z) => [r * math.cos(a), r * math.sin(a), z];
        tri(p(rOut, a0, 0), p(rOut, a1, 0), p(rOut, a1, h));
        tri(p(rOut, a0, 0), p(rOut, a1, h), p(rOut, a0, h));
        tri(p(rIn, a0, 0), p(rIn, a1, h), p(rIn, a1, 0));
        tri(p(rIn, a0, 0), p(rIn, a0, h), p(rIn, a1, h));
        tri(p(rOut, a0, h), p(rOut, a1, h), p(rIn, a1, h));
        tri(p(rOut, a0, h), p(rIn, a1, h), p(rIn, a0, h));
        tri(p(rOut, a0, 0), p(rIn, a1, 0), p(rOut, a1, 0));
        tri(p(rOut, a0, 0), p(rIn, a0, 0), p(rIn, a1, 0));
      }
      return out;
    }

    final z = Float32List.fromList(tube());
    expect(Mesh(z).signedVolume(), greaterThan(0));
    final hz = findHoles(z);
    expect(hz.length, 1);
    expect(hz.single.axis, 2);
    expect(hz.single.diameter, closeTo(8, 0.12));
    expect(hz.single.depth, closeTo(12, 0.5));
    expect(hz.single.wallDistance(4, 0, 6), closeTo(0, 0.1));
    expect(hz.single.wallDistance(10, 0, 6), greaterThan(1));

    // Same tube lying along X: (x, y, z) -> (z, x, y).
    final src = tube();
    final xs = Float32List(src.length);
    for (int i = 0; i < src.length; i += 3) {
      xs[i] = src[i + 2];
      xs[i + 1] = src[i];
      xs[i + 2] = src[i + 1];
    }
    final hx = findHoles(xs);
    expect(hx.length, 1);
    expect(hx.single.axis, 0);
    expect(hx.single.diameter, closeTo(8, 0.12));

    // Inverted winding is handled with the flag.
    final inv = Float32List.fromList(tube());
    for (int i = 0; i < inv.length; i += 9) {
      for (int k = 0; k < 3; k++) {
        final tmp = inv[i + 3 + k];
        inv[i + 3 + k] = inv[i + 6 + k];
        inv[i + 6 + k] = tmp;
      }
    }
    expect(findHoles(inv, inverted: true).length, 1);

    expect(findHoles(box(20, 20, 20)), isEmpty);
  });

  group('slicer files', () {
    const bambuSettings = '{"layer_height": "0.2", "initial_layer_print_height": "0.2", '
        '"wall_loops": "6", "top_shell_layers": "5", "top_shell_thickness": "1", '
        '"bottom_shell_layers": "3", "bottom_shell_thickness": "0", "sparse_infill_density": "25%", '
        '"enable_support": "0", "support_type": "tree(auto)", "support_threshold_angle": "30", '
        '"support_on_build_plate_only": "0", "filament_type": ["PLA", "PLA"], '
        '"filament_density": ["1.26", "1.26"], "filament_diameter": ["1.75", "1.75"], '
        '"inner_wall_line_width": "0.45", "nozzle_diameter": ["0.4"], '
        '"ensure_vertical_shell_thickness": "enabled", "printer_model": "Bambu Lab A1 mini", '
        '"print_settings_id": "0.20mm Strength @BBL A1M"}';
    const sliceInfo = '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n  <plate>\n'
        '    <metadata key="index" value="1"/>\n    <metadata key="prediction" value="3490"/>\n'
        '    <metadata key="weight" value="10.47"/>\n'
        '    <filament id="1" type="PLA" color="#FFFF00" used_m="3.46" used_g="10.47" />\n'
        '  </plate>\n</config>\n';
    const model = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
        ' <metadata name="Application">BambuStudio-02.01.01.52</metadata>\n'
        ' <resources><object id="1" type="model"><mesh><vertices>'
        '<vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>'
        '</vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>'
        '<triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh></object></resources>\n'
        ' <build><item objectid="1"/></build>\n</model>';

    test('Bambu project 3MF: settings, printer and material', () {
      final p = readProjectFrom3mf(zip({
        '3D/3dmodel.model': model,
        'Metadata/project_settings.config': bambuSettings,
      }))!;
      expect(p.app, 'Bambu Studio');
      expect(p.layerHeight, 0.2);
      expect(p.walls, 6);
      expect(p.topLayers, 5);
      expect(p.bottomLayers, 3);
      expect(p.infillPercent, 25);
      expect(p.supports, isFalse);
      expect(p.supportTree, isTrue);
      expect(p.supportAngle, 60);
      expect(p.density, 1.26);
      expect(p.lineWidth, 0.45);
      expect(p.materialId, 'PLA');
      expect(p.printerId, 'bambu_a1mini');
      expect(p.isSliced, isFalse);
      final s = p.applyTo(const SliceSettings());
      expect(s.walls, 6);
      expect(s.infillPercent, 25);
      expect(s.density, 1.26);
      expect(s.printerId, 'bambu_a1mini');
      expect(s.supportsEnabled, isFalse);
      expect(p.describe(), isNotEmpty);
    });

    test('sliced 3MF: plate weight and time; mesh still loads', () async {
      final bytes = zip({
        '3D/3dmodel.model': model,
        'Metadata/project_settings.config': bambuSettings,
        'Metadata/slice_info.config': sliceInfo,
      });
      final p = readProjectFrom3mf(bytes)!;
      expect(p.isSliced, isTrue);
      expect(p.grams, closeTo(10.47, 1e-9));
      expect(p.seconds, 3490);
      expect(p.meters, closeTo(3.46, 1e-9));
      final m = await loadModel('part.gcode.3mf', bytes);
      expect(m.hasMesh, isTrue);
      expect(m.project!.grams, closeTo(10.47, 1e-9));
    });

    test('G-code from Bambu, Prusa and Cura', () async {
      const bambu = '; HEADER_BLOCK_START\n; BambuStudio 02.01.01.52\n'
          '; model printing time: 52m 3s; total estimated time: 58m 10s\n'
          '; total layer number: 145\n; total filament length [mm] : 3456.78\n'
          '; total filament weight [g] : 10.47\n; HEADER_BLOCK_END\nG28\nG1 X10 Y10\n'
          '; CONFIG_BLOCK_START\n; layer_height = 0.2\n; wall_loops = 3\n; sparse_infill_density = 15%\n'
          '; filament_type = PETG\n; filament_density = 1.25\n; CONFIG_BLOCK_END\n';
      final b = readGcode(Uint8List.fromList(utf8.encode(bambu)))!;
      expect(b.app, 'Bambu Studio');
      expect(b.grams, closeTo(10.47, 1e-9));
      expect(b.seconds, 3490);
      expect(b.meters, closeTo(3.45678, 1e-9));
      expect(b.walls, 3);
      expect(b.materialId, 'PETG');

      const prusa = '; generated by PrusaSlicer 2.8.1 on 2026-10-09 at 12:00:00 UTC\nG28\n'
          '; filament used [mm] = 4100.5\n; filament used [g] = 12.30\n'
          '; estimated printing time (normal mode) = 1h 2m 3s\n'
          '; layer_height = 0.15\n; perimeters = 3\n; fill_density = 20%\n; filament_type = PETG;PETG\n'
          '; support_material = 1\n; support_material_style = organic\n; support_material_threshold = 0\n';
      final p = readGcode(Uint8List.fromList(utf8.encode(prusa)))!;
      expect(p.app, 'PrusaSlicer');
      expect(p.grams, closeTo(12.3, 1e-9));
      expect(p.seconds, 3723);
      expect(p.layerHeight, 0.15);
      expect(p.walls, 3);
      expect(p.infillPercent, 20);
      expect(p.supports, isTrue);
      expect(p.supportTree, isTrue);
      expect(p.supportAngle, 60);

      const cura = ';FLAVOR:Marlin\n;TIME:3490\n;Filament used: 3.5m\n;Layer height: 0.2\n'
          ';Generated with Cura_SteamEngine 5.7.1\nG28\n';
      final c = readGcode(Uint8List.fromList(utf8.encode(cura)))!;
      expect(c.app, 'Cura');
      expect(c.seconds, 3490);
      expect(c.meters, closeTo(3.5, 1e-9));
      expect(c.grams, closeTo(10.44, 0.05));
      expect(c.layerHeight, 0.2);

      final m = await loadModel('part.gcode', Uint8List.fromList(utf8.encode(bambu)));
      expect(m.hasMesh, isFalse);
      expect(m.project!.isSliced, isTrue);
      expect(readGcode(Uint8List.fromList(utf8.encode('G28\nG1 X1\n'))), isNull);
      expect(parseDuration('1d 2h 3m 4s'), 93784);
    });

    test('calibration averages samples per printer', () {
      var s = const SliceSettings();
      expect(s.weightFactor, 1);
      s = s.calibrated(rawGrams: 10, slicerGrams: 11, rawSeconds: 3600, slicerSeconds: 3000);
      expect(s.weightFactor, closeTo(1.1, 1e-9));
      expect(s.timeFactor, closeTo(3000 / 3600, 1e-9));
      s = s.calibrated(rawGrams: 10, slicerGrams: 12);
      expect(s.weightFactor, closeTo(1.15, 1e-9));
      expect(s.weightSamples, 2);
      // Time factors are per printer.
      expect(s.copyWith(printerId: 'classic').timeFactor, 1);
      final back = SliceSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.weightFactor, closeTo(1.15, 1e-9));
      expect(back.timeFactor, closeTo(3000 / 3600, 1e-9));
      expect(s.withoutCalibration().isCalibrated, isFalse);
      expect(s.resetAll().weightFactor, closeTo(1.15, 1e-9));
    });
  });

  group('geometry tools', () {
    test('mesh check: watertight, holes, flipped faces, shells', () {
      final ok = checkMesh(box(10, 10, 10));
      expect(ok.isWatertight, isTrue);
      expect(ok.hasProblems, isFalse);
      expect(ok.shells, 1);

      final open = Float32List.fromList(box(10, 10, 10).sublist(9));
      final r = checkMesh(open);
      expect(r.openEdges, 3);
      expect(r.hasProblems, isTrue);

      final flipped = Float32List.fromList(box(10, 10, 10));
      for (int k = 0; k < 3; k++) {
        final t = flipped[3 + k];
        flipped[3 + k] = flipped[6 + k];
        flipped[6 + k] = t;
      }
      expect(checkMesh(flipped).flippedEdges, 3);

      final two = Float32List.fromList([...box(5, 5, 5), ...box(5, 5, 5, 20, 0, 0)]);
      expect(checkMesh(two).shells, 2);
    });

    test('rotations and lay flat', () {
      for (final n in [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.3, -0.5, 0.8), (0.0, 0.0, 1.0), (0.0, 0.0, -1.0)]) {
        final m = rotateToDown(n.$1, n.$2, n.$3);
        final l = math.sqrt(n.$1 * n.$1 + n.$2 * n.$2 + n.$3 * n.$3);
        final z = (m[6] * n.$1 + m[7] * n.$2 + m[8] * n.$3) / l;
        expect(z, closeTo(-1, 1e-9));
      }
      final r = mul3(rot90(2), mul3(rot90(2), mul3(rot90(2), rot90(2))));
      expect(isIdentity(r), isTrue);

      // A standing 5×5×40 bar is laid down on a long face.
      final bar = box(5, 5, 40);
      final m = autoOrient(bar);
      final b = Bounds.of(applyMat3(bar, m));
      expect(b.sizeZ, closeTo(5, 1e-4));
    });

    test('brim and skirt add first-layer plastic', () {
      final plain = sliceMesh(box(20, 20, 4), const SliceSettings());
      final brim = sliceMesh(box(20, 20, 4), const SliceSettings(brimWidth: 5));
      expect(plain.brimVolumeMm3, 0);
      // 4·20·5 + π·5² ≈ 478.5 mm² × 0.2 mm
      expect(brim.brimVolumeMm3, closeTo(95.7, 95.7 * 0.12));
      expect(brim.volumeMm3, closeTo(plain.volumeMm3, plain.volumeMm3 * 0.01));
      expect(brim.preview!.classes.contains(SliceClass.adhesion), isTrue);
      final skirt = sliceMesh(box(20, 20, 4), const SliceSettings(skirtLoops: 1));
      // ring at ~2.2 mm: (80 + 2π·2.2) × 0.42 × 0.2
      expect(skirt.brimVolumeMm3, closeTo(7.9, 7.9 * 0.3));
    });

    test('3MF objects: names, selection, rotation', () async {
      const model = '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">\n'
          ' <resources>'
          '<object id="1" name="Кубик" type="model"><mesh><vertices>'
          '<vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>'
          '</vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>'
          '<triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh></object>'
          '<object id="2" name="Друга" type="model"><mesh><vertices>'
          '<vertex x="0" y="0" z="0"/><vertex x="20" y="0" z="0"/><vertex x="0" y="20" z="0"/><vertex x="0" y="0" z="20"/>'
          '</vertices><triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>'
          '<triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh></object>'
          '</resources>\n <build><item objectid="1"/><item objectid="2" transform="1 0 0 0 1 0 0 0 1 50 0 0"/></build>\n</model>';
      final m = await loadModel('two.3mf', zip({'3D/3dmodel.model': model}));
      expect(m.source.objects.length, 2);
      expect(m.source.objects.first.name, 'Кубик');
      expect(m.mesh.triangleCount, 8);
      final only = await deriveModel(m, enabled: [false, true]);
      expect(only.mesh.triangleCount, 4);
      expect(only.bounds.sizeX, closeTo(20, 1e-4));
      final turned = await deriveModel(only, rotation: rot90(0));
      expect(turned.bounds.sizeY, closeTo(20, 1e-4));
      expect(turned.mesh.signedVolume(), closeTo(only.mesh.signedVolume(), 1e-3));
    });
  });

  group('business', () {
    test('pricing rules: failure, discount, minimum, rounding', () {
      const s = SliceSettings(
        pricesPerKg: {'PLA': 1000},
        powerW: 0,
        amortizationPerHour: 0,
        failurePercent: 10,
        markupPercent: 100,
        discounts: [QtyDiscount(5, 10), QtyDiscount(10, 20)],
        extraCost: 0,
        minOrderPrice: 0,
        roundTo: 5,
      );
      final c = CostBreakdown.of(100, 1, s, copies: 10);
      expect(c.material, closeTo(100, 1e-9));
      expect(c.failure, closeTo(10, 1e-9));
      expect(c.costPrice, closeTo(110, 1e-9));
      expect(c.profit, closeTo(110, 1e-9));
      expect(c.discount, closeTo(44, 1e-9)); // 20 % of 220
      expect(c.price, closeTo(180, 1e-9)); // 176 rounded up to 5
      final small = CostBreakdown.of(1, 0.1, s.copyWith(minOrderPrice: 50));
      expect(small.price, closeTo(50, 1e-9));
      expect(discountFor(s.discounts, 7), 10);
    });

    test('order totals and JSON', () {
      final o = Order(
        id: 'o1',
        createdAt: DateTime(2026, 10, 9),
        client: 'Іван',
        extraCost: 20,
        roundTo: 50,
        discounts: const [QtyDiscount(3, 10)],
        items: const [
          OrderItem(
            id: 'i1',
            name: 'a.stl',
            material: 'PLA',
            materialId: 'PLA',
            qty: 3,
            gramsEach: 10,
            hoursEach: 0.5,
            costEach: 40,
            priceEach: 100,
          ),
        ],
      );
      final t = o.totals;
      expect(t.subtotal, 300);
      expect(t.discount, closeTo(30, 1e-9));
      expect(t.total, closeTo(300, 1e-9)); // 290 → 300
      expect(t.cost, 120);
      expect(t.profit, closeTo(180, 1e-9));
      expect(t.grams, 30);
      final back = Order.fromJson(jsonDecode(jsonEncode(o.toJson())))!;
      expect(back.totals.total, closeTo(300, 1e-9));
      expect(back.client, 'Іван');
      expect(OrderStatus.done.printed, isTrue);

      final sp = Spool(
        id: 's1',
        materialId: 'PETG',
        name: 'Bambu',
        colorArgb: 0xFF000000,
        totalGrams: 1000,
        remainingGrams: 120,
        createdAt: _epoch,
      );
      final sb = Spool.fromJson(jsonDecode(jsonEncode(sp.toJson())))!;
      expect(sb.remainingGrams, 120);
      expect(sb.isLow, isTrue);
    });
  });

  group('plates, vase, colours', () {
    test('copies per plate', () {
      expect(copiesPerPlate(20, 20, 256, 256, 5), 100);
      expect(copiesPerPlate(300, 10, 256, 256, 5), 0);
      // 100×20 fits better rotated on a narrow bed.
      expect(copiesPerPlate(100, 20, 120, 250, 5), copiesPerPlate(20, 100, 120, 250, 5));
      expect(copiesPerPlate(100, 20, 120, 250, 5), greaterThanOrEqualTo(10));
    });

    test('colour waste', () {
      const s = SliceSettings();
      expect(ColorWaste.estimate([1, 1, 1], 0.2, s).changes, 0);
      final w = ColorWaste.estimate([1, 2, 2, 1, 1], 0.2, s);
      expect(w.changes, 2);
      expect(w.flushMm3, 2 * s.flushMm3);
      expect(w.towerMm3, closeTo(3 * 245 * 0.2, 1e-9));
      final noTower = ColorWaste.estimate([2], 0.2, s.copyWith(primeTower: false));
      expect(noTower.towerMm3, 0);
    });

    test('vase mode prints one wall and a bottom', () {
      const base = SliceSettings(layerHeight: 0.2, firstLayerHeight: 0.2, lineWidth: 0.45, bottomLayers: 3);
      final normal = sliceMesh(box(40, 40, 40), base);
      final vase = sliceMesh(box(40, 40, 40), base.copyWith(vaseMode: true));
      const expected = 3 * 1600 * 0.2 + 197 * 160 * 0.45 * 0.2;
      expect(vase.volumeMm3, closeTo(expected, expected * 0.15));
      expect(vase.volumeMm3, lessThan(normal.volumeMm3 * 0.6));
    });

    test('big model: 160k triangle sphere slices fine', () {
      const lat = 200, lon = 400;
      const r = 40.0;
      final out = Float32List(lat * lon * 2 * 9);
      List<double> p(int i, int j) {
        final th = math.pi * i / lat, ph = 2 * math.pi * j / lon;
        return [r * math.sin(th) * math.cos(ph), r * math.sin(th) * math.sin(ph), r + r * math.cos(th)];
      }

      int o = 0;
      void put(List<double> a) {
        for (final v in a) {
          out[o++] = v;
        }
      }

      for (int i = 0; i < lat; i++) {
        for (int j = 0; j < lon; j++) {
          final a = p(i, j), b = p(i + 1, j), c = p(i + 1, j + 1), d = p(i, j + 1);
          put(a);
          put(b);
          put(c);
          put(a);
          put(c);
          put(d);
        }
      }
      final sw = Stopwatch()..start();
      final res = sliceMesh(out, const SliceSettings(infillPercent: 100));
      sw.stop();
      // ignore: avoid_print
      print('sphere 160k tris: ${sw.elapsedMilliseconds} ms, ${res.layers} layers');
      final v = 4 / 3 * math.pi * r * r * r;
      expect(res.volumeMm3, closeTo(v, v * 0.05));
      expect(sw.elapsed.inSeconds, lessThan(120));
    });
  });

  group('business 2', () {
    test('client links', () {
      const c = Client(id: '1', name: 'Оля', phone: '+38 (050) 123-45-67', telegram: '@olya_print');
      expect(c.callUrl, 'tel:+380501234567');
      expect(c.telegramUrl, 'https://t.me/olya_print');
      expect(c.viberUrl, 'viber://chat?number=%2B380501234567');
      const p = Client(id: '2', name: 'Петро', phone: '0671112233');
      expect(p.telegramUrl, 'https://t.me/+0671112233');
      const none = Client(id: '3', name: 'X');
      expect(none.callUrl, isNull);
      expect(none.telegramUrl, isNull);
      final back = Client.fromJson(jsonDecode(jsonEncode(c.toJson())))!;
      expect(back.telegram, '@olya_print');
    });

    test('order deadline and reminders', () {
      final now = DateTime(2026, 10, 9, 12);
      final o = Order(id: 'x', createdAt: now, dueAt: DateTime(2026, 10, 12));
      expect(OrderReminders.fireTime(o, now: now), DateTime(2026, 10, 12, 9));
      expect(OrderReminders.fireTime(o, now: DateTime(2026, 10, 12, 10)), isNull);
      o.status = OrderStatus.done;
      expect(OrderReminders.fireTime(o, now: now), isNull);
      final past = Order(id: 'y', createdAt: now, dueAt: DateTime(2000, 1, 1));
      expect(past.overdue, isTrue);
      expect(Order(id: 'z', createdAt: now).overdue, isFalse);
      final back = Order.fromJson(jsonDecode(jsonEncode(o.toJson())))!;
      expect(back.dueAt, DateTime(2026, 10, 12));
      expect(back.number, '261009-1200');
    });

    test('spool price per kg', () {
      final sp = Spool(
        id: 's',
        materialId: 'PLA',
        name: '',
        colorArgb: 0,
        totalGrams: 1000,
        remainingGrams: 1000,
        createdAt: _epoch,
        price: 650,
      );
      expect(sp.pricePerKg, closeTo(650, 1e-9));
      expect(Spool.fromJson(jsonDecode(jsonEncode(sp.toJson())))!.price, 650);
    });

    test('pdf writer', () {
      final rgba = Uint8List(40 * 30 * 4);
      for (int i = 0; i < rgba.length; i += 4) {
        rgba[i] = 200;
        rgba[i + 3] = i % 8 == 0 ? 255 : 0;
      }
      for (final h in [30, 3000]) {
        final big = h == 30 ? rgba : Uint8List(40 * h * 4);
        final pdf = PdfImage.build(big, 40, h, title: 'Рахунок');
        final text = latin1.decode(pdf);
        expect(text.startsWith('%PDF-1.4'), isTrue);
        expect(text.trimRight().endsWith('%%EOF'), isTrue);
        final start = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!);
        expect(text.substring(start, start + 4), 'xref');
        // Every xref entry points at "N 0 obj".
        final entries = RegExp(r'(\d{10}) 00000 n').allMatches(text).toList();
        for (int k = 0; k < entries.length; k++) {
          final off = int.parse(entries[k].group(1)!);
          expect(text.substring(off).startsWith('${k + 1} 0 obj'), isTrue);
        }
        final pages = RegExp(r'/Count (\d+)').firstMatch(text)!.group(1)!;
        expect(int.parse(pages), h == 30 ? 1 : greaterThan(1));
      }
    });

    test('links and archives', () {
      expect(resolveModelUrl('look https://www.thingiverse.com/thing:12345/files').toString(),
          'https://www.thingiverse.com/thing:12345/zip');
      expect(resolveModelUrl('https://example.com/a.stl').toString(), 'https://example.com/a.stl');
      expect(() => resolveModelUrl('https://makerworld.com/en/models/1'), throwsA(isA<DownloadException>()));
      expect(() => resolveModelUrl('нема посилання'), throwsA(isA<DownloadException>()));
      const stl = 'solid a\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\n'
          'endloop\nendfacet\nendsolid a\n';
      final z = zip({
        'files/big.stl': stl * 1,
        'readme.txt': 'hi',
        '__MACOSX/files/._big.stl': 'x',
        'files/small.3mf': 'x',
      });
      final models = modelsInZip(z);
      expect(models.map((m) => m.name).toList(), ['big.stl', 'small.3mf']);
    });
  });

  group('printers', () {
    test('mqtt packets', () {
      expect(mqttLength(0), [0]);
      expect(mqttLength(127), [127]);
      expect(mqttLength(128), [0x80, 1]);
      expect(mqttLength(16383), [0xff, 0x7f]);
      final c = mqttConnect('id', user: 'bblp', password: '12345678');
      expect(c[0], 0x10);
      expect(c[1], c.length - 2);
      expect(String.fromCharCodes(c.sublist(4, 8)), 'MQTT');
      expect(c[9], 0xC2);

      // A big publish split across chunks + a ping response.
      final payload = List<int>.filled(300, 0x41);
      final pub = mqttPublish('device/X/report', payload);
      final all = [...pub, 0xD0, 0];
      final parser = MqttParser();
      final got = <(int, Uint8List)>[];
      for (int i = 0; i < all.length; i += 7) {
        got.addAll(parser.add(all.sublist(i, math.min(all.length, i + 7))));
      }
      expect(got.length, 2);
      expect(got[0].$1, 0x30);
      expect(got[0].$2.length, 2 + 'device/X/report'.length + 300);
      expect(got[1].$1, 0xD0);
    });

    test('bambu report', () {
      final st = <String, dynamic>{};
      mergeBambuReport(st, {
        'gcode_state': 'RUNNING',
        'mc_percent': 42,
        'mc_remaining_time': 75,
        'layer_num': 10,
        'total_layer_num': 120,
        'subtask_name': 'cube',
        'nozzle_temper': 219.5,
        'nozzle_target_temper': 220,
        'ams': {
          'tray_now': '1',
          'ams': [
            {
              'id': '0',
              'tray': [
                {'id': '0', 'tray_type': 'PLA', 'tray_color': 'FF0000FF', 'remain': 50, 'tray_weight': '1000'},
                {'id': '1', 'tray_type': 'PETG', 'tray_color': '00FF00FF', 'remain': -1, 'tray_sub_brands': 'PETG HF'},
                {'id': '2'},
              ],
            },
          ],
        },
      });
      mergeBambuReport(st, {'mc_percent': 43});
      final s = bambuStatus(st);
      expect(s.printing, isTrue);
      expect(s.state, 'Друкує');
      expect(s.progress, closeTo(0.43, 1e-9));
      expect(s.remaining, const Duration(minutes: 75));
      expect(s.slots.length, 2);
      expect(s.slots[0].remainingGrams, 500);
      expect(s.slots[0].colorArgb, 0xFFFF0000);
      expect(s.slots[1].remainPercent, isNull);
      expect(s.slots[1].active, isTrue);
      expect(s.slots[1].label, 'AMS 1 · слот 2');
      expect(materialIdForType(s.slots[1].brand), 'PETG');
    });

    test('moonraker status and history', () {
      final s = moonrakerStatus({
        'print_stats': {'state': 'printing', 'filename': 'a.gcode', 'print_duration': 600.0},
        'virtual_sdcard': {'progress': 0.25},
        'extruder': {'temperature': 240.0, 'target': 240.0},
      });
      expect(s.printing, isTrue);
      expect(s.remaining, const Duration(seconds: 1800));
      expect(s.nozzle, 240);
      final j = PrintJob.fromJson({
        'job_id': '00001A',
        'filename': 'a.gcode',
        'status': 'completed',
        'end_time': 1700000000.5,
        'filament_used': 1000.0,
        'print_duration': 3600.0,
        'metadata': <String, dynamic>{},
      })!;
      // 1 m of 1.75 mm PLA ≈ 2.98 g
      expect(j.gramsFor(1.24), closeTo(2.98, 0.01));
      final withMeta = PrintJob.fromJson({
        'job_id': '2',
        'filament_used': 1000.0,
        'metadata': {'filament_weight_total': 3.5},
      })!;
      expect(withMeta.gramsFor(1.24), 3.5);
      final p = PrinterConn.fromJson(jsonDecode(jsonEncode(const PrinterConn(
        id: 'p',
        name: 'K1',
        kind: PrinterKind.moonraker,
        host: '192.168.1.5',
        writtenOff: ['1'],
      ).toJson())))!;
      expect(p.kind, PrinterKind.moonraker);
      expect(p.writtenOff, ['1']);
    });
  });

  group('currency and labels', () {
    test('currency conversion', () {
      const s = SliceSettings(pricesPerKg: {'PETG': 700}, tariff: 4.8, amortizationPerHour: 8, roundTo: 10);
      final e = s.withCurrency('EUR', 48);
      expect(e.currency, 'EUR');
      expect(e.pricesPerKg['PETG'], closeTo(700 / 48, 1e-9));
      expect(e.copyWith(materialId: 'PLA').pricePerKg, closeTo(600 / 48, 1e-9)); // default converted
      expect(e.tariff, closeTo(0.1, 1e-9));
      expect(e.roundTo, 0.1);
      final back = e.withCurrency('UAH', 1);
      expect(back.pricesPerKg['PETG'], closeTo(700, 1e-6));
      expect(back.tariff, closeTo(4.8, 1e-9));
      expect(e.moneyDefaults.amortizationPerHour, closeTo(8 / 48, 1e-9));
      final j = SliceSettings.fromJson(e.toJson());
      expect(j.currency, 'EUR');
      expect(j.currencyRate, 48);
      expect(fmtMoney(12.5, code: 'EUR'), '12,50 €');
      expect(fmtMoney(12.5, code: 'USD'), r'12,50 $');
      expect(fmtMoney(12.5, code: 'UAH'), '12,50 грн');
      final o = Order.create(e);
      expect(Order.fromJson(jsonDecode(jsonEncode(o.toJson())))!.currency, 'EUR');
    });

    test('spool label parsing', () {
      var l = parseSpoolLabel('Bambu Lab\nPLA Basic\nJade White\n10100\n1.75 mm ±0.02mm\nNet Weight: 1kg\n');
      expect(l.brand, 'Bambu Lab');
      expect(l.materialId, 'PLA');
      expect(l.materialText, 'PLA Basic');
      expect(l.colorName, 'Jade White');
      expect(l.colorArgb, 0xFFFFFFFF);
      expect(l.weightGrams, 1000);
      expect(l.name, 'Bambu Lab, Jade White');

      l = parseSpoolLabel('eSUN\nPETG\nDiameter 1.75mm\nColor: Black\nN.W. 1KG(2.2LBS)\nSpool weight 230g');
      expect(l.brand, 'eSUN');
      expect(l.materialId, 'PETG');
      expect(l.colorName, 'Black');
      expect(l.weightGrams, 1000);

      l = parseSpoolLabel('PolyTerra™ PLA\nCharcoal Black\n1000g\nPolymaker');
      expect(l.brand, 'Polymaker');
      expect(l.colorName, 'Charcoal Black');
      expect(l.weightGrams, 1000);

      l = parseSpoolLabel('SUNLU PLA-CF 0.5kg Navy Blue');
      expect(l.materialId, 'PLA-CF');
      expect(l.weightGrams, 500);
      expect(l.colorArgb, 0xFF1E88E5);

      l = parseSpoolLabel('Creality Hyper Series ASA\nGrey 1kg');
      expect(l.brand, 'Creality');
      expect(l.materialId, 'ASA');
      expect(l.colorArgb, 0xFF9E9E9E);

      // SUNLU spool label without the brand name (photo from a user).
      l = parseSpoolLabel('PETG Black Ø1.75mm\n01240722Z\n\nPrint Temp:230-240℃50-100mm/s\n'
          'Print Temp:240-260℃100-200mm/s\nBed temp:60-70℃\n\n1000g\n');
      expect(l.materialId, 'PETG');
      expect(l.colorName, 'Black');
      expect(l.colorArgb, 0xFF202020);
      expect(l.weightGrams, 1000);
      expect(l.name, 'Black');

      expect(parseSpoolLabel('hello world').isEmpty, isTrue);
    });
  });
}

final _epoch = DateTime.fromMillisecondsSinceEpoch(0);
