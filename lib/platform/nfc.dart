import 'dart:typed_data';

import 'package:flutter/services.dart';

/// One NDEF record of a tag.
class NdefRec {
  final int tnf;
  final String type; // MIME type for TNF 2
  final Uint8List payload;

  const NdefRec(this.tnf, this.type, this.payload);
}

/// What was read from an NFC tag.
class NfcTag {
  final String uid; // hex, upper case
  final List<String> techs;
  final List<NdefRec> records;

  /// Blocks 0..19 of a Bambu Lab MIFARE Classic tag (null = not MIFARE).
  final List<Uint8List?>? mifareBlocks;

  /// Why the MIFARE blocks could not be read ("auth", "unsupported", …).
  final String? mifareError;
  final bool writable;

  const NfcTag({
    required this.uid,
    this.techs = const [],
    this.records = const [],
    this.mifareBlocks,
    this.mifareError,
    this.writable = false,
  });

  static NfcTag? fromMap(Object? r) {
    if (r is! Map || r['uid'] is! String) return null;
    final m = r['mifare'];
    return NfcTag(
      uid: r['uid'] as String,
      techs: [for (final t in (r['techs'] as List? ?? const [])) '$t'],
      records: [
        for (final x in (r['records'] as List? ?? const []))
          if (x is Map && x['payload'] is Uint8List)
            NdefRec((x['tnf'] as num?)?.toInt() ?? 0, '${x['type'] ?? ''}', x['payload'] as Uint8List),
      ],
      mifareBlocks: m is Map && m['blocks'] is List
          ? [for (final b in m['blocks'] as List) b is Uint8List ? b : null]
          : null,
      mifareError: m is Map ? m['error'] as String? : null,
      writable: r['writable'] == true,
    );
  }
}

/// NFC through MainActivity (reader mode while a dialog waits for a tag).
class Nfc {
  static const _channel = MethodChannel('stl_weight/files');

  /// Tests: a tag returned instead of reading a real one.
  static NfcTag? debugTag;

  /// Tests: the last write instead of writing a real tag.
  static (String, Uint8List)? debugWritten;

  /// "on", "off" or "none" (no NFC hardware).
  static Future<String> state() async {
    if (debugTag != null) return 'on';
    try {
      return await _channel.invokeMethod<String>('nfcState') ?? 'none';
    } on MissingPluginException {
      return 'none';
    }
  }

  /// Waits for a tag; null when cancelled.
  static Future<NfcTag?> read() async {
    if (debugTag != null) {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      return debugTag;
    }
    return NfcTag.fromMap(await _channel.invokeMethod<Object?>('nfcRead'));
  }

  /// Waits for a tag and writes one MIME record; returns the tag UID (null = cancelled).
  static Future<String?> write(String mime, Uint8List payload) async {
    if (debugTag != null) {
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      debugWritten = (mime, payload);
      return debugTag!.uid;
    }
    final r = await _channel.invokeMethod<Object?>('nfcWrite', {'mime': mime, 'payload': payload});
    return r is Map ? r['uid'] as String? : null;
  }

  static Future<void> cancel() async {
    if (debugTag != null) return;
    try {
      await _channel.invokeMethod<void>('nfcCancel');
    } on MissingPluginException {
      // not on Android
    }
  }

  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<Object?>('openNfcSettings');
    } on MissingPluginException {
      // not on Android
    }
  }
}
