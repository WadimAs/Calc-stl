import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/records.dart';
import '../expenses/expenses.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import '../spools/label_parser.dart';
import '../platform/files.dart';
import 'widgets.dart';
import '../i18n/i18n.dart';

const spoolColors = <int>[
  0xFFFFFFFF, 0xFF202020, 0xFF9E9E9E, 0xFFE53935, 0xFFFF8A3D, 0xFFFDD835, //
  0xFF43A047, 0xFF1E88E5, 0xFF8E24AA, 0xFFEC407A, 0xFF795548, 0xFF00ACC1,
];

class SpoolsPage extends StatefulWidget {
  /// Puts a spool's purchase price into the cost calculation.
  final void Function(String materialId, double pricePerKg)? onUsePrice;

  const SpoolsPage({super.key, this.onUsePrice});

  @override
  State<SpoolsPage> createState() => _SpoolsPageState();
}

class _SpoolsPageState extends State<SpoolsPage> {
  List<Spool>? _spools;

  @override
  void initState() {
    super.initState();
    SpoolStore.load().then((v) {
      if (mounted) setState(() => _spools = v);
    });
  }

  Future<void> _edit([Spool? s, bool scan = false]) async {
    final r = await showDialog<(Spool, bool)>(context: context, builder: (_) => _SpoolDialog(spool: s, scan: scan));
    if (r == null) return;
    final (result, asExpense) = r;
    final list = await SpoolStore.upsert(result);
    if (asExpense && result.price > 0) {
      await expenseStore.upsert(Expense(
        id: newId(),
        date: DateTime.now(),
        category: 'Пластик', // no-tr
        amount: result.price,
        note: '${materialById(result.materialId).name}${result.title.isEmpty ? '' : ' ${result.title}'}, '
            '${fmtGrams(result.totalGrams)}',
      ));
    }
    if (mounted) setState(() => _spools = list);
    final perKg = result.pricePerKg;
    if (perKg != null && widget.onUsePrice != null && mounted && (s == null || s.price != result.price)) {
      final use = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('Рахувати за цією ціною?')),
          content: Text(trf('{0}: {1} за кг буде використано в розрахунку собівартості.', [materialById(result.materialId).name, fmtMoney(perKg)])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('Ні'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('Так'))),
          ],
        ),
      );
      if (use == true) widget.onUsePrice!(result.materialId, perKg);
    }
  }

  void _usePrice(Spool s) {
    final perKg = s.pricePerKg;
    if (perKg == null || widget.onUsePrice == null) return;
    widget.onUsePrice!(s.materialId, perKg);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(trf('{0}: тепер {1} за кг', [materialById(s.materialId).name, fmtMoney(perKg)])),
    ));
  }

  Future<void> _delete(Spool s) async {
    final list = await SpoolStore.remove(s.id);
    if (mounted) setState(() => _spools = list);
  }

  Future<void> _setOnSpool(Spool s, bool v) async {
    final list = await SpoolStore.upsert(s.copyWith(onSpool: v));
    if (mounted) setState(() => _spools = list);
  }

  Future<void> _writeOff(Spool s) async {
    final c = TextEditingController();
    final g = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Списати вручну')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: tr('Скільки грамів'), helperText: tr('Напр. невдалий друк або продувка')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Скасувати'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.replaceAll(',', '.'))),
            child: Text(tr('Списати')),
          ),
        ],
      ),
    );
    if (g == null || g <= 0) return;
    final list = await SpoolStore.adjust({s.id: -g});
    if (mounted) setState(() => _spools = list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _spools;
    final total = list?.fold(0.0, (a, s) => a + s.remainingGrams) ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Котушки')),
        actions: [
          IconButton(
            tooltip: tr('Додати з фото етикетки'),
            onPressed: () => _edit(null, true),
            icon: const Icon(Icons.document_scanner_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: Text(tr('Котушка')),
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      tr('Додайте свої котушки — коли замовлення стане «Готово», використаний пластик спишеться автоматично.'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(trf('Усього на котушках: {0}', [fmtGrams(total)]), style: theme.textTheme.labelLarge),
                    ),
                    for (final s in list)
                      Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _edit(s),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Color(s.colorArgb),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: theme.colorScheme.outlineVariant, width: 2),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(
                                    s.title.isEmpty ? materialById(s.materialId).name : '${materialById(s.materialId).name} · ${s.title}',
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  if (s.refill)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: _RefillChip(onSpool: s.onSpool),
                                    ),
                                  const SizedBox(height: 6),
                                  LinearProgressIndicator(
                                    value: s.fraction,
                                    minHeight: 6,
                                    borderRadius: BorderRadius.circular(3),
                                    color: s.isLow ? theme.colorScheme.error : null,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    trf('{0} з {1}{2}{3}', [fmtGrams(s.remainingGrams), fmtGrams(s.totalGrams), s.isLow ? tr(' — закінчується') : '', s.pricePerKg != null ? trf(' · {0}/кг', [fmtMoney(s.pricePerKg!)]) : '']),
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: s.isLow ? theme.colorScheme.error : null),
                                  ),
                                ]),
                              ),
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'off') _writeOff(s);
                                  if (v == 'price') _usePrice(s);
                                  if (v == 'mount') _setOnSpool(s, !s.onSpool);
                                  if (v == 'del') _delete(s);
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: 'off', child: Text(tr('Списати вручну'))),
                                  if (s.refill)
                                    PopupMenuItem(
                                      value: 'mount',
                                      child: Text(s.onSpool ? tr('Зняти з котушки') : tr('Встановлено на котушку')),
                                    ),
                                  if (s.pricePerKg != null && widget.onUsePrice != null)
                                    PopupMenuItem(value: 'price', child: Text(tr('Рахувати за ціною котушки'))),
                                  PopupMenuItem(value: 'del', child: Text(tr('Видалити'))),
                                ],
                              ),
                            ]),
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _SpoolDialog extends StatefulWidget {
  final Spool? spool;

  /// Start by photographing the spool label.
  final bool scan;

  const _SpoolDialog({this.spool, this.scan = false});

  @override
  State<_SpoolDialog> createState() => _SpoolDialogState();
}

class _SpoolDialogState extends State<_SpoolDialog> {
  late String _material = widget.spool?.materialId ?? 'PLA';
  late int _color = widget.spool?.colorArgb ?? spoolColors[4];
  late final _name = TextEditingController(text: widget.spool?.name ?? '');
  late final _brand = TextEditingController(text: widget.spool?.brand ?? '');
  late bool _refill = widget.spool?.refill ?? false;
  late bool _onSpool = widget.spool?.onSpool ?? false;

  Future<void> _pickBrand() async {
    final b = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _BrandPicker(),
    );
    if (b != null) setState(() => _brand.text = b);
  }
  late final _total = TextEditingController(text: _fmt(widget.spool?.totalGrams ?? 1000));
  late final _left = TextEditingController(text: _fmt(widget.spool?.remainingGrams ?? 1000));
  late final _price =
      TextEditingController(text: (widget.spool?.price ?? 0) > 0 ? _fmt(widget.spool!.price) : '');
  bool _asExpense = true;
  bool _scanning = false;
  String? _scanNote;

  @override
  void initState() {
    super.initState();
    if (widget.scan) WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  /// Photo of the label → OCR → fields.
  Future<void> _scan() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(tr('Сфотографувати етикетку')),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(tr('З галереї')),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
        ]),
      ),
    );
    if (how == null || !mounted) return;
    setState(() {
      _scanning = true;
      _scanNote = null;
    });
    try {
      final img = how == 'camera' ? await PlatformFiles.takePhoto() : await PlatformFiles.pickImage();
      if (img == null) return;
      final text = await PlatformFiles.recognizeText(img);
      final l = parseSpoolLabel(text);
      if (!mounted) return;
      setState(() {
        if (l.materialId != null && materials.any((m) => m.id == l.materialId)) _material = l.materialId!;
        if (l.colorArgb != null) _color = l.colorArgb!;
        if (l.brand != null) _brand.text = l.brand!;
        if (l.colorName != null) _name.text = l.colorName!;
        if (l.refill) {
          _refill = true;
          _onSpool = false;
        }
        if (l.weightGrams != null) {
          _total.text = _fmt(l.weightGrams!);
          if (widget.spool == null) _left.text = _fmt(l.weightGrams!);
        }
        _scanNote = l.isEmpty
            ? tr('Не вдалося нічого розпізнати. Сфотографуйте етикетку ближче, рівно й при гарному світлі.')
            : trf('Розпізнано: {0}', [
                [
                  l.brand,
                  l.materialText,
                  l.colorName,
                  if (l.weightGrams != null) fmtGrams(l.weightGrams!),
                  if (l.refill) tr('Refill (без котушки)'),
                ].whereType<String>().join(' · ')
              ]);
      });
    } catch (e) {
      final msg = e is PlatformException ? (e.message ?? e.code) : '$e';
      if (mounted) setState(() => _scanNote = trf('Не вдалося розпізнати: {0}', [msg]));
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _total.dispose();
    _left.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.spool == null ? tr('Нова котушка') : tr('Котушка')),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OutlinedButton.icon(
            onPressed: _scanning ? null : _scan,
            icon: _scanning
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.document_scanner_outlined),
            label: Text(tr('Заповнити з фото етикетки')),
          ),
          if (_scanNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_scanNote!, style: Theme.of(context).textTheme.bodySmall),
            ),
          DropdownButtonFormField<String>(
            key: ValueKey(_material),
            // ignore: deprecated_member_use
            value: _material,
            decoration: InputDecoration(labelText: tr('Пластик')),
            items: [
              for (final m in materials) DropdownMenuItem(value: m.id, child: Text(m.name)),
            ],
            onChanged: (v) => setState(() => _material = v ?? _material),
          ),
          TextField(
            controller: _brand,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: tr('Виробник'),
              hintText: 'Bambu Lab, eSUN, Plexiwire…',
              suffixIcon: IconButton(
                tooltip: tr('Вибрати зі списку'),
                icon: const Icon(Icons.arrow_drop_down_circle_outlined),
                onPressed: _pickBrand,
              ),
            ),
          ),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: tr('Колір / назва'), hintText: tr('Jade White, чорний…')),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(tr('Refill (без котушки)')),
            value: _refill,
            onChanged: (v) => setState(() {
              _refill = v;
              if (!v) _onSpool = false;
            }),
          ),
          if (_refill)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(tr('Уже встановлено на котушку')),
              value: _onSpool,
              onChanged: (v) => setState(() => _onSpool = v ?? false),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in spoolColors)
              GestureDetector(
                onTap: () => setState(() => _color = c),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _color == c ? Theme.of(context).colorScheme.primary : Colors.black26,
                      width: _color == c ? 3 : 1,
                    ),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _total,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr('Вага нової, г')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _left,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: tr('Залишилось, г')),
              ),
            ),
          ]),
          TextField(
            controller: _price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: trf('Ціна котушки, {0}', [currency]), hintText: tr('необов\'язково')),
          ),
          if (widget.spool == null && _price.text.trim().isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _asExpense,
              onChanged: (v) => setState(() => _asExpense = v ?? true),
              title: Text(tr('Записати покупку у витрати')),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Скасувати'))),
        FilledButton(
          onPressed: () {
            final total = double.tryParse(_total.text.replaceAll(',', '.')) ?? 1000;
            final left = double.tryParse(_left.text.replaceAll(',', '.')) ?? total;
            final old = widget.spool;
            final price = double.tryParse(_price.text.replaceAll(',', '.').replaceAll(' ', '')) ?? 0;
            Navigator.pop(context, (
              old == null
                  ? Spool(
                      id: DateTime.now().microsecondsSinceEpoch.toString(),
                      materialId: _material,
                      name: _name.text.trim(),
                      colorArgb: _color,
                      totalGrams: total,
                      remainingGrams: left,
                      createdAt: DateTime.now(),
                      price: price,
                      brand: _brand.text.trim(),
                      refill: _refill,
                      onSpool: _refill && _onSpool,
                    )
                  : old.copyWith(
                      materialId: _material,
                      name: _name.text.trim(),
                      colorArgb: _color,
                      totalGrams: total,
                      remainingGrams: left,
                      price: price,
                      brand: _brand.text.trim(),
                      refill: _refill,
                      onSpool: _refill && _onSpool,
                    ),
              old == null && _asExpense,
            ));
          },
          child: Text(tr('Зберегти')),
        ),
      ],
    );
  }
}

/// Searchable list of filament makers.
class _BrandPicker extends StatefulWidget {
  const _BrandPicker();

  @override
  State<_BrandPicker> createState() => _BrandPickerState();
}

class _BrandPickerState extends State<_BrandPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final list = [for (final b in filamentBrands) if (q.isEmpty || b.toLowerCase().contains(q)) b];
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: false,
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: tr('Пошук виробника')),
            onChanged: (v) => setState(() => _q = v.trim()),
          ),
        ),
        Expanded(
          child: ListView(children: [
            for (final b in list) ListTile(title: Text(b), onTap: () => Navigator.pop(context, b)),
            if (_q.isNotEmpty && !list.any((b) => b.toLowerCase() == q))
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(trf('Інший: «{0}»', [_q])),
                onTap: () => Navigator.pop(context, _q),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// "Refill" badge: without a spool, or already mounted on one.
class _RefillChip extends StatelessWidget {
  final bool onSpool;

  const _RefillChip({required this.onSpool});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = onSpool ? scheme.primary : scheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(onSpool ? Icons.album : Icons.all_inclusive, size: 13, color: c),
        const SizedBox(width: 4),
        Text(onSpool ? tr('Refill на котушці') : tr('Refill, без котушки'),
            style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
