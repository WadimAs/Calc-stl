import 'dart:io';

import 'package:flutter/material.dart';

import '../data/photos.dart';
import '../platform/files.dart';

/// Asks camera or gallery and stores the photo; returns its path.
Future<String?> addPhoto(BuildContext context) async {
  final how = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.photo_camera_outlined),
          title: const Text('Зробити фото'),
          onTap: () => Navigator.pop(ctx, 'camera'),
        ),
        ListTile(
          leading: const Icon(Icons.photo_library_outlined),
          title: const Text('З галереї'),
          onTap: () => Navigator.pop(ctx, 'gallery'),
        ),
      ]),
    ),
  );
  if (how == null) return null;
  try {
    final bytes = how == 'camera' ? await PlatformFiles.takePhoto() : await PlatformFiles.pickImage();
    if (bytes == null) return null;
    return await Photos.save(bytes);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не вдалося додати фото: $e')));
    }
    return null;
  }
}

Future<void> sharePhoto(String path) async {
  final f = File(path);
  if (!await f.exists()) return;
  await PlatformFiles.shareFile('foto.jpg', 'image/jpeg', await f.readAsBytes());
}

/// Horizontal row of photos with an "add" tile.
class PhotoStrip extends StatelessWidget {
  final List<String> photos;
  final VoidCallback onAdd;
  final void Function(int index) onOpen;
  final double size;

  const PhotoStrip({super.key, required this.photos, required this.onAdd, required this.onOpen, this.size = 84});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: size,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (int i = 0; i < photos.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onOpen(i),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(
                    File(photos[i]),
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    cacheWidth: (size * 3).round(),
                    errorBuilder: (_, __, ___) => Container(
                      width: size,
                      height: size,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onAdd,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.add_a_photo_outlined, color: theme.colorScheme.primary),
                const SizedBox(height: 4),
                Text('Фото', style: theme.textTheme.labelSmall),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen photos with zoom, share and delete.
class PhotoViewer extends StatefulWidget {
  final List<String> photos;
  final int initial;

  /// Called with the path to delete; the viewer closes afterwards.
  final Future<void> Function(String path)? onDelete;

  const PhotoViewer({super.key, required this.photos, this.initial = 0, this.onDelete});

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _pages = PageController(initialPage: widget.initial);
  late int _i = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final path = widget.photos[_i];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Видалити фото?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Скасувати')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Видалити')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onDelete?.call(path);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_i + 1} / ${widget.photos.length}'),
        actions: [
          IconButton(
            tooltip: 'Надіслати',
            onPressed: () => sharePhoto(widget.photos[_i]).catchError((Object _) {}),
            icon: const Icon(Icons.share_outlined),
          ),
          if (widget.onDelete != null)
            IconButton(tooltip: 'Видалити', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: PageView(
        controller: _pages,
        onPageChanged: (i) => setState(() => _i = i),
        children: [
          for (final p in widget.photos)
            InteractiveViewer(
              maxScale: 5,
              child: Center(child: Image.file(File(p), fit: BoxFit.contain)),
            ),
        ],
      ),
    );
  }
}
