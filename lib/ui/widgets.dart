import 'package:flutter/material.dart';

String fmtNum(double v, int decimals) => v.toStringAsFixed(decimals).replaceAll('.', ',');

String fmtGrams(double g) {
  if (g >= 1000) return '${fmtNum(g / 1000, 2)} кг';
  if (g >= 100) return '${fmtNum(g, 0)} г';
  return '${fmtNum(g, 1)} г';
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
