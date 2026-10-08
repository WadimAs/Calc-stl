import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'settings.dart';
import 'slicer.dart';

class SliceCancelled implements Exception {
  const SliceCancelled();
}

/// Runs [sliceMesh] in a background isolate with progress and cancellation.
class SliceJob {
  Isolate? _isolate;
  ReceivePort? _port;
  Completer<SliceResult>? _completer;

  Future<SliceResult> run(Float32List tris, SliceSettings settings, void Function(double) onProgress) async {
    final port = ReceivePort();
    final completer = Completer<SliceResult>();
    _port = port;
    _completer = completer;

    port.listen((msg) {
      if (completer.isCompleted) return;
      if (msg is double) {
        onProgress(msg);
      } else if (msg is Map) {
        if (msg['error'] != null) {
          completer.completeError(Exception(msg['error'].toString()));
        } else {
          completer.complete(SliceResult.fromMap(msg));
        }
        _close();
      } else if (msg is List) {
        // Uncaught error from the isolate: [error, stackTrace].
        completer.completeError(Exception(msg.isNotEmpty ? msg.first.toString() : 'Помилка нарізання'));
        _close();
      } else if (msg == null) {
        completer.completeError(const SliceCancelled());
        _close();
      }
    });

    final data = TransferableTypedData.fromList([tris]);
    try {
      _isolate = await Isolate.spawn<List<Object>>(
        _entry,
        [port.sendPort, data, settings.toJson()],
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
      );
    } catch (e) {
      if (!completer.isCompleted) completer.completeError(e);
      _close();
    }
    return completer.future;
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    final c = _completer;
    if (c != null && !c.isCompleted) c.completeError(const SliceCancelled());
    _close();
  }

  void _close() {
    _port?.close();
    _port = null;
    _isolate = null;
  }
}

void _entry(List<Object> args) {
  final send = args[0] as SendPort;
  final tris = (args[1] as TransferableTypedData).materialize().asFloat32List();
  final settings = SliceSettings.fromJson(Map<String, dynamic>.from(args[2] as Map));
  try {
    final r = sliceMesh(tris, settings, onProgress: (p) => send.send(p));
    send.send(r.toMap());
  } catch (e) {
    send.send({'error': e.toString()});
  }
}
