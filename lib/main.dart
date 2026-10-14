import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'i18n/i18n.dart';
import 'platform/files.dart';
import 'slicer/settings.dart';
import 'printers/print_hub.dart';
import 'history/history.dart' show formatDuration;
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
    // A print is running: switch to the live watch (allowed when the app
    // may work in the background).
    if (PrinterHub.instance.sawPrinting) await PlatformFiles.startPrintService();
  } catch (_) {
    // offline / printer unreachable: next run
  }
  await PlatformFiles.backgroundDone();
}

/// Foreground service while a print runs: live connection to the printers,
/// progress in the notification shade, "print finished" right away.
@pragma('vm:entry-point')
Future<void> printWatchService() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final s = await PlatformFiles.loadSettings();
    currencyCode = s.currency;
    applyLang(s.language);
  } catch (_) {}
  final hub = PrinterHub.instance..serviceMode = true;
  hub.finished.listen((f) async {
    if (await PlatformFiles.appResumed()) return; // the app asks itself
    if (await hub.notifiedElsewhere(f.key)) return;
    await notifyFinishedPrint(f);
  });
  await hub.start();
  if (!hub.enabled || hub.printers.isEmpty) {
    await PlatformFiles.stopPrintService();
    return;
  }
  final started = DateTime.now();
  var idle = 0;
  var last = '';
  Timer.periodic(const Duration(seconds: 20), (t) async {
    final act = hub.activePrints;
    if (act.isEmpty) {
      idle++;
      // Give the connections time; then a minute without prints → stop.
      if (DateTime.now().difference(started) > const Duration(minutes: 3) && idle >= 4) {
        t.cancel();
        await Future<void>.delayed(const Duration(seconds: 10)); // let the last notification go out
        await PlatformFiles.stopPrintService();
      }
      return;
    }
    idle = 0;
    final text = [
      for (final (p, s) in act)
        [
          if (act.length > 1) p.name.isEmpty ? p.serial : p.name,
          if (s.job.isNotEmpty) s.job,
          if (s.progress != null) '${(s.progress! * 100).round()}%',
          if (s.remaining != null && s.remaining!.inMinutes > 0)
            trf('ще {0}', [formatDuration(s.remaining!.inMinutes / 60)]),
        ].join(' · '),
    ].join('\n');
    final line = trf('Друкується: {0}', [text]);
    if (line != last) {
      last = line;
      await PlatformFiles.printServiceText(line);
    }
  });
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
