import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/i18n.dart';

/// One release in assets/changelog.json (newest first).
class ChangeEntry {
  final String id;
  final String version;
  final List<String> uk, en;

  const ChangeEntry(this.id, this.version, this.uk, this.en);

  List<String> get items => lang == 'en' && en.isNotEmpty ? en : uk;
}

Future<List<ChangeEntry>> loadChangelog() async {
  try {
    final raw = jsonDecode(await rootBundle.loadString('assets/changelog.json'));
    if (raw is! List) return [];
    List<String> strs(Object? v) => [if (v is List) for (final s in v) if (s is String) s];
    return [
      for (final e in raw)
        if (e is Map && e['id'] is String)
          ChangeEntry(e['id'] as String, '${e['version'] ?? ''}', strs(e['uk']), strs(e['en'])),
    ];
  } catch (_) {
    return [];
  }
}

/// Entries newer than [seenId] (only the newest when nothing was seen yet).
List<ChangeEntry> unseenChanges(List<ChangeEntry> all, String seenId) {
  if (all.isEmpty || all.first.id == seenId) return [];
  if (seenId.isEmpty) return [all.first];
  final out = <ChangeEntry>[];
  for (final e in all) {
    if (e.id == seenId) break;
    out.add(e);
  }
  return out;
}

Future<void> showWhatsNew(BuildContext context, List<ChangeEntry> entries) {
  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        icon: Icon(Icons.auto_awesome, color: theme.colorScheme.primary),
        title: Text(tr('Що нового')),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(shrinkWrap: true, children: [
            for (final (i, e) in entries.indexed) ...[
              if (entries.length > 1 || e.version.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 16, bottom: 6),
                  child: Text(trf('Версія {0}', [e.version]), style: theme.textTheme.titleSmall),
                ),
              for (final item in e.items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 7, right: 10),
                      child: Icon(Icons.circle, size: 6, color: theme.colorScheme.primary),
                    ),
                    Expanded(child: Text(item, style: theme.textTheme.bodyMedium)),
                  ]),
                ),
            ],
          ]),
        ),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Зрозуміло'))),
        ],
      );
    },
  );
}
