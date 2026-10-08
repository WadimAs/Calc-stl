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
}

const printers = <PrinterProfile>[
  PrinterProfile(
    id: 'bambu',
    name: 'Bambu Lab (X1, P1, A1)',
    outerWall: 200,
    innerWall: 300,
    sparse: 270,
    solid: 250,
    support: 150,
    firstLayer: 50,
    layerSeconds: 2.5,
    accelFactor: 1.6,
    startMinutes: 4,
    powerW: 140,
  ),
  PrinterProfile(
    id: 'klipper',
    name: 'Швидкий Klipper (K1, Voron, Neptune 4, MK4)',
    outerWall: 120,
    innerWall: 180,
    sparse: 200,
    solid: 160,
    support: 120,
    firstLayer: 40,
    layerSeconds: 2,
    accelFactor: 1.5,
    startMinutes: 4,
    powerW: 160,
  ),
  PrinterProfile(
    id: 'classic',
    name: 'Класичний (Ender 3, Prusa MK3, Anycubic)',
    outerWall: 35,
    innerWall: 60,
    sparse: 80,
    solid: 60,
    support: 50,
    firstLayer: 20,
    layerSeconds: 1.5,
    accelFactor: 1.15,
    startMinutes: 5,
    powerW: 120,
  ),
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
  });

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
    );
  }

  /// Settings that change the slice geometry (copies, material, prices do not).
  String get geometryKey => '$layerHeight|$firstLayerHeight|$lineWidth|$walls|$topLayers|$bottomLayers|'
      '$infillPercent|$scalePercent|$supportsEnabled|$supportPlateOnly|$supportAngle|$supportDensity|'
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
    );
  }
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
