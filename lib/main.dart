import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'i18n/i18n.dart';
import 'platform/files.dart';
import 'slicer/settings.dart';
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
        title: tr('STL Вага'),
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
