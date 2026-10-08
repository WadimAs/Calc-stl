class FilamentMaterial {
  final String id;
  final String name;
  final double density; // g/cm³
  final double defaultPricePerKg; // грн

  const FilamentMaterial(this.id, this.name, this.density, this.defaultPricePerKg);
}

const materials = <FilamentMaterial>[
  FilamentMaterial('PLA', 'PLA', 1.24, 600),
  FilamentMaterial('PETG', 'PETG', 1.27, 650),
  FilamentMaterial('ABS', 'ABS', 1.04, 600),
  FilamentMaterial('ASA', 'ASA', 1.07, 800),
  FilamentMaterial('TPU', 'TPU', 1.21, 950),
  FilamentMaterial('PA', 'Nylon (PA)', 1.14, 1500),
  FilamentMaterial('PC', 'PC', 1.20, 1300),
  FilamentMaterial('PLA-CF', 'PLA-CF', 1.29, 1100),
  FilamentMaterial('PETG-CF', 'PETG-CF', 1.30, 1200),
  FilamentMaterial('HIPS', 'HIPS', 1.04, 650),
  FilamentMaterial('PVA', 'PVA', 1.23, 2200),
  FilamentMaterial('custom', 'Свій матеріал', 1.24, 600),
];

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

  // Cost.
  final Map<String, double> pricesPerKg; // overrides of defaultPricePerKg
  final double markupPercent;
  final double extraCost; // per order

  const SliceSettings({
    this.layerHeight = 0.2,
    this.firstLayerHeight = 0.2,
    this.lineWidth = 0.42,
    this.walls = 2,
    this.topLayers = 4,
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
    this.pricesPerKg = const {},
    this.markupPercent = 0,
    this.extraCost = 0,
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
    Map<String, double>? pricesPerKg,
    double? markupPercent,
    double? extraCost,
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
      pricesPerKg: pricesPerKg ?? this.pricesPerKg,
      markupPercent: markupPercent ?? this.markupPercent,
      extraCost: extraCost ?? this.extraCost,
    );
  }

  /// Settings that change the slice geometry (copies, material, prices do not).
  String get geometryKey => '$layerHeight|$firstLayerHeight|$lineWidth|$walls|$topLayers|$bottomLayers|'
      '$infillPercent|$scalePercent|$supportsEnabled|$supportPlateOnly|$supportAngle|$supportDensity';

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
        'pricesPerKg': pricesPerKg,
        'markupPercent': markupPercent,
        'extraCost': extraCost,
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
    return SliceSettings(
      layerHeight: dbl('layerHeight', d.layerHeight),
      firstLayerHeight: dbl('firstLayerHeight', d.firstLayerHeight),
      lineWidth: dbl('lineWidth', d.lineWidth),
      walls: integer('walls', d.walls),
      topLayers: integer('topLayers', d.topLayers),
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
      pricesPerKg: prices,
      markupPercent: dbl('markupPercent', d.markupPercent),
      extraCost: dbl('extraCost', d.extraCost),
    );
  }
}

/// Price breakdown for the current result.
class CostBreakdown {
  final double grams; // all copies, model + supports
  final double material;
  final double markup;
  final double extra;

  const CostBreakdown(this.grams, this.material, this.markup, this.extra);

  double get total => material + markup + extra;

  static CostBreakdown of(double gramsAllCopies, SliceSettings s) {
    final material = gramsAllCopies * s.pricePerKg / 1000.0;
    final markup = material * s.markupPercent / 100.0;
    return CostBreakdown(gramsAllCopies, material, markup, s.extraCost);
  }
}
