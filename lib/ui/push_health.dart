import 'package:flutter/material.dart';

import '../data/json_store.dart';
import '../i18n/i18n.dart';
import '../platform/files.dart';

/// Phones that kill background apps unless the user allows autostart.
bool _strictMaker(String m) => const ['xiaomi', 'redmi', 'poco', 'huawei', 'honor', 'oppo', 'vivo', 'realme', 'oneplus', 'meizu', 'tecno', 'infinix']
    .contains(m.toLowerCase());

/// Shows what may block "print finished" notifications and how to fix it.
class PushHealthCard extends StatefulWidget {
  const PushHealthCard({super.key});

  @override
  State<PushHealthCard> createState() => _PushHealthCardState();
}

class _PushHealthCardState extends State<PushHealthCard> with WidgetsBindingObserver {
  ({bool notifications, bool battery, String maker})? _s;
  bool _hintSeen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check(); // back from the system settings
  }

  Future<void> _check() async {
    final s = await PlatformFiles.pushStatus();
    final h = await JsonStore.read('pushhint.json');
    if (mounted) {
      setState(() {
        _s = s;
        _hintSeen = h is Map && h['seen'] == true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) return const SizedBox.shrink();
    final strict = _strictMaker(s.maker) && (!_hintSeen || !s.battery || !s.notifications);
    if (s.notifications && s.battery && !strict) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final bad = !s.notifications || !s.battery;
    return Card(
      color: bad ? cs.errorContainer : cs.surfaceContainerHighest,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(bad ? Icons.notifications_off_outlined : Icons.notifications_active_outlined,
                color: bad ? cs.onErrorContainer : cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(bad ? tr('Сповіщення про друк можуть не приходити') : tr('Щоб сповіщення приходили вчасно'),
                  style: theme.textTheme.titleSmall?.copyWith(color: bad ? cs.onErrorContainer : null)),
            ),
          ]),
          if (!s.notifications) ...[
            const SizedBox(height: 6),
            Text(tr('Сповіщення застосунку вимкнені в налаштуваннях телефону.'),
                style: TextStyle(color: cs.onErrorContainer)),
            TextButton.icon(
              onPressed: PlatformFiles.openNotificationSettings,
              icon: const Icon(Icons.notifications_outlined),
              label: Text(tr('Увімкнути сповіщення')),
            ),
          ],
          if (!s.battery) ...[
            const SizedBox(height: 6),
            Text(
              tr('Android обмежує застосунок у фоні, тому перевірки принтера відкладаються на години. Дозвольте роботу без обмежень батареї.'),
              style: TextStyle(color: cs.onErrorContainer),
            ),
            TextButton.icon(
              onPressed: PlatformFiles.requestBatteryExemption,
              icon: const Icon(Icons.battery_charging_full_outlined),
              label: Text(tr('Дозволити роботу у фоні')),
            ),
          ],
          if (strict) ...[
            const SizedBox(height: 6),
            Text(
              trf('На телефонах {0} також увімкніть «Автозапуск» і в «Контролі активності» / «Батареї» виберіть «Без обмежень» для «Котушки».',
                  [s.maker]),
              style: TextStyle(color: bad ? cs.onErrorContainer : null),
            ),
            TextButton.icon(
              onPressed: PlatformFiles.openAppSettings,
              icon: const Icon(Icons.settings_outlined),
              label: Text(tr('Налаштування застосунку')),
            ),
            if (!bad)
              TextButton(
                onPressed: () async {
                  await JsonStore.write('pushhint.json', {'seen': true, 'asked': true});
                  if (mounted) setState(() => _hintSeen = true);
                },
                child: Text(tr('Зроблено')),
              ),
          ],
        ]),
      ),
    );
  }
}
