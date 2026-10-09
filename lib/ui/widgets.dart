import 'dart:async';

import 'package:flutter/material.dart';

String fmtNum(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');

String fmtGrams(double g) {
  if (g >= 1000) return '${fmtNum(g / 1000, 2)} кг';
  if (g >= 100) return '${fmtNum(g, 0)} г';
  return '${fmtNum(g, 1)} г';
}

String fmtMoney(double v) {
  final whole = v.abs() >= 1000;
  final txt = v.toStringAsFixed(whole ? 0 : 2);
  // Thousands separator (thin space) for readability.
  final parts = txt.split('.');
  final digits = parts[0];
  final b = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0 && digits[i - 1] != '-') b.write('\u202F');
    b.write(digits[i]);
  }
  if (parts.length > 1) b.write(',${parts[1]}');
  return '$b грн';
}

/// Bambu-style "back to default" icon: shown only when the value differs.
class ResetButton extends StatelessWidget {
  final bool changed;
  final VoidCallback onReset;

  const ResetButton({super.key, required this.changed, required this.onReset});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: changed
          ? IconButton(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tooltip: 'Повернути значення за замовчуванням',
              onPressed: onReset,
              icon: Icon(Icons.undo, size: 20, color: Theme.of(context).colorScheme.primary),
            )
          : null,
    );
  }
}

/// "label  [-] value [+]" row used for integer and decimal settings.
class StepperRow extends StatelessWidget {
  final String label;
  final String? hint;
  final double value;
  final double min;
  final double max;
  final double step;
  final int decimals;
  final String unit;
  final ValueChanged<double> onChanged;

  /// When set, a reset icon appears while [value] differs from it.
  final double? defaultValue;

  const StepperRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.decimals = 0,
    this.unit = '',
    this.hint,
    this.defaultValue,
  });

  double _round(double v) {
    final f = decimals <= 0 ? 1.0 : (decimals == 1 ? 10.0 : (decimals == 2 ? 100.0 : 1000.0));
    return (v * f).round() / f;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodyLarge),
                if (hint != null)
                  Text(hint!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (defaultValue != null)
            ResetButton(
              changed: (value - defaultValue!).abs() > 1e-9,
              onReset: () => onChanged(defaultValue!),
            ),
          IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            onPressed: value - step >= min - 1e-9 ? () => onChanged(_round(value - step)) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 76,
            child: Text(
              '${fmtNum(value, decimals)}$unit',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ),
          IconButton.filledTonal(
            visualDensity: VisualDensity.compact,
            onPressed: value + step <= max + 1e-9 ? () => onChanged(_round(value + step)) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

class Stat extends StatelessWidget {
  final String label;
  final String value;

  const Stat(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(value, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }
}

/// Numeric text field that reports valid values as they are typed and picks up
/// external changes of [value].
class NumberField extends StatefulWidget {
  final String label;
  final String? helper;
  final String? suffix;
  final double value;
  final ValueChanged<double> onChanged;
  final double? defaultValue;

  const NumberField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.suffix,
    this.defaultValue,
  });

  @override
  State<NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<NumberField> {
  late final TextEditingController _c = TextEditingController(text: _fmt(widget.value));

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : fmtNum(v, 2);

  static double? _parse(String t) => double.tryParse(t.replaceAll(',', '.').replaceAll(' ', '').trim());

  @override
  void didUpdateWidget(covariant NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final cur = _parse(_c.text);
    if (cur != null && (cur - widget.value).abs() > 1e-9) _c.text = _fmt(widget.value);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helper,
        suffixText: widget.suffix,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: widget.defaultValue != null && (widget.value - widget.defaultValue!).abs() > 1e-9
            ? IconButton(
                tooltip: 'Повернути значення за замовчуванням',
                icon: Icon(Icons.undo, size: 20, color: Theme.of(context).colorScheme.primary),
                onPressed: () {
                  _c.text = _fmt(widget.defaultValue!);
                  widget.onChanged(widget.defaultValue!);
                },
              )
            : null,
      ),
      onChanged: (t) {
        final v = _parse(t);
        if (v != null && v >= 0) widget.onChanged(v);
      },
    );
  }
}


/// Shows a snack bar that also closes by itself when it has an action
/// (newer Flutter keeps such snack bars until tapped).
void showTimedSnack(BuildContext context, SnackBar bar, {Duration after = const Duration(seconds: 5)}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  final c = m.showSnackBar(bar);
  var done = false;
  c.closed.then((_) => done = true);
  Timer(after, () {
    if (!done) {
      try {
        c.close();
      } catch (_) {}
    }
  });
}
