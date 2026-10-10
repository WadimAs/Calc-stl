import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stl_weight/i18n/i18n.dart';
import 'package:stl_weight/main.dart' as app;
import 'package:stl_weight/printers/print_hub.dart';
import 'package:stl_weight/printers/printers.dart';
import 'package:stl_weight/platform/files.dart';
import 'package:stl_weight/ui/home_page.dart';

/// Triangles of an axis-aligned box (outward normals).
List<double> _box(double x0, double y0, double z0, double x1, double y1, double z1) {
  final v = [
    [x0, y0, z0], [x1, y0, z0], [x1, y1, z0], [x0, y1, z0], //
    [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1],
  ];
  const faces = [
    [0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3], //
  ];
  final out = <double>[];
  for (final f in faces) {
    for (final t in [
      [f[0], f[1], f[2]],
      [f[0], f[2], f[3]],
    ]) {
      for (final i in t) {
        out.addAll(v[i]);
      }
    }
  }
  return out;
}

/// An L-bracket with an overhanging shelf (needs supports).
Uint8List bracketStl() {
  final tris = [
    ..._box(0, 0, 0, 40, 20, 5),
    ..._box(0, 0, 5, 6, 20, 30),
    ..._box(0, 0, 30, 25, 20, 34),
  ];
  final n = tris.length ~/ 9;
  final bd = ByteData(84 + n * 50);
  bd.setUint32(80, n, Endian.little);
  int o = 84;
  for (int t = 0; t < n; t++) {
    o += 12;
    for (int k = 0; k < 9; k++) {
      bd.setFloat32(o, tris[t * 9 + k], Endian.little);
      o += 4;
    }
    o += 2;
  }
  return bd.buffer.asUint8List();
}

/// A printed spool label rendered as a PNG (for the on-device OCR check).
Future<Uint8List> labelPng() async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawRect(const Rect.fromLTWH(0, 0, 1000, 640), Paint()..color = Colors.white);
  final tp = TextPainter(
    text: const TextSpan(
      text: 'Bambu Lab\nPLA Basic Refill\nJade White\nNet Weight: 1kg',
      style: TextStyle(color: Colors.black, fontSize: 80, fontWeight: FontWeight.bold, height: 1.3),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: 940);
  tp.paint(c, const Offset(30, 40));
  final img = await rec.endRecording().toImage(1000, 640);
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bd!.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final errors = <String>[];

  testWidgets('walk through the app', (tester) async {
    Future<void> settle([int ms = 1200]) async {
      for (int t = 0; t < ms; t += 100) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitFor(Finder f, {int seconds = 20}) async {
      for (int i = 0; i < seconds * 5; i++) {
        if (f.evaluate().isNotEmpty) return;
        await tester.pump(const Duration(milliseconds: 200));
      }
      throw StateError('Не з\'явилось: $f');
    }

    String? screensDir;
    final log = StringBuffer();

    void note(String line) {
      log.writeln(line);
      // ignore: avoid_print
      print('UI_LOG $line');
      final d = screensDir;
      if (d != null) {
        try {
          File('$d/report.txt').writeAsStringSync(log.toString());
        } catch (_) {}
      }
    }

    // Renders the whole Flutter scene (dialogs included) into a PNG file in
    // the app's private storage; the CI script pulls it with adb.
    Future<void> shot(String name) async {
      await settle(500);
      try {
        screensDir ??= '${await PlatformFiles.filesDir()}/screens';
        await Directory(screensDir!).create(recursive: true);
        final view = tester.binding.renderViews.first;
        final layer = view.debugLayer! as OffsetLayer;
        final img = await layer.toImage(view.paintBounds, pixelRatio: 0.5);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        if (data != null) {
          final tmp = File('$screensDir/$name.png.tmp');
          await tmp.writeAsBytes(data.buffer.asUint8List());
          await tmp.rename('$screensDir/$name.png');
        }
        note('shot $name');
      } catch (e) {
        note('shot $name FAILED: $e');
      }
    }

    Future<void> tap(Finder f) async {
      await waitFor(f);
      await tester.ensureVisible(f.first);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(f.first, warnIfMissed: false);
      await settle();
    }

    Future<void> home() async {
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.popUntil((r) => r.isFirst);
      await settle();
    }

    Finder mainScroll() {
      Element? best;
      double area = 0;
      for (final e in find.byType(Scrollable).evaluate()) {
        final w = e.widget as Scrollable;
        if (w.axisDirection != AxisDirection.down) continue;
        final box = e.renderObject;
        if (box is! RenderBox || !box.hasSize) continue;
        final a = box.size.width * box.size.height;
        if (a > area) {
          area = a;
          best = e;
        }
      }
      return best == null ? find.byType(Scrollable).first : find.byElementPredicate((e) => identical(e, best));
    }

    Future<void> scrollTo(Finder f) async {
      await tester.scrollUntilVisible(f, 250, scrollable: mainScroll(), maxScrolls: 40);
      await settle(400);
    }

    Future<void> step(String name, Future<void> Function() body) async {
      note('step $name');
      try {
        await body();
      } catch (e, st) {
        errors.add('$name: $e');
        note('UI_STEP_FAILED $name: $e');
        // ignore: avoid_print
        print(st);
        await shot('ERR_$name');
        try {
          await home();
        } catch (_) {}
      }
    }

    Finder inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

    Future<void> menu(String item) async {
      await tap(find.byIcon(Icons.more_vert));
      await tap(find.text(item));
    }

    debugForceLang = 'uk'; // the emulator is English; the walk-through starts in Ukrainian
    app.main();
    await settle(3000);

    await step('intro', () async {
      await waitFor(find.text('Відкрийте модель'), seconds: 30);
      await shot('01_intro');
      for (int i = 0; i < 3; i++) {
        await tap(find.text('Далі'));
      }
      await shot('02_mode');
      await tap(find.text('Розширений'));
    });

    await step('home_empty', () async {
      await waitFor(find.byTooltip('Відкрити файл'));
      await shot('03_home_empty');
    });

    await step('open_model', () async {
      final open = HomePage.debugOpen;
      if (open == null) throw StateError('debugOpen не встановлено');
      open(PickedFile('bracket.stl', bracketStl()));
      await waitFor(find.text('До замовлення'), seconds: 60);
      await settle(15000); // slicing
      await shot('04_model');
      await scrollTo(find.text('До замовлення'));
      await shot('05_result');
    });

    await step('layers', () async {
      await tap(find.text('Шари'));
      await settle(2000);
      await shot('06_layers');
      await tap(find.text('Модель'));
    });

    await step('settings', () async {
      await tap(find.byTooltip('Налаштування'));
      await settle(1500);
      await shot('07_settings');
      await tester.drag(mainScroll(), const Offset(0, -900));
      await settle();
      await shot('08_settings_more');
      await tester.drag(mainScroll(), const Offset(0, -1500));
      await settle();
      await shot('09_settings_cost');
      await home();
    });

    await step('catalog_add', () async {
      await scrollTo(find.byTooltip('У прайс-лист'));
      await tap(find.byTooltip('У прайс-лист'));
      await shot('10_catalog_dialog');
      await tap(inDialog(find.text('Додати')));
    });

    await step('order', () async {
      await scrollTo(find.text('До замовлення'));
      await tap(find.text('До замовлення'));
      await tap(find.text('Нове замовлення'));
      await waitFor(find.text('Новий клієнт'));
      await shot('11_client_picker');
      await tap(find.text('Новий клієнт'));
      final fields = inDialog(find.byType(TextField));
      await tester.enterText(fields.at(0), 'Оля Тестова');
      await tester.enterText(fields.at(1), '+380501234567');
      await tester.enterText(fields.at(2), '@olya_test');
      await settle(500);
      await shot('12_client_dialog');
      await tap(inDialog(find.text('Зберегти')));
      await settle(1500);
      await shot('12b_after_save');
      await waitFor(find.textContaining('Додано до «Оля'), seconds: 8);
      await tap(find.text('Відкрити'));
      await waitFor(find.text('Термін (нагадаю о 9:00)'), seconds: 8);
      await shot('13_order');
      await tap(find.textContaining('Термін'));
      await waitFor(find.byType(DatePickerDialog));
      await shot('14_date_picker');
      await tap(find.descendant(of: find.byType(DatePickerDialog), matching: find.byType(TextButton)).last);
      await shot('15_order_due');
      await scrollTo(find.text('Надіслати розрахунок клієнту'));
      await shot('15b_order_bottom');
      await tap(find.text('Надіслати розрахунок клієнту'));
      await shot('16_quote');
      await tap(find.text('Рахунок'));
      await shot('17_invoice');
      await home();
    });

    for (final (item, name) in [
      ('Замовлення', '20_orders'),
      ('Клієнти', '21_clients'),
      ('Прайс-лист', '22_catalog'),
      ('Витрати', '23_expenses'),
      ('Котушки', '24_spools'),
      ('Статистика', '25_stats'),
      ('Принтери', '26_printers'),
      ('Історія', '27_history'),
    ]) {
      await step(name, () async {
        await menu(item);
        await settle(1500);
        await shot(name);
        await home();
      });
    }

    await step('snack_hidden', () async {
      await settle(6000);
      if (find.byType(SnackBar).evaluate().isNotEmpty) throw StateError('SnackBar не зникає');
    });

    await step('menu', () async {
      await tap(find.byIcon(Icons.more_vert));
      await shot('28_menu');
      await home();
    });

    await step('client_page', () async {
      await menu('Клієнти');
      await tap(find.text('Оля Тестова'));
      await shot('29_client_page');
      await home();
    });

    await step('expense', () async {
      await menu('Витрати');
      await tap(find.text('Витрата'));
      await tester.enterText(inDialog(find.byType(TextField)).first, '650');
      await settle(400);
      await shot('30_expense_dialog');
      await tap(inDialog(find.text('Зберегти')));
      await shot('31_expenses_list');
      await home();
    });

    await step('spool', () async {
      await menu('Котушки');
      await tap(find.text('Котушка'));
      await shot('32_spool_dialog');
      await home();
    });

    await step('label_ocr', () async {
      PlatformFiles.debugImage = await labelPng();
      await menu('Котушки');
      await tap(find.byTooltip('Додати з фото етикетки'));
      await tap(find.text('Сфотографувати етикетку'));
      await waitFor(find.textContaining('Розпізнано'), seconds: 40);
      await settle(800);
      await shot('32b_label_ocr');
      final t = (find.textContaining('Розпізнано').evaluate().first.widget as Text).data ?? '';
      note('OCR result: $t');
      PlatformFiles.debugImage = null;
      if (!t.contains('PLA') || !t.contains('Bambu') || !t.contains('Refill')) throw StateError('OCR: $t');
      await tap(find.text('Зберегти'));
      await waitFor(find.text('Refill, без котушки'));
      await shot('32c_refill_in_list');
      await tap(find.byType(PopupMenuButton<String>).last);
      await tap(find.text('Встановлено на котушку'));
      await waitFor(find.text('Refill на котушці'));
      await shot('32d_refill_mounted');
      await home();
    });

    await step('print_finished', () async {
      PrinterHub.instance.debugEmit(const FinishedPrint(
        printer: PrinterConn(id: 'test', name: 'A1 mini', kind: PrinterKind.bambu, host: '', serial: 'TEST'),
        key: 'test:1',
        job: 'bracket',
        failed: false,
        lines: [UsageLine(slotKey: '0-0', type: 'PLA', color: 0xFFFFFFFF, grams: 12.5)],
        source: 'test',
      ));
      await waitFor(find.text('Друк завершено'));
      await settle(800);
      await shot('32e_print_finished');
      await tap(find.text('Списати'));
      await waitFor(find.textContaining('Списано'));
      await menu('Котушки');
      await settle(800);
      await shot('32f_spools_after_print');
      await tap(find.byTooltip('Журнал списань'));
      await shot('32g_writeoffs');
      await home();
    });

    await step('printer', () async {
      await menu('Принтери');
      await tap(find.text('Принтер'));
      await shot('33a_printer_kinds');
      await tap(find.text('Bambu Lab у локальній мережі'));
      await shot('33_printer_dialog');
      await tap(find.text('Klipper'));
      await shot('34_printer_klipper');
      await home();
    });

    await step('bambu_cloud_login', () async {
      await menu('Принтери');
      await tap(find.text('Принтер'));
      await tap(find.text('Bambu Lab через інтернет'));
      await waitFor(find.text('Увійти'));
      final fields = inDialog(find.byType(TextField));
      await tester.enterText(fields.at(0), 'stl-vaga-probe@example.com');
      await tester.enterText(fields.at(1), 'wrong-password');
      await settle(300);
      await shot('34a_bambu_login');
      await tap(find.text('Увійти'));
      // A wrong password must give a clear error from the real Bambu server.
      await waitFor(find.textContaining('пароль'), seconds: 30);
      await settle(500);
      await shot('34b_bambu_login_error');
      await home();
    });

    await step('url', () async {
      await menu('Відкрити за посиланням');
      await shot('35_url_dialog');
      await home();
    });

    await step('whats_new', () async {
      await menu('Що нового');
      await waitFor(find.text('Зрозуміло'));
      await shot('36a_whats_new');
      await tap(find.text('Зрозуміло'));
    });

    await step('autobackup', () async {
      await menu('Автокопія (Google Диск)');
      await shot('36_autobackup');
      await home();
    });

    await step('stats_after', () async {
      await menu('Статистика');
      await shot('37_stats_after');
      await home();
    });

    await step('currency', () async {
      await tap(find.byTooltip('Налаштування'));
      await settle(1000);
      await tap(find.text('€ EUR'));
      await waitFor(find.text('Перерахувати'));
      await settle(5000); // NBU rate
      await shot('37b_rate_dialog');
      await tester.enterText(inDialog(find.byType(TextField)), '48');
      await settle(300);
      await tap(inDialog(find.text('Перерахувати')));
      await settle(1500);
      await shot('37c_settings_eur');
      await home();
      await scrollTo(find.text('До замовлення'));
      await shot('37d_home_eur');
      await menu('Замовлення');
      await shot('37e_orders_still_uah');
      await home();
      await tap(find.byTooltip('Налаштування'));
      await settle(1000);
      await tap(find.textContaining('UAH'));
      await settle(1000);
      await home();
    });

    await step('simple_mode', () async {
      await menu('Розширений режим');
      await settle(1500);
      await shot('38_simple_mode');
      await tester.drag(mainScroll(), const Offset(0, -700));
      await settle();
      await shot('39_simple_mode_more');
    });

    // ---- The same app in English ----
    await step('en_switch', () async {
      debugForceLang = 'en';
      applyLang('en');
      await settle(3000);
      await waitFor(find.byTooltip('Open file'));
      await shot('40_en_home_simple');
      await tap(find.byIcon(Icons.more_vert));
      await shot('41_en_menu');
      await tap(find.text('Advanced mode'));
      await settle(1500);
    });

    await step('en_model', () async {
      HomePage.debugOpen!(PickedFile('bracket.stl', bracketStl()));
      await waitFor(find.text('To order'), seconds: 60);
      await settle(12000);
      await shot('42_en_model');
      await scrollTo(find.text('To order'));
      await shot('43_en_result');
      await tester.drag(mainScroll(), const Offset(0, -900));
      await settle();
      await shot('44_en_result_more');
      await home();
    });

    await step('en_settings', () async {
      await tap(find.byTooltip('Settings'));
      await settle(1500);
      await shot('45_en_settings');
      await tester.drag(mainScroll(), const Offset(0, -1200));
      await settle();
      await shot('46_en_settings_more');
      await home();
    });

    await step('en_order', () async {
      await menu('Orders');
      await shot('47_en_orders');
      await tap(find.text('Оля Тестова'));
      await settle(1500);
      await shot('48_en_order');
      await scrollTo(find.text('Send the quote to the client'));
      await shot('49_en_order_bottom');
      await tap(find.text('Send the quote to the client'));
      await tap(find.text('Invoice'));
      await shot('50_en_invoice');
      await home();
    });

    for (final (item, name) in [
      ('Statistics', '51_en_stats'),
      ('Expenses', '52_en_expenses'),
      ('Printers', '53_en_printers'),
      ('Price list', '54_en_catalog'),
    ]) {
      await step(name, () async {
        await menu(item);
        await settle(1500);
        await shot(name);
        await home();
      });
    }

    await step('en_intro', () async {
      await menu('How to use');
      await shot('55_en_intro');
      await home();
    });

    note('UI_ERRORS ${errors.length}: ${errors.join(' | ')}');
    note('DONE');
    await settle(25000); // let the CI script copy the last screenshots
  });
}
