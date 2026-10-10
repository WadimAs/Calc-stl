import '../mesh/slicer_project.dart';

/// What could be read from a spool label.
class SpoolLabel {
  final String? brand;
  final String? materialId;
  final String? materialText; // e.g. "PLA Basic", "PETG HF", "PLA+"
  final String? colorName; // e.g. "Jade White"
  final int? colorArgb;
  final double? weightGrams;

  /// Sold without a spool ("Refill").
  final bool refill;

  /// Second / third colour of a dual / tri-colour filament.
  final List<int> extraColors;

  const SpoolLabel({
    this.brand,
    this.materialId,
    this.materialText,
    this.colorName,
    this.colorArgb,
    this.weightGrams,
    this.refill = false,
    this.extraColors = const [],
  });

  bool get isEmpty => brand == null && materialId == null && colorArgb == null && weightGrams == null && !refill;

  /// "Bambu Lab, Jade White" for the spool name field.
  String get name => [brand, colorName].whereType<String>().join(', ');
}

/// Filament makers for the manual picker, most popular first.
List<String> get filamentBrands => _brands.keys.toList();

final _refill = RegExp(
  r'\bre-?fill?\b|\brefil\b|spool[\s-]*(?:less|free)|without\s+spool|no\s+spool|eco[\s-]*spool|masterspool|без\s+котушки',
  caseSensitive: false,
);

const _brands = <String, List<String>>{
  'Bambu Lab': ['bambu lab', 'bambulab', 'bambu'],
  'eSUN': ['esun'],
  'Polymaker': ['polymaker', 'polyterra', 'polylite', 'polymax'],
  'SUNLU': ['sunlu'],
  'Elegoo': ['elegoo'],
  'Creality': ['creality', 'hyper pla', 'ender pla'],
  'Anycubic': ['anycubic'],
  'Plexiwire': ['plexiwire'],
  'Monofilament': ['monofilament'],
  'FDplast': ['fdplast', 'fd plast'],
  'Prusament': ['prusament', 'prusa'],
  'Overture': ['overture'],
  'JAYO': ['jayo'],
  'Kingroon': ['kingroon'],
  'Eryone': ['eryone'],
  'Geeetech': ['geeetech'],
  'Hatchbox': ['hatchbox'],
  'Fiberlogy': ['fiberlogy'],
  'Spectrum': ['spectrum filaments', 'spectrum'],
  'Devil Design': ['devil design', 'devildesign'],
  'Fillamentum': ['fillamentum'],
  'colorFabb': ['colorfabb'],
  '3DJake': ['3djake'],
  'Amolen': ['amolen'],
  'Tinmorry': ['tinmorry'],
  'Azurefilm': ['azurefilm'],
  'Rosa3D': ['rosa3d', 'rosa 3d'],
  'Gembird': ['gembird'],
  'Inland': ['inland'],
  'Duramic': ['duramic'],
  'Kexcelled': ['kexcelled'],
  'QIDI': ['qidi'],
  'Flashforge': ['flashforge'],
  'Snapmaker': ['snapmaker'],
  'Sovol': ['sovol'],
  'Artillery': ['artillery'],
  'Ziro': ['ziro'],
  'Proto-pasta': ['proto-pasta', 'protopasta'],
  'Extrudr': ['extrudr'],
  'Formfutura': ['formfutura'],
  'Verbatim': ['verbatim'],
  'Raise3D': ['raise3d'],
  'Ultimaker': ['ultimaker'],
  'Paramount 3D': ['paramount'],
  'Zyltech': ['zyltech'],
  'Voxelab': ['voxelab'],
  'Kodak': ['kodak'],
  'R3D': ['r3d'],
};

/// Colour words (English and Ukrainian) → app palette colour.
const _colors = <String, int>{
  'black': 0xFF202020, 'charcoal': 0xFF202020, 'чорний': 0xFF202020, 'чорна': 0xFF202020,
  'white': 0xFFFFFFFF, 'білий': 0xFFFFFFFF, 'біла': 0xFFFFFFFF,
  'ivory': 0xFFF5E6C8, 'beige': 0xFFF5E6C8, 'cream': 0xFFF5E6C8, 'бежевий': 0xFFF5E6C8,
  'natural': 0xFFE3F2FD, 'transparent': 0xFFE3F2FD, 'clear': 0xFFE3F2FD, 'прозорий': 0xFFE3F2FD,
  'grey': 0xFF9E9E9E, 'gray': 0xFF9E9E9E, 'сірий': 0xFF9E9E9E,
  'silver': 0xFFC0C0C0, 'срібний': 0xFFC0C0C0,
  'red': 0xFFE53935, 'scarlet': 0xFFE53935, 'червоний': 0xFFE53935,
  'burgundy': 0xFF8E1B1B, 'wine': 0xFF8E1B1B, 'maroon': 0xFF8E1B1B,
  'orange': 0xFFFF8A3D, 'помаранчевий': 0xFFFF8A3D, 'оранжевий': 0xFFFF8A3D,
  'peach': 0xFFFFB38A,
  'yellow': 0xFFFDD835, 'lemon': 0xFFFDD835, 'жовтий': 0xFFFDD835,
  'gold': 0xFFD4AF37, 'golden': 0xFFD4AF37, 'золотий': 0xFFD4AF37,
  'lime': 0xFFC0CA33,
  'green': 0xFF43A047, 'olive': 0xFF1B5E20, 'зелений': 0xFF43A047,
  'mint': 0xFF80CBC4,
  'cyan': 0xFF00ACC1, 'teal': 0xFF00ACC1, 'turquoise': 0xFF00ACC1, 'бірюзовий': 0xFF00ACC1,
  'sky': 0xFF64B5F6, 'блакитний': 0xFF64B5F6,
  'blue': 0xFF1E88E5, 'синій': 0xFF1E88E5,
  'navy': 0xFF1A237E,
  'purple': 0xFF8E24AA, 'violet': 0xFF8E24AA, 'фіолетовий': 0xFF8E24AA,
  'lilac': 0xFFB39DDB, 'lavender': 0xFFB39DDB,
  'pink': 0xFFEC407A, 'рожевий': 0xFFEC407A,
  'magenta': 0xFFD81B60,
  'brown': 0xFF795548, 'коричневий': 0xFF795548,
  'wood': 0xFFA1887F,
  'copper': 0xFFB87333, 'мідний': 0xFFB87333,
  'bronze': 0xFFCD7F32,
};

/// "Dual Color", "Tri-Color", "Rainbow"…: several colours in one filament.
final _multi = RegExp(r'dual|tri[\s-]*colou?r|two[\s-]*colou?r|three[\s-]*colou?r|bi[\s-]*colou?r|multi[\s-]*colou?r|rainbow|двоколір|триколір',
    caseSensitive: false);

/// Words that may precede a colour word and belong to its name ("Jade White").
final _colorAdj = RegExp(r'^[A-Za-zА-Яа-яІіЇїЄєҐґ]{3,12}$');
const _notColorAdj = {
  'pla', 'petg', 'abs', 'asa', 'tpu', 'basic', 'matte', 'silk', 'color', 'colour', 'filament', 'the', 'and',
  'net', 'weight', 'spool', 'with', 'for', 'premium', 'high', 'speed',
};

final _material = RegExp(
  r'\b(PLA[\s\-+]*CF|PETG[\s\-]*CF|PET[\s\-]*CF|PA[\s\-]*CF|PCTG|PETG|PLA\+?|ABS\+?|ASA|TPU|TPE|PA6|PA12|PA|NYLON|PC|HIPS|PVA)\b'
  r'(?:[\s\-]*(BASIC|MATTE|SILK|PRO|HF|PLUS|META|TOUGH|LITE|HS|HIGH SPEED|GLOW|WOOD|MARBLE|GALAXY|95A|85A|64D))?',
  caseSensitive: false,
);

final _kg = RegExp(r'(\d+(?:[.,]\d+)?)\s*(?:kgs?|кг|kr)\b', caseSensitive: false);
final _g = RegExp(r'(\d{3,4})\s*(?:g|gr|grams?|г)\b', caseSensitive: false);

SpoolLabel parseSpoolLabel(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final lower = text.toLowerCase();

  // Brand: the alias that appears earliest wins (labels print the brand on top).
  String? brand;
  int bestPos = 1 << 30;
  _brands.forEach((name, aliases) {
    for (final a in aliases) {
      final m = RegExp('(^|[^a-z0-9])${RegExp.escape(a)}(\$|[^a-z0-9])').firstMatch(lower);
      if (m != null && m.start < bestPos) {
        bestPos = m.start;
        brand = name;
      }
    }
  });

  // Material: first match; label text like "PLA Basic".
  String? materialText, materialId;
  final mm = _material.firstMatch(text);
  if (mm != null) {
    final base = mm.group(1)!.toUpperCase().replaceAll(RegExp(r'\s+'), ' ');
    final sub = mm.group(2);
    materialText = sub == null ? base : '$base ${sub[0].toUpperCase()}${sub.substring(1).toLowerCase()}';
    materialId = materialIdForType(base.replaceAll(RegExp(r'[\s\-+]+(?=CF)'), '-').replaceAll('+', ''));
    if (materialId == 'PLA' && RegExp(r'\bsilk', caseSensitive: false).hasMatch(text)) materialId = 'PLA-SILK';
    if (base.startsWith('NYLON')) materialId = 'PA';
  }

  // Weight: kilograms first (net weight lines preferred), then grams.
  double? weight;
  double? fromLine(String l) {
    for (final m in _kg.allMatches(l)) {
      final v = double.tryParse(m.group(1)!.replaceAll(',', '.'));
      if (v != null && v >= 0.1 && v <= 5) return v * 1000;
    }
    for (final m in _g.allMatches(l)) {
      final v = double.tryParse(m.group(1)!);
      if (v != null && v >= 100 && v <= 5000) return v;
    }
    return null;
  }

  for (final l in lines) {
    final ll = l.toLowerCase();
    if (ll.contains('net') || ll.contains('n.w') || ll.contains('нетто') || ll.contains('вага')) {
      weight = fromLine(l);
      if (weight != null) break;
    }
  }
  if (weight == null) {
    for (final l in lines) {
      final ll = l.toLowerCase();
      if (ll.contains('spool') && !ll.contains('net')) continue; // empty spool weight
      weight = fromLine(l);
      if (weight != null) break;
    }
  }

  // Colour: a line mentioning "colour" first, then any line.
  String? colorName;
  final colors = <int>[];
  final multi = _multi.hasMatch(text);
  final ordered = [
    ...lines.where((l) => l.toLowerCase().contains('colo')),
    ...lines.where((l) => !l.toLowerCase().contains('colo')),
  ];
  for (final l in ordered) {
    final words = l.split(RegExp(r'[\s,:;/()&+-]+')).where((w) => w.isNotEmpty).toList();
    final names = <String>[];
    for (int i = 0; i < words.length && colors.length < 3; i++) {
      if (_colors[words[i].toLowerCase()] == null) continue;
      // "Charcoal Black", "Navy Blue": in a one-colour filament the last colour
      // word is the colour; in a dual / tri-colour one every word counts.
      if (!multi) {
        while (i + 1 < words.length && _colors[words[i + 1].toLowerCase()] != null) {
          i++;
        }
      }
      final c = _colors[words[i].toLowerCase()]!;
      final parts = <String>[];
      if (i > 0 &&
          _colorAdj.hasMatch(words[i - 1]) &&
          !_notColorAdj.contains(words[i - 1].toLowerCase()) &&
          (!multi || _colors[words[i - 1].toLowerCase()] == null)) {
        parts.add(_cap(words[i - 1]));
      }
      parts.add(_cap(words[i]));
      if (!colors.contains(c)) colors.add(c);
      names.add(parts.join(' '));
      if (!multi) break;
    }
    if (colors.isNotEmpty) {
      colorName = names.join(multi ? ' / ' : ' ');
      break;
    }
  }
  final color = colors.isEmpty ? null : colors.first;

  return SpoolLabel(
    refill: _refill.hasMatch(text),
    brand: brand,
    materialId: materialId,
    materialText: materialText,
    colorName: colorName,
    colorArgb: color,
    extraColors: colors.length > 1 ? colors.sublist(1) : const [],
    weightGrams: weight,
  );
}

String _cap(String w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}';
