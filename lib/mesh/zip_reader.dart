import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';
import 'dart:convert';

class _Entry {
  final String name;
  final int method;
  final int compSize;
  final int localOffset;

  _Entry(this.name, this.method, this.compSize, this.localOffset);
}

/// Minimal ZIP reader (stored + deflate, ZIP64 aware) — enough for 3MF.
class ZipReader {
  final Uint8List bytes;
  final ByteData _bd;
  final Map<String, _Entry> _entries = {};

  ZipReader(this.bytes) : _bd = ByteData.sublistView(bytes) {
    _readCentralDirectory();
  }

  Iterable<String> get names => _entries.keys;

  bool contains(String name) => _entries.containsKey(name);

  int _u16(int o) => _bd.getUint16(o, Endian.little);
  int _u32(int o) => _bd.getUint32(o, Endian.little);
  int _u64(int o) => _u32(o) + _u32(o + 4) * 0x100000000;

  void _readCentralDirectory() {
    if (bytes.length < 22) throw const FormatException('Файл не є ZIP/3MF архівом');
    int eocd = -1;
    final stop = bytes.length - 22 - 65535 < 0 ? 0 : bytes.length - 22 - 65535;
    for (int i = bytes.length - 22; i >= stop; i--) {
      if (_u32(i) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FormatException('Пошкоджений 3MF: немає каталогу ZIP');

    int count = _u16(eocd + 10);
    int cdOffset = _u32(eocd + 16);

    if ((cdOffset == 0xFFFFFFFF || count == 0xFFFF) && eocd >= 20 && _u32(eocd - 20) == 0x07064b50) {
      final z64 = _u64(eocd - 20 + 8);
      if (z64 >= 0 && z64 + 56 <= bytes.length && _u32(z64) == 0x06064b50) {
        count = _u64(z64 + 32);
        cdOffset = _u64(z64 + 48);
      }
    }

    int p = cdOffset;
    for (int k = 0; k < count; k++) {
      if (p + 46 > bytes.length || _u32(p) != 0x02014b50) break;
      final method = _u16(p + 10);
      int compSize = _u32(p + 20);
      int uncompSize = _u32(p + 24);
      final nameLen = _u16(p + 28);
      final extraLen = _u16(p + 30);
      final commentLen = _u16(p + 32);
      int localOffset = _u32(p + 42);
      final name = utf8.decode(Uint8List.sublistView(bytes, p + 46, p + 46 + nameLen), allowMalformed: true);

      // ZIP64 extended information.
      int e = p + 46 + nameLen;
      final eEnd = e + extraLen;
      while (e + 4 <= eEnd) {
        final id = _u16(e);
        final size = _u16(e + 2);
        if (id == 0x0001) {
          int q = e + 4;
          if (uncompSize == 0xFFFFFFFF) {
            uncompSize = _u64(q);
            q += 8;
          }
          if (compSize == 0xFFFFFFFF) {
            compSize = _u64(q);
            q += 8;
          }
          if (localOffset == 0xFFFFFFFF) {
            localOffset = _u64(q);
          }
        }
        e += 4 + size;
      }

      _entries[name] = _Entry(name, method, compSize, localOffset);
      p += 46 + nameLen + extraLen + commentLen;
    }
  }

  Uint8List read(String name) {
    final e = _entries[name];
    if (e == null) throw FormatException('У 3MF немає файлу $name');
    final lo = e.localOffset;
    if (_u32(lo) != 0x04034b50) throw FormatException('Пошкоджений запис ZIP: $name');
    final start = lo + 30 + _u16(lo + 26) + _u16(lo + 28);
    final data = Uint8List.sublistView(bytes, start, start + e.compSize);
    switch (e.method) {
      case 0:
        return Uint8List.fromList(data);
      case 8:
        final out = ZLibDecoder(raw: true).convert(data);
        return out is Uint8List ? out : Uint8List.fromList(out);
      default:
        throw FormatException('Непідтримуване стиснення ZIP (${e.method})');
    }
  }
}
