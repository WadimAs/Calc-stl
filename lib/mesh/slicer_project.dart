import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../slicer/settings.dart';
import 'zip_reader.dart';

/// Weight / time of one plate as computed by the slicer that made the file.
/// One filament used on a sliced plate.
class SlicedFilament {
  final String type;
  final String color; // #RRGGBB or ''
  final double grams;

  const SlicedFilament(this.type, this.color, this.grams);
}

class SlicedPlate {
  final int index;
  final double grams;
  final double seconds;
  final double meters;
  final List<SlicedFilament> filaments;

  const SlicedPlate({
    required this.index,
    required this.grams,
    required this.seconds,
    required this.meters,
    this.filaments = const [],
  });
}

/// Print settings and (for sliced files) exact results found in a 3MF
/// project or a G-code file from Bambu Studio, OrcaSlicer, PrusaSlicer or Cura.
class SlicerProject {
  final String app;
  final String? printProfile;
  final String? printerModel;
  final String? filamentType;
  final String? filamentProfile;
  final double? layerHeight;
  final double? firstLayerHeight;
  final double? lineWidth;
  final int? walls;
  final int? topLayers;
  final int? bottomLayers;
  final double? infillPercent;
  final bool? supports;
  final bool? supportTree;
  final bool? supportPlateOnly;

  /// Our convention: overhang angle measured from vertical.
  final double? supportAngle;
  final bool? ensureVertical;
  final double? density;
  final double? filamentDiameter;
  final double? brimWidth;
  final int? skirtLoops;
  final bool? vase;
  final List<SlicedPlate> plates;
  final Uint8List? thumbnail;

  const SlicerProject({
    required this.app,
    this.printProfile,
    this.printerModel,
    this.filamentType,
    this.filamentProfile,
    this.layerHeight,
    this.firstLayerHeight,
    this.lineWidth,
    this.walls,
    this.topLayers,
    this.bottomLayers,
    this.infillPercent,
    this.supports,
    this.supportTree,
    this.supportPlateOnly,
    this.supportAngle,
    this.ensureVertical,
    this.density,
    this.filamentDiameter,
    this.brimWidth,
    this.skirtLoops,
    this.vase,
    this.plates = const [],
    this.thumbnail,
  });

  bool get hasSettings => layerHeight != null || walls != null || infillPercent != null;

  bool get isSliced => plates.any((p) => p.grams > 0 || p.seconds > 0);

  double get grams => plates.fold(0.0, (a, p) => a + p.grams);
  double get seconds => plates.fold(0.0, (a, p) => a + p.seconds);
  double get meters => plates.fold(0.0, (a, p) => a + p.meters);

  /// Grams per filament (by type + colour) over all plates.
  List<SlicedFilament> get filaments {
    final m = <String, SlicedFilament>{};
    for (final p in plates) {
      for (final f in p.filaments) {
        final k = '${f.type}|${f.color}';
        final o = m[k];
        m[k] = SlicedFilament(f.type, f.color, (o?.grams ?? 0) + f.grams);
      }
    }
    return m.values.toList();
  }

  /// Our material id for the file's filament type.
  String? get materialId {
    final t = filamentType?.toUpperCase().trim();
    if (t == null || t.isEmpty) return null;
    for (final m in materials) {
      if (m.id == t) return m.id;
    }
    if (t.startsWith('PLA-CF') || t == 'PLA CF') return 'PLA-CF';
    if (t.startsWith('PETG-CF') || t.startsWith('PET-CF')) return 'PETG-CF';
    if (t.startsWith('PLA')) return 'PLA';
    if (t.startsWith('PETG') || t == 'PET' || t == 'PCTG') return 'PETG';
    if (t.startsWith('ABS')) return 'ABS';
    if (t.startsWith('ASA')) return 'ASA';
    if (t.startsWith('TPU') || t.startsWith('TPE') || t == 'FLEX') return 'TPU';
    if (t.startsWith('PA') || t.startsWith('NYLON')) return 'PA';
    if (t.startsWith('PC')) return 'PC';
    if (t.startsWith('HIPS')) return 'HIPS';
    if (t.startsWith('PVA')) return 'PVA';
    return 'custom';
  }

  /// Our printer profile for the file's printer, if recognised.
  String? get printerId {
    final m = printerModel?.toLowerCase();
    if (m == null || m.isEmpty) return null;
    bool has(String s) => m.contains(s);
    if (has('bambu') || has('bbl')) {
      if (has('a1 mini') || has('a1m')) return 'bambu_a1mini';
      if (has('a1')) return 'bambu_a1';
      if (has('h2')) return 'bambu_h2d';
      return 'bambu';
    }
    if (has('creality') || has('ender') || has('k1') || has('k2') || has('cr-')) {
      if (has('k1 max') || has('k2 plus') || has('k2')) return 'creality_k1max';
      if (has('k1')) return 'creality_k1';
      if (has('v3 plus')) return 'creality_v3plus';
      if (has('v3 se') || has('ender-5 s1') || has('ender 5 s1')) return 'creality_v3se';
      if (has('v3')) return 'creality_v3';
      return 'creality_classic';
    }
    if (has('anycubic') || has('kobra') || has('vyper') || has('i3 mega')) {
      if (has('s1')) return 'anycubic_s1';
      if (has('max')) return 'anycubic_k3max';
      if (has('kobra 3') || has('kobra 2 pro') || has('kobra 2 plus')) return 'anycubic_k3';
      if (has('kobra 2')) return 'anycubic_k2';
      return 'anycubic_classic';
    }
    if (has('elegoo') || has('neptune') || has('centauri')) {
      if (has('centauri')) return 'elegoo_cc';
      if ((has('neptune 4') || has('neptune4')) && (has('plus') || has('max'))) return 'elegoo_n4max';
      if (has('neptune 4') || has('neptune4')) return 'elegoo_n4';
      return 'elegoo_n3';
    }
    if (has('prusa') || has('mk4') || has('mk3') || has('core one')) {
      if (has('mk3')) return 'prusa_mk3';
      if (has('core one')) return 'prusa_core';
      return 'prusa_mk4';
    }
    if (has('voron')) return 'klipper';
    return null;
  }

  /// [s] with every setting the file defines.
  SliceSettings applyTo(SliceSettings s) {
    final mat = materialId;
    return s.copyWith(
      layerHeight: layerHeight,
      firstLayerHeight: firstLayerHeight,
      lineWidth: lineWidth,
      walls: walls,
      topLayers: topLayers,
      bottomLayers: bottomLayers,
      infillPercent: infillPercent,
      supportsEnabled: supports,
      supportType: supportTree == null ? null : (supportTree! ? 'tree' : 'normal'),
      supportPlateOnly: supportPlateOnly,
      supportAngle: supportAngle,
      ensureVerticalShell: ensureVertical,
      materialId: mat,
      density: density ?? (mat != null ? materialById(mat).density : null),
      filamentDiameter: filamentDiameter == null ? null : (filamentDiameter! > 2.3 ? 2.85 : 1.75),
      printerId: printerId,
      powerW: printerId == null ? null : printerById(printerId!).powerW,
      brimWidth: brimWidth,
      skirtLoops: skirtLoops,
      vaseMode: vase,
    );
  }

  /// Human-readable list of the settings found.
  List<String> describe() {
    String n(double v, int d) => v.toStringAsFixed(d).replaceAll('.', ',');
    return [
      if (printProfile != null) 'Профіль: $printProfile',
      if (printerModel != null) 'Принтер: $printerModel',
      if (filamentType != null)
        'Пластик: $filamentType${density != null ? ', ${n(density!, 2)} г/см³' : ''}',
      if (layerHeight != null)
        'Шар ${n(layerHeight!, 2)} мм${firstLayerHeight != null ? ', перший ${n(firstLayerHeight!, 2)} мм' : ''}',
      if (walls != null) 'Стінки: $walls',
      if (topLayers != null || bottomLayers != null) 'Верх / низ: ${topLayers ?? '—'} / ${bottomLayers ?? '—'} шарів',
      if (infillPercent != null) 'Заповнення: ${n(infillPercent!, 0)}%',
      if (vase == true) 'Режим вази',
      if (brimWidth != null && brimWidth! > 0) 'Кайма: ${n(brimWidth!, 0)} мм',
      if (skirtLoops != null && skirtLoops! > 0) 'Спідниця: $skirtLoops',
      if (supports != null)
        supports!
            ? 'Підтримки: ${supportTree == true ? 'деревоподібні' : 'звичайні'}'
                '${supportPlateOnly == true ? ', лише від столу' : ''}'
            : 'Підтримки: вимкнено',
    ];
  }
}

// ---------------------------------------------------------------- parsing

double? _num(String? v, {double? percentOf}) {
  if (v == null) return null;
  var s = v.trim();
  if (s.isEmpty || s == 'nil') return null;
  // First element of lists such as "0.4,0.4" or "PLA;PLA".
  s = s.split(RegExp(r'[,;]')).first.trim();
  if (s.endsWith('%')) {
    final p = double.tryParse(s.substring(0, s.length - 1));
    if (p == null) return null;
    return percentOf == null ? p : p / 100 * percentOf;
  }
  return double.tryParse(s);
}

String? _first(String? v) {
  if (v == null) return null;
  final s = v.split(';').first.trim();
  return s.isEmpty ? null : s;
}

bool? _flag(String? v) {
  if (v == null) return null;
  final s = v.trim().toLowerCase();
  if (s.isEmpty) return null;
  if (s == '1' || s == 'true' || s == 'yes' || s == 'enabled') return true;
  if (s == '0' || s == 'false' || s == 'no' || s == 'none' || s == 'disabled') return false;
  return true; // e.g. Orca "ensure_all", "ensure_critical_only"
}

/// Settings dictionary from Bambu/Orca JSON or PrusaSlicer "key = value" text.
Map<String, String> _parseConfig(String text) {
  final out = <String, String>{};
  final trimmed = text.trimLeft();
  if (trimmed.startsWith('{')) {
    try {
      final j = jsonDecode(trimmed);
      if (j is Map) {
        j.forEach((k, v) {
          if (v is List) {
            if (v.isNotEmpty) out['$k'] = '${v.first}';
          } else if (v != null) {
            out['$k'] = '$v';
          }
        });
      }
      return out;
    } catch (_) {}
  }
  final re = RegExp(r'^[;\s]*([A-Za-z0-9_]+)\s*=\s*(.*)$', multiLine: true);
  for (final m in re.allMatches(text)) {
    out.putIfAbsent(m.group(1)!, () => m.group(2)!.trim());
  }
  return out;
}

SlicerProject _fromConfig(String app, Map<String, String> c,
    {List<SlicedPlate> plates = const [], Uint8List? thumbnail}) {
  String? g(List<String> keys) {
    for (final k in keys) {
      final v = c[k];
      if (v != null && v.trim().isNotEmpty) return v;
    }
    return null;
  }

  final nozzle = _num(g(['nozzle_diameter'])) ?? 0.4;
  final layer = _num(g(['layer_height']));
  final first = _num(g(['initial_layer_print_height', 'first_layer_height']), percentOf: layer);
  double? width = _num(g(['inner_wall_line_width', 'perimeter_extrusion_width', 'line_width', 'extrusion_width']),
      percentOf: nozzle);
  if (width != null && width <= 0) width = null;

  int? layers(String countKey, String thickKey) {
    final count = _num(g([countKey]))?.round();
    final thick = _num(g([thickKey]));
    if (count == null) return null;
    if (thick != null && layer != null && layer > 0) {
      return math.max(count, (thick / layer - 1e-6).ceil());
    }
    return count;
  }

  final top = layers(c.containsKey('top_shell_layers') ? 'top_shell_layers' : 'top_solid_layers',
      c.containsKey('top_shell_thickness') ? 'top_shell_thickness' : 'top_solid_min_thickness');
  final bottom = layers(c.containsKey('bottom_shell_layers') ? 'bottom_shell_layers' : 'bottom_solid_layers',
      c.containsKey('bottom_shell_thickness') ? 'bottom_shell_thickness' : 'bottom_solid_min_thickness');

  final infillRaw = g(['sparse_infill_density', 'fill_density']);
  double? infill = _num(infillRaw);
  if (infill != null && infillRaw != null && !infillRaw.contains('%') && infill <= 1) infill *= 100;

  final supports = _flag(g(['enable_support', 'support_material']));
  final typeRaw = g(['support_type', 'support_material_style'])?.toLowerCase();
  final tree = typeRaw == null ? null : (typeRaw.contains('tree') || typeRaw.contains('organic'));
  // Slicers measure the threshold from the horizontal; 0 means automatic.
  double? angle;
  final thr = _num(g(['support_threshold_angle', 'support_material_threshold']));
  if (thr != null) angle = 90 - (thr > 0 ? thr : 30);

  final filament = _first(g(['filament_type']));
  // Brim: Bambu/Orca brim_type + brim_width; Prusa brim_width. "auto" is
  // decided by the slicer per model, so it is not assumed here.
  double? brim;
  final brimType = g(['brim_type'])?.toLowerCase();
  final brimW = _num(g(['brim_width']));
  if (brimType != null) {
    brim = (brimType.contains('no_brim') || brimType.contains('auto') || brimW == null) ? 0 : brimW;
  } else if (brimW != null) {
    brim = brimW;
  }
  final skirt = _num(g(['skirt_loops', 'skirts']))?.round();
  return SlicerProject(
    app: app,
    printProfile: _first(g(['print_settings_id'])),
    printerModel: _first(g(['printer_model', 'printer_settings_id', 'printer_notes'])),
    filamentType: filament,
    filamentProfile: _first(g(['filament_settings_id'])),
    layerHeight: layer,
    firstLayerHeight: first,
    lineWidth: width,
    walls: _num(g(['wall_loops', 'perimeters']))?.round(),
    topLayers: top,
    bottomLayers: bottom,
    infillPercent: infill,
    supports: supports,
    supportTree: tree,
    supportPlateOnly: _flag(g(['support_on_build_plate_only', 'support_material_buildplate_only'])),
    supportAngle: angle,
    ensureVertical: _flag(g(['ensure_vertical_shell_thickness'])),
    density: _num(g(['filament_density'])),
    filamentDiameter: _num(g(['filament_diameter'])),
    brimWidth: brim,
    skirtLoops: skirt,
    vase: _flag(g(['spiral_mode', 'spiral_vase'])),
    plates: plates,
    thumbnail: thumbnail,
  );
}

String _appName(String raw) {
  final s = raw.toLowerCase();
  if (s.contains('bambu')) return 'Bambu Studio';
  if (s.contains('orca')) return 'OrcaSlicer';
  if (s.contains('prusa')) return 'PrusaSlicer';
  if (s.contains('cura')) return 'Cura';
  if (s.contains('creality')) return 'Creality Print';
  if (s.contains('elegoo')) return 'ElegooSlicer';
  if (s.contains('anycubic')) return 'AnycubicSlicer';
  if (s.contains('superslicer')) return 'SuperSlicer';
  return raw.trim().isEmpty ? 'слайсер' : raw.trim();
}

/// Parses durations like "1d 2h 3m 4s", "58m 10s" or a plain number of seconds.
double? parseDuration(String s) {
  final t = s.trim();
  final plain = double.tryParse(t);
  if (plain != null) return plain;
  double total = 0;
  bool any = false;
  for (final m in RegExp(r'(\d+(?:\.\d+)?)\s*([dhms])').allMatches(t)) {
    final v = double.parse(m.group(1)!);
    any = true;
    switch (m.group(2)) {
      case 'd':
        total += v * 86400;
      case 'h':
        total += v * 3600;
      case 'm':
        total += v * 60;
      default:
        total += v;
    }
  }
  return any ? total : null;
}

double _sumList(String v) {
  double s = 0;
  for (final part in v.split(RegExp(r'[,;\s]+'))) {
    s += double.tryParse(part.trim()) ?? 0;
  }
  return s;
}

/// Weight, time and settings from the comments of a G-code file.
SlicerProject? readGcode(Uint8List bytes) {
  const chunk = 512 * 1024;
  final head = latin1.decode(Uint8List.sublistView(bytes, 0, math.min(bytes.length, chunk)));
  final tail = bytes.length > chunk
      ? latin1.decode(Uint8List.sublistView(bytes, math.max(chunk, bytes.length - chunk)))
      : '';
  final text = '$head\n$tail';

  String? find(List<RegExp> res) {
    for (final re in res) {
      final m = re.firstMatch(text);
      if (m != null) return m.group(1);
    }
    return null;
  }

  RegExp r(String p) => RegExp(p, caseSensitive: false, multiLine: true);

  final appRaw = find([
        r(r'^;\s*generated by\s+(.+)$'),
        r(r'^;\s*(BambuStudio[^\r\n]*)$'),
        r(r'^;\s*(OrcaSlicer[^\r\n]*)$'),
        r(r'^;Generated with\s+(.+)$'),
        r(r'^;\s*(PrusaSlicer[^\r\n]*)$'),
      ]) ??
      '';
  final gramsRaw = find([
    r(r'^;\s*total filament weight \[g\]\s*[:=]\s*([\d.,\s]+)$'),
    r(r'^;\s*total filament used \[g\]\s*[:=]\s*([\d.,\s]+)$'),
    r(r'^;\s*filament used \[g\]\s*[:=]\s*([\d.,\s]+)$'),
  ]);
  final secondsRaw = find([
    r(r'total estimated time\s*[:=]\s*([0-9dhms .]+)'),
    r(r'^;\s*estimated printing time \(normal mode\)\s*=\s*([0-9dhms .]+)$'),
    r(r'^;\s*estimated printing time\s*[:=]\s*([0-9dhms .]+)$'),
    r(r'^;TIME:\s*([\d.]+)$'),
    r(r'^;\s*model printing time\s*[:=]\s*([0-9dhms .]+)'),
  ]);
  final mmRaw = find([
    r(r'^;\s*total filament length \[mm\]\s*[:=]\s*([\d.,\s]+)$'),
    r(r'^;\s*filament used \[mm\]\s*[:=]\s*([\d.,\s]+)$'),
  ]);
  final curaMeters = find([r(r'^;Filament used:\s*([\d.,m\s]+)$')]);

  final config = _parseConfig(text);
  final density = _num(config['filament_density']) ??
      _num(find([r(r'^;\s*filament_density:\s*([\d.,]+)$')]));
  final diameter = _num(config['filament_diameter']) ??
      _num(find([r(r'^;\s*filament_diameter:\s*([\d.,]+)$')])) ??
      1.75;

  double meters = 0;
  if (mmRaw != null) {
    meters = _sumList(mmRaw) / 1000;
  } else if (curaMeters != null) {
    meters = _sumList(curaMeters.replaceAll('m', ' '));
  }
  double grams = gramsRaw == null ? 0 : _sumList(gramsRaw);
  if (grams <= 0 && meters > 0) {
    final r2 = diameter / 2;
    grams = meters * 1000 * math.pi * r2 * r2 * (density ?? 1.24) / 1000;
  }
  final seconds = secondsRaw == null ? 0.0 : (parseDuration(secondsRaw) ?? 0.0);
  if (grams <= 0 && seconds <= 0) return null;

  // Cura names the settings differently; pick the essentials from its header.
  if (!config.containsKey('layer_height')) {
    final lh = find([r(r'^;Layer height:\s*([\d.]+)$')]);
    if (lh != null) config['layer_height'] = lh;
  }
  return _fromConfig(
    _appName(appRaw),
    config,
    plates: [SlicedPlate(index: 1, grams: grams, seconds: seconds, meters: meters)],
    thumbnail: _gcodeThumbnail(head),
  );
}

/// Largest PNG/JPG thumbnail embedded as base64 comments.
Uint8List? _gcodeThumbnail(String head) {
  final re = RegExp(
    r'^;\s*thumbnail(?:_(PNG|JPG))?\s+begin\s+(\d+)x(\d+)[^\n]*\n([\s\S]*?)^;\s*thumbnail(?:_(?:PNG|JPG))?\s+end',
    multiLine: true,
  );
  Uint8List? best;
  int bestArea = 0;
  for (final m in re.allMatches(head)) {
    final area = int.parse(m.group(2)!) * int.parse(m.group(3)!);
    if (area <= bestArea) continue;
    final b64 = m.group(4)!.replaceAll(RegExp(r'[;\s]'), '');
    try {
      best = base64.decode(b64);
      bestArea = area;
    } catch (_) {}
  }
  return best;
}

/// Settings and sliced results of a 3MF package, or null when it has neither.
SlicerProject? readProjectFrom3mf(Uint8List bytes) {
  final ZipReader zip;
  try {
    zip = ZipReader(bytes);
  } catch (_) {
    return null;
  }
  final byLower = <String, String>{for (final n in zip.names) n.toLowerCase(): n};
  String? text(String lowerName) {
    final real = byLower[lowerName];
    if (real == null) return null;
    try {
      return utf8.decode(zip.read(real), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  Uint8List? file(String lowerName) {
    final real = byLower[lowerName];
    if (real == null) return null;
    try {
      return zip.read(real);
    } catch (_) {
      return null;
    }
  }

  String app = '';
  final model = text('3d/3dmodel.model');
  if (model != null) {
    final m = RegExp(r'<metadata\s+name="Application"\s*>([^<]*)<').firstMatch(model);
    if (m != null) app = m.group(1)!;
  }

  final configText = text('metadata/project_settings.config') ??
      text('metadata/slic3r_pe.config') ??
      text('metadata/prusaslicer.config');
  final config = configText == null ? <String, String>{} : _parseConfig(configText);
  if (app.isEmpty && byLower.containsKey('metadata/slic3r_pe.config')) app = 'PrusaSlicer';

  // Sliced results: Bambu/Orca slice_info, else the plate G-code headers.
  final plates = <SlicedPlate>[];
  final info = text('metadata/slice_info.config');
  if (info != null) {
    for (final pm in RegExp(r'<plate>([\s\S]*?)</plate>').allMatches(info)) {
      final body = pm.group(1)!;
      String? meta(String key) => RegExp('<metadata\\s+key="$key"\\s+value="([^"]*)"').firstMatch(body)?.group(1);
      final index = int.tryParse(meta('index') ?? '') ?? plates.length + 1;
      double grams = double.tryParse(meta('weight') ?? '') ?? 0;
      final seconds = double.tryParse(meta('prediction') ?? '') ?? 0;
      double meters = 0;
      double filamentGrams = 0;
      final fils = <SlicedFilament>[];
      for (final fm in RegExp(r'<filament\s[^>]*>').allMatches(body)) {
        final tag = fm.group(0)!;
        String? attr(String n) => RegExp('$n="([^"]*)"').firstMatch(tag)?.group(1);
        final g = double.tryParse(attr('used_g') ?? '') ?? 0;
        meters += double.tryParse(attr('used_m') ?? '') ?? 0;
        filamentGrams += g;
        if (g > 0) fils.add(SlicedFilament(attr('type') ?? '', attr('color') ?? '', g));
      }
      if (grams <= 0) grams = filamentGrams;
      if (grams > 0 || seconds > 0) {
        plates.add(SlicedPlate(index: index, grams: grams, seconds: seconds, meters: meters, filaments: fils));
      }
    }
  }
  if (plates.isEmpty) {
    final gcodes = byLower.keys.where((k) => RegExp(r'^metadata/plate_\d+\.gcode$').hasMatch(k)).toList()..sort();
    for (final k in gcodes) {
      final data = file(k);
      if (data == null) continue;
      final g = readGcode(data);
      if (g == null || !g.isSliced) continue;
      final idx = int.tryParse(RegExp(r'plate_(\d+)').firstMatch(k)!.group(1)!) ?? plates.length + 1;
      final p = g.plates.first;
      plates.add(SlicedPlate(index: idx, grams: p.grams, seconds: p.seconds, meters: p.meters));
    }
  }

  if (config.isEmpty && plates.isEmpty) return null;
  final thumb = file('metadata/plate_1.png') ??
      file('metadata/thumbnail.png') ??
      file('auxiliaries/.thumbnails/thumbnail_middle.png') ??
      file('auxiliaries/.thumbnails/thumbnail_3mf.png');
  return _fromConfig(_appName(app), config, plates: plates, thumbnail: thumb);
}
