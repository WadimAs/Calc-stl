import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';
import '../platform/nfc.dart';

/// Bottom sheet that waits for a spool tag and reads it.
Future<NfcTag?> scanNfcTag(BuildContext context) => showModalBottomSheet<NfcTag>(
      context: context,
      showDragHandle: true,
      builder: (_) => _NfcSheet<NfcTag>(
        title: tr('Піднесіть котушку до телефону'),
        hint: tr('Мітка зазвичай на боці котушки. Тримайте її біля задньої частини телефону, де NFC.'),
        run: Nfc.read,
      ),
    );

/// Bottom sheet that waits for a tag and writes [payload]; returns the tag UID.
Future<String?> writeNfcTag(BuildContext context, String mime, Uint8List payload) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (_) => _NfcSheet<String>(
        title: tr('Піднесіть чисту NFC-мітку'),
        hint: tr('Підійдуть наліпки NTAG213/215/216. Дані котушки буде записано у форматі OpenSpool.'),
        run: () => Nfc.write(mime, payload),
      ),
    );

class _NfcSheet<T> extends StatefulWidget {
  final String title, hint;
  final Future<T?> Function() run;

  const _NfcSheet({required this.title, required this.hint, required this.run});

  @override
  State<_NfcSheet<T>> createState() => _NfcSheetState<T>();
}

class _NfcSheetState<T> extends State<_NfcSheet<T>> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  String? _state; // on / off / none
  String? _error;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final st = await Nfc.state();
    if (!mounted) return;
    setState(() {
      _state = st;
      _error = null;
    });
    if (st != 'on') return;
    setState(() => _waiting = true);
    try {
      final r = await widget.run();
      _waiting = false;
      if (!mounted) return;
      if (r == null) {
        Navigator.of(context).maybePop();
        return;
      }
      Navigator.of(context).pop(r);
    } catch (e) {
      _waiting = false;
      if (!mounted) return;
      final code = e is PlatformException ? e.code : '';
      final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
      setState(() => _error = switch (code) {
            'nfc_off' => null,
            _ when msg.contains('read-only') => tr('Мітка захищена від запису.'),
            _ when msg.contains('too small') => tr('На мітці замало місця. Візьміть NTAG215 або NTAG216.'),
            _ when msg.contains('not NDEF') => tr('Ця мітка не підтримує запис NDEF.'),
            _ => trf('Не вдалося прочитати мітку: {0}. Спробуйте ще раз і тримайте телефон нерухомо.', [msg]),
          });
      if (code == 'nfc_off') setState(() => _state = 'off');
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    if (_waiting) Nfc.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget body;
    if (_state == null) {
      body = const Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator());
    } else if (_state == 'none') {
      body = Text(tr('На цьому телефоні немає NFC.'), textAlign: TextAlign.center, style: theme.textTheme.bodyLarge);
    } else if (_state == 'off') {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.nfc, size: 56, color: cs.outline),
        const SizedBox(height: 12),
        Text(tr('NFC вимкнено'), style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(spacing: 8, alignment: WrapAlignment.center, children: [
          FilledButton.tonal(onPressed: Nfc.openSettings, child: Text(tr('Увімкнути NFC'))),
          TextButton(onPressed: _start, child: Text(tr('Спробувати знову'))),
        ]),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 140,
          height: 140,
          child: AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => CustomPaint(
              painter: _Waves(_error == null ? _pulse.value : 0, cs.primary),
              child: Center(
                child: CircleAvatar(
                  radius: 36,
                  backgroundColor: cs.primaryContainer,
                  child: Icon(Icons.nfc, size: 40, color: cs.onPrimaryContainer),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(widget.title, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text(
          _error ?? widget.hint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: _error != null ? cs.error : cs.onSurfaceVariant),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: _start, child: Text(tr('Спробувати знову'))),
        ],
      ]);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: SizedBox(width: double.infinity, child: Center(child: body)),
      ),
    );
  }
}

class _Waves extends CustomPainter {
  final double t;
  final Color color;

  _Waves(this.t, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    for (int i = 0; i < 2; i++) {
      final p = (t + i * 0.5) % 1.0;
      if (t == 0 && i > 0) break;
      canvas.drawCircle(
        c,
        38 + p * 32,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: (1 - p) * 0.5),
      );
    }
  }

  @override
  bool shouldRepaint(_Waves old) => old.t != t;
}
