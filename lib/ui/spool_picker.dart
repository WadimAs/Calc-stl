import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../slicer/settings.dart';
import '../spools/spools.dart';
import 'spool_icon.dart';
import 'widgets.dart';

/// Spool chooser that shows what is left on each spool right now.
class SpoolDropdown extends StatelessWidget {
  final List<Spool> spools;
  final String? value;
  final ValueChanged<String?> onChanged;

  /// Grams about to be taken: spools with less are marked red.
  final double? need;
  final String? noneLabel;

  const SpoolDropdown({
    super.key,
    required this.spools,
    required this.value,
    required this.onChanged,
    this.need,
    this.noneLabel,
  });

  String _name(Spool s) => '${materialById(s.materialId).name}${s.title.isEmpty ? '' : ' · ${s.title}'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color? short(Spool s) => need != null && s.remainingGrams < need! ? theme.colorScheme.error : null;
    return DropdownButton<String?>(
      isExpanded: true,
      value: spools.any((s) => s.id == value) ? value : null,
      itemHeight: 56,
      selectedItemBuilder: (_) => [
        Align(alignment: Alignment.centerLeft, child: Text(noneLabel ?? tr('Не списувати'))),
        for (final s in spools)
          Row(children: [
            SpoolIcon.of(s, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_name(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  trf('залишилось {0}', [fmtGrams(s.remainingGrams)]),
                  style: theme.textTheme.bodySmall?.copyWith(color: short(s)),
                ),
              ]),
            ),
          ]),
      ],
      items: [
        DropdownMenuItem<String?>(value: null, child: Text(noneLabel ?? tr('Не списувати'))),
        for (final s in spools)
          DropdownMenuItem<String?>(
            value: s.id,
            child: Row(children: [
              SpoolIcon.of(s, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_name(s), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    trf('{0} з {1}', [fmtGrams(s.remainingGrams), fmtGrams(s.totalGrams)]),
                    style: theme.textTheme.bodySmall?.copyWith(color: short(s)),
                  ),
                ]),
              ),
            ]),
          ),
      ],
      onChanged: onChanged,
    );
  }
}
