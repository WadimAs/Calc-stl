// Slow, human-paced walk through the app for the promo video. The CI script
// records the emulator screen; every clip is marked in the log with device
// time (PROMO_MARK <name> start|end <epoch ms>) so the video can be cut.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stl_weight/i18n/i18n.dart';
import 'package:stl_weight/main.dart' as app;
import 'package:stl_weight/platform/files.dart';
import 'package:stl_weight/platform/updates.dart';
import 'package:stl_weight/printers/print_hub.dart';
import 'package:stl_weight/printers/printers.dart';
import 'package:stl_weight/ui/home_page.dart';
import 'package:stl_weight/viewer/model_viewer.dart';

import 'demo_models.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('promo recording', (tester) async {
    Future<void> settle([int ms = 1200]) async {
      for (int t = 0; t < ms; t += 50) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> waitFor(Finder f, {int seconds = 30}) async {
      for (int i = 0; i < seconds * 20; i++) {
        if (f.evaluate().isNotEmpty) return;
        await tester.pump(const Duration(milliseconds: 50));
      }
      throw StateError('Не з\'явилось: $f');
    }

    void mark(String name, String what) {
      // ignore: avoid_print
      print('PROMO_MARK $name $what ${DateTime.now().millisecondsSinceEpoch}');
    }

    Future<void> clip(String name, Future<void> Function() body) async {
      mark(name, 'start');
      try {
        await body();
        mark(name, 'end');
      } catch (e) {
        mark(name, 'failed');
        // ignore: avoid_print
        print('PROMO_FAILED $name: $e');
        try {
          tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((r) => r.isFirst);
        } catch (_) {}
        await settle(800);
      }
    }

    Future<void> tap(Finder f, {int after = 700}) async {
      await waitFor(f);
      await tester.ensureVisible(f.first);
      await settle(150);
      await tester.tap(f.first, warnIfMissed: false);
      await settle(after);
    }

    Future<void> home() async {
      tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((r) => r.isFirst);
      await settle(800);
    }

    Future<void> menu(String item) async {
      await tap(find.byIcon(Icons.more_vert), after: 500);
      await tap(find.text(item));
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

    /// Smooth scroll (visible in the recording, unlike a jump).
    Future<void> glide(double dy, {int ms = 900}) async {
      await tester.timedDrag(mainScroll(), Offset(0, dy), Duration(milliseconds: ms));
      await settle(500);
    }

    Future<void> glideTo(Finder f) async {
      for (int i = 0; i < 20 && f.evaluate().isEmpty; i++) {
        await glide(-350, ms: 500);
      }
      await tester.ensureVisible(f.first);
      await settle(500);
    }

    Finder inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

    Updates.disabled = true;
    debugForceLang = 'uk';
    app.main();
    await settle(3000);

    // Setup (not recorded as a clip).
    await waitFor(find.text('Відкрийте модель'), seconds: 40);
    for (int i = 0; i < 3; i++) {
      await tap(find.text('Далі'), after: 400);
    }
    await tap(find.text('Розширений'));
    await waitFor(find.byTooltip('Відкрити файл'));
    await settle(1500);

    await clip('open', () async {
      await settle(600);
      HomePage.debugOpen!(PickedFile('gear.stl', gearStl()));
      await waitFor(find.text('Підігнати під слайсер'), seconds: 60);
      await settle(2000);
    });

    await clip('rotate', () async {
      final v = find.byType(ModelViewer);
      await waitFor(v);
      final c = tester.getCenter(v);
      await tester.timedDragFrom(c + const Offset(-150, 0), const Offset(320, 40), const Duration(milliseconds: 1800));
      await settle(300);
      await tester.timedDragFrom(c + const Offset(100, 60), const Offset(-200, -160), const Duration(milliseconds: 1500));
      await settle(300);
      // Two-finger zoom in.
      final g1 = await tester.startGesture(c + const Offset(-40, 0));
      final g2 = await tester.startGesture(c + const Offset(40, 0), pointer: 7);
      for (int i = 0; i < 20; i++) {
        await g1.moveBy(const Offset(-5, 0));
        await g2.moveBy(const Offset(5, 0));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await g1.up();
      await g2.up();
      await settle(1000);
    });

    await clip('holes', () async {
      await tap(find.byTooltip('Вимірювання'));
      await tap(find.text('Отвори'), after: 300);
      await settle(2500);
    });

    await clip('infill', () async {
      if (find.byTooltip('Закрити вимірювання').evaluate().isNotEmpty) {
        await tap(find.byTooltip('Закрити вимірювання'), after: 300);
      }
      final slider = find.byType(Slider);
      await glideTo(slider);
      final s = tester.getRect(slider.first);
      final from = Offset(s.left + s.width * 0.15, s.center.dy);
      final g = await tester.startGesture(from);
      for (int i = 0; i < 40; i++) {
        await g.moveBy(Offset(s.width * 0.6 / 40, 0));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await g.up();
      await settle(1500);
      await glide(700, ms: 1000);
      await settle(1500);
    });

    await clip('supports', () async {
      HomePage.debugOpen!(PickedFile('bracket.stl', bracketStl()));
      await waitFor(find.text('Підігнати під слайсер'), seconds: 60);
      await settle(800);
      final sw = find.widgetWithText(SwitchListTile, 'Підтримки');
      await glideTo(sw);
      await tap(sw, after: 600);
      await tap(find.text('Деревоподібні'), after: 600);
      await waitFor(find.text('Підігнати під слайсер'), seconds: 60);
      await settle(1500);
    });

    await clip('layers', () async {
      await tester.dragUntilVisible(find.text('Шари'), mainScroll(), const Offset(0, 400), maxIteration: 10);
      await settle(400);
      await tap(find.text('Шари'), after: 1200);
      final sl = find.byType(Slider).first;
      await waitFor(sl);
      final r = tester.getRect(sl);
      final g = await tester.startGesture(Offset(r.left + 12, r.center.dy));
      for (int i = 0; i < 50; i++) {
        await g.moveBy(Offset((r.width - 24) / 50, 0));
        await tester.pump(const Duration(milliseconds: 70));
      }
      await g.up();
      await settle(1200);
      await tap(find.text('Модель'), after: 400);
    });

    await clip('order', () async {
      await glideTo(find.text('До замовлення'));
      await tap(find.text('До замовлення'));
      await tap(find.text('Нове замовлення'));
      await tap(find.text('Новий клієнт'));
      final fields = inDialog(find.byType(TextField));
      await tester.enterText(fields.at(0), 'Оля Тестова');
      await settle(300);
      await tester.enterText(fields.at(1), '+380501234567');
      await settle(400);
      await tap(inDialog(find.text('Зберегти')), after: 1200);
      await tap(find.text('Відкрити'), after: 1200);
      await glide(-500);
      await settle(600);
    });

    await clip('pdf', () async {
      await glideTo(find.text('Надіслати розрахунок клієнту'));
      await tap(find.text('Надіслати розрахунок клієнту'), after: 1500);
      await tap(find.text('Рахунок'), after: 1500);
      await glide(-400, ms: 1200);
      await settle(800);
      await home();
    });

    await clip('ocr', () async {
      PlatformFiles.debugImage = await labelPng();
      await menu('Котушки');
      await tap(find.byTooltip('Додати з фото етикетки'));
      await tap(find.text('Сфотографувати етикетку'));
      await waitFor(find.textContaining('Розпізнано'), seconds: 40);
      await settle(2200);
      PlatformFiles.debugImage = null;
      await tap(find.text('Зберегти'), after: 1800);
    });

    await clip('print', () async {
      await home();
      PrinterHub.instance.debugEmit(const FinishedPrint(
        printer: PrinterConn(id: 'p', name: 'A1 mini', kind: PrinterKind.bambu, host: '', serial: 'DEMO'),
        key: 'p:1',
        job: 'gear',
        failed: false,
        lines: [UsageLine(slotKey: '0-0', type: 'PLA', color: 0xFFFFFFFF, grams: 12.5)],
        source: 'demo',
      ));
      await waitFor(find.text('Друк завершено'));
      await settle(2200);
      await tap(find.text('Списати'), after: 1200);
      await menu('Котушки');
      await settle(1800);
      await home();
    });

    await clip('printers', () async {
      await menu('Принтери');
      await tap(find.text('Принтер'), after: 1800);
      await home();
    });

    await clip('lang', () async {
      await settle(800);
      debugForceLang = 'en';
      applyLang('en');
      await settle(2500);
      await tap(find.byIcon(Icons.more_vert), after: 1500);
      await home();
    });

    // ignore: avoid_print
    print('PROMO_DONE');
    await settle(3000);
  });
}
