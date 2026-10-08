import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../history/history.dart';
import '../mesh/loader.dart';
import '../platform/files.dart';
import '../slicer/settings.dart';
import '../slicer/slice_runner.dart';
import '../slicer/slicer.dart';
import '../viewer/model_viewer.dart';
import 'history_page.dart';
import 'settings_sheet.dart';
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

  @override
  void initState() {
    super.initState();
    PlatformFiles.listen(_open);
    _init();
  }

  Future<void> _init() async {
    final s = await PlatformFiles.loadSettings();
    if (!mounted) return;
    setState(() => _settings = s);
    final f = await PlatformFiles.initialFile();
    if (f != null && mounted) await _open(f);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _job?.cancel();
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
      final m = await loadModel(f.name, f.bytes);
      if (!mounted) return;
      _job?.cancel();
      _job = null;
      setState(() {
        _model = m;
        _loading = false;
        _result = null;
        _progress = null;
        _sliceError = null;
      });
      _slice();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = isSupportedFile(f.name)
            ? 'Не вдалося прочитати «${f.name}»:\n$e'
            : 'Файл «${f.name}» не схожий на STL або 3MF.';
      });
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

  Future<void> _slice() async {
    final model = _model;
    if (model == null) return;
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
      });
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

  /// Snapshot of the current calculation as a history entry.
  HistoryEntry? _buildEntry({String note = '', String? thumbPath, String? id}) {
    final m = _model;
    final r = _result;
    if (m == null || r == null) return null;
    final s = _settings;
    final grams = r.grams(s.density, copies: s.copies);
    final cost = CostBreakdown.of(grams, s);
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
      modelGrams: r.modelGrams(s.density),
      supportGrams: r.supportGrams(s.density),
      filamentMeters: r.filamentMeters(s.filamentDiameter, copies: s.copies),
      materialCost: cost.material,
      markupPercent: s.markupPercent,
      extraCost: s.extraCost,
      totalCost: cost.total,
      sizeX: r.sizeX,
      sizeY: r.sizeY,
      sizeZ: r.sizeZ,
      note: note,
      thumbPath: thumbPath,
    );
  }

  Future<Uint8List?> _captureThumb() async {
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
          IconButton(tooltip: 'Історія', onPressed: _openHistory, icon: const Icon(Icons.history)),
          IconButton(tooltip: 'Налаштування', onPressed: _openSettings, icon: const Icon(Icons.tune)),
        ],
      ),
      body: _loading
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
                  final viewer = _viewer(model);
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
                }),
    );
  }

  Widget _viewer(LoadedModel m) {
    final theme = Theme.of(context);
    final k = _settings.scalePercent / 100;
    final b = m.bounds;
    String mm(double v) => fmtNum(v * k, 1);
    return Stack(children: [
      Positioned.fill(
        child: RepaintBoundary(key: _viewerKey, child: ModelViewer(model: m, color: _modelColor)),
      ),
      Positioned(
        left: 12,
        bottom: 10,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text('${mm(b.sizeX)} × ${mm(b.sizeY)} × ${mm(b.sizeZ)} мм', style: theme.textTheme.labelMedium),
        ),
      ),
      if (_loadError != null)
        Positioned(
          left: 12,
          right: 12,
          top: 10,
          child: Material(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(_loadError!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
            ),
          ),
        ),
    ]);
  }

  Widget _panel(LoadedModel m) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _resultCard(),
        const SizedBox(height: 8),
        _costCard(),
        const SizedBox(height: 8),
        _quickSettings(),
        const SizedBox(height: 8),
        _modelInfo(m),
      ],
    );
  }

  Widget _resultCard() {
    final theme = Theme.of(context);
    final r = _result;
    final s = _settings;
    final busy = _progress != null;
    final onCard = theme.colorScheme.onPrimaryContainer;
    final grams = r?.grams(s.density, copies: s.copies) ?? 0;
    final cost = CostBreakdown.of(grams, s);
    final costParts = <String>[
      'пластик ${fmtMoney(cost.material)}',
      if (cost.markup != 0) 'націнка ${fmtMoney(cost.markup)}',
      if (cost.extra != 0) 'доплата ${fmtMoney(cost.extra)}',
    ];
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
            if (r != null)
              AnimatedOpacity(
                opacity: busy ? 0.4 : 1,
                duration: const Duration(milliseconds: 200),
                child: Text(
                  fmtGrams(grams),
                  style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w700, color: onCard),
                ),
              )
            else if (!busy && _sliceError == null)
              const Text('—'),
            if (busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 4),
              Text(
                '${s.supportsEnabled ? 'Нарізання і підтримки' : 'Нарізання'}… ${((_progress ?? 0) * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_sliceError != null) ...[
              const SizedBox(height: 8),
              Text(_sliceError!, style: TextStyle(color: theme.colorScheme.error)),
              TextButton(onPressed: _slice, child: const Text('Спробувати ще раз')),
            ],
            if (r != null) ...[
              if (s.supportsEnabled)
                Text(
                  'модель ${fmtGrams(r.modelGrams(s.density) * s.copies)} · '
                  'підтримки ${fmtGrams(r.supportGrams(s.density) * s.copies)}',
                  style: theme.textTheme.bodyMedium,
                ),
              if (s.copies > 1)
                Text('${s.copies} шт. · одна: ${fmtGrams(r.grams(s.density))}', style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Stat('філамент', '${fmtNum(r.filamentMeters(s.filamentDiameter, copies: s.copies), 2)} м'),
                  Stat('об\'єм', '${fmtNum(r.totalVolumeMm3 * s.copies / 1000, 1)} см³'),
                  Stat('шарів', '${r.layers}'),
                ],
              ),
              Divider(height: 28, color: onCard.withValues(alpha: 0.2)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Вартість', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  Text(
                    fmtMoney(cost.total),
                    style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: onCard),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${costParts.join(' + ')} · ${fmtNum(s.pricePerKg, 0)} $currency/кг',
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: busy ? null : _share,
                    icon: const Icon(Icons.share_outlined),
                    label: const Text('Поділитися'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: busy || _saving ? null : _saveToHistory,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Зберегти'),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Суцільна модель (100%): ${fmtGrams(r.solidGrams(s.density))}',
                style: theme.textTheme.bodySmall,
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
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
                  label: 'Націнка',
                  suffix: '%',
                  value: s.markupPercent,
                  onChanged: (v) => _updateSettings(_settings.copyWith(markupPercent: v)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NumberField(
                  label: 'Доплата',
                  suffix: currency,
                  value: s.extraCost,
                  onChanged: (v) => _updateSettings(_settings.copyWith(extraCost: v)),
                ),
              ),
            ]),
          ],
        ),
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
              min: 1,
              max: 15,
              step: 1,
              onChanged: (v) => _updateSettings(s.copyWith(walls: v.round())),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Підтримки'),
              subtitle: s.supportsEnabled
                  ? Text('${s.supportPlateOnly ? 'лише від столу' : 'скрізь'} · '
                      '${fmtNum(s.supportAngle, 0)}° · ${fmtNum(s.supportDensity, 0)}%')
                  : null,
              value: s.supportsEnabled,
              onChanged: (v) => _updateSettings(s.copyWith(supportsEnabled: v)),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Модель', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            row('Трикутників', '${m.mesh.triangleCount}'),
            row('Розмір X × Y × Z',
                '${fmtNum(b.sizeX * k, 1)} × ${fmtNum(b.sizeY * k, 1)} × ${fmtNum(b.sizeZ * k, 1)} мм'),
            row('Об\'єм моделі', '${fmtNum(m.volume * k * k * k / 1000, 2)} см³'),
            row('Площа поверхні', '${fmtNum(m.area * k * k / 100, 1)} см²'),
            if (_settings.scalePercent != 100) row('Масштаб', '${fmtNum(_settings.scalePercent, 0)}%'),
            if (_result != null) row('Час розрахунку', '${fmtNum(_result!.millis / 1000, 1)} с'),
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
            Icon(Icons.view_in_ar_outlined, size: 96, color: theme.colorScheme.primary),
            const SizedBox(height: 16),
            Text('Відкрийте STL або 3MF', style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
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
