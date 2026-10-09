import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../i18n/i18n.dart';

/// One received PUBLISH.
class MqttMessage {
  final String topic;
  final Uint8List payload;

  const MqttMessage(this.topic, this.payload);
}

class MqttException implements Exception {
  final String message;

  const MqttException(this.message);

  @override
  String toString() => message;
}

/// Encodes the MQTT "remaining length" varint.
List<int> mqttLength(int n) {
  final out = <int>[];
  do {
    var b = n % 128;
    n ~/= 128;
    if (n > 0) b |= 0x80;
    out.add(b);
  } while (n > 0);
  return out;
}

List<int> _str(String s) {
  final b = utf8.encode(s);
  return [b.length >> 8, b.length & 0xff, ...b];
}

Uint8List _packet(int header, List<int> body) =>
    Uint8List.fromList([header, ...mqttLength(body.length), ...body]);

Uint8List mqttConnect(String clientId, {String? user, String? password, int keepAlive = 60}) {
  int flags = 0x02; // clean session
  if (user != null) flags |= 0x80;
  if (password != null) flags |= 0x40;
  return _packet(0x10, [
    ..._str('MQTT'), 4, flags, keepAlive >> 8, keepAlive & 0xff, //
    ..._str(clientId),
    if (user != null) ..._str(user),
    if (password != null) ..._str(password),
  ]);
}

Uint8List mqttSubscribe(int id, String topic) => _packet(0x82, [id >> 8, id & 0xff, ..._str(topic), 0]);

Uint8List mqttPublish(String topic, List<int> payload) => _packet(0x30, [..._str(topic), ...payload]);

/// Splits a byte stream into MQTT packets: (first byte, body).
class MqttParser {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<(int, Uint8List)> add(List<int> data) {
    _buf.add(_pending);
    _buf.add(data);
    var b = _buf.takeBytes();
    final out = <(int, Uint8List)>[];
    int p = 0;
    while (true) {
      if (b.length - p < 2) break;
      int len = 0, mul = 1, i = p + 1;
      bool complete = false;
      while (i < b.length) {
        final x = b[i++];
        len += (x & 0x7f) * mul;
        mul *= 128;
        if (x & 0x80 == 0) {
          complete = true;
          break;
        }
        if (mul > 128 * 128 * 128 * 128) throw MqttException(tr('Пошкоджений пакет'));
      }
      if (!complete || b.length - i < len) break;
      out.add((b[p], Uint8List.sublistView(b, i, i + len)));
      p = i + len;
    }
    _pending = Uint8List.fromList(Uint8List.sublistView(b, p));
    b = Uint8List(0);
    return out;
  }
}

/// Minimal MQTT 3.1.1 client (QoS 0) over TLS or TCP.
class MqttClient {
  final String host;
  final int port;
  final bool tls;
  final String? user, password;
  final String clientId;

  Socket? _socket;
  Timer? _ping;
  final _parser = MqttParser();
  final _messages = StreamController<MqttMessage>.broadcast();
  Completer<int>? _connack;
  bool _closed = false;

  MqttClient(this.host, {this.port = 8883, this.tls = true, this.user, this.password, String? clientId})
      : clientId = clientId ?? 'stlvaga${DateTime.now().millisecondsSinceEpoch % 1000000}';

  Stream<MqttMessage> get messages => _messages.stream;

  Future<void> connect({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      _socket = tls
          ? await SecureSocket.connect(host, port, timeout: timeout, onBadCertificate: (_) => true)
          : await Socket.connect(host, port, timeout: timeout);
    } on SocketException catch (e) {
      throw MqttException(trf('Немає з\'єднання з {0}: {1}', [host, e.osError?.message ?? e.message]));
    } on HandshakeException {
      throw MqttException(tr('Не вдалося встановити захищене з\'єднання'));
    }
    _connack = Completer<int>();
    _socket!.listen(_onData, onError: (Object e) => _fail(e), onDone: () => _fail('closed'), cancelOnError: true);
    _socket!.add(mqttConnect(clientId, user: user, password: password));
    final rc = await _connack!.future.timeout(timeout, onTimeout: () => -1);
    if (rc != 0) {
      await close();
      throw MqttException(switch (rc) {
        4 || 5 => tr('Принтер не прийняв код доступу'),
        -1 => tr('Принтер не відповідає'),
        _ => trf('Принтер відхилив з\'єднання (код {0})', [rc]),
      });
    }
    _ping = Timer.periodic(const Duration(seconds: 30), (_) => _send(Uint8List.fromList([0xC0, 0])));
  }

  void _fail(Object e) {
    if (_connack != null && !_connack!.isCompleted) _connack!.complete(-1);
    if (!_closed) _messages.addError(MqttException(tr('З\'єднання з принтером розірвано')));
    close();
  }

  void _send(Uint8List data) {
    try {
      _socket?.add(data);
    } catch (_) {}
  }

  void _onData(Uint8List data) {
    for (final (h, body) in _parser.add(data)) {
      switch (h >> 4) {
        case 2: // CONNACK
          if (_connack != null && !_connack!.isCompleted) _connack!.complete(body.length >= 2 ? body[1] : -1);
        case 3: // PUBLISH
          if (body.length < 2) continue;
          final tl = (body[0] << 8) | body[1];
          if (body.length < 2 + tl) continue;
          final topic = utf8.decode(body.sublist(2, 2 + tl), allowMalformed: true);
          int p = 2 + tl;
          final qos = (h >> 1) & 3;
          if (qos > 0 && body.length >= p + 2) {
            _send(Uint8List.fromList([0x40, 2, body[p], body[p + 1]])); // PUBACK
            p += 2;
          }
          _messages.add(MqttMessage(topic, Uint8List.fromList(body.sublist(p))));
      }
    }
  }

  void subscribe(String topic) => _send(mqttSubscribe(1, topic));

  void publish(String topic, String json) => _send(mqttPublish(topic, utf8.encode(json)));

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ping?.cancel();
    try {
      _socket?.add(Uint8List.fromList([0xE0, 0])); // DISCONNECT
      await _socket?.flush();
    } catch (_) {}
    _socket?.destroy();
    await _messages.close();
  }
}
