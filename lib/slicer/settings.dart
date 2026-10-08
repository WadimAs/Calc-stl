class FilamentMaterial {
  final String id;
  final String name;
  final double density; // g/cm³

  const FilamentMaterial(this.id, this.name, this.density);
}

const materials = <FilamentMaterial>[
  FilamentMaterial('PLA', 'PLA', 1.24),
  FilamentMaterial('PETG', 'PETG', 1.27),
  FilamentMaterial('ABS', 'ABS', 1.04),
  FilamentMaterial('ASA', 'ASA', 1.07),
  FilamentMaterial('TPU', 'TPU', 1.21),
  FilamentMaterial('PA', 'Nylon (PA)', 1.14),
  FilamentMaterial('PC', 'PC', 1.20),
  FilamentMaterial('PLA-CF', 'PLA-CF', 1.29),
  FilamentMaterial('PETG-CF', 'PETG-CF', 1.30),
  FilamentMaterial('HIPS', 'HIPS', 1.04),
  FilamentMaterial('PVA', 'PVA', 1.23),
  FilamentMaterial('custom', 'Свій матеріал', 1.24),
];

FilamentMaterial materialById(String id) =>
    materials.firstWhere((m) => m.id == id, orElse: () => materials.first);

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
  });

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
    );
  }

  /// Settings that change the slice geometry (copies/density do not).
  String get geometryKey =>
      '$layerHeight|$firstLayerHeight|$lineWidth|$walls|$topLayers|$bottomLayers|$infillPercent|$scalePercent';

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
      };

  static SliceSettings fromJson(Map<String, dynamic> j) {
    const d = SliceSettings();
    double dbl(String k, double def) => (j[k] is num) ? (j[k] as num).toDouble() : def;
    int integer(String k, int def) => (j[k] is num) ? (j[k] as num).toInt() : def;
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
    );
  }
}
