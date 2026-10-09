import '../data/records.dart';

enum PrinterKind { bambu, moonraker }

/// A printer on the local network.
class PrinterConn {
  final String id;
  final String name;
  final PrinterKind kind;
  final String host; // IP or hostname
  final String serial; // Bambu
  final String accessCode; // Bambu LAN access code
  final String apiKey; // Moonraker (optional)
  final int port; // Moonraker HTTP port
  final List<String> writtenOff; // Moonraker job ids already written off spools

  const PrinterConn({
    required this.id,
    required this.name,
    required this.kind,
    required this.host,
    this.serial = '',
    this.accessCode = '',
    this.apiKey = '',
    this.port = 7125,
    this.writtenOff = const [],
  });

  PrinterConn copyWith({List<String>? writtenOff}) => PrinterConn(
        id: id,
        name: name,
        kind: kind,
        host: host,
        serial: serial,
        accessCode: accessCode,
        apiKey: apiKey,
        port: port,
        writtenOff: writtenOff ?? this.writtenOff,
      );

  String get kindLabel => kind == PrinterKind.bambu ? 'Bambu Lab' : 'Klipper (Moonraker)';

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'host': host,
        'serial': serial,
        'accessCode': accessCode,
        'apiKey': apiKey,
        'port': port,
        'writtenOff': writtenOff,
      };

  static PrinterConn? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    String s(String k) => raw[k] is String ? raw[k] as String : '';
    return PrinterConn(
      id: raw['id'] as String,
      name: s('name'),
      kind: raw['kind'] == 'moonraker' ? PrinterKind.moonraker : PrinterKind.bambu,
      host: s('host'),
      serial: s('serial'),
      accessCode: s('accessCode'),
      apiKey: s('apiKey'),
      port: raw['port'] is num ? (raw['port'] as num).toInt() : 7125,
      writtenOff: [
        if (raw['writtenOff'] is List)
          for (final e in raw['writtenOff'] as List)
            if (e is String) e,
      ],
    );
  }
}

const printerStore = RecordStore<PrinterConn>('printers.json', PrinterConn.fromJson, _pJson, _pId);
Map<String, dynamic> _pJson(PrinterConn p) => p.toJson();
String _pId(PrinterConn p) => p.id;

/// A filament slot (AMS tray / external spool).
class FilamentSlot {
  final String key; // "0-1" = AMS 1, tray 2; "ext" = external spool
  final String type;
  final String brand;
  final int colorArgb;
  final int? remainPercent; // null = unknown
  final double weightGrams;
  final bool active;

  const FilamentSlot({
    required this.key,
    required this.type,
    required this.brand,
    required this.colorArgb,
    required this.remainPercent,
    required this.weightGrams,
    this.active = false,
  });

  String get label {
    if (key == 'ext') return 'Зовнішня котушка';
    final p = key.split('-');
    if (p.length != 2) return key;
    final a = (int.tryParse(p[0]) ?? 0) + 1, t = (int.tryParse(p[1]) ?? 0) + 1;
    return 'AMS $a · слот $t';
  }

  double? get remainingGrams => remainPercent == null ? null : weightGrams * remainPercent! / 100;
}

/// What the printer is doing now.
class PrinterStatus {
  final String state; // our label
  final bool printing;
  final String job;
  final double? progress; // 0..1
  final Duration? remaining;
  final int? layer, totalLayers;
  final double? nozzle, nozzleTarget, bed, bedTarget;
  final List<FilamentSlot> slots;
  final String? error;

  const PrinterStatus({
    required this.state,
    this.printing = false,
    this.job = '',
    this.progress,
    this.remaining,
    this.layer,
    this.totalLayers,
    this.nozzle,
    this.nozzleTarget,
    this.bed,
    this.bedTarget,
    this.slots = const [],
    this.error,
  });
}

/// "FF8800FF" (RRGGBBAA) → ARGB int.
int colorFromRgba(String? hex, [int fallback = 0xFF9E9E9E]) {
  if (hex == null) return fallback;
  final h = hex.replaceAll('#', '').trim();
  if (h.length < 6) return fallback;
  final rgb = int.tryParse(h.substring(0, 6), radix: 16);
  if (rgb == null) return fallback;
  return 0xFF000000 | rgb;
}

double? _d(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
int? _i(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);

/// Merges partial Bambu reports ("print" objects) into a full state.
void mergeBambuReport(Map<String, dynamic> state, Map<String, dynamic> print) {
  print.forEach((k, v) => state[k] = v);
}

String bambuStateLabel(String? s) => switch (s) {
      'IDLE' => 'Вільний',
      'PREPARE' => 'Підготовка',
      'RUNNING' => 'Друкує',
      'PAUSE' => 'Пауза',
      'FINISH' => 'Готово',
      'FAILED' => 'Помилка друку',
      'SLICING' => 'Нарізає',
      null => 'Невідомо',
      _ => s,
    };

PrinterStatus bambuStatus(Map<String, dynamic> st) {
  final gs = st['gcode_state'] is String ? st['gcode_state'] as String : null;
  final slots = <FilamentSlot>[];
  final ams = st['ams'];
  String? trayNow;
  if (ams is Map) {
    trayNow = ams['tray_now']?.toString();
    final units = ams['ams'];
    if (units is List) {
      for (final u in units) {
        if (u is! Map) continue;
        final aid = _i(u['id']) ?? 0;
        final trays = u['tray'];
        if (trays is! List) continue;
        for (final t in trays) {
          if (t is! Map) continue;
          final type = t['tray_type'] is String ? (t['tray_type'] as String).trim() : '';
          if (type.isEmpty) continue;
          final tid = _i(t['id']) ?? 0;
          final remain = _i(t['remain']);
          slots.add(FilamentSlot(
            key: '$aid-$tid',
            type: type,
            brand: t['tray_sub_brands'] is String ? t['tray_sub_brands'] as String : '',
            colorArgb: colorFromRgba(t['tray_color'] as String?),
            remainPercent: remain == null || remain < 0 ? null : remain,
            weightGrams: _d(t['tray_weight']) ?? 1000,
            active: trayNow == '${aid * 4 + tid}',
          ));
        }
      }
    }
  }
  final vt = st['vt_tray'];
  if (vt is Map && vt['tray_type'] is String && (vt['tray_type'] as String).trim().isNotEmpty) {
    final remain = _i(vt['remain']);
    slots.add(FilamentSlot(
      key: 'ext',
      type: (vt['tray_type'] as String).trim(),
      brand: vt['tray_sub_brands'] is String ? vt['tray_sub_brands'] as String : '',
      colorArgb: colorFromRgba(vt['tray_color'] as String?),
      remainPercent: remain == null || remain < 0 ? null : remain,
      weightGrams: _d(vt['tray_weight']) ?? 1000,
      active: trayNow == '254',
    ));
  }
  final printing = gs == 'RUNNING' || gs == 'PAUSE' || gs == 'PREPARE';
  final pct = _d(st['mc_percent']);
  final rem = _i(st['mc_remaining_time']);
  final err = _i(st['print_error']);
  final job = st['subtask_name'] is String ? st['subtask_name'] as String : '';
  return PrinterStatus(
    state: bambuStateLabel(gs),
    printing: printing,
    job: job,
    progress: pct == null ? null : (pct / 100).clamp(0.0, 1.0).toDouble(),
    remaining: rem == null || !printing ? null : Duration(minutes: rem),
    layer: _i(st['layer_num']),
    totalLayers: _i(st['total_layer_num']),
    nozzle: _d(st['nozzle_temper']),
    nozzleTarget: _d(st['nozzle_target_temper']),
    bed: _d(st['bed_temper']),
    bedTarget: _d(st['bed_target_temper']),
    slots: slots,
    error: err != null && err != 0 ? 'Код помилки ${err.toRadixString(16).toUpperCase()}' : null,
  );
}

String moonrakerStateLabel(String? s) => switch (s) {
      'standby' => 'Вільний',
      'printing' => 'Друкує',
      'paused' => 'Пауза',
      'complete' => 'Готово',
      'cancelled' => 'Скасовано',
      'error' => 'Помилка',
      null => 'Невідомо',
      _ => s,
    };

PrinterStatus moonrakerStatus(Map<String, dynamic> status) {
  Map<String, dynamic> obj(String k) =>
      status[k] is Map ? Map<String, dynamic>.from(status[k] as Map) : const <String, dynamic>{};
  final ps = obj('print_stats');
  final sd = obj('virtual_sdcard');
  final ds = obj('display_status');
  final ex = obj('extruder');
  final bed = obj('heater_bed');
  final state = ps['state'] as String?;
  final printing = state == 'printing' || state == 'paused';
  final progress = _d(sd['progress']) ?? _d(ds['progress']);
  final dur = _d(ps['print_duration']);
  Duration? remaining;
  if (printing && progress != null && progress > 0.01 && dur != null) {
    remaining = Duration(seconds: (dur / progress - dur).round());
  }
  final info = ps['info'] is Map ? ps['info'] as Map : const {};
  return PrinterStatus(
    state: moonrakerStateLabel(state),
    printing: printing,
    job: ps['filename'] is String ? ps['filename'] as String : '',
    progress: progress?.clamp(0.0, 1.0).toDouble(),
    remaining: remaining,
    layer: _i(info['current_layer']),
    totalLayers: _i(info['total_layer']),
    nozzle: _d(ex['temperature']),
    nozzleTarget: _d(ex['target']),
    bed: _d(bed['temperature']),
    bedTarget: _d(bed['target']),
    error: state == 'error' && ps['message'] is String ? ps['message'] as String : null,
  );
}

/// A finished Moonraker job.
class PrintJob {
  final String id;
  final String file;
  final String status;
  final DateTime? end;
  final double filamentMm;
  final double? grams; // from slicer metadata when present
  final double seconds;

  const PrintJob({
    required this.id,
    required this.file,
    required this.status,
    required this.end,
    required this.filamentMm,
    required this.grams,
    required this.seconds,
  });

  /// Grams for [density] g/cm³ and [diameter] mm when the slicer weight is missing.
  double gramsFor(double density, [double diameter = 1.75]) {
    if (grams != null && grams! > 0) return grams!;
    final r = diameter / 2;
    return filamentMm * 3.141592653589793 * r * r * density / 1000;
  }

  static PrintJob? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['job_id']?.toString();
    if (id == null) return null;
    final meta = raw['metadata'] is Map ? raw['metadata'] as Map : const {};
    final end = _d(raw['end_time']);
    return PrintJob(
      id: id,
      file: raw['filename'] is String ? raw['filename'] as String : '',
      status: raw['status'] is String ? raw['status'] as String : '',
      end: end == null ? null : DateTime.fromMillisecondsSinceEpoch((end * 1000).round()),
      filamentMm: _d(raw['filament_used']) ?? 0,
      grams: _d(meta['filament_weight_total']),
      seconds: _d(raw['print_duration']) ?? 0,
    );
  }
}
