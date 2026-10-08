import 'package:flutter/material.dart';

import '../slicer/settings.dart';
import '../platform/updates.dart';
import 'widgets.dart';

Future<void> showSettingsSheet(
  BuildContext context,
  SliceSettings initial,
  ValueChanged<SliceSettings> onChanged,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, controller) => _SettingsBody(
        initial: initial,
        onChanged: onChanged,
        controller: controller,
      ),
    ),
  );
}

class _SettingsBody extends StatefulWidget {
  final SliceSettings initial;
  final ValueChanged<SliceSettings> onChanged;
  final ScrollController controller;

  const _SettingsBody({required this.initial, required this.onChanged, required this.controller});

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  late SliceSettings _s = widget.initial;
  late final TextEditingController _density = TextEditingController(text: fmtNum(widget.initial.density, 2));

  void _set(SliceSettings s) {
    setState(() => _s = s);
    widget.onChanged(s);
  }

  @override
  void dispose() {
    _density.dispose();
    super.dispose();
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 6),
        child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            )),
      );

  /// Setting row with a Bambu-style reset icon on the right.
  Widget _withReset(Widget child, bool changed, VoidCallback reset) => Row(children: [
        Expanded(child: child),
        ResetButton(changed: changed, onReset: reset),
      ]);

  Future<void> _resetAll() async {
    final choice = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Скинути налаштування?'),
        content: const Text('Усі параметри повернуться до значень за замовчуванням (як «0.20mm Standard» у Bambu Studio).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Скасувати')),
          TextButton(onPressed: () => Navigator.pop(c, 2), child: const Text('Разом із цінами')),
          FilledButton(onPressed: () => Navigator.pop(c, 1), child: const Text('Скинути')),
        ],
      ),
    );
    if (choice == null) return;
    final d = _s.resetAll(prices: choice == 2);
    _density.text = fmtNum(d.density, 2);
    _set(d);
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    const d = SliceSettings();
    final theme = Theme.of(context);
    final currentPrinter = printerById(s.printerId);
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Налаштування', style: theme.textTheme.titleLarge)),
            TextButton.icon(
              onPressed: _resetAll,
              icon: const Icon(Icons.restart_alt),
              label: const Text('Скинути все'),
            ),
          ],
        ),
        _section('Шари'),
        StepperRow(
          label: 'Висота шару',
          value: s.layerHeight,
          defaultValue: d.layerHeight,
          min: 0.04,
          max: 1.0,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(_s.copyWith(layerHeight: v)),
        ),
        StepperRow(
          label: 'Перший шар',
          value: s.firstLayerHeight,
          defaultValue: d.firstLayerHeight,
          min: 0.06,
          max: 1.0,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(_s.copyWith(firstLayerHeight: v)),
        ),
        StepperRow(
          label: 'Ширина лінії',
          hint: 'зазвичай ≈ сопло × 1,05',
          value: s.lineWidth,
          defaultValue: d.lineWidth,
          min: 0.2,
          max: 1.6,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(_s.copyWith(lineWidth: v)),
        ),
        _section('Стінки та оболонка'),
        StepperRow(
          label: 'Стінки (периметри)',
          value: s.walls.toDouble(),
          defaultValue: d.walls.toDouble(),
          min: 1,
          max: 15,
          step: 1,
          onChanged: (v) => _set(_s.copyWith(walls: v.round())),
        ),
        StepperRow(
          label: 'Верхні шари',
          value: s.topLayers.toDouble(),
          defaultValue: d.topLayers.toDouble(),
          min: 0,
          max: 30,
          step: 1,
          onChanged: (v) => _set(_s.copyWith(topLayers: v.round())),
        ),
        StepperRow(
          label: 'Нижні шари',
          value: s.bottomLayers.toDouble(),
          defaultValue: d.bottomLayers.toDouble(),
          min: 0,
          max: 30,
          step: 1,
          onChanged: (v) => _set(_s.copyWith(bottomLayers: v.round())),
        ),
        _withReset(
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Товщина вертикальної оболонки'),
            subtitle: const Text('Суцільне заповнення біля похилих стінок, як у Bambu/Orca/Prusa'),
            value: s.ensureVerticalShell,
            onChanged: (v) => _set(_s.copyWith(ensureVerticalShell: v)),
          ),
          s.ensureVerticalShell != d.ensureVerticalShell,
          () => _set(_s.copyWith(ensureVerticalShell: d.ensureVerticalShell)),
        ),
        _withReset(
          _section('Заповнення — ${fmtNum(s.infillPercent, 0)}%'),
          s.infillPercent != d.infillPercent,
          () => _set(_s.copyWith(infillPercent: d.infillPercent)),
        ),
        Slider(
          value: s.infillPercent.clamp(0, 100).toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          label: '${fmtNum(s.infillPercent, 0)}%',
          onChanged: (v) => _set(_s.copyWith(infillPercent: v)),
        ),
        _section('Підтримки'),
        _withReset(
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Друкувати з підтримками'),
            value: s.supportsEnabled,
            onChanged: (v) => _set(_s.copyWith(supportsEnabled: v)),
          ),
          s.supportsEnabled != d.supportsEnabled,
          () => _set(_s.copyWith(supportsEnabled: d.supportsEnabled)),
        ),
        if (s.supportsEnabled) ...[
          _withReset(
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'normal', label: Text('Звичайні'), icon: Icon(Icons.view_column_outlined)),
                ButtonSegment(value: 'tree', label: Text('Деревоподібні'), icon: Icon(Icons.park_outlined)),
              ],
              selected: {s.isTreeSupport ? 'tree' : 'normal'},
              onSelectionChanged: (v) => _set(_s.copyWith(supportType: v.first)),
            ),
            s.supportType != d.supportType,
            () => _set(_s.copyWith(supportType: d.supportType)),
          ),
          const SizedBox(height: 8),
          _withReset(
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Скрізь')),
                ButtonSegment(value: true, label: Text('Лише від столу')),
              ],
              selected: {s.supportPlateOnly},
              onSelectionChanged: (v) => _set(_s.copyWith(supportPlateOnly: v.first)),
            ),
            s.supportPlateOnly != d.supportPlateOnly,
            () => _set(_s.copyWith(supportPlateOnly: d.supportPlateOnly)),
          ),
          const SizedBox(height: 8),
          StepperRow(
            label: 'Кут нависання',
            hint: 'від вертикалі; більший кут — менше підтримок',
            value: s.supportAngle,
            defaultValue: d.supportAngle,
            min: 20,
            max: 80,
            step: 5,
            unit: '°',
            onChanged: (v) => _set(_s.copyWith(supportAngle: v)),
          ),
          if (!s.isTreeSupport)
            StepperRow(
              label: 'Щільність підтримок',
              value: s.supportDensity,
              defaultValue: d.supportDensity,
              min: 5,
              max: 60,
              step: 5,
              unit: '%',
              onChanged: (v) => _set(_s.copyWith(supportDensity: v)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 36),
              child: Text(
                'Гілки: крок 6 мм, кінчики Ø2 мм, донизу товщають і зливаються у стовбури.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
        _section('Принтер'),
        _withReset(
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Модель (для оцінки часу)',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: currentPrinter.id,
                selectedItemBuilder: (_) => [
                  for (final brand in printerBrands) ...[
                    const SizedBox.shrink(),
                    for (final p in printers.where((p) => p.brand == brand))
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(p.fullName, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ],
                items: [
                  for (final brand in printerBrands) ...[
                    DropdownMenuItem<String>(
                      enabled: false,
                      value: 'brand:$brand',
                      child: Text(
                        brand,
                        style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary),
                      ),
                    ),
                    for (final p in printers.where((p) => p.brand == brand))
                      DropdownMenuItem<String>(
                        value: p.id,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Text(p.name, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                  ],
                ],
                onChanged: (id) {
                  if (id == null || id.startsWith('brand:')) return;
                  _set(_s.copyWith(printerId: id, powerW: printerById(id).powerW));
                },
              ),
            ),
          ),
          s.printerId != d.printerId,
          () => _set(_s.copyWith(printerId: d.printerId, powerW: printerById(d.printerId).powerW)),
        ),
        _section('Собівартість'),
        NumberField(
          key: ValueKey('price-${s.materialId}'),
          label: 'Котушка ${materialById(s.materialId).name}, за 1 кг',
          suffix: currency,
          value: s.pricePerKg,
          defaultValue: s.defaultPricePerKg,
          onChanged: (v) => _set(
            (v - _s.defaultPricePerKg).abs() < 1e-9 ? _s.withoutPriceOverride() : _s.withPrice(v),
          ),
        ),
        const SizedBox(height: 12),
        NumberField(
          key: ValueKey('power-${s.printerId}'),
          label: 'Споживання принтера',
          suffix: 'Вт',
          value: s.powerW,
          defaultValue: currentPrinter.powerW,
          onChanged: (v) => _set(_s.copyWith(powerW: v)),
        ),
        const SizedBox(height: 12),
        NumberField(
          label: 'Тариф, за кВт·год',
          suffix: currency,
          value: s.tariff,
          defaultValue: d.tariff,
          onChanged: (v) => _set(_s.copyWith(tariff: v)),
        ),
        const SizedBox(height: 12),
        NumberField(
          label: 'Амортизація, за годину друку',
          helper: 'Ціна принтера й запчастин ÷ ресурс у годинах',
          suffix: currency,
          value: s.amortizationPerHour,
          defaultValue: d.amortizationPerHour,
          onChanged: (v) => _set(_s.copyWith(amortizationPerHour: v)),
        ),
        _section('Заробіток'),
        NumberField(
          label: 'Націнка на собівартість',
          suffix: '%',
          value: s.markupPercent,
          defaultValue: d.markupPercent,
          onChanged: (v) => _set(_s.copyWith(markupPercent: v)),
        ),
        const SizedBox(height: 12),
        NumberField(
          label: 'Доплата за замовлення',
          helper: 'Робота, моделювання, пакування тощо',
          suffix: currency,
          value: s.extraCost,
          defaultValue: d.extraCost,
          onChanged: (v) => _set(_s.copyWith(extraCost: v)),
        ),
        _section('Модель'),
        StepperRow(
          label: 'Масштаб',
          value: s.scalePercent,
          defaultValue: d.scalePercent,
          min: 5,
          max: 2000,
          step: 5,
          unit: '%',
          onChanged: (v) => _set(_s.copyWith(scalePercent: v)),
        ),
        StepperRow(
          label: 'Кількість копій',
          value: s.copies.toDouble(),
          defaultValue: d.copies.toDouble(),
          min: 1,
          max: 500,
          step: 1,
          onChanged: (v) => _set(_s.copyWith(copies: v.round())),
        ),
        _section('Матеріал'),
        _withReset(
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Пластик',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: s.materialId,
                items: [
                  for (final m in materials)
                    DropdownMenuItem(
                      value: m.id,
                      child: Text(m.id == 'custom' ? m.name : '${m.name} — ${fmtNum(m.density, 2)} г/см³'),
                    ),
                ],
                onChanged: (id) {
                  if (id == null) return;
                  final m = materialById(id);
                  final density = id == 'custom' ? _s.density : m.density;
                  _density.text = fmtNum(density, 2);
                  _set(_s.copyWith(materialId: id, density: density));
                },
              ),
            ),
          ),
          s.materialId != d.materialId,
          () {
            _density.text = fmtNum(d.density, 2);
            _set(_s.copyWith(materialId: d.materialId, density: d.density));
          },
        ),
        const SizedBox(height: 12),
        _withReset(
          TextField(
            controller: _density,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Густина, г/см³',
              helperText: 'Можна уточнити з паспорта котушки',
              border: OutlineInputBorder(),
            ),
            onChanged: (t) {
              final v = double.tryParse(t.replaceAll(',', '.').trim());
              if (v != null && v > 0.3 && v < 5) _set(_s.copyWith(density: v));
            },
          ),
          s.materialId != 'custom' && (s.density - materialById(s.materialId).density).abs() > 1e-9,
          () {
            final v = materialById(_s.materialId).density;
            _density.text = fmtNum(v, 2);
            _set(_s.copyWith(density: v));
          },
        ),
        const SizedBox(height: 16),
        Text('Діаметр філаменту', style: theme.textTheme.bodyLarge),
        const SizedBox(height: 8),
        _withReset(
          SegmentedButton<double>(
            segments: const [
              ButtonSegment(value: 1.75, label: Text('1,75 мм')),
              ButtonSegment(value: 2.85, label: Text('2,85 мм')),
            ],
            selected: {s.filamentDiameter == 2.85 ? 2.85 : 1.75},
            onSelectionChanged: (v) => _set(_s.copyWith(filamentDiameter: v.first)),
          ),
          s.filamentDiameter != d.filamentDiameter,
          () => _set(_s.copyWith(filamentDiameter: d.filamentDiameter)),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            'Розрахунок не враховує кайму (brim), спідницю та очищувальну вежу.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 16),
        const _AboutRow(),
      ],
    );
  }
}

class _AboutRow extends StatefulWidget {
  const _AboutRow();

  @override
  State<_AboutRow> createState() => _AboutRowState();
}

class _AboutRowState extends State<_AboutRow> {
  String _version = '';
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    Updates.installedName().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final u = await Updates.check();
    if (!mounted) return;
    setState(() => _checking = false);
    if (u == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('У вас найновіша версія')));
    } else {
      await Updates.open(u.downloadUrl).catchError((Object _) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Expanded(
        child: Text('Версія $_version', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
      ),
      TextButton.icon(
        onPressed: _checking ? null : _check,
        icon: _checking
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.system_update_outlined),
        label: const Text('Перевірити оновлення'),
      ),
    ]);
  }
}
