class FilamentMaterial {
  final String id;
  final String name;
  final double density; // g/cm³
  final double defaultPricePerKg; // грн

  /// Typical max volumetric flow, mm³/s (limits speed on fast printers).
  final double maxFlow;

  const FilamentMaterial(this.id, this.name, this.density, this.defaultPricePerKg, this.maxFlow);
}

const materials = <FilamentMaterial>[
  FilamentMaterial('PLA', 'PLA', 1.24, 600, 21),
  FilamentMaterial('PETG', 'PETG', 1.27, 650, 13),
  FilamentMaterial('ABS', 'ABS', 1.04, 600, 18),
  FilamentMaterial('ASA', 'ASA', 1.07, 800, 18),
  FilamentMaterial('TPU', 'TPU', 1.21, 950, 3.6),
  FilamentMaterial('PA', 'Nylon (PA)', 1.14, 1500, 10),
  FilamentMaterial('PC', 'PC', 1.20, 1300, 12),
  FilamentMaterial('PLA-CF', 'PLA-CF', 1.29, 1100, 15),
  FilamentMaterial('PETG-CF', 'PETG-CF', 1.30, 1200, 12),
  FilamentMaterial('HIPS', 'HIPS', 1.04, 650, 15),
  FilamentMaterial('PVA', 'PVA', 1.23, 2200, 8),
  FilamentMaterial('custom', 'Свій матеріал', 1.24, 600, 15),
];

/// Speeds (mm/s) and overheads used for the print-time estimate.
class PrinterProfile {
  final String id;
  final String brand;
  final String name;
  final double outerWall, innerWall, sparse, solid, support, firstLayer;

  /// Seconds per layer (layer change, wipe, retraction, travel overhead).
  final double layerSeconds;

  /// Multiplier for acceleration / short moves: real time vs. length / speed.
  final double accelFactor;

  /// Heating, calibration, purge — once per print, minutes.
  final double startMinutes;

  /// Typical average consumption, W.
  final double powerW;

  const PrinterProfile({
    required this.id,
    required this.brand,
    required this.name,
    required this.outerWall,
    required this.innerWall,
    required this.sparse,
    required this.solid,
    required this.support,
    required this.firstLayer,
    required this.layerSeconds,
    required this.accelFactor,
    required this.startMinutes,
    required this.powerW,
  });

  String get fullName => '$brand $name';
}

// Fast CoreXY / Klipper machines (300+ mm/s class).
const _fastCoreXY = (outer: 200.0, inner: 300.0, sparse: 270.0, solid: 250.0, support: 150.0, first: 50.0);
// Bed-slingers with Klipper / input shaping (~250 mm/s class).
const _fastSlinger = (outer: 150.0, inner: 220.0, sparse: 250.0, solid: 200.0, support: 150.0, first: 50.0);
// Mid-speed machines (~150 mm/s class).
const _mid = (outer: 100.0, inner: 150.0, sparse: 180.0, solid: 150.0, support: 100.0, first: 40.0);
// Classic Marlin machines (~50–80 mm/s).
const _classic = (outer: 35.0, inner: 60.0, sparse: 80.0, solid: 60.0, support: 50.0, first: 20.0);

PrinterProfile _p(
  String id,
  String brand,
  String name,
  ({double outer, double inner, double sparse, double solid, double support, double first}) v, {
  required double power,
  double layer = 2.5,
  double accel = 1.6,
  double start = 4,
}) =>
    PrinterProfile(
      id: id,
      brand: brand,
      name: name,
      outerWall: v.outer,
      innerWall: v.inner,
      sparse: v.sparse,
      solid: v.solid,
      support: v.support,
      firstLayer: v.first,
      layerSeconds: layer,
      accelFactor: accel,
      startMinutes: start,
      powerW: power,
    );

final printers = <PrinterProfile>[
  _p('bambu', 'Bambu Lab', 'X1 / P1 / H2D', _fastCoreXY, power: 140),
  _p('bambu_a1', 'Bambu Lab', 'A1 / A1 mini', _fastCoreXY, power: 95, accel: 1.7),
  _p('creality_k1', 'Creality', 'K1 / K1C / K1 Max / K2', _fastCoreXY, power: 180, accel: 1.7),
  _p('creality_v3', 'Creality', 'Ender-3 V3 / V3 KE / V3 Plus', _fastSlinger, power: 130),
  _p('creality_v3se', 'Creality', 'Ender-3 V3 SE / Ender-5 S1', _mid, power: 120, accel: 1.5),
  _p('creality_classic', 'Creality', 'Ender-3 / V2 / S1 / CR-10', _classic, power: 120, layer: 1.5, accel: 1.15, start: 5),
  _p('anycubic_s1', 'Anycubic', 'Kobra S1', _fastCoreXY, power: 150, accel: 1.7),
  _p('anycubic_k3', 'Anycubic', 'Kobra 3 / Kobra 2 Pro / Max', _fastSlinger, power: 140),
  _p('anycubic_k2', 'Anycubic', 'Kobra 2 / Kobra 2 Neo', _mid, power: 130, accel: 1.5),
  _p('anycubic_classic', 'Anycubic', 'Kobra / Vyper / i3 Mega', _classic, power: 120, layer: 1.5, accel: 1.15, start: 5),
  _p('elegoo_cc', 'Elegoo', 'Centauri Carbon', _fastCoreXY, power: 150, accel: 1.7),
  _p('elegoo_n4', 'Elegoo', 'Neptune 4 / 4 Pro / 4 Plus / 4 Max', _fastSlinger, power: 150),
  _p('elegoo_n3', 'Elegoo', 'Neptune 3 / 3 Pro / 3 Plus / 3 Max', _classic, power: 120, layer: 1.5, accel: 1.15, start: 5),
  _p('prusa_mk4', 'Prusa', 'MK4 / MK4S / Core One', _mid, power: 110, accel: 1.5),
  _p('prusa_mk3', 'Prusa', 'MK3S / MK3S+', _classic, power: 100, layer: 1.5, accel: 1.15, start: 5),
  _p('klipper', 'Інші', 'Швидкий Klipper (Voron тощо)', _fastSlinger, power: 160, layer: 2, accel: 1.5),
  _p('classic', 'Інші', 'Класичний Marlin', _classic, power: 120, layer: 1.5, accel: 1.15, start: 5),
];

List<String> get printerBrands => [
      for (final p in printers)
        if (p == printers.firstWhere((q) => q.brand == p.brand)) p.brand,
    ];

PrinterProfile printerById(String id) => printers.firstWhere((p) => p.id == id, orElse: () => printers.first);

FilamentMaterial materialById(String id) =>
    materials.firstWhere((m) => m.id == id, orElse: () => materials.first);

const currency = 'грн';

class SliceSettings {
  final double layerHeight;
  final double firstLayerHeight;
  final double lineWidth;
  final int walls;
  final int topLayers;
  final int bottomLayers;
  final double infillPercent;
  final String materialId;
  final double density;
  final double filamentDiameter;
  final double scalePercent;
  final int copies;

  // Supports.
  final bool supportsEnabled;
  final bool supportPlateOnly;

  /// 'normal' or 'tree'.
  final String supportType;

  /// Overhang angle measured from vertical: steeper overhangs get supports.
  final double supportAngle;
  final double supportDensity; // %

  /// Solid infill where neighbouring layers have perimeters (slicers'
  /// "ensure vertical shell thickness"; on by default in Bambu/Orca/Prusa).
  final bool ensureVerticalShell;

  // Cost.
  final Map<String, double> pricesPerKg; // overrides of defaultPricePerKg
  final double markupPercent; // profit on top of the cost price
  final double extraCost; // per order (work, modelling, packaging)
  final String printerId;
  final double powerW;
  final double tariff; // грн per kWh
  final double amortizationPerHour; // грн per printing hour

  // Calibration against the user's slicer: estimate × factor.
  final double weightFactor;
  final int weightSamples;
  final Map<String, double> timeFactors; // per printer profile
  final Map<String, int> timeSamples;

  /// Apply print settings found in 3MF/G-code files without asking.
  final bool autoApplyFileSettings;

  /// Price from the slicer's exact numbers when a sliced file has them.
  final bool preferSlicerData;

  const SliceSettings({
    this.layerHeight = 0.2,
    this.firstLayerHeight = 0.2,
    this.lineWidth = 0.42,
    this.walls = 2,
    this.topLayers = 5,
    this.bottomLayers = 3,
    this.infillPercent = 15,
    this.materialId = 'PLA',
    this.density = 1.24,
    this.filamentDiameter = 1.75,
    this.scalePercent = 100,
    this.copies = 1,
    this.supportsEnabled = false,
    this.supportPlateOnly = false,
    this.supportType = 'normal',
    this.supportAngle = 45,
    this.supportDensity = 15,
    this.ensureVerticalShell = true,
    this.pricesPerKg = const {},
    this.markupPercent = 50,
    this.extraCost = 0,
    this.printerId = 'bambu',
    this.powerW = 140,
    this.tariff = 4.32,
    this.amortizationPerHour = 8,
    this.weightFactor = 1,
    this.weightSamples = 0,
    this.timeFactors = const {},
    this.timeSamples = const {},
    this.autoApplyFileSettings = false,
    this.preferSlicerData = true,
  });

  double get timeFactor => timeFactors[printerId] ?? 1;

  bool get isCalibrated => weightSamples > 0 || (timeSamples[printerId] ?? 0) > 0;

  /// Adds one comparison with the slicer (raw = our uncalibrated estimate).
  /// Factors are the average of up to the last 10 samples.
  SliceSettings calibrated({double? rawGrams, double? slicerGrams, double? rawSeconds, double? slicerSeconds}) {
    var s = this;
    double avg(double old, int n, double sample) {
      final m = n.clamp(0, 9);
      return (old * m + sample) / (m + 1);
    }

    if (rawGrams != null && slicerGrams != null && rawGrams > 0 && slicerGrams > 0) {
      final sample = (slicerGrams / rawGrams).clamp(0.5, 2.0).toDouble();
      s = s.copyWith(weightFactor: avg(weightFactor, weightSamples, sample), weightSamples: weightSamples + 1);
    }
    if (rawSeconds != null && slicerSeconds != null && rawSeconds > 0 && slicerSeconds > 0) {
      final sample = (slicerSeconds / rawSeconds).clamp(0.3, 3.0).toDouble();
      final n = timeSamples[printerId] ?? 0;
      s = s.copyWith(
        timeFactors: {...timeFactors, printerId: avg(timeFactor, n, sample)},
        timeSamples: {...timeSamples, printerId: n + 1},
      );
    }
    return s;
  }

  SliceSettings withoutCalibration() => copyWith(weightFactor: 1, weightSamples: 0, timeFactors: {}, timeSamples: {});

  double get pricePerKg => pricesPerKg[materialId] ?? materialById(materialId).defaultPricePerKg;

  SliceSettings withPrice(double price) {
    final m = Map<String, double>.from(pricesPerKg);
    m[materialId] = price;
    return copyWith(pricesPerKg: m);
  }

  SliceSettings copyWith({
    double? layerHeight,
    double? firstLayerHeight,
    double? lineWidth,
    int? walls,
    int? topLayers,
    int? bottomLayers,
    double? infillPercent,
    String? materialId,
    double? density,
    double? filamentDiameter,
    double? scalePercent,
    int? copies,
    bool? supportsEnabled,
    bool? supportPlateOnly,
    String? supportType,
    double? supportAngle,
    double? supportDensity,
    bool? ensureVerticalShell,
    Map<String, double>? pricesPerKg,
    double? markupPercent,
    double? extraCost,
    String? printerId,
    double? powerW,
    double? tariff,
    double? amortizationPerHour,
    double? weightFactor,
    int? weightSamples,
    Map<String, double>? timeFactors,
    Map<String, int>? timeSamples,
    bool? autoApplyFileSettings,
    bool? preferSlicerData,
  }) {
    return SliceSettings(
      layerHeight: layerHeight ?? this.layerHeight,
      firstLayerHeight: firstLayerHeight ?? this.firstLayerHeight,
      lineWidth: lineWidth ?? this.lineWidth,
      walls: walls ?? this.walls,
      topLayers: topLayers ?? this.topLayers,
      bottomLayers: bottomLayers ?? this.bottomLayers,
      infillPercent: infillPercent ?? this.infillPercent,
      materialId: materialId ?? this.materialId,
      density: density ?? this.density,
      filamentDiameter: filamentDiameter ?? this.filamentDiameter,
      scalePercent: scalePercent ?? this.scalePercent,
      copies: copies ?? this.copies,
      supportsEnabled: supportsEnabled ?? this.supportsEnabled,
      supportPlateOnly: supportPlateOnly ?? this.supportPlateOnly,
      supportType: supportType ?? this.supportType,
      supportAngle: supportAngle ?? this.supportAngle,
      supportDensity: supportDensity ?? this.supportDensity,
      ensureVerticalShell: ensureVerticalShell ?? this.ensureVerticalShell,
      pricesPerKg: pricesPerKg ?? this.pricesPerKg,
      markupPercent: markupPercent ?? this.markupPercent,
      extraCost: extraCost ?? this.extraCost,
      printerId: printerId ?? this.printerId,
      powerW: powerW ?? this.powerW,
      tariff: tariff ?? this.tariff,
      amortizationPerHour: amortizationPerHour ?? this.amortizationPerHour,
      weightFactor: weightFactor ?? this.weightFactor,
      weightSamples: weightSamples ?? this.weightSamples,
      timeFactors: timeFactors ?? this.timeFactors,
      timeSamples: timeSamples ?? this.timeSamples,
      autoApplyFileSettings: autoApplyFileSettings ?? this.autoApplyFileSettings,
      preferSlicerData: preferSlicerData ?? this.preferSlicerData,
    );
  }

  /// Settings that change the slice geometry (copies, material, prices do not).
  String get geometryKey => '$layerHeight|$firstLayerHeight|$lineWidth|$walls|$topLayers|$bottomLayers|'
      '$infillPercent|$scalePercent|$supportsEnabled|$supportPlateOnly|$supportType|$supportAngle|$supportDensity|'
      '$ensureVerticalShell';

  Map<String, dynamic> toJson() => {
        'layerHeight': layerHeight,
        'firstLayerHeight': firstLayerHeight,
        'lineWidth': lineWidth,
        'walls': walls,
        'topLayers': topLayers,
        'bottomLayers': bottomLayers,
        'infillPercent': infillPercent,
        'materialId': materialId,
        'density': density,
        'filamentDiameter': filamentDiameter,
        'scalePercent': scalePercent,
        'copies': copies,
        'supportsEnabled': supportsEnabled,
        'supportPlateOnly': supportPlateOnly,
        'supportType': supportType,
        'supportAngle': supportAngle,
        'supportDensity': supportDensity,
        'ensureVerticalShell': ensureVerticalShell,
        'pricesPerKg': pricesPerKg,
        'markupPercent': markupPercent,
        'extraCost': extraCost,
        'printerId': printerId,
        'powerW': powerW,
        'tariff': tariff,
        'amortizationPerHour': amortizationPerHour,
        'weightFactor': weightFactor,
        'weightSamples': weightSamples,
        'timeFactors': timeFactors,
        'timeSamples': timeSamples,
        'autoApplyFileSettings': autoApplyFileSettings,
        'preferSlicerData': preferSlicerData,
        'v': 2,
      };

  static SliceSettings fromJson(Map<String, dynamic> j) {
    const d = SliceSettings();
    double dbl(String k, double def) => (j[k] is num) ? (j[k] as num).toDouble() : def;
    int integer(String k, int def) => (j[k] is num) ? (j[k] as num).toInt() : def;
    bool flag(String k, bool def) => (j[k] is bool) ? j[k] as bool : def;
    final prices = <String, double>{};
    final rawPrices = j['pricesPerKg'];
    if (rawPrices is Map) {
      rawPrices.forEach((k, v) {
        if (k is String && v is num) prices[k] = v.toDouble();
      });
    }
    final version = integer('v', 1);
    int topLayers = integer('topLayers', d.topLayers);
    // v1 used 4 top layers by default; Bambu/Orca use 5.
    if (version < 2 && topLayers == 4) topLayers = 5;
    return SliceSettings(
      layerHeight: dbl('layerHeight', d.layerHeight),
      firstLayerHeight: dbl('firstLayerHeight', d.firstLayerHeight),
      lineWidth: dbl('lineWidth', d.lineWidth),
      walls: integer('walls', d.walls),
      topLayers: topLayers,
      bottomLayers: integer('bottomLayers', d.bottomLayers),
      infillPercent: dbl('infillPercent', d.infillPercent),
      materialId: j['materialId'] is String ? j['materialId'] as String : d.materialId,
      density: dbl('density', d.density),
      filamentDiameter: dbl('filamentDiameter', d.filamentDiameter),
      scalePercent: dbl('scalePercent', d.scalePercent),
      copies: integer('copies', d.copies),
      supportsEnabled: flag('supportsEnabled', d.supportsEnabled),
      supportPlateOnly: flag('supportPlateOnly', d.supportPlateOnly),
      supportType: j['supportType'] == 'tree' ? 'tree' : 'normal',
      supportAngle: dbl('supportAngle', d.supportAngle),
      supportDensity: dbl('supportDensity', d.supportDensity),
      ensureVerticalShell: flag('ensureVerticalShell', d.ensureVerticalShell),
      pricesPerKg: prices,
      markupPercent: dbl('markupPercent', d.markupPercent),
      extraCost: dbl('extraCost', d.extraCost),
      printerId: j['printerId'] is String ? j['printerId'] as String : d.printerId,
      powerW: dbl('powerW', d.powerW),
      tariff: dbl('tariff', d.tariff),
      amortizationPerHour: dbl('amortizationPerHour', d.amortizationPerHour),
      weightFactor: dbl('weightFactor', d.weightFactor),
      weightSamples: integer('weightSamples', d.weightSamples),
      timeFactors: _doubleMap(j['timeFactors']),
      timeSamples: _intMap(j['timeSamples']),
      autoApplyFileSettings: flag('autoApplyFileSettings', d.autoApplyFileSettings),
      preferSlicerData: flag('preferSlicerData', d.preferSlicerData),
    );
  }
}

Map<String, double> _doubleMap(Object? raw) {
  final out = <String, double>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (k is String && v is num) out[k] = v.toDouble();
    });
  }
  return out;
}

Map<String, int> _intMap(Object? raw) {
  final out = <String, int>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      if (k is String && v is num) out[k] = v.toInt();
    });
  }
  return out;
}

/// Estimated print time of one copy, seconds.
double estimatePrintSeconds({
  required double outer,
  required double inner,
  required double solid,
  required double sparse,
  required double support,
  required double firstLayer,
  required int layers,
  required SliceSettings settings,
}) {
  final p = printerById(settings.printerId);
  final flow = materialById(settings.materialId).maxFlow;
  final cross = settings.lineWidth * settings.layerHeight;
  double v(double speed) {
    final limit = cross > 0 ? flow / cross : speed;
    return speed < limit ? speed : limit;
  }

  final moving = outer / v(p.outerWall) +
      inner / v(p.innerWall) +
      solid / v(p.solid) +
      sparse / v(p.sparse) +
      support / v(p.support) +
      firstLayer / v(p.firstLayer);
  return moving * p.accelFactor + layers * p.layerSeconds;
}

/// Cost price (plastic + electricity + amortization) and the selling price.
class CostBreakdown {
  final double grams; // all copies, model + supports
  final double hours; // all copies
  final double material;
  final double electricity;
  final double amortization;
  final double profit; // markup on the cost price
  final double extra;

  const CostBreakdown({
    required this.grams,
    required this.hours,
    required this.material,
    required this.electricity,
    required this.amortization,
    required this.profit,
    required this.extra,
  });

  double get costPrice => material + electricity + amortization;

  double get price => costPrice + profit + extra;

  static CostBreakdown of(double gramsAllCopies, double hoursAllCopies, SliceSettings s) {
    final material = gramsAllCopies * s.pricePerKg / 1000.0;
    final electricity = hoursAllCopies * s.powerW / 1000.0 * s.tariff;
    final amortization = hoursAllCopies * s.amortizationPerHour;
    final cost = material + electricity + amortization;
    return CostBreakdown(
      grams: gramsAllCopies,
      hours: hoursAllCopies,
      material: material,
      electricity: electricity,
      amortization: amortization,
      profit: cost * s.markupPercent / 100.0,
      extra: s.extraCost,
    );
  }
}

extension SliceSettingsDefaults on SliceSettings {
  bool get isTreeSupport => supportType == 'tree';

  /// Price of the current material without the user's override.
  double get defaultPricePerKg => materialById(materialId).defaultPricePerKg;

  SliceSettings withoutPriceOverride() {
    final m = Map<String, double>.from(pricesPerKg)..remove(materialId);
    return copyWith(pricesPerKg: m);
  }

  /// Everything back to defaults; prices and calibration kept unless [prices].
  SliceSettings resetAll({bool prices = false}) {
    const d = SliceSettings();
    return prices
        ? d
        : d.copyWith(
            pricesPerKg: pricesPerKg,
            weightFactor: weightFactor,
            weightSamples: weightSamples,
            timeFactors: timeFactors,
            timeSamples: timeSamples,
          );
  }
}
