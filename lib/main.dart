import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'i18n/i18n.dart';
import 'platform/files.dart';
import 'slicer/settings.dart';
import 'printers/print_hub.dart';
import 'ui/finished_print_dialog.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final s = await PlatformFiles.loadSettings();
    currencyCode = s.currency;
    applyLang(s.language);
  } catch (_) {
    applyLang('auto');
  }
  runApp(const StlWeightApp());
}

/// Android background job (every ~15 min, app closed): checks the printers
/// and posts a notification for every finished print not answered yet.
@pragma('vm:entry-point')
Future<void> backgroundCheck() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final s = await PlatformFiles.loadSettings();
    applyLang(s.language);
    final found = await PrinterHub.instance.checkInBackground().timeout(const Duration(seconds: 50));
    for (final f in found) {
      await notifyFinishedPrint(f);
    }
  } catch (_) {
    // offline / printer unreachable: next run
  }
  await PlatformFiles.backgroundDone();
}

class StlWeightApp extends StatelessWidget {
  const StlWeightApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFFF7A2F);
    return ValueListenableBuilder<String>(
      valueListenable: langNotifier,
      // A new key rebuilds every screen in the new language.
      builder: (context, l, _) => MaterialApp(
        key: ValueKey(l),
        title: tr('Котушка'),
        debugShowCheckedModeBanner: false,
        locale: Locale(l),
        supportedLocales: const [Locale('uk'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}
