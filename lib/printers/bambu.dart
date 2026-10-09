import 'dart:async';
import 'dart:convert';

import 'mqtt.dart';
import 'printers.dart';

/// Live status of a Bambu Lab printer over the LAN (MQTT on port 8883).
///
/// Needs the printer's IP, serial number and LAN access code (on the printer:
/// Settings → Network / WLAN). Newer firmware may also require
/// "LAN only" + "Developer mode" for third-party apps.
class BambuClient {
  final PrinterConn printer;
  MqttClient? _mqtt;
  final _state = <String, dynamic>{};
  final _out = StreamController<PrinterStatus>.broadcast();
  StreamSubscription<MqttMessage>? _sub;
  Timer? _refresh;

  BambuClient(this.printer);

  Stream<PrinterStatus> get status => _out.stream;

  Future<void> connect() async {
    final m = MqttClient(printer.host, user: 'bblp', password: printer.accessCode);
    _mqtt = m;
    await m.connect();
    _sub = m.messages.listen(_onMessage, onError: (Object e) {
      if (!_out.isClosed) _out.addError(e);
    });
    m.subscribe('device/${printer.serial}/report');
    pushAll();
    // P1/A1 send only changes; ask for the full state now and then.
    _refresh = Timer.periodic(const Duration(minutes: 5), (_) => pushAll());
  }

  void pushAll() => _mqtt?.publish('device/${printer.serial}/request',
      jsonEncode({'pushing': {'sequence_id': '0', 'command': 'pushall'}}));

  void _onMessage(MqttMessage msg) {
    try {
      final j = jsonDecode(utf8.decode(msg.payload, allowMalformed: true));
      if (j is Map && j['print'] is Map) {
        mergeBambuReport(_state, Map<String, dynamic>.from(j['print'] as Map));
        if (!_out.isClosed) _out.add(bambuStatus(_state));
      }
    } catch (_) {}
  }

  Future<void> close() async {
    _refresh?.cancel();
    await _sub?.cancel();
    await _mqtt?.close();
    await _out.close();
  }
}
