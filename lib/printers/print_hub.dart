import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/json_store.dart';
import '../i18n/i18n.dart';
import 'bambu.dart';
import 'bambu_cloud.dart';
import 'moonraker.dart';
import 'printers.dart';

/// Filament used by one material of a finished print.
class UsageLine {
  final String? slotKey; // AMS slot ("0-1", "ext") when known
  final String? type; // filament type from the printer
  final int? color;
  final double? grams; // null = unknown
  final double? filamentMm; // Klipper: length, grams depend on the spool's density

  const UsageLine({this.slotKey, this.type, this.color, this.grams, this.filamentMm});
}

/// A print that ended and can be written off spools.
class FinishedPrint {
  final PrinterConn printer;
  final String key;
  final String job;
  final bool failed;
  final List<UsageLine> lines;
  final String source; // where the weight came from

  /// Klipper job id (to mark it in the printer's history).
  final String? moonrakerJob;

  const FinishedPrint({
    required this.printer,
    required this.key,
    required this.job,
    required this.failed,
    required this.lines,
    required this.source,
    this.moonrakerJob,
  });

  double? get grams {
    final known = lines.where((l) => l.grams != null);
    return known.isEmpty ? null : known.fold<double>(0.0, (a, l) => a + l.grams!);
  }
}

class _Bambu {
  BambuClient client;
  bool retrying = false;
  final StreamController<PrinterStatus> out = StreamController.broadcast();
  StreamSubscription<PrinterStatus>? sub;
  PrinterStatus? last;

  // Current job: key and AMS grams at its start (for the usage estimate).
  String? jobKey;
  Map<String, double> startGrams = {};
  bool sawPrinting = false;

  _Bambu(this.client);
}

/// One connection per printer shared by the screens, plus a watcher that
/// notices finished prints and offers to write the filament off.
class PrinterHub with WidgetsBindingObserver {
  PrinterHub._();

  static final instance = PrinterHub._();

  static const _file = 'printwatch.json';

  final _bambu = <String, _Bambu>{};
  final _finished = StreamController<FinishedPrint>.broadcast();
  final _pending = <String>{};
  Set<String> _done = {};
  bool enabled = true;
  bool _started = false;
  Timer? _poll;
  List<PrinterConn> _printers = [];

  Stream<FinishedPrint> get finished => _finished.stream;

  Future<void> _load() async {
    final raw = await JsonStore.read(_file);
    if (raw is Map) {
      enabled = raw['enabled'] != false;
      _done = {
        if (raw['done'] is List)
          for (final k in raw['done'] as List)
            if (k is String) k,
      };
    }
  }

  Future<void> _save() async {
    final list = _done.toList();
    await JsonStore.write(_file, {
      'enabled': enabled,
      'done': list.length > 300 ? list.sublist(list.length - 300) : list,
    });
  }

  /// Starts watching every saved printer (when the app opens).
  Future<void> start() async {
    if (!_started) {
      _started = true;
      WidgetsBinding.instance.addObserver(this);
      await _load();
    }
    await refresh();
  }

  /// Re-reads the printer list (after adding / removing printers).
  Future<void> refresh() async {
    _printers = await printerStore.load();
    final ids = {for (final p in _printers) p.id};
    for (final id in _bambu.keys.toList()) {
      if (!ids.contains(id)) _drop(id);
    }
    if (enabled) {
      for (final p in _printers) {
        if (p.kind == PrinterKind.bambu) _ensure(p);
      }
    }
    _poll?.cancel();
    if (enabled && _printers.any((p) => p.kind == PrinterKind.moonraker)) {
      _poll = Timer.periodic(const Duration(minutes: 1), (_) => _pollMoonraker());
      _pollMoonraker();
    }
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    await _save();
    if (!v) {
      _poll?.cancel();
    }
    await refresh();
  }

  /// Live status of a Bambu printer (shared connection).
  Stream<PrinterStatus> bambuStatus(PrinterConn p) {
    final b = _ensure(p);
    final last = b.last;
    if (last == null) return b.out.stream;
    // Replay the latest status to the new listener first.
    late StreamController<PrinterStatus> c;
    StreamSubscription<PrinterStatus>? s;
    c = StreamController<PrinterStatus>(
      onListen: () {
        c.add(last);
        s = b.out.stream.listen(c.add, onError: c.addError);
      },
      onCancel: () => s?.cancel(),
    );
    return c.stream;
  }

  void pushAll(PrinterConn p) => _bambu[p.id]?.client.pushAll();

  /// Forces a new connection (after a login or an error).
  void reconnect(PrinterConn p) {
    _drop(p.id);
    _ensure(p);
  }

  _Bambu _ensure(PrinterConn p) {
    final have = _bambu[p.id];
    if (have != null) return have;
    final b = _Bambu(BambuClient(p));
    _bambu[p.id] = b;
    _connect(p, b);
    return b;
  }

  Future<void> _connect(PrinterConn p, _Bambu b) async {
    try {
      await b.client.connect();
      b.sub = b.client.status.listen(
        (s) {
          b.last = s;
          if (!b.out.isClosed) b.out.add(s);
          _onBambu(p, b, s);
        },
        onError: (Object e) {
          if (!b.out.isClosed) b.out.addError(e);
          _retryLater(p, b);
        },
        onDone: () => _retryLater(p, b),
      );
    } catch (e) {
      if (!b.out.isClosed) b.out.addError(e);
      _retryLater(p, b);
    }
  }

  void _retryLater(PrinterConn p, _Bambu b) {
    if (b.retrying) return;
    b.retrying = true;
    Timer(const Duration(seconds: 45), () {
      b.retrying = false;
      if (!identical(_bambu[p.id], b)) return;
      b.sub?.cancel();
      b.client.close();
      b.client = BambuClient(p);
      _connect(p, b);
    });
  }

  void _drop(String id) {
    final b = _bambu.remove(id);
    if (b == null) return;
    b.sub?.cancel();
    b.client.close();
    b.out.close();
  }

  void _onBambu(PrinterConn p, _Bambu b, PrinterStatus s) {
    final key = s.jobKey;
    if (s.printing) {
      if (key != b.jobKey) {
        b.jobKey = key;
        b.startGrams = {
          for (final sl in s.slots)
            if (sl.remainingGrams != null) sl.key: sl.remainingGrams!,
        };
      }
      b.sawPrinting = true;
      return;
    }
    if (!enabled || key == null || !(s.finished || s.failed)) return;
    final id = 'bambu:${p.serial}:$key';
    if (_done.contains(id) || _pending.contains(id)) return;
    // Only recent jobs (also those that ended while the app was closed).
    final recent = (b.sawPrinting && b.jobKey == key) ||
        (s.jobStart != null && DateTime.now().difference(s.jobStart!) < const Duration(days: 3));
    if (!recent) return;
    _pending.add(id);
    _bambuUsage(p, b, s).then((ev) => _emit(FinishedPrint(
          printer: p,
          key: id,
          job: s.job,
          failed: s.failed,
          lines: ev.$1,
          source: ev.$2,
        )));
  }

  /// Weight from the Bambu cloud job list, else from the AMS gauges.
  Future<(List<UsageLine>, String)> _bambuUsage(PrinterConn p, _Bambu b, PrinterStatus s) async {
    final slots = {for (final sl in s.slots) sl.key: sl};
    final fraction = s.failed ? (s.progress ?? 1) : 1.0;
    final acc = await BambuAccount.load();
    if (acc != null) {
      try {
        final tasks = await BambuCloud.tasks(acc, p.serial, limit: 5);
        CloudTask? t;
        final job = s.job.toLowerCase();
        for (final x in tasks) {
          final title = x.title.toLowerCase();
          if (title.isNotEmpty && (job.contains(title) || title.contains(job))) {
            t = x;
            break;
          }
        }
        t ??= tasks.isEmpty ? null : tasks.first;
        if (t != null && t.weight > 0) {
          final lines = <UsageLine>[];
          if (t.perTray.isNotEmpty) {
            t.perTray.forEach((tray, g) {
              final key = tray == 254 ? 'ext' : '${tray ~/ 4}-${tray % 4}';
              final sl = slots[key];
              lines.add(UsageLine(slotKey: key, type: sl?.type, color: sl?.colorArgb, grams: g * fraction));
            });
          } else {
            final act = s.slots.where((x) => x.active);
            final sl = act.isEmpty ? null : act.first;
            lines.add(UsageLine(slotKey: sl?.key, type: sl?.type, color: sl?.colorArgb, grams: t.weight * fraction));
          }
          return (lines, tr('дані Bambu Cloud'));
        }
      } catch (_) {}
    }
    // AMS gauges (RFID spools; 1 % ≈ 10 g).
    final lines = <UsageLine>[];
    if (b.jobKey == s.jobKey) {
      for (final sl in s.slots) {
        final before = b.startGrams[sl.key];
        final after = sl.remainingGrams;
        if (before != null && after != null && before - after > 0.5) {
          lines.add(UsageLine(slotKey: sl.key, type: sl.type, color: sl.colorArgb, grams: before - after));
        }
      }
    }
    if (lines.isNotEmpty) return (lines, tr('за датчиком AMS, приблизно'));
    final act = s.slots.where((x) => x.active);
    final sl = act.isEmpty ? (s.slots.length == 1 ? s.slots.first : null) : act.first;
    return ([UsageLine(slotKey: sl?.key, type: sl?.type, color: sl?.colorArgb)], '');
  }

  Future<void> _pollMoonraker() async {
    if (!enabled) return;
    for (final p in _printers.where((p) => p.kind == PrinterKind.moonraker)) {
      try {
        final jobs = await MoonrakerClient(p).history(limit: 5);
        for (final j in jobs) {
          final id = 'mr:${p.id}:${j.id}';
          if (_done.contains(id) || _pending.contains(id) || p.writtenOff.contains(j.id)) continue;
          final end = j.end;
          if (end == null || DateTime.now().difference(end) > const Duration(days: 3)) continue;
          if (j.status != 'completed' && j.status != 'cancelled' && j.status != 'error') continue;
          if (j.filamentMm <= 0 && (j.grams ?? 0) <= 0) continue;
          _pending.add(id);
          _emit(FinishedPrint(
            printer: p,
            key: id,
            job: j.file,
            failed: j.status != 'completed',
            lines: [UsageLine(grams: j.grams, filamentMm: j.filamentMm)],
            source: j.grams != null ? tr('дані слайсера з принтера') : tr('за довжиною філаменту'),
            moonrakerJob: j.id,
          ));
        }
      } catch (_) {}
    }
  }

  // ---- Prompts ----

  final _queue = <FinishedPrint>[];
  bool _foreground = true;

  void _emit(FinishedPrint f) {
    _queue.add(f);
    _finished.add(f);
  }

  /// UI tests: pretend a printer just finished [f].
  @visibleForTesting
  void debugEmit(FinishedPrint f) {
    _pending.add(f.key);
    _emit(f);
  }

  /// Prints waiting for the user's decision.
  List<FinishedPrint> takeQueue() {
    final q = List.of(_queue);
    _queue.clear();
    return q;
  }

  bool get inForeground => _foreground;

  /// The user wrote the print off (or skipped it): never ask again.
  Future<void> resolve(FinishedPrint f) async {
    _pending.remove(f.key);
    _queue.removeWhere((x) => x.key == f.key);
    _done.add(f.key);
    await _save();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      for (final b in _bambu.values) {
        b.client.pushAll();
      }
      _pollMoonraker();
      if (_queue.isNotEmpty) _finished.add(_queue.first); // show what came in while away
    }
  }
}
