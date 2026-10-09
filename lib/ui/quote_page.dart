import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/business.dart';
import '../history/history.dart';
import '../orders/orders.dart';
import '../platform/files.dart';
import '../platform/pdf.dart';
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
  bool _invoice = false;
  late bool _withPhotos = widget.order.photos.isNotEmpty;
  BusinessInfo _business = const BusinessInfo();

  @override
  void initState() {
    super.initState();
    BusinessInfo.load().then((b) {
      if (mounted) setState(() => _business = b);
    });
  }

  String get _fileBase => _invoice ? 'rahunok-${widget.order.number}' : 'rozrahunok';

  Future<void> _capture(Future<void> Function(ui.Image img) use) async {
    setState(() => _busy = true);
    try {
      final obj = _key.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return;
      final img = await obj.toImage(pixelRatio: 2.5);
      try {
        await use(img);
      } finally {
        img.dispose();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не вдалося: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareImage() => _capture((img) async {
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return;
        await PlatformFiles.shareFile('$_fileBase.png', 'image/png', data.buffer.asUint8List());
      });

  Future<Uint8List?> _pdf(ui.Image img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return PdfImage.build(data.buffer.asUint8List(), img.width, img.height,
        title: _invoice ? 'Рахунок № ${widget.order.number}' : 'Розрахунок вартості 3D-друку');
  }

  Future<void> _sharePdf() => _capture((img) async {
        final pdf = await _pdf(img);
        if (pdf != null) await PlatformFiles.shareFile('$_fileBase.pdf', 'application/pdf', pdf);
      });

  Future<void> _savePdf() => _capture((img) async {
        final pdf = await _pdf(img);
        if (pdf == null) return;
        final ok = await PlatformFiles.saveFile('$_fileBase.pdf', 'application/pdf', pdf);
        if (ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PDF збережено')));
      });

  Future<void> _editBusiness() async {
    final r = await showDialog<BusinessInfo>(context: context, builder: (_) => _BusinessDialog(info: _business));
    if (r == null) return;
    await r.save();
    if (mounted) setState(() => _business = r);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_invoice ? 'Рахунок' : 'Пропозиція для клієнта'),
        actions: [
          IconButton(
            tooltip: 'Мої реквізити',
            onPressed: _editBusiness,
            icon: const Icon(Icons.storefront_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Пропозиція'), icon: Icon(Icons.request_quote_outlined)),
              ButtonSegment(value: true, label: Text('Рахунок'), icon: Icon(Icons.receipt_long_outlined)),
            ],
            selected: {_invoice},
            onSelectionChanged: (v) => setState(() => _invoice = v.first),
          ),
          if (_invoice && _business.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextButton.icon(
                onPressed: _editBusiness,
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Додати свої реквізити для оплати'),
              ),
            ),
          if (widget.order.photos.isNotEmpty)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Додати фото виробу'),
              value: _withPhotos,
              onChanged: (v) => setState(() => _withPhotos = v),
            ),
          const SizedBox(height: 12),
          RepaintBoundary(
            key: _key,
            child: QuoteCard(order: widget.order, invoice: _invoice, business: _business, photos: _withPhotos),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _sharePdf,
            icon: const Icon(Icons.picture_as_pdf_outlined),
            label: const Text('Надіслати PDF'),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _shareImage,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Картинкою'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _savePdf,
                icon: const Icon(Icons.save_alt),
                label: const Text('Зберегти PDF'),
              ),
            ),
          ]),
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
  final bool invoice;
  final BusinessInfo business;
  final bool photos;

  const QuoteCard({
    super.key,
    required this.order,
    this.invoice = false,
    this.business = const BusinessInfo(),
    this.photos = false,
  });

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
                Text(invoice ? 'Рахунок № ${o.number}' : 'Розрахунок вартості 3D-друку',
                    style: const TextStyle(color: _ink, fontSize: 17, fontWeight: FontWeight.w700)),
                Text(formatDate(DateTime.now()).split(' ').first, style: base.copyWith(color: _muted, fontSize: 12)),
                if (business.name.trim().isNotEmpty)
                  Text(business.name.trim(), style: base.copyWith(color: _muted, fontSize: 12)),
              ]),
            ),
          ]),
          if (o.client.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(invoice ? 'Платник: ${o.client.trim()}' : 'Для: ${o.client.trim()}',
                style: base.copyWith(fontWeight: FontWeight.w600)),
          ],
          if (o.dueAt != null) ...[
            const SizedBox(height: 4),
            Text('Готовність: ${formatDate(o.dueAt!).split(' ').first}', style: base.copyWith(color: _muted)),
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
          if (photos && o.photos.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(children: [
              for (final p in o.photos.take(3)) ...[
                Expanded(
                  child: AspectRatio(
                    aspectRatio: o.photos.length == 1 ? 4 / 3 : 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.file(File(p), fit: BoxFit.cover, cacheWidth: 900),
                    ),
                  ),
                ),
                if (p != o.photos.take(3).last) const SizedBox(width: 6),
              ],
            ]),
            const SizedBox(height: 10),
          ],
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
          if (invoice && business.payment.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: Color(0xFFE7E3EC), height: 1),
            const SizedBox(height: 8),
            Text('Оплата', style: base.copyWith(fontWeight: FontWeight.w700)),
            Text(business.payment.trim(), style: base),
          ],
          if (business.contacts.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(business.contacts.trim(), style: base.copyWith(color: _muted, fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}

class _BusinessDialog extends StatefulWidget {
  final BusinessInfo info;

  const _BusinessDialog({required this.info});

  @override
  State<_BusinessDialog> createState() => _BusinessDialogState();
}

class _BusinessDialogState extends State<_BusinessDialog> {
  late final _name = TextEditingController(text: widget.info.name);
  late final _contacts = TextEditingController(text: widget.info.contacts);
  late final _payment = TextEditingController(text: widget.info.payment);

  @override
  void dispose() {
    _name.dispose();
    _contacts.dispose();
    _payment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Мої реквізити'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Назва / ФОП', hintText: 'ФОП Іваненко І. І.'),
          ),
          TextField(
            controller: _contacts,
            decoration: const InputDecoration(labelText: 'Контакти', hintText: '+380…, @telegram'),
          ),
          TextField(
            controller: _payment,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Як оплатити', hintText: 'IBAN UA… або номер картки'),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            BusinessInfo(name: _name.text.trim(), contacts: _contacts.text.trim(), payment: _payment.text.trim()),
          ),
          child: const Text('Зберегти'),
        ),
      ],
    );
  }
}
