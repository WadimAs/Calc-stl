import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stl_weight/main.dart' as app;
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

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
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

    bool converted = false;
    Future<void> shot(String name) async {
      if (!converted) {
        await binding.convertFlutterSurfaceToImage();
        converted = true;
      }
      await settle(500);
      await binding.takeScreenshot(name);
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
      try {
        await body();
      } catch (e, st) {
        errors.add('$name: $e');
        // ignore: avoid_print
        print('UI_STEP_FAILED $name: $e\n$st');
        try {
          await binding.takeScreenshot('ERR_$name');
        } catch (_) {}
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
      await tap(find.text('Відкрити'));
      await waitFor(find.text('Надіслати розрахунок клієнту'));
      await shot('13_order');
      await tap(find.textContaining('Термін'));
      await waitFor(find.byType(DatePickerDialog));
      await shot('14_date_picker');
      await tap(find.text('OK'));
      await shot('15_order_due');
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

    await step('printer', () async {
      await menu('Принтери');
      await tap(find.text('Принтер'));
      await shot('33_printer_dialog');
      await tap(find.text('Klipper'));
      await shot('34_printer_klipper');
      await home();
    });

    await step('url', () async {
      await menu('Відкрити за посиланням');
      await shot('35_url_dialog');
      await home();
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

    await step('simple_mode', () async {
      await menu('Розширений режим');
      await settle(1500);
      await shot('38_simple_mode');
      await tester.drag(mainScroll(), const Offset(0, -700));
      await settle();
      await shot('39_simple_mode_more');
    });

    binding.reportData = {'errors': errors};
    // ignore: avoid_print
    print('UI_ERRORS ${errors.length}: ${errors.join(' | ')}');
  });
}
