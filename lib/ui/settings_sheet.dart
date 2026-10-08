import 'package:flutter/material.dart';

import '../slicer/settings.dart';
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

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Row(
          children: [
            Expanded(child: Text('Налаштування друку', style: Theme.of(context).textTheme.titleLarge)),
            TextButton(
              onPressed: () {
                // Reset print settings, keep prices.
                final d = const SliceSettings().copyWith(
                  pricesPerKg: _s.pricesPerKg,
                  markupPercent: _s.markupPercent,
                  extraCost: _s.extraCost,
                );
                _density.text = fmtNum(d.density, 2);
                _set(d);
              },
              child: const Text('Скинути'),
            ),
          ],
        ),
        _section('Шари'),
        StepperRow(
          label: 'Висота шару',
          value: s.layerHeight,
          min: 0.04,
          max: 1.0,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(s.copyWith(layerHeight: v)),
        ),
        StepperRow(
          label: 'Перший шар',
          value: s.firstLayerHeight,
          min: 0.06,
          max: 1.0,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(s.copyWith(firstLayerHeight: v)),
        ),
        StepperRow(
          label: 'Ширина лінії',
          hint: 'зазвичай ≈ сопло × 1,05',
          value: s.lineWidth,
          min: 0.2,
          max: 1.6,
          step: 0.02,
          decimals: 2,
          unit: ' мм',
          onChanged: (v) => _set(s.copyWith(lineWidth: v)),
        ),
        _section('Стінки та оболонка'),
        StepperRow(
          label: 'Стінки (периметри)',
          value: s.walls.toDouble(),
          min: 1,
          max: 15,
          step: 1,
          onChanged: (v) => _set(s.copyWith(walls: v.round())),
        ),
        StepperRow(
          label: 'Верхні шари',
          value: s.topLayers.toDouble(),
          min: 0,
          max: 30,
          step: 1,
          onChanged: (v) => _set(s.copyWith(topLayers: v.round())),
        ),
        StepperRow(
          label: 'Нижні шари',
          value: s.bottomLayers.toDouble(),
          min: 0,
          max: 30,
          step: 1,
          onChanged: (v) => _set(s.copyWith(bottomLayers: v.round())),
        ),
        _section('Заповнення — ${fmtNum(s.infillPercent, 0)}%'),
        Slider(
          value: s.infillPercent.clamp(0, 100).toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          label: '${fmtNum(s.infillPercent, 0)}%',
          onChanged: (v) => _set(s.copyWith(infillPercent: v)),
        ),
        _section('Підтримки'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Друкувати з підтримками'),
          value: s.supportsEnabled,
          onChanged: (v) => _set(s.copyWith(supportsEnabled: v)),
        ),
        if (s.supportsEnabled) ...[
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Скрізь')),
              ButtonSegment(value: true, label: Text('Лише від столу')),
            ],
            selected: {s.supportPlateOnly},
            onSelectionChanged: (v) => _set(s.copyWith(supportPlateOnly: v.first)),
          ),
          const SizedBox(height: 8),
          StepperRow(
            label: 'Кут нависання',
            hint: 'від вертикалі; більший кут — менше підтримок',
            value: s.supportAngle,
            min: 20,
            max: 80,
            step: 5,
            unit: '°',
            onChanged: (v) => _set(s.copyWith(supportAngle: v)),
          ),
          StepperRow(
            label: 'Щільність підтримок',
            value: s.supportDensity,
            min: 5,
            max: 60,
            step: 5,
            unit: '%',
            onChanged: (v) => _set(s.copyWith(supportDensity: v)),
          ),
        ],
        _section('Вартість'),
        NumberField(
          key: ValueKey('price-${s.materialId}'),
          label: 'Ціна ${materialById(s.materialId).name}, $currency за кг',
          value: s.pricePerKg,
          onChanged: (v) => _set(_s.withPrice(v)),
        ),
        const SizedBox(height: 12),
        NumberField(
          label: 'Націнка, %',
          value: s.markupPercent,
          onChanged: (v) => _set(_s.copyWith(markupPercent: v)),
        ),
        const SizedBox(height: 12),
        NumberField(
          label: 'Доплата за замовлення, $currency',
          helper: 'Робота, моделювання, пакування тощо',
          value: s.extraCost,
          onChanged: (v) => _set(_s.copyWith(extraCost: v)),
        ),
        _section('Модель'),
        StepperRow(
          label: 'Масштаб',
          value: s.scalePercent,
          min: 5,
          max: 2000,
          step: 5,
          unit: '%',
          onChanged: (v) => _set(s.copyWith(scalePercent: v)),
        ),
        StepperRow(
          label: 'Кількість копій',
          value: s.copies.toDouble(),
          min: 1,
          max: 500,
          step: 1,
          onChanged: (v) => _set(s.copyWith(copies: v.round())),
        ),
        _section('Матеріал'),
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
                final density = id == 'custom' ? s.density : m.density;
                _density.text = fmtNum(density, 2);
                _set(s.copyWith(materialId: id, density: density));
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
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
            if (v != null && v > 0.3 && v < 5) _set(s.copyWith(density: v));
          },
        ),
        const SizedBox(height: 16),
        Text('Діаметр філаменту', style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 8),
        SegmentedButton<double>(
          segments: const [
            ButtonSegment(value: 1.75, label: Text('1,75 мм')),
            ButtonSegment(value: 2.85, label: Text('2,85 мм')),
          ],
          selected: {s.filamentDiameter == 2.85 ? 2.85 : 1.75},
          onSelectionChanged: (v) => _set(s.copyWith(filamentDiameter: v.first)),
        ),
        const SizedBox(height: 20),
        Text(
          'Розрахунок не враховує кайму (brim), спідницю та очищувальну вежу.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

