import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../history/history.dart';
import '../orders/orders.dart';
import '../platform/files.dart';
import 'widgets.dart';

String quoteText(Order o) {
  final t = o.totals;
  final b = StringBuffer('Розрахунок вартості 3D-друку');
  if (o.client.trim().isNotEmpty) b.write(' для ${o.client.trim()}');
  b.writeln();
  for (final it in o.items) {
    b.writeln('• ${it.name} — ${it.material}, ${it.qty} шт × ${fmtGrams(it.gramsEach)}: '
        '${fmtMoney(it.priceEach * it.qty)}');
  }
  if (t.discount > 0) b.writeln('Знижка: −${fmtMoney(t.discount)}');
  if (t.extra > 0) b.writeln('Підготовка / робота: ${fmtMoney(t.extra)}');
  b.writeln('Разом: ${fmtMoney(t.total)}');
  b.writeln('Орієнтовний час друку: ${formatDuration(t.hours)}');
  if (o.note.trim().isNotEmpty) b.writeln(o.note.trim());
  return b.toString().trim();
}

/// A neat picture of the order to send to the client.
class QuotePage extends StatefulWidget {
  final Order order;

  const QuotePage({super.key, required this.order});

  @override
  State<QuotePage> createState() => _QuotePageState();
}

class _QuotePageState extends State<QuotePage> {
  final _key = GlobalKey();
  bool _busy = false;

  Future<void> _shareImage() async {
    setState(() => _busy = true);
    try {
      final obj = _key.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;
      final img = await obj.toImage(pixelRatio: 2.5);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (data == null) return;
      await PlatformFiles.shareFile('rozrahunok.png', 'image/png', data.buffer.asUint8List());
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не вдалося: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Пропозиція для клієнта')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          RepaintBoundary(key: _key, child: QuoteCard(order: widget.order)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _shareImage,
            icon: const Icon(Icons.image_outlined),
            label: const Text('Надіслати картинкою'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => PlatformFiles.shareText(quoteText(widget.order)).catchError((Object _) {}),
            icon: const Icon(Icons.text_snippet_outlined),
            label: const Text('Надіслати текстом'),
          ),
        ],
      ),
    );
  }
}

/// Light card regardless of the app theme (it is sent as an image).
class QuoteCard extends StatelessWidget {
  final Order order;

  const QuoteCard({super.key, required this.order});

  static const _ink = Color(0xFF1E1B26);
  static const _muted = Color(0xFF6B6577);
  static const _accent = Color(0xFFE8681F);

  @override
  Widget build(BuildContext context) {
    final o = order;
    final t = o.totals;
    const base = TextStyle(color: _ink, fontSize: 14, height: 1.3);
    Widget row(String a, String b, {TextStyle? style}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(a, style: style ?? base.copyWith(color: _muted))),
            Text(b, style: style ?? base),
          ]),
        );
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 12, offset: Offset(0, 4))],
      ),
      padding: const EdgeInsets.all(20),
      child: DefaultTextStyle(
        style: base,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset('assets/logo.png', width: 40, height: 40),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Розрахунок вартості 3D-друку',
                    style: TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w700)),
                Text(formatDate(DateTime.now()).split(' ').first, style: base.copyWith(color: _muted, fontSize: 12)),
              ]),
            ),
          ]),
          if (o.client.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Для: ${o.client.trim()}', style: base.copyWith(fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 12),
          const Divider(color: Color(0xFFE7E3EC), height: 1),
          for (final it in o.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 52,
                    height: 52,
                    color: const Color(0xFFF3EFF6),
                    child: it.thumbPath != null && File(it.thumbPath!).existsSync()
                        ? Image.file(File(it.thumbPath!), fit: BoxFit.cover)
                        : const Icon(Icons.view_in_ar_outlined, color: _accent),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: base.copyWith(fontWeight: FontWeight.w600)),
                    Text('${it.material} · ${it.qty} шт · ${fmtGrams(it.gramsEach)}',
                        style: base.copyWith(color: _muted, fontSize: 12)),
                  ]),
                ),
                Text(fmtMoney(it.priceEach * it.qty), style: base.copyWith(fontWeight: FontWeight.w600)),
              ]),
            ),
          const Divider(color: Color(0xFFE7E3EC), height: 1),
          const SizedBox(height: 8),
          if (t.discount > 0) row('Знижка від кількості', '−${fmtMoney(t.discount)}'),
          if (t.extra > 0) row('Підготовка, робота', fmtMoney(t.extra)),
          if (t.minimumAdd > 0) row('Мінімальне замовлення', fmtMoney(t.minimumAdd)),
          row('Орієнтовний час друку', formatDuration(t.hours)),
          const SizedBox(height: 8),
          Row(children: [
            const Expanded(child: Text('Разом', style: TextStyle(color: _ink, fontSize: 18, fontWeight: FontWeight.w700))),
            Text(fmtMoney(t.total), style: const TextStyle(color: _accent, fontSize: 24, fontWeight: FontWeight.w800)),
          ]),
          if (o.note.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(o.note.trim(), style: base.copyWith(color: _muted, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}
