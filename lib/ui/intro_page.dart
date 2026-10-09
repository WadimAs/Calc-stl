import 'package:flutter/material.dart';
import '../i18n/i18n.dart';

class _Slide {
  final IconData icon;
  final String title;
  final String text;

  const _Slide(this.icon, this.title, this.text);
}

List<_Slide> get _slides => [
  _Slide(
    Icons.view_in_ar_outlined,
    tr('Відкрийте модель'),
    tr('STL, 3MF, G-code або архів .zip — з файлів, Telegram, Viber чи за посиланням. Застосунок по-справжньому нарізає модель і рахує вагу пластику, як слайсер.'),
  ),
  _Slide(
    Icons.payments_outlined,
    tr('Отримайте ціну'),
    tr('Собівартість — пластик, світло, знос принтера — і ціна з вашим заробітком. Якщо файл з Bambu Studio чи Orca, цифри беруться точно з нього.'),
  ),
  _Slide(
    Icons.receipt_long_outlined,
    tr('Ведіть замовлення'),
    tr('Клієнти, терміни з нагадуваннями, рахунок у PDF, котушки зі списанням пластику та статистика заробітку.'),
  ),
];

/// First-run walkthrough; pops with the chosen mode (true = advanced).
class IntroPage extends StatefulWidget {
  const IntroPage({super.key});

  @override
  State<IntroPage> createState() => _IntroPageState();
}

class _IntroPageState extends State<IntroPage> {
  final _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _slides.length; // index of the mode page
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Row(children: [
            const SizedBox(width: 8),
            // Language for the whole app; applied when the intro closes.
            TextButton.icon(
              onPressed: () => setState(() => lang = lang == 'uk' ? 'en' : 'uk'),
              icon: const Icon(Icons.language, size: 18),
              label: Text(lang == 'uk' ? 'English' : 'Українська'),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Пропустити')),
            ),
          ]),
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                for (final s in _slides)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(s.icon, size: 56, color: theme.colorScheme.onPrimaryContainer),
                      ),
                      const SizedBox(height: 32),
                      Text(s.title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      Text(s.text, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
                    ]),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(tr('Який вигляд вам зручніший?'),
                        style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                    const SizedBox(height: 24),
                    _ModeCard(
                      icon: Icons.bolt_outlined,
                      title: tr('Простий'),
                      text: tr('Лише вага, час і ціна. Мінімум налаштувань.'),
                      onTap: () => Navigator.pop(context, false),
                    ),
                    const SizedBox(height: 12),
                    _ModeCard(
                      icon: Icons.tune,
                      title: tr('Розширений'),
                      text: tr('Шари й підтримки, вимірювання, калібрування, котушки, прайс-лист, витрати.'),
                      onTap: () => Navigator.pop(context, true),
                    ),
                    const SizedBox(height: 16),
                    Text(tr('Змінити можна будь-коли в меню ⋮'),
                        style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
                  ]),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(children: [
              for (int i = 0; i <= last; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.only(right: 6),
                  width: i == _page ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _page ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              const Spacer(),
              if (_page < last)
                FilledButton(
                  onPressed: () =>
                      _pages.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut),
                  child: Text(tr('Далі')),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final VoidCallback onTap;

  const _ModeCard({required this.icon, required this.title, required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            Icon(icon, size: 32, color: theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(text, style: theme.textTheme.bodyMedium),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
