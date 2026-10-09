import 'json_store.dart';

/// Shared CRUD for lists of JSON records with an "id".
class RecordStore<T> {
  final String file;
  final T? Function(Object?) fromJson;
  final Map<String, dynamic> Function(T) toJson;
  final String Function(T) idOf;

  const RecordStore(this.file, this.fromJson, this.toJson, this.idOf);

  Future<List<T>> load() async {
    final raw = await JsonStore.read(file);
    if (raw is! List) return [];
    return raw.map(fromJson).whereType<T>().toList();
  }

  Future<void> saveAll(List<T> list) => JsonStore.write(file, [for (final e in list) toJson(e)]);

  Future<List<T>> upsert(T item, {bool atStart = true}) async {
    final list = await load();
    final i = list.indexWhere((x) => idOf(x) == idOf(item));
    if (i >= 0) {
      list[i] = item;
    } else if (atStart) {
      list.insert(0, item);
    } else {
      list.add(item);
    }
    await saveAll(list);
    return list;
  }

  Future<List<T>> remove(String id) async {
    final list = await load()
      ..removeWhere((x) => idOf(x) == id);
    await saveAll(list);
    return list;
  }
}

String newId() => DateTime.now().microsecondsSinceEpoch.toString();
