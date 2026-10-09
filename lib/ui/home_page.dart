import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../backup/backup.dart';
import '../catalog/catalog.dart';
import '../data/json_store.dart';
import '../data/records.dart';
import '../history/history.dart';
import '../mesh/loader.dart';
import '../mesh/mesh_check.dart';
import '../mesh/slicer_project.dart';
import '../mesh/transform.dart';
import '../orders/orders.dart';
import '../orders/reminders.dart';
import '../platform/downloader.dart';
import '../platform/files.dart';
import '../platform/updates.dart';
import '../slicer/settings.dart';
import '../slicer/slice_runner.dart';
import '../slicer/slicer.dart';
import '../viewer/measure.dart';
import '../viewer/model_viewer.dart';
import 'catalog_page.dart';
import 'clients_page.dart';
import 'expenses_page.dart';
import 'history_page.dart';
import 'intro_page.dart';
import 'orders_page.dart';
import 'quote_page.dart';
import 'settings_sheet.dart';
import 'spools_page.dart';
import 'stats_page.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _modelColor = Color(0xFFFF8A3D);
  static const _layerChoices = [0.08, 0.12, 0.16, 0.20, 0.24, 0.28];

  SliceSettings _settings = const SliceSettings();
  LoadedModel? _model;
  bool _loading = false;
  String? _loadError;

  SliceJob? _job;
  SliceResult? _result;
  double? _progress;
  String? _sliceError;
  Timer? _debounce;
  bool _saving = false;
  final GlobalKey _viewerKey = GlobalKey();
  bool _layersView = false;
  int _layer = 0;
  double? _manualHours; // print time of one copy entered by the user
  UpdateInfo? _update;
  bool _autoCalibrated = false;
  final MeasureController _measure = MeasureController();

  MeshReport? _report;
  List<double>? _objectVolumes; // per printed object, mm³
  bool _orientOpen = false;
  bool _pickFace = false;
  bool _reorienting = false;
  final Map<int, int> _objectColors = {}; // source object index -> filament slot

  bool get _adv => _settings.advancedUi;

  @override
  void initState() {
    super.initState();
    PlatformFiles.listen(_open, onLink: _openUrl);
    AutoBackup.settingsSource = () => _settings;
    onJsonWrite = (name) {
      if (name != 'autobackup.json') AutoBackup.schedule();
    };
    _init();
  }

  Future<void> _init() async {
    final s = await PlatformFiles.loadSettings();
    if (!mounted) return;
    setState(() => _settings = s);
    Updates.check().then((u) {
      if (u != null && mounted) setState(() => _update = u);
    });
    OrderReminders.rescheduleAll();
    if (!s.seenIntro && mounted) {
      final adv = await Navigator.of(context).push<bool>(
        MaterialPageRoute(fullscreenDialog: true, builder: (_) => const IntroPage()),
      );
      if (!mounted) return;
      _updateSettings(_settings.copyWith(seenIntro: true, advancedUi: adv ?? _settings.advancedUi));
    }
    final f = await PlatformFiles.initialFile();
    if (f != null && mounted) {
      await _open(f);
      return;
    }
    final link = await PlatformFiles.initialLink();
    if (link != null && mounted) await _openUrl(link);
  }

  // ---- Open by link / archives ----

  Future<void> _askUrl() async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Відкрити за посиланням'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: c,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Посилання', hintText: 'https://…'),
            onSubmitted: (_) => Navigator.pop(ctx, c.text.trim()),
          ),
          const SizedBox(height: 8),
          Text(
            'Пряме посилання на .stl / .3mf / .zip або сторінка Thingiverse. '
            'З MakerWorld і Printables завантажте файл у браузері й поділіться ним із застосунком.',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Відкрити')),
        ],
      ),
    );
    if (url != null && url.isNotEmpty) await _openUrl(url);
  }

  Future<void> _openUrl(String text) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final f = await download(resolveModelUrl(text));
      if (!mounted) return;
      await _open(f);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Не вдалося завантажити:\n$e';
      });
    }
  }

  /// A .zip with models: pick which one to open.
  Future<PickedFile?> _chooseFromArchive(PickedFile f) async {
    final models = await Isolate.run(() => modelsInZip(f.bytes));
    if (!mounted) return null;
    if (models.isEmpty) throw const FormatException('В архіві немає STL, 3MF чи G-code');
    if (models.length == 1) return models.first;
    return showModalBottomSheet<PickedFile>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('В архіві ${models.length} моделей', style: Theme.of(ctx).textTheme.titleMedium),
          ),
          for (final m in models)
            ListTile(
              leading: const Icon(Icons.view_in_ar_outlined),
              title: Text(m.name),
              subtitle: Text('${(m.bytes.length / 1024).toStringAsFixed(0)} КБ'),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _job?.cancel();
    _measure.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    try {
      final f = await PlatformFiles.pick();
      if (f != null) await _open(f);
    } catch (e) {
      _snack('Не вдалося відкрити файл: $e');
    }
  }

  Future<void> _open(PickedFile f) async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      if (isArchive(f)) {
        final inner = await _chooseFromArchive(f);
        if (inner == null) {
          if (mounted) setState(() => _loading = false);
          return;
        }
        f = inner;
      }
      final m = await loadModel(f.name, f.bytes);
      if (!mounted) return;
      _setModel(m, fresh: true);
      await _offerFileSettings(m);
      if (!mounted || !identical(_model, m)) return;
      _slice();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = isSupportedFile(f.name) || isArchive(f)
            ? 'Не вдалося прочитати «${f.name}»:\n$e'
            : 'Файл «${f.name}» не схожий на STL, 3MF чи G-code.';
      });
    }
  }

  /// Shows [m]; [fresh] = a newly opened file (not a re-orientation).
  void _setModel(LoadedModel m, {required bool fresh}) {
    _job?.cancel();
    _job = null;
    setState(() {
      _model = m;
      _loading = false;
      _result = null;
      _progress = null;
      _sliceError = null;
      _objectVolumes = null;
      _layersView = false;
      _pickFace = false;
      if (fresh) {
        _objectColors.clear();
        _manualHours = null;
        _autoCalibrated = false;
        _orientOpen = false;
        _report = null;
      }
      _measure.attachModel(m.mesh.tris, inverted: !m.outwardNormals);
    });
    if (m.hasMesh) _checkMesh(m);
  }

  Future<void> _checkMesh(LoadedModel m) async {
    final tris = m.mesh.tris;
    try {
      final r = await Isolate.run(() => checkMesh(tris));
      if (mounted && identical(_model, m)) setState(() => _report = r);
    } catch (_) {}
  }

  /// Same file, new orientation / object selection.
  Future<void> _derive({Mat3? rotation, List<bool>? enabled}) async {
    final m = _model;
    if (m == null || !m.hasMesh || _reorienting) return;
    setState(() => _reorienting = true);
    try {
      final next = await deriveModel(m, rotation: rotation, enabled: enabled);
      if (!mounted || !identical(_model, m)) return;
      _setModel(next, fresh: false);
      _slice();
    } catch (e) {
      _snack('Не вдалося: $e');
    } finally {
      if (mounted) setState(() => _reorienting = false);
    }
  }

  void _rotate(int axis) {
    final m = _model;
    if (m == null) return;
    _derive(rotation: mul3(rot90(axis), m.rotation));
  }

  Future<void> _autoOrient() async {
    final m = _model;
    if (m == null || !m.hasMesh) return;
    final tris = m.mesh.tris;
    final outward = m.outwardNormals;
    setState(() => _reorienting = true);
    final r = await Isolate.run(() => autoOrient(tris, outward: outward));
    if (!mounted) return;
    setState(() => _reorienting = false);
    if (isIdentity(r)) {
      _snack('Модель уже лежить найбільшою гранню вниз');
      return;
    }
    _derive(rotation: mul3(r, m.rotation));
  }

  void _layFlat(double nx, double ny, double nz) {
    final m = _model;
    if (m == null) return;
    setState(() => _pickFace = false);
    _derive(rotation: mul3(rotateToDown(nx, ny, nz), m.rotation));
  }

  Future<void> _computeObjectVolumes(SliceResult r) async {
    final m = _model;
    if (m == null || m.mesh.objects.length < 2 || m.mesh.objects.length > 40) return;
    final s = _settings;
    try {
      final v = await sliceObjectVolumes(m.mesh.tris, m.mesh.objects, s);
      if (mounted && identical(_model, m) && identical(_result, r)) setState(() => _objectVolumes = v);
    } catch (_) {}
  }

  // ---- Menu actions ----

  void _openOrders() =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrdersPage(settings: _settings)));

  void _openSpools() => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => SpoolsPage(onUsePrice: (materialId, perKg) {
          final m = Map<String, double>.from(_settings.pricesPerKg)..[materialId] = perKg;
          _updateSettings(_settings.copyWith(pricesPerKg: m));
        }),
      ));

  void _push(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Future<void> _autoBackupMenu() async {
    final uri = await AutoBackup.target();
    if (!mounted) return;
    final last = AutoBackup.lastOk;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Автоматична копія'),
        content: Text(uri == null
            ? 'Виберіть файл на Google Диску (або в іншій папці) — застосунок сам оновлюватиме в ньому '
                'копію всіх даних після кожної зміни. Якщо телефон загубиться, дані можна відновити з цього файлу.'
            : 'Увімкнено.${last != null ? '\nОстання копія: ${formatDate(last)}' : ''}'
                '${AutoBackup.lastFailed ? '\nОстання спроба не вдалася — можливо, немає доступу до файлу.' : ''}'),
        actions: [
          if (uri != null) TextButton(onPressed: () => Navigator.pop(ctx, 'off'), child: const Text('Вимкнути')),
          if (uri != null) TextButton(onPressed: () => Navigator.pop(ctx, 'now'), child: const Text('Зараз')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'pick'),
            child: Text(uri == null ? 'Вибрати файл' : 'Інший файл'),
          ),
        ],
      ),
    );
    switch (action) {
      case 'pick':
        final ok = await AutoBackup.setup();
        _snack(ok ? 'Автокопію увімкнено' : 'Не вдалося записати у вибраний файл');
      case 'now':
        final ok = await AutoBackup.runNow();
        _snack(ok ? 'Копію оновлено' : 'Не вдалося записати копію');
      case 'off':
        await AutoBackup.disable();
        _snack('Автокопію вимкнено');
    }
  }

  void _openStats() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const StatsPage()));

  Future<void> _exportBackup() async {
    try {
      final bytes = await Backup.export(_settings);
      final d = DateTime.now();
      final name = 'stl-vaga-backup-${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}.json';
      final ok = await PlatformFiles.saveFile(name, 'application/json', bytes);
      if (ok) _snack('Резервну копію збережено');
    } catch (e) {
      _snack('Не вдалося зберегти: $e');
    }
  }

  Future<void> _importBackup() async {
    try {
      final f = await PlatformFiles.pick();
      if (f == null || !mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Відновити з копії?'),
          content: Text('Налаштування, історія, замовлення й котушки буде замінено вмістом «${f.name}».'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Скасувати')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Відновити')),
          ],
        ),
      );
      if (ok != true) return;
      final s = await Backup.restore(f.bytes);
      if (!mounted) return;
      _updateSettings(s);
      _snack('Дані відновлено');
    } catch (e) {
      _snack('Не вдалося відновити: $e');
    }
  }

  void _onMenu(String v) {
    switch (v) {
      case 'history':
        _openHistory();
      case 'orders':
        _openOrders();
      case 'spools':
        _openSpools();
      case 'stats':
        _openStats();
      case 'export':
        _exportBackup();
      case 'import':
        _importBackup();
      case 'url':
        _askUrl();
      case 'clients':
        _push(const ClientsPage());
      case 'catalog':
        _push(const CatalogPage());
      case 'expenses':
        _push(const ExpensesPage());
      case 'autobackup':
        _autoBackupMenu();
      case 'intro':
        Navigator.of(context)
            .push<bool>(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const IntroPage()))
            .then((adv) {
          if (adv != null && adv != _adv) _updateSettings(_settings.copyWith(advancedUi: adv));
        });
      case 'mode':
        _updateSettings(_settings.copyWith(advancedUi: !_adv));
        if (_adv) {
          _measure.tool = MeasureTool.none;
          setState(() => _layersView = false);
        }
        _snack(_adv ? 'Розширений режим' : 'Простий режим');
    }
  }

  // ---- Orders ----

  OrderItem? _orderItem({String? thumbPath, String? id}) {
    final m = _model;
    final fig = _figures();
    if (m == null || fig == null) return null;
    final s = _settings;
    final copies = s.copies;
    final mat = materialById(s.materialId);
    // Per piece, without the quantity discount and per-order extras.
    final c = CostBreakdown.of(fig.gramsTotal / copies, fig.hours / copies, s, orderExtras: false);
    return OrderItem(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      name: m.name,
      material: mat.id == 'custom' ? 'Свій (${fmtNum(s.density, 2)} г/см³)' : mat.name,
      materialId: s.materialId,
      qty: copies,
      gramsEach: fig.gramsTotal / copies,
      hoursEach: fig.hours / copies,
      costEach: c.costPrice,
      priceEach: c.costPrice + c.profit,
      thumbPath: thumbPath,
      source: fig.source ?? '',
    );
  }

  Future<void> _addToOrder() async {
    if (_orderItem() == null) return;
    final orders = (await OrderStore.load()).where((o) => !o.status.printed).toList();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: const Text('Нове замовлення'),
            onTap: () => Navigator.pop(ctx, 'new'),
          ),
          for (final o in orders)
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text(o.title),
              subtitle: Text('${o.items.length} поз. · ${fmtMoney(o.totals.total)}'),
              onTap: () => Navigator.pop(ctx, o),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    Order order;
    if (picked is Order) {
      order = picked;
    } else {
      final client = await pickClient(context);
      if (client == null) return;
      order = Order.create(_settings, client: client.name);
      if (client.id.isNotEmpty) {
        order.clientId = client.id;
        order.contact = client.phone.isNotEmpty ? client.phone : client.telegram;
      }
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final png = await _captureThumb();
    final thumb = png == null ? null : await HistoryStore.saveThumb('o$id', png);
    final item = _orderItem(thumbPath: thumb, id: id);
    if (item == null) return;
    order.items.add(item);
    await OrderStore.upsert(order);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Додано до «${order.title}»'),
      action: SnackBarAction(
        label: 'Відкрити',
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => OrderPage(orderId: order.id))),
      ),
    ));
  }

  Future<void> _addToCatalog() async {
    final m = _model;
    final base = _orderItem();
    if (m == null || base == null) return;
    final copies = _settings.copies;
    final (_, rounding) = finishPriceRaw(base.priceEach, 0, _settings.roundTo);
    final suggested = base.priceEach + rounding;
    final name = TextEditingController(text: m.name.replaceAll(RegExp(r'\.(stl|3mf|gcode)$', caseSensitive: false), ''));
    final price = TextEditingController(text: fmtNum(suggested, suggested == suggested.roundToDouble() ? 0 : 2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('У прайс-лист'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Назва виробу')),
          TextField(
            controller: price,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Ціна за штуку, $currency',
              helperText: 'собівартість ${fmtMoney(base.costEach)}${copies > 1 ? ' (з $copies шт на столі)' : ''}',
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Додати')),
        ],
      ),
    );
    if (ok != true) return;
    final id = newId();
    final png = await _captureThumb();
    final thumb = png == null ? null : await HistoryStore.saveThumb('p$id', png);
    await productStore.upsert(Product(
      id: id,
      name: name.text.trim().isEmpty ? m.name : name.text.trim(),
      material: base.material,
      materialId: base.materialId,
      grams: base.gramsEach,
      hours: base.hoursEach,
      cost: base.costEach,
      price: double.tryParse(price.text.replaceAll(',', '.').replaceAll(' ', '')) ?? suggested,
      thumbPath: thumb,
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: const Text('Додано до прайс-листа'),
      action: SnackBarAction(label: 'Відкрити', onPressed: () => _push(const CatalogPage())),
    ));
  }

  Future<void> _shareChoice() async {
    final how = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Картинкою для клієнта'),
            onTap: () => Navigator.pop(ctx, 'image'),
          ),
          ListTile(
            leading: const Icon(Icons.text_snippet_outlined),
            title: const Text('Текстом'),
            onTap: () => Navigator.pop(ctx, 'text'),
          ),
        ]),
      ),
    );
    if (how == 'text') {
      _share();
    } else if (how == 'image') {
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final png = await _captureThumb();
      final thumb = png == null ? null : await HistoryStore.saveThumb('q$id', png);
      final item = _orderItem(thumbPath: thumb, id: id);
      if (item == null || !mounted) return;
      final o = Order.create(_settings)..items.add(item);
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => QuotePage(order: o)));
    }
  }

  void _updateSettings(SliceSettings s) {
    final geometryChanged = s.geometryKey != _settings.geometryKey;
    setState(() => _settings = s);
    PlatformFiles.saveSettings(s);
    if (geometryChanged && _model != null) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _slice);
    }
  }

  /// Offers (or auto-applies) the print settings stored in a 3MF / G-code.
  Future<void> _offerFileSettings(LoadedModel m) async {
    final p = m.project;
    if (p == null || !p.hasSettings) return;
    final before = _settings;
    final after = p.applyTo(before);
    if (after.geometryKey == before.geometryKey &&
        after.materialId == before.materialId &&
        after.density == before.density &&
        after.printerId == before.printerId) {
      return; // already the same
    }
    if (before.autoApplyFileSettings) {
      _applySettingsSilently(after);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Застосовано налаштування з файлу (${p.app})'),
        action: SnackBarAction(label: 'Відмінити', onPressed: () => _updateSettings(before)),
      ));
      return;
    }
    final choice = await showDialog<_FileSettingsChoice>(
      context: context,
      builder: (_) => _FileSettingsDialog(project: p),
    );
    if (choice == null || !choice.apply || !mounted) return;
    _applySettingsSilently(choice.always ? after.copyWith(autoApplyFileSettings: true) : after);
  }

  /// Settings change without the debounced re-slice (the caller slices).
  void _applySettingsSilently(SliceSettings s) {
    setState(() => _settings = s);
    PlatformFiles.saveSettings(s);
  }

  /// Whether the current settings reproduce the file's own slicing setup.
  bool _settingsMatchFile(SlicerProject p) {
    final s = _settings;
    final f = p.applyTo(s);
    return f.geometryKey == s.geometryKey &&
        s.scalePercent == 100 &&
        (p.density == null || (p.density! - s.density).abs() < 0.005);
  }

  /// Learns the calibration from a sliced file once its settings are in use.
  void _maybeAutoCalibrate(SliceResult r) {
    final m = _model;
    final p = m?.project;
    if (_autoCalibrated || p == null || !p.isSliced || !m!.hasMesh || !_settingsMatchFile(p)) return;
    _autoCalibrated = true;
    final s = _settings;
    final rawSeconds = r.printSeconds(s) + printerById(s.printerId).startMinutes * 60;
    final next = s.calibrated(
      rawGrams: r.grams(s.density),
      slicerGrams: p.grams,
      rawSeconds: rawSeconds,
      slicerSeconds: p.seconds > 0 ? p.seconds : null,
    );
    _applySettingsSilently(next);
    _snack('Калібрування оновлено за ${p.app}: вага ×${fmtNum(next.weightFactor, 2)}, '
        'час ×${fmtNum(next.timeFactor, 2)}');
  }

  Future<void> _slice() async {
    final model = _model;
    if (model == null) return;
    if (!model.hasMesh) {
      setState(() {
        _result = null;
        _progress = null;
      });
      return;
    }
    _job?.cancel();
    final job = SliceJob();
    _job = job;
    setState(() {
      _progress = 0;
      _sliceError = null;
    });
    try {
      final r = await job.run(model.mesh.tris, _settings, (p) {
        if (mounted && identical(_job, job)) setState(() => _progress = p);
      });
      if (!mounted || !identical(_job, job)) return;
      setState(() {
        _result = r;
        _progress = null;
        _layer = r.layers - 1;
      });
      _maybeAutoCalibrate(r);
      _computeObjectVolumes(r);
    } on SliceCancelled {
      // A newer job replaced this one.
    } catch (e) {
      if (!mounted || !identical(_job, job)) return;
      setState(() {
        _sliceError = e.toString();
        _progress = null;
      });
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _openSettings() => showSettingsSheet(context, _settings, _updateSettings);

  void _openHistory() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HistoryPage()));
  }

  /// Slicer data of the open file, when it is the source of the numbers.
  SlicerProject? get _slicerSource {
    final m = _model;
    final p = m?.project;
    if (m == null || p == null || !p.isSliced) return null;
    if (!m.hasMesh) return p;
    return _settings.preferSlicerData && _settings.scalePercent == 100 ? p : null;
  }

  /// Our estimate of one copy's print time incl. start-up, hours (calibrated).
  double _estimateHours(SliceResult r) =>
      (r.printSeconds(_settings) * _settings.timeFactor + printerById(_settings.printerId).startMinutes * 60) / 3600;

  /// Copies per plate and number of plates for the current copies.
  (int, int) _plates() {
    final m = _model;
    final s = _settings;
    if (m == null || !m.hasMesh) return (1, s.copies);
    final k = s.scalePercent / 100;
    final (bx, by, _) = s.bed;
    var per = copiesPerPlate(m.bounds.sizeX * k, m.bounds.sizeY * k, bx, by, s.plateGap);
    if (per < 1) per = 1;
    return (per, (s.copies + per - 1) ~/ per);
  }

  /// Colour (filament slot) of every printed object, in mesh order.
  List<int> _printedColors(LoadedModel m) {
    final out = <int>[];
    for (int i = 0; i < m.source.objects.length; i++) {
      if (i < m.enabled.length && m.enabled[i]) out.add(_objectColors[i] ?? m.source.objects[i].extruder);
    }
    return out;
  }

  /// Purge + prime tower for one plate, mm³ (0 for a single colour).
  ColorWaste? _colorWaste() {
    final m = _model;
    final r = _result;
    if (m == null || r == null || m.mesh.objects.length < 2) return null;
    final colors = _printedColors(m);
    if (colors.toSet().length < 2 || colors.length != m.mesh.objects.length) return null;
    final s = _settings;
    final k = s.scalePercent / 100;
    final t = m.mesh.tris;
    final z0 = m.bounds.minZ;
    final ranges = <(double, double)>[];
    for (final o in m.mesh.objects) {
      double lo = double.infinity, hi = -double.infinity;
      for (int i = o.start * 9 + 2; i < o.end * 9; i += 3) {
        final z = t[i];
        if (z < lo) lo = z;
        if (z > hi) hi = z;
      }
      ranges.add(((lo - z0) * k, (hi - z0) * k));
    }
    final layerColors = <int>[];
    for (int l = 0; l < r.layers; l++) {
      final z = s.firstLayerHeight + (l - 0.5) * s.layerHeight;
      final present = <int>{};
      for (int j = 0; j < ranges.length; j++) {
        if (ranges[j].$1 < z && ranges[j].$2 > z) present.add(colors[j]);
      }
      layerColors.add(present.length);
    }
    return ColorWaste.estimate(layerColors, s.layerHeight, s);
  }

  /// Weight, time and price of the order, from the slicer or our estimate.
  _Figures? _figures() {
    final s = _settings;
    final r = _result;
    final p = _slicerSource;
    final copies = s.copies;
    if (p != null) {
      final grams1 = p.grams;
      double meters1 = p.meters;
      if (meters1 <= 0 && grams1 > 0) {
        final rad = s.filamentDiameter / 2;
        meters1 = grams1 / s.density * 1000 / (math.pi * rad * rad) / 1000;
      }
      final hours1 = _manualHours ?? p.seconds / 3600;
      final grams = grams1 * copies;
      final hours = hours1 * copies;
      return _Figures(
        source: p.app,
        grams1: grams1,
        gramsTotal: grams,
        model1: grams1,
        support1: 0,
        meters: meters1 * copies,
        hours: hours,
        perPlate: 1,
        plates: copies,
        cost: CostBreakdown.of(grams, hours, s, copies: copies),
        estimateGrams: r == null ? null : r.grams(s.density, copies: copies) * s.weightFactor,
      );
    }
    if (r == null) return null;
    final f = s.weightFactor;
    final grams1 = r.grams(s.density) * f;
    final (per, plates) = _plates();
    final waste = _colorWaste();
    final wasteG = waste == null ? 0.0 : waste.totalMm3 * s.density / 1000 * plates;
    final gramsTotal = grams1 * copies + wasteG;
    final start = printerById(s.printerId).startMinutes * 60;
    final double hours;
    if (_manualHours != null) {
      hours = _manualHours! * copies;
    } else {
      // Copies on one plate share layer changes and the start-up.
      final moving = r.movingSeconds(s), layersOh = layerOverheadSeconds(r.layers, s);
      hours = ((copies * moving + plates * layersOh) * s.timeFactor + plates * start) / 3600;
    }
    final rad = s.filamentDiameter / 2;
    return _Figures(
      source: null,
      grams1: grams1,
      gramsTotal: gramsTotal,
      model1: r.modelGrams(s.density) * f,
      support1: r.supportGrams(s.density) * f,
      brim1: r.brimGrams(s.density) * f,
      meters: gramsTotal / s.density * 1000 / (math.pi * rad * rad) / 1000,
      hours: hours,
      perPlate: per,
      plates: plates,
      waste: waste,
      wasteGrams: wasteG,
      cost: CostBreakdown.of(gramsTotal, hours, s, copies: copies),
    );
  }

  Future<void> _calibrate() async {
    final r = _result;
    if (r == null) return;
    final s = _settings;
    final input = await showDialog<(double?, double?)>(
      context: context,
      builder: (_) => _CalibrateDialog(
        estimateGrams: r.grams(s.density) * s.weightFactor,
        estimateHours: _estimateHours(r),
      ),
    );
    if (input == null || !mounted) return;
    final (grams, hours) = input;
    if (grams == null && hours == null) return;
    final rawSeconds = r.printSeconds(s) + printerById(s.printerId).startMinutes * 60;
    final next = s.calibrated(
      rawGrams: r.grams(s.density),
      slicerGrams: grams,
      rawSeconds: rawSeconds,
      slicerSeconds: hours == null ? null : hours * 3600,
    );
    setState(() => _manualHours = null);
    _updateSettings(next);
    _snack('Калібрування збережено: вага ×${fmtNum(next.weightFactor, 2)}, час ×${fmtNum(next.timeFactor, 2)}');
  }

  Future<void> _editTime() async {
    final r = _result;
    final p = _slicerSource;
    if (r == null && p == null) return;
    final current = _manualHours ?? (p != null ? p.seconds / 3600 : _estimateHours(r!));
    final v = await showDialog<double>(
      context: context,
      builder: (_) => _TimeDialog(initialHours: current, isManual: _manualHours != null),
    );
    if (v == null || !mounted) return;
    setState(() => _manualHours = v < 0 ? null : v);
  }

  /// Snapshot of the current calculation as a history entry.
  HistoryEntry? _buildEntry({String note = '', String? thumbPath, String? id}) {
    final m = _model;
    final r = _result;
    final fig = _figures();
    if (m == null || fig == null) return null;
    final s = _settings;
    final cost = fig.cost;
    final mat = materialById(s.materialId);
    return HistoryEntry(
      id: id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      date: DateTime.now(),
      name: m.name,
      material: mat.id == 'custom' ? 'Свій (${fmtNum(s.density, 2)} г/см³)' : mat.name,
      density: s.density,
      pricePerKg: s.pricePerKg,
      layerHeight: s.layerHeight,
      infillPercent: s.infillPercent,
      walls: s.walls,
      supports: s.supportsEnabled,
      supportPlateOnly: s.supportPlateOnly,
      scalePercent: s.scalePercent,
      copies: s.copies,
      modelGrams: fig.model1,
      supportGrams: fig.support1,
      filamentMeters: fig.meters,
      materialCost: cost.material,
      printHours: cost.hours,
      electricityCost: cost.electricity,
      amortizationCost: cost.amortization,
      costPrice: cost.costPrice,
      markupPercent: s.markupPercent,
      extraCost: s.extraCost,
      totalCost: cost.price,
      sizeX: r?.sizeX ?? 0,
      sizeY: r?.sizeY ?? 0,
      sizeZ: r?.sizeZ ?? 0,
      note: note,
      thumbPath: thumbPath,
      source: fig.source ?? '',
    );
  }

  Future<Uint8List?> _captureThumb() async {
    final m = _model;
    if (m != null && !m.hasMesh) return m.project?.thumbnail;
    try {
      final obj = _viewerKey.currentContext?.findRenderObject();
      if (obj is! RenderRepaintBoundary) return null;
      final size = obj.size;
      if (size.isEmpty) return null;
      final ratio = 320 / math.max(size.width, size.height);
      final img = await obj.toImage(pixelRatio: ratio);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToHistory() async {
    if (_buildEntry() == null) return;
    final note = await showDialog<String>(context: context, builder: (_) => const _NoteDialog());
    if (note == null || !mounted) return;
    setState(() => _saving = true);
    try {
      final id = DateTime.now().microsecondsSinceEpoch.toString();
      final png = await _captureThumb();
      final thumb = png == null ? null : await HistoryStore.saveThumb(id, png);
      final e = _buildEntry(note: note, thumbPath: thumb, id: id);
      if (e == null) return;
      await HistoryStore.add(e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Збережено в історію'),
        action: SnackBarAction(label: 'Відкрити', onPressed: _openHistory),
      ));
    } catch (e) {
      _snack('Не вдалося зберегти: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _share() {
    final e = _buildEntry();
    if (e == null) return;
    PlatformFiles.shareText(historySummary(e)).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    return Scaffold(
      appBar: AppBar(
        title: Text(model?.name ?? 'STL Вага', overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(tooltip: 'Відкрити файл', onPressed: _loading ? null : _pick, icon: const Icon(Icons.folder_open)),
          IconButton(tooltip: 'Налаштування', onPressed: _openSettings, icon: const Icon(Icons.tune)),
          PopupMenuButton<String>(
            onSelected: _onMenu,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'url', child: ListTile(leading: Icon(Icons.link), title: Text('Відкрити за посиланням'))),
              const PopupMenuItem(value: 'history', child: ListTile(leading: Icon(Icons.history), title: Text('Історія'))),
              const PopupMenuItem(
                  value: 'orders', child: ListTile(leading: Icon(Icons.receipt_long_outlined), title: Text('Замовлення'))),
              const PopupMenuItem(
                  value: 'clients', child: ListTile(leading: Icon(Icons.people_outline), title: Text('Клієнти'))),
              if (_adv) ...[
                const PopupMenuItem(
                    value: 'catalog', child: ListTile(leading: Icon(Icons.storefront_outlined), title: Text('Прайс-лист'))),
                const PopupMenuItem(
                    value: 'expenses',
                    child: ListTile(leading: Icon(Icons.account_balance_wallet_outlined), title: Text('Витрати'))),
                const PopupMenuItem(
                    value: 'spools', child: ListTile(leading: Icon(Icons.album_outlined), title: Text('Котушки'))),
                const PopupMenuItem(
                    value: 'stats', child: ListTile(leading: Icon(Icons.bar_chart), title: Text('Статистика'))),
                const PopupMenuItem(
                    value: 'export', child: ListTile(leading: Icon(Icons.backup_outlined), title: Text('Зберегти копію даних'))),
                const PopupMenuItem(
                    value: 'import', child: ListTile(leading: Icon(Icons.restore), title: Text('Відновити з копії'))),
              ],
              const PopupMenuItem(
                  value: 'autobackup',
                  child: ListTile(leading: Icon(Icons.cloud_sync_outlined), title: Text('Автокопія (Google Диск)'))),
              const PopupMenuItem(
                  value: 'intro', child: ListTile(leading: Icon(Icons.help_outline), title: Text('Як користуватися'))),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'mode', checked: _adv, child: const Text('Розширений режим')),
            ],
          ),
        ],
      ),
      body: Column(children: [
        if (_update != null) _updateBanner(_update!),
        Expanded(child: _body()),
      ]),
    );
  }

  Widget _updateBanner(UpdateInfo u) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(children: [
          Icon(Icons.system_update, color: theme.colorScheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Доступна нова версія (збірка ${u.build})',
                style: TextStyle(color: theme.colorScheme.onTertiaryContainer)),
          ),
          TextButton(
            onPressed: () => Updates.open(u.downloadUrl).catchError((Object _) {}),
            child: const Text('Оновити'),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _update = null),
            icon: const Icon(Icons.close, size: 18),
          ),
        ]),
      ),
    );
  }

  Widget _body() {
    final model = _model;
    return _loading
          ? const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Читаю модель…'),
              ]),
            )
          : model == null
              ? _EmptyState(onOpen: _pick, error: _loadError)
              : LayoutBuilder(builder: (context, c) {
                  final viewer = model.hasMesh ? _viewer(model) : _fileOnlyView(model);
                  final panel = _panel(model);
                  if (c.maxWidth > c.maxHeight * 1.15) {
                    return Row(children: [
                      Expanded(child: viewer),
                      SizedBox(width: 400, child: panel),
                    ]);
                  }
                  return Column(children: [
                    SizedBox(height: c.maxHeight * 0.45, child: viewer),
                    Expanded(child: panel),
                  ]);
                });
  }

  /// G-code or sliced file without geometry: show its picture.
  Widget _fileOnlyView(LoadedModel m) {
    final theme = Theme.of(context);
    final thumb = m.project?.thumbnail;
    return Container(
      color: theme.colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.all(16),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Expanded(
          child: thumb != null
              ? Image.memory(thumb, fit: BoxFit.contain, gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Icon(Icons.description_outlined, size: 72, color: theme.colorScheme.primary))
              : Icon(Icons.description_outlined, size: 72, color: theme.colorScheme.primary),
        ),
        const SizedBox(height: 8),
        Text(
          'Нарізаний файл ${m.project?.app ?? ''}: 3D-моделі немає, вага й час — зі слайсера',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }

  Widget _viewer(LoadedModel m) {
    final theme = Theme.of(context);
    final k = _settings.scalePercent / 100;
    final b = m.bounds;
    String mm(double v) => fmtNum(v * k, 1);
    final preview = _result?.preview;
    final layersMode = _adv && _layersView && preview != null && preview.layers > 0;
    final fit = _bedFit(m);
    final chipDecoration = BoxDecoration(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(8),
    );
    final layer = preview == null || preview.layers == 0 ? 0 : _layer.clamp(0, preview.layers - 1).toInt();

    return Column(children: [
      Expanded(
        child: Stack(children: [
          Positioned.fill(
            child: RepaintBoundary(
              key: _viewerKey,
              child: ModelViewer(
                model: m,
                color: _modelColor,
                preview: preview,
                previewScale: k,
                showLayers: layersMode,
                maxLayer: layer,
                measure: _measure,
                onFacePicked: _pickFace && !layersMode ? _layFlat : null,
              ),
            ),
          ),
          if (_adv)
          Positioned(
            left: 10,
            top: 8,
            child: SegmentedButton<bool>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('Модель'), icon: Icon(Icons.view_in_ar_outlined)),
                ButtonSegment(value: true, label: Text('Шари'), icon: Icon(Icons.layers_outlined)),
              ],
              selected: {layersMode},
              onSelectionChanged: (v) {
                if (v.first && preview == null) {
                  _snack('Шари з\'являться після нарізання');
                  return;
                }
                setState(() => _layersView = v.first);
              },
            ),
          ),
          Positioned(
            right: 10,
            top: 12,
            child: GestureDetector(
              onTap: () => _scaleDialog(m),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: chipDecoration,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${mm(b.sizeX)} × ${mm(b.sizeY)} × ${mm(b.sizeZ)} мм', style: theme.textTheme.labelMedium),
                  const SizedBox(width: 4),
                  const Icon(Icons.edit_outlined, size: 14),
                ]),
              ),
            ),
          ),
          if (!layersMode)
            Positioned(
              right: 10,
              top: 50,
              child: Column(children: [
                if (_adv)
                  AnimatedBuilder(
                    animation: _measure,
                    builder: (context, _) => _measure.active
                        ? IconButton.filled(
                            tooltip: 'Закрити вимірювання',
                            onPressed: () => _measure.tool = MeasureTool.none,
                            icon: const Icon(Icons.straighten),
                          )
                        : IconButton.filledTonal(
                            tooltip: 'Вимірювання',
                            onPressed: () {
                              setState(() {
                                _orientOpen = false;
                                _pickFace = false;
                              });
                              _measure.tool = MeasureTool.distance;
                            },
                            icon: const Icon(Icons.straighten),
                          ),
                  ),
                const SizedBox(height: 4),
                (_orientOpen ? IconButton.filled : IconButton.filledTonal)(
                  tooltip: 'Положення на столі',
                  onPressed: () {
                    _measure.tool = MeasureTool.none;
                    setState(() {
                      _orientOpen = !_orientOpen;
                      _pickFace = false;
                    });
                  },
                  icon: const Icon(Icons.screen_rotation_alt),
                ),
              ]),
            ),
          if (!layersMode && fit != null)
            Positioned(
              left: 10,
              top: _adv ? 54 : 10,
              right: 64,
              child: Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: fit.$3 ? () => _rotate(2) : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: (fit.$1 ? const Color(0xFF2E7D32) : theme.colorScheme.error).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      fit.$2,
                      style: theme.textTheme.labelSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          if (!layersMode)
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: _orientOpen
                  ? _orientPanel(m)
                  : AnimatedBuilder(
                      animation: _measure,
                      builder: (context, _) => _measure.active ? _measurePanel(k) : const SizedBox.shrink(),
                    ),
            ),
          if (layersMode)
            Positioned(
              left: 10,
              bottom: 8,
              right: 10,
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final c in [1, 2, 3, 4, if (_settings.supportsEnabled) 5, if (_settings.brimWidth > 0 || _settings.skirtLoops > 0) 7])
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: chipDecoration,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(color: sliceColors[c], borderRadius: BorderRadius.circular(3)),
                        ),
                        const SizedBox(width: 5),
                        Text(sliceClassNames[c], style: theme.textTheme.labelSmall),
                      ]),
                    ),
                ],
              ),
            ),
          if (_loadError != null)
            Positioned(
              left: 12,
              right: 12,
              top: 56,
              child: Material(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(_loadError!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                ),
              ),
            ),
        ]),
      ),
      if (layersMode)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
          child: Row(children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: layer > 0 ? () => setState(() => _layer = layer - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Slider(
                value: layer.toDouble(),
                min: 0,
                max: (preview!.layers - 1).toDouble(),
                onChanged: (v) => setState(() => _layer = v.round()),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: layer < preview!.layers - 1 ? () => setState(() => _layer = layer + 1) : null,
              icon: const Icon(Icons.add),
            ),
            SizedBox(
              width: 92,
              child: Text(
                '${layer + 1}/${preview!.layers}\n${fmtNum(preview!.zTop[layer], 2)} мм',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall,
              ),
            ),
          ]),
        ),
    ]);
  }

  Future<void> _scaleDialog(LoadedModel m) async {
    final v = await showDialog<double>(
      context: context,
      builder: (_) => _ScaleDialog(
        sizes: (m.bounds.sizeX, m.bounds.sizeY, m.bounds.sizeZ),
        scalePercent: _settings.scalePercent,
        bed: _settings.bed,
      ),
    );
    if (v != null) _updateSettings(_settings.copyWith(scalePercent: v));
  }

  /// (fits, label, fits after a 90° turn) for the current printer's bed.
  (bool, String, bool)? _bedFit(LoadedModel m) {
    if (!m.hasMesh) return null;
    final k = _settings.scalePercent / 100;
    final (bx, by, bz) = _settings.bed;
    final x = m.bounds.sizeX * k, y = m.bounds.sizeY * k, z = m.bounds.sizeZ * k;
    final name = printerById(_settings.printerId).name;
    if (x <= bx && y <= by && z <= bz) return (true, '✓ влазить на $name', false);
    if (y <= bx && x <= by && z <= bz) return (false, 'Не влазить — торкніться, щоб повернути на 90°', true);
    final over = <String>[
      if (x > bx) 'X ${fmtNum(x, 0)}>${fmtNum(bx, 0)}',
      if (y > by) 'Y ${fmtNum(y, 0)}>${fmtNum(by, 0)}',
      if (z > bz) 'Z ${fmtNum(z, 0)}>${fmtNum(bz, 0)}',
    ];
    return (false, '✗ не влазить на $name: ${over.join(', ')} мм', false);
  }

  Widget _orientPanel(LoadedModel m) {
    final theme = Theme.of(context);
    Widget btn(String label, IconData icon, VoidCallback? onTap, {bool selected = false}) => Padding(
          padding: const EdgeInsets.only(right: 6, bottom: 6),
          child: selected
              ? FilledButton.icon(
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: Text(label),
                )
              : FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: Text(label),
                ),
        );
    final busy = _reorienting;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                _pickFace ? 'Торкніться грані, яка має лягти на стіл' : 'Положення на столі',
                style: theme.textTheme.titleSmall,
              ),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _orientOpen = false;
                _pickFace = false;
              }),
              icon: const Icon(Icons.close),
            ),
          ]),
          Wrap(children: [
            btn('Авто', Icons.auto_fix_high, busy ? null : _autoOrient),
            btn('Гранню на стіл', Icons.touch_app_outlined, busy ? null : () => setState(() => _pickFace = !_pickFace),
                selected: _pickFace),
            btn('X 90°', Icons.rotate_right, busy ? null : () => _rotate(0)),
            btn('Y 90°', Icons.rotate_right, busy ? null : () => _rotate(1)),
            btn('Z 90°', Icons.rotate_right, busy ? null : () => _rotate(2)),
            if (!isIdentity(m.rotation))
              btn('Як у файлі', Icons.restart_alt, busy ? null : () => _derive(rotation: identity3)),
          ]),
        ]),
      ),
    );
  }

  String _measureText(Measurement m, double k) {
    String mm(double v) => '${fmtNum(v * k, 2)} мм';
    switch (m.tool) {
      case MeasureTool.distance:
        final d = m.delta;
        return '${mm(m.distance)}   ΔX ${fmtNum(d.x.abs() * k, 2)} · ΔY ${fmtNum(d.y.abs() * k, 2)} · ΔZ ${fmtNum(d.z.abs() * k, 2)}';
      case MeasureTool.circle:
        final c = m.circle;
        if (c == null) return 'Точки на одній прямій — коло не визначене';
        return '⌀ ${mm(c.radius * 2)}   R ${mm(c.radius)}';
      case MeasureTool.angle:
        return '${fmtNum(m.angle, 1)}°';
      case MeasureTool.none:
      case MeasureTool.holes:
        return '';
    }
  }

  static String _holesWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'отвір';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'отвори';
    return 'отворів';
  }

  String _holesText(double k) {
    final mc = _measure;
    if (mc.holesBusy) return 'Шукаю отвори…';
    if (mc.holesError != null) return mc.holesError!;
    final list = mc.holes;
    if (list == null) return '';
    if (list.isEmpty) return 'Круглих отворів уздовж осей X, Y, Z не знайдено';
    final h = mc.selectedHole;
    if (h != null) {
      final chamfer = h.chamferRadius > h.radius ? ' · фаска до ⌀${fmtNum(h.chamferRadius * 2 * k, 2)}' : '';
      return 'Отвір ⌀${fmtNum(h.diameter * k, 2)} мм · глибина ≈${fmtNum(h.depth * k, 1)} мм · вісь ${h.axisName}$chamfer';
    }
    final groups = <String, int>{};
    for (final x in list) {
      final key = fmtNum(x.diameter * k, 1);
      groups[key] = (groups[key] ?? 0) + 1;
    }
    final keys = groups.keys.toList()
      ..sort((a, b) => double.parse(a.replaceAll(',', '.')).compareTo(double.parse(b.replaceAll(',', '.'))));
    final parts = [for (final d in keys) groups[d]! > 1 ? '⌀$d ×${groups[d]}' : '⌀$d'];
    final miss = mc.holeMiss ? 'Тут немає отвору. ' : '';
    return '$miss${list.length} ${_holesWord(list.length)}: ${parts.join(' · ')} — торкніться отвору';
  }

  Widget _measurePanel(double k) {
    final theme = Theme.of(context);
    final mc = _measure;
    final need = mc.tool.points;
    String text;
    if (mc.tool == MeasureTool.holes) {
      text = _holesText(k);
    } else if (mc.pending.isNotEmpty) {
      text = 'Точка ${mc.pending.length + 1} з $need — торкніться моделі';
    } else if (mc.done.isNotEmpty && mc.done.last.tool == mc.tool) {
      text = _measureText(mc.done.last, k);
    } else {
      text = switch (mc.tool) {
        MeasureTool.circle => 'Торкніться 3 точок на краю отвору чи дуги',
        MeasureTool.angle => 'Торкніться 3 точок: кінець, вершина кута, кінець',
        _ => 'Торкніться двох точок на моделі',
      };
    }
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: SegmentedButton<MeasureTool>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
                    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500)),
                  ),
                  showSelectedIcon: false,
                  segments: [
                    for (final t in [MeasureTool.distance, MeasureTool.circle, MeasureTool.angle, MeasureTool.holes])
                      ButtonSegment(value: t, label: Text(t.label, maxLines: 1)),
                  ],
                  selected: {mc.tool},
                  onSelectionChanged: (v) => mc.tool = v.first,
                ),
              ),
            ]),
            Row(children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 3,
                  ),
                ),
              ),
              if (mc.tool == MeasureTool.holes && mc.holesBusy)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              if (mc.tool != MeasureTool.holes) ...[
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: mc.snap ? 'Прилипання до вершин: увімк.' : 'Прилипання до вершин: вимк.',
                isSelected: mc.snap,
                onPressed: () => mc.snap = !mc.snap,
                icon: const Icon(Icons.filter_center_focus_outlined),
                selectedIcon: Icon(Icons.filter_center_focus, color: theme.colorScheme.primary),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Скасувати точку',
                onPressed: mc.pending.isEmpty && mc.done.isEmpty ? null : mc.undo,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Очистити всі виміри',
                onPressed: mc.pending.isEmpty && mc.done.isEmpty ? null : mc.clear,
                icon: const Icon(Icons.delete_sweep_outlined),
              ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  Widget _panel(LoadedModel m) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _resultCard(),
        const SizedBox(height: 8),
        _costCard(),
        const SizedBox(height: 8),
        if (m.hasMesh) ...[
          _adv ? _quickSettings() : _simpleSettings(),
          const SizedBox(height: 8),
        ],
        if (m.source.objects.length > 1) ...[
          _objectsCard(m),
          const SizedBox(height: 8),
        ],
        if (_adv || !m.hasMesh) _modelInfo(m),
      ],
    );
  }

  Widget _resultCard() {
    final theme = Theme.of(context);
    final r = _result;
    final s = _settings;
    final m = _model;
    final busy = _progress != null;
    final onCard = theme.colorScheme.onPrimaryContainer;
    final fig = _figures();
    final cost = fig?.cost;
    final small = theme.textTheme.bodySmall;
    final project = m?.project;
    final canChooseSource = project != null && project.isSliced && (m?.hasMesh ?? false);

    Widget line(String label, String value, {bool strong = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(children: [
            Expanded(child: Text(label, style: strong ? theme.textTheme.bodyMedium : small)),
            Text(value, style: strong ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) : small),
          ]),
        );

    Widget badge(String text, IconData icon) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: onCard.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: onCard),
            const SizedBox(width: 4),
            Text(text, style: theme.textTheme.labelSmall?.copyWith(color: onCard)),
          ]),
        );

    String timeNote() {
      if (_manualHours != null) {
        return 'введено вручну${s.copies > 1 ? ' (${formatDuration(_manualHours!)} × ${s.copies})' : ''}';
      }
      if (fig?.source != null) return 'з файлу ${fig!.source}';
      final calibrated = (s.timeSamples[s.printerId] ?? 0) > 0;
      return 'оцінка для «${printerById(s.printerId).fullName}»${calibrated ? ', калібровано' : ''}; '
          'торкніться, щоб ввести час';
    }

    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Text('Вага пластику', style: theme.textTheme.titleSmall),
              const Spacer(),
              Text(
                materialById(s.materialId).id == 'custom'
                    ? 'свій, ${fmtNum(s.density, 2)} г/см³'
                    : materialById(s.materialId).name,
                style: theme.textTheme.labelLarge,
              ),
            ]),
            const SizedBox(height: 4),
            if (fig != null)
              AnimatedOpacity(
                opacity: busy && fig.source == null ? 0.4 : 1,
                duration: const Duration(milliseconds: 200),
                child: Text(
                  fmtGrams(fig.gramsTotal),
                  style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: onCard),
                ),
              )
            else if (!busy && _sliceError == null)
              const Text('—'),
            if (fig != null)
              Wrap(spacing: 6, runSpacing: 4, children: [
                if (fig.source != null)
                  badge('точно: ${fig.source}', Icons.verified_outlined)
                else if (s.weightSamples > 0)
                  badge('калібровано ×${fmtNum(s.weightFactor, 2)}', Icons.tune)
                else
                  badge('оцінка', Icons.calculate_outlined),
              ]),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text(
                '${s.supportsEnabled ? 'Нарізання і підтримки' : 'Нарізання'}… ${((_progress ?? 0) * 100).round()}%',
                style: small,
              ),
            ],
            if (_sliceError != null) ...[
              const SizedBox(height: 8),
              Text(_sliceError!, style: TextStyle(color: theme.colorScheme.error)),
              TextButton(onPressed: _slice, child: const Text('Спробувати ще раз')),
            ],
            if (_report != null && _report!.hasProblems)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _report!.isWatertight
                          ? 'У моделі є перевернуті грані — вага може бути неточною'
                          : 'Модель має дірки в сітці — вага може бути неточною',
                      style: small?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                ]),
              ),
            if (fig != null && cost != null) ...[
              const SizedBox(height: 6),
              if (_adv && fig.source != null && fig.estimateGrams != null)
                Text('наш розрахунок: ${fmtGrams(fig.estimateGrams!)}', style: small),
              if (fig.source == null && fig.brim1 > 0)
                Text('у т.ч. кайма / спідниця: ${fmtGrams(fig.brim1 * s.copies)}', style: small),
              if (_adv && fig.source == null && s.supportsEnabled)
                Text(
                  'модель ${fmtGrams(fig.model1 * s.copies)} · підтримки ${fmtGrams(fig.support1 * s.copies)}',
                  style: theme.textTheme.bodyMedium,
                ),
              if (s.copies > 1)
                Text('${s.copies} шт. · одна: ${fmtGrams(fig.grams1)}', style: theme.textTheme.bodyMedium),
              if (fig.source == null && (s.copies > 1 || fig.perPlate > 1))
                Text(
                  fig.plates == 1
                      ? 'на стіл влазить ${fig.perPlate} шт · одна пластина'
                      : 'на стіл влазить ${fig.perPlate} шт · пластин: ${fig.plates}',
                  style: small,
                ),
              if (fig.waste != null && fig.waste!.changes > 0)
                Text(
                  'відходи на зміну кольору: ${fmtGrams(fig.wasteGrams)} '
                  '(${fig.waste!.changes} змін${s.primeTower ? ', з вежею' : ''})',
                  style: small,
                ),
              if (fig.source != null && project != null && project.filaments.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    for (final f in project.filaments)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: _hexColor(f.color) ?? onCard,
                            shape: BoxShape.circle,
                            border: Border.all(color: onCard.withValues(alpha: 0.4)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text('${f.type} ${fmtGrams(f.grams * s.copies)}', style: small),
                      ]),
                  ]),
                ),
              if (_adv && canChooseSource) ...[
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  style: const ButtonStyle(visualDensity: VisualDensity.compact),
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: true, label: Text('Дані ${project!.app}')),
                    const ButtonSegment(value: false, label: Text('Наш розрахунок')),
                  ],
                  selected: {fig.source != null},
                  onSelectionChanged: (v) {
                    if (v.first && s.scalePercent != 100) {
                      _snack('Дані слайсера діють лише при масштабі 100%');
                    }
                    _updateSettings(s.copyWith(preferSlicerData: v.first));
                  },
                ),
              ],
              if (_adv) const SizedBox(height: 12),
              if (_adv)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Stat('філамент', '${fmtNum(fig.meters, 2)} м'),
                  Stat('об\'єм', '${fmtNum(fig.gramsTotal / s.density, 1)} см³'),
                  if (r != null) Stat('шарів', '${r.layers}'),
                ],
              ),
              Divider(height: 24, color: onCard.withValues(alpha: 0.2)),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _editTime,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    const Icon(Icons.schedule, size: 18),
                    const SizedBox(width: 6),
                    Text('Час друку', style: theme.textTheme.bodyMedium),
                    const Spacer(),
                    Text(
                      '${_manualHours == null && fig.source == null ? '≈ ' : ''}${formatDuration(cost.hours)}',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    Icon(_manualHours == null ? Icons.edit_outlined : Icons.edit, size: 16),
                  ]),
                ),
              ),
              Text(timeNote(), style: small),
              const SizedBox(height: 10),
              if (_adv) ...[
                line('Пластик', fmtMoney(cost.material)),
                line('Електроенергія', fmtMoney(cost.electricity)),
                line('Амортизація', fmtMoney(cost.amortization)),
                if (cost.failure > 0) line('Брак ${fmtNum(s.failurePercent, 0)}%', fmtMoney(cost.failure)),
              ],
              line('Собівартість', fmtMoney(cost.costPrice), strong: true),
              if (_adv) ...[
                const SizedBox(height: 4),
                line('Заробіток ${fmtNum(s.markupPercent, 0)}%', fmtMoney(cost.profit)),
              ],
              if (cost.discount > 0)
                line('Знижка ${fmtNum(discountFor(s.discounts, s.copies), 0)}% (від кількості)', '−${fmtMoney(cost.discount)}'),
              if (_adv && cost.extra != 0) line('Доплата', fmtMoney(cost.extra)),
              if (cost.minimumAdd > 0) line('До мінімальної ціни', fmtMoney(cost.minimumAdd)),
              if (_adv && cost.rounding > 0.004) line('Округлення', fmtMoney(cost.rounding)),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Ціна', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    fmtMoney(cost.price),
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: onCard),
                  ),
                ],
              ),
              if (s.copies > 1)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text('${fmtMoney(cost.price / s.copies)} за штуку', style: small),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy && fig.source == null ? null : _shareChoice,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Поділитися'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: (busy && fig.source == null) || _saving ? null : _saveToHistory,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Зберегти'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: busy && fig.source == null ? null : _addToOrder,
                    icon: const Icon(Icons.add_shopping_cart),
                    label: const Text('До замовлення'),
                  ),
                ),
                if (_adv) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: 'У прайс-лист',
                    onPressed: busy && fig.source == null ? null : _addToCatalog,
                    icon: const Icon(Icons.storefront_outlined),
                  ),
                ],
              ]),
              if (_adv && r != null && fig.source == null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                    onPressed: busy ? null : _calibrate,
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Підігнати під слайсер'),
                  ),
                ),
              if (_adv && r != null)
                Text(
                  'Суцільна модель (100%): ${fmtGrams(r.solidGrams(s.density))}',
                  style: small,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _costCard() {
    final theme = Theme.of(context);
    final s = _settings;
    final mat = materialById(s.materialId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ціни', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            NumberField(
              key: ValueKey('price-${s.materialId}'),
              label: 'Котушка ${mat.id == 'custom' ? 'свого матеріалу' : mat.name}, за 1 кг',
              suffix: currency,
              value: s.pricePerKg,
              onChanged: (v) => _updateSettings(_settings.withPrice(v)),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: NumberField(
                  label: 'Заробіток',
                  suffix: '%',
                  value: s.markupPercent,
                  onChanged: (v) => _updateSettings(_settings.copyWith(markupPercent: v)),
                ),
              ),
              if (_adv) ...[
              const SizedBox(width: 12),
              Expanded(
                child: NumberField(
                  label: 'Доплата',
                  suffix: currency,
                  value: s.extraCost,
                  onChanged: (v) => _updateSettings(_settings.copyWith(extraCost: v)),
                ),
              ),
              ],
            ]),
            const SizedBox(height: 4),
            if (_adv)
            TextButton.icon(
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
              onPressed: _openSettings,
              icon: const Icon(Icons.bolt_outlined, size: 18),
              label: Text(
                '${fmtNum(s.powerW, 0)} Вт × ${fmtNum(s.tariff, 2)} $currency/кВт·год · '
                'амортизація ${fmtNum(s.amortizationPerHour, 1)} $currency/год',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Simplified print settings: material, quality, strength, supports, copies.
  Widget _simpleSettings() {
    final theme = Theme.of(context);
    final s = _settings;
    const quality = [(0.28, 'Чорнова'), (0.2, 'Стандарт'), (0.12, 'Висока')];
    const strength = [(10.0, 'Легка'), (15.0, 'Звичайна'), (30.0, 'Міцна'), (100.0, 'Суцільна')];
    Widget title(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Text(t, style: theme.textTheme.titleSmall),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          title('Пластик'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in materials.where((m) => m.id != 'custom').take(6))
              ChoiceChip(
                label: Text(m.name),
                selected: s.materialId == m.id,
                onSelected: (_) => _updateSettings(s.copyWith(materialId: m.id, density: m.density)),
              ),
          ]),
          title('Якість'),
          SegmentedButton<double>(
            showSelectedIcon: false,
            segments: [for (final (h, l) in quality) ButtonSegment(value: h, label: Text(l))],
            selected: {
              for (final (h, _) in quality)
                if ((h - s.layerHeight).abs() < 1e-6) h,
            },
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isNotEmpty) _updateSettings(s.copyWith(layerHeight: v.first));
            },
          ),
          title('Міцність (заповнення)'),
          SegmentedButton<double>(
            showSelectedIcon: false,
            style: const ButtonStyle(padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4))),
            segments: [for (final (p, l) in strength) ButtonSegment(value: p, label: Text(l, maxLines: 1))],
            selected: {
              for (final (p, _) in strength)
                if ((p - s.infillPercent).abs() < 1e-6) p,
            },
            emptySelectionAllowed: true,
            onSelectionChanged: (v) {
              if (v.isNotEmpty) _updateSettings(s.copyWith(infillPercent: v.first));
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Підтримки'),
            subtitle: const Text('Для нависань і мостів'),
            value: s.supportsEnabled,
            onChanged: (v) => _updateSettings(s.copyWith(supportsEnabled: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Режим вази'),
            subtitle: const Text('Одна стінка, без кришки й заповнення'),
            value: s.vaseMode,
            onChanged: (v) => _updateSettings(s.copyWith(vaseMode: v)),
          ),
          StepperRow(
            label: 'Кількість',
            value: s.copies.toDouble(),
            min: 1,
            max: 500,
            step: 1,
            unit: ' шт',
            onChanged: (v) => _updateSettings(s.copyWith(copies: v.round())),
          ),
        ]),
      ),
    );
  }

  Widget _objectsCard(LoadedModel m) {
    final theme = Theme.of(context);
    final s = _settings;
    final objs = m.source.objects;
    final vols = _objectVolumes;
    // Volumes come for printed objects in order; map them back to source indices.
    final volBySource = <int, double>{};
    if (vols != null) {
      int j = 0;
      for (int i = 0; i < objs.length && j < vols.length; i++) {
        if (i < m.enabled.length && m.enabled[i]) volBySource[i] = vols[j++];
      }
    }
    final enabledCount = m.enabled.where((e) => e).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
            child: Row(children: [
              Expanded(child: Text('Об\'єкти (${objs.length})', style: theme.textTheme.titleSmall)),
              if (_reorienting || (vols == null && _result != null && enabledCount > 1))
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          for (int i = 0; i < objs.length; i++)
            CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: i < m.enabled.length && m.enabled[i],
              onChanged: _reorienting
                  ? null
                  : (v) {
                      final next = List<bool>.of(m.enabled);
                      next[i] = v ?? false;
                      if (!next.contains(true)) {
                        _snack('Залиште хоча б один об\'єкт');
                        return;
                      }
                      _derive(enabled: next);
                    },
              title: Row(children: [
                Expanded(child: Text(objs[i].name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (_adv)
                  PopupMenuButton<int>(
                    tooltip: 'Колір (слот філаменту)',
                    onSelected: (c) => setState(() => _objectColors[i] = c),
                    itemBuilder: (_) => [
                      for (int c = 1; c <= 4; c++)
                        PopupMenuItem(
                          value: c,
                          child: Row(children: [
                            CircleAvatar(radius: 8, backgroundColor: _slotColors[c - 1]),
                            const SizedBox(width: 8),
                            Text('Колір $c'),
                          ]),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: CircleAvatar(
                        radius: 10,
                        backgroundColor: _slotColors[((_objectColors[i] ?? objs[i].extruder) - 1).clamp(0, 3).toInt()],
                        child: Text(
                          '${_objectColors[i] ?? objs[i].extruder}',
                          style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
              ]),
              secondary: volBySource[i] != null
                  ? Text(fmtGrams(volBySource[i]! * s.density / 1000 * s.weightFactor),
                      style: theme.textTheme.bodyMedium)
                  : null,
            ),
          if (_adv && vols != null && _printedColors(m).toSet().length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
              child: Wrap(spacing: 10, runSpacing: 4, children: [
                for (final c in (_printedColors(m).toSet().toList()..sort()))
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    CircleAvatar(radius: 6, backgroundColor: _slotColors[(c - 1).clamp(0, 3).toInt()]),
                    const SizedBox(width: 4),
                    Text(
                      fmtGrams([
                        for (int i = 0; i < objs.length; i++)
                          if (volBySource[i] != null && (_objectColors[i] ?? objs[i].extruder) == c) volBySource[i]!,
                      ].fold(0.0, (a, v) => a + v) * s.density / 1000 * s.weightFactor * s.copies),
                      style: theme.textTheme.bodySmall,
                    ),
                  ]),
              ]),
            ),
          if (enabledCount > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 0, 4),
              child: Text(
                'Вага кожного — окремим нарізанням, без кайми',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _quickSettings() {
    final theme = Theme.of(context);
    final s = _settings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Матеріал', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in materials.where((m) => m.id != 'custom').take(6))
                  ChoiceChip(
                    label: Text(m.name),
                    selected: s.materialId == m.id,
                    onSelected: (_) => _updateSettings(s.copyWith(materialId: m.id, density: m.density)),
                  ),
                ActionChip(label: const Text('Інші…'), onPressed: _openSettings),
              ],
            ),
            const SizedBox(height: 14),
            Text('Висота шару, мм', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final h in _layerChoices)
                  ChoiceChip(
                    label: Text(fmtNum(h, 2)),
                    selected: (s.layerHeight - h).abs() < 1e-6,
                    onSelected: (_) => _updateSettings(s.copyWith(layerHeight: h)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Заповнення: ${fmtNum(s.infillPercent, 0)}%', style: theme.textTheme.titleSmall),
            Slider(
              value: s.infillPercent.clamp(0, 100).toDouble(),
              min: 0,
              max: 100,
              divisions: 20,
              label: '${fmtNum(s.infillPercent, 0)}%',
              onChanged: (v) => _updateSettings(s.copyWith(infillPercent: v)),
            ),
            StepperRow(
              label: 'Стінки',
              value: s.walls.toDouble(),
              defaultValue: const SliceSettings().walls.toDouble(),
              min: 1,
              max: 15,
              step: 1,
              onChanged: (v) => _updateSettings(s.copyWith(walls: v.round())),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Підтримки'),
              subtitle: s.supportsEnabled
                  ? Text('${s.isTreeSupport ? 'деревоподібні' : 'звичайні ${fmtNum(s.supportDensity, 0)}%'} · '
                      '${s.supportPlateOnly ? 'від столу' : 'скрізь'} · ${fmtNum(s.supportAngle, 0)}°')
                  : null,
              value: s.supportsEnabled,
              onChanged: (v) => _updateSettings(s.copyWith(supportsEnabled: v)),
            ),
            if (s.supportsEnabled)
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'normal', label: Text('Звичайні'), icon: Icon(Icons.view_column_outlined)),
                  ButtonSegment(value: 'tree', label: Text('Деревоподібні'), icon: Icon(Icons.park_outlined)),
                ],
                selected: {s.isTreeSupport ? 'tree' : 'normal'},
                onSelectionChanged: (v) => _updateSettings(s.copyWith(supportType: v.first)),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Режим вази (спіраль)'),
              value: s.vaseMode,
              onChanged: (v) => _updateSettings(s.copyWith(vaseMode: v)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _openSettings,
                icon: const Icon(Icons.tune),
                label: const Text('Усі налаштування'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelInfo(LoadedModel m) {
    final theme = Theme.of(context);
    final k = _settings.scalePercent / 100;
    final style = theme.textTheme.bodyMedium;
    Widget row(String a, String b) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(a, style: style?.copyWith(color: theme.colorScheme.onSurfaceVariant))),
            Text(b, style: style),
          ]),
        );
    final b = m.bounds;
    final p = m.project;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(m.hasMesh ? 'Модель' : 'Файл', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            if (p != null) row('Створено в', p.app),
            if (p?.printProfile != null) row('Профіль', p!.printProfile!),
            if (p != null && p.plates.length > 1)
              for (final pl in p.plates)
                row('Пластина ${pl.index}', '${fmtGrams(pl.grams)} · ${formatDuration(pl.seconds / 3600)}'),
            if (m.hasMesh) ...[
            row('Трикутників', '${m.mesh.triangleCount}'),
            row('Розмір X × Y × Z',
                '${fmtNum(b.sizeX * k, 1)} × ${fmtNum(b.sizeY * k, 1)} × ${fmtNum(b.sizeZ * k, 1)} мм'),
            row('Об\'єм моделі', '${fmtNum(m.volume * k * k * k / 1000, 2)} см³'),
            row('Площа поверхні', '${fmtNum(m.area * k * k / 100, 1)} см²'),
            if (_settings.scalePercent != 100) row('Масштаб', '${fmtNum(_settings.scalePercent, 0)}%'),
            if (_result != null) row('Час розрахунку', '${fmtNum(_result!.millis / 1000, 1)} с'),
            if (_report != null) ...[
              row('Сітка', _report!.hasProblems ? '⚠ є помилки' : '✓ без помилок'),
              if (_report!.openEdges > 0) row('Відкриті ребра (дірки)', '${_report!.openEdges}'),
              if (_report!.nonManifoldEdges > 0) row('Неоднозначні ребра', '${_report!.nonManifoldEdges}'),
              if (_report!.flippedEdges > 0) row('Перевернуті грані (ребер)', '${_report!.flippedEdges}'),
              if (_report!.degenerate > 0) row('Вироджені трикутники', '${_report!.degenerate}'),
              if (_report!.shells > 1) row('Окремих частин', '${_report!.shells}'),
            ],
            if (!isIdentity(m.rotation)) row('Положення', 'змінене'),
            ],
            if (p != null && p.hasSettings)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                  onPressed: () {
                    final before = _settings;
                    _updateSettings(p.applyTo(before));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text('Застосовано налаштування з файлу (${p.app})'),
                      action: SnackBarAction(label: 'Відмінити', onPressed: () => _updateSettings(before)),
                    ));
                  },
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Застосувати налаштування з файлу'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onOpen;
  final String? error;

  const _EmptyState({required this.onOpen, this.error});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset('assets/logo.png', width: 112, height: 112),
            ),
            const SizedBox(height: 20),
            Text('Відкрийте STL, 3MF або G-code', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Додаток покаже модель і порахує, скільки пластику піде на друк.\n'
              'Файл також можна відкрити з Telegram чи файлового менеджера через «Відкрити за допомогою».',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.folder_open),
              label: const Text('Вибрати файл'),
            ),
            if (error != null) ...[
              const SizedBox(height: 24),
              Text(error!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Зберегти розрахунок'),
      content: TextField(
        controller: _c,
        autofocus: true,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Примітка (необов\'язково)',
          hintText: 'Клієнт, колір, термін…',
        ),
        onSubmitted: (_) => Navigator.pop(context, _c.text.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(onPressed: () => Navigator.pop(context, _c.text.trim()), child: const Text('Зберегти')),
      ],
    );
  }
}

/// Print-time input: hours and minutes of one copy, as shown by the slicer.
/// Pops the hours, or -1 to go back to the estimate.
class _TimeDialog extends StatefulWidget {
  final double initialHours;
  final bool isManual;

  const _TimeDialog({required this.initialHours, required this.isManual});

  @override
  State<_TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends State<_TimeDialog> {
  late final TextEditingController _h;
  late final TextEditingController _m;

  @override
  void initState() {
    super.initState();
    final total = (widget.initialHours * 60).round();
    _h = TextEditingController(text: '${total ~/ 60}');
    _m = TextEditingController(text: '${total % 60}');
  }

  @override
  void dispose() {
    _h.dispose();
    _m.dispose();
    super.dispose();
  }

  void _save() {
    final h = int.tryParse(_h.text.trim()) ?? 0;
    final m = int.tryParse(_m.text.trim()) ?? 0;
    final hours = h + m / 60.0;
    Navigator.pop(context, hours > 0 ? hours : -1.0);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Час друку однієї копії'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Введіть час, який показує ваш слайсер — розрахунок світла та амортизації стане точним.'),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _h,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Години', border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _m,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Хвилини', border: OutlineInputBorder()),
              onSubmitted: (_) => _save(),
            ),
          ),
        ]),
      ]),
      actions: [
        if (widget.isManual)
          TextButton(onPressed: () => Navigator.pop(context, -1.0), child: const Text('Оцінка')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(onPressed: _save, child: const Text('Готово')),
      ],
    );
  }
}

const _slotColors = [Color(0xFFFF8A3D), Color(0xFF1E88E5), Color(0xFF43A047), Color(0xFF8E24AA)];

Color? _hexColor(String hex) {
  var h = hex.replaceAll('#', '').trim();
  if (h.length == 8) h = h.substring(0, 6);
  if (h.length != 6) return null;
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// Numbers shown on the result card.
class _Figures {
  final String? source; // slicer name when the numbers are exact
  final double gramsTotal; // all copies incl. colour-change waste
  final int perPlate, plates;
  final ColorWaste? waste; // per plate
  final double wasteGrams; // all plates
  final double grams1; // one copy, model + supports
  final double model1, support1;
  final double brim1;
  final double meters; // all copies
  final double hours; // all copies
  final CostBreakdown cost;
  final double? estimateGrams; // our estimate (all copies) for comparison

  const _Figures({
    required this.source,
    required this.gramsTotal,
    required this.perPlate,
    required this.plates,
    this.waste,
    this.wasteGrams = 0,
    required this.grams1,
    required this.model1,
    required this.support1,
    this.brim1 = 0,
    required this.meters,
    required this.hours,
    required this.cost,
    this.estimateGrams,
  });
}

class _FileSettingsChoice {
  final bool apply;
  final bool always;

  const _FileSettingsChoice(this.apply, this.always);
}

class _FileSettingsDialog extends StatefulWidget {
  final SlicerProject project;

  const _FileSettingsDialog({required this.project});

  @override
  State<_FileSettingsDialog> createState() => _FileSettingsDialogState();
}

class _FileSettingsDialogState extends State<_FileSettingsDialog> {
  bool _always = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.project;
    return AlertDialog(
      title: Text('Налаштування з ${p.app}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Файл містить параметри друку. Застосувати їх для розрахунку?'),
            const SizedBox(height: 10),
            for (final line in p.describe())
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('• $line', style: theme.textTheme.bodyMedium),
              ),
            if (p.isSliced) ...[
              const SizedBox(height: 10),
              Text(
                'Файл нарізаний: вага й час слайсера (${fmtGrams(p.grams)}, ${formatDuration(p.seconds / 3600)}) '
                'буде використано для ціни.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 6),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _always,
              onChanged: (v) => setState(() => _always = v ?? false),
              title: const Text('Завжди застосовувати без питання'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _FileSettingsChoice(false, false)),
          child: const Text('Залишити мої'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _FileSettingsChoice(true, _always)),
          child: const Text('Застосувати'),
        ),
      ],
    );
  }
}

/// Weight (g) and time (h) of one copy as shown by the user's slicer.
class _CalibrateDialog extends StatefulWidget {
  final double estimateGrams;
  final double estimateHours;

  const _CalibrateDialog({required this.estimateGrams, required this.estimateHours});

  @override
  State<_CalibrateDialog> createState() => _CalibrateDialogState();
}

class _CalibrateDialogState extends State<_CalibrateDialog> {
  final _g = TextEditingController();
  final _h = TextEditingController();
  final _m = TextEditingController();

  @override
  void dispose() {
    _g.dispose();
    _h.dispose();
    _m.dispose();
    super.dispose();
  }

  void _save() {
    final g = double.tryParse(_g.text.replaceAll(',', '.').trim());
    final h = int.tryParse(_h.text.trim()) ?? 0;
    final m = int.tryParse(_m.text.trim()) ?? 0;
    final hours = h + m / 60.0;
    Navigator.pop<(double?, double?)>(context, (g != null && g > 0 ? g : null, hours > 0 ? hours : null));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Підігнати під слайсер'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Наріжте цю модель у своєму слайсері з тими самими налаштуваннями й введіть його цифри '
            'для однієї копії. Додаток запам\'ятає поправку й застосовуватиме до всіх моделей. '
            'Що більше моделей підженете, то точніше.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _g,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Вага у слайсері, г',
              helperText: 'зараз у нас: ${fmtGrams(widget.estimateGrams)}',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Text('Час у слайсері', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _h,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'год', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _m,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'хв', border: OutlineInputBorder()),
                onSubmitted: (_) => _save(),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text('зараз у нас: ${formatDuration(widget.estimateHours)} (можна залишити порожнім)', style: theme.textTheme.bodySmall),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(onPressed: _save, child: const Text('Зберегти')),
      ],
    );
  }
}

/// Uniform scale by a target size on any axis, or to fit the bed.
class _ScaleDialog extends StatefulWidget {
  final (double, double, double) sizes; // at 100 %
  final double scalePercent;
  final (double, double, double) bed;

  const _ScaleDialog({required this.sizes, required this.scalePercent, required this.bed});

  @override
  State<_ScaleDialog> createState() => _ScaleDialogState();
}

class _ScaleDialogState extends State<_ScaleDialog> {
  late double _scale = widget.scalePercent;
  final _c = [TextEditingController(), TextEditingController(), TextEditingController()];
  final _p = TextEditingController();

  List<double> get _base => [widget.sizes.$1, widget.sizes.$2, widget.sizes.$3];

  @override
  void initState() {
    super.initState();
    _fill(except: -1);
  }

  void _fill({required int except}) {
    for (int i = 0; i < 3; i++) {
      if (i != except) _c[i].text = fmtNum(_base[i] * _scale / 100, 2);
    }
    if (except != 3) _p.text = fmtNum(_scale, 1);
  }

  void _fromAxis(int i, String t) {
    final v = double.tryParse(t.replaceAll(',', '.').trim());
    if (v == null || v <= 0 || _base[i] <= 0) return;
    setState(() => _scale = v / _base[i] * 100);
    _fill(except: i);
  }

  void _fromPercent(String t) {
    final v = double.tryParse(t.replaceAll(',', '.').trim());
    if (v == null || v <= 0) return;
    setState(() => _scale = v);
    _fill(except: 3);
  }

  void _fitBed() {
    final b = [widget.bed.$1 * 0.95, widget.bed.$2 * 0.95, widget.bed.$3 * 0.95];
    double k = double.infinity;
    for (int i = 0; i < 3; i++) {
      if (_base[i] > 0) k = math.min(k, b[i] / _base[i]);
    }
    // Also allow the footprint turned by 90°.
    if (_base[0] > 0 && _base[1] > 0 && _base[2] > 0) {
      final turned = math.min(math.min(b[0] / _base[1], b[1] / _base[0]), b[2] / _base[2]);
      if (turned > k) k = turned;
    }
    if (!k.isFinite) return;
    setState(() => _scale = (k * 1000).floorToDouble() / 10);
    _fill(except: -1);
  }

  @override
  void dispose() {
    for (final c in _c) {
      c.dispose();
    }
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget field(int i, String axis) => Expanded(
          child: TextField(
            controller: _c[i],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: '$axis, мм', border: const OutlineInputBorder(), isDense: true),
            onChanged: (t) => _fromAxis(i, t),
          ),
        );
    return AlertDialog(
      title: const Text('Розмір моделі'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Введіть потрібний розмір по будь-якій осі — інші зміняться пропорційно.'),
        const SizedBox(height: 14),
        Row(children: [field(0, 'X'), const SizedBox(width: 8), field(1, 'Y'), const SizedBox(width: 8), field(2, 'Z')]),
        const SizedBox(height: 12),
        TextField(
          controller: _p,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Масштаб', suffixText: '%', border: OutlineInputBorder(), isDense: true),
          onChanged: _fromPercent,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ActionChip(label: const Text('100%'), onPressed: () {
            setState(() => _scale = 100);
            _fill(except: -1);
          }),
          ActionChip(label: const Text('Вписати в стіл'), onPressed: _fitBed),
        ]),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Скасувати')),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_scale * 100).roundToDouble() / 100),
          child: const Text('Застосувати'),
        ),
      ],
    );
  }
}
