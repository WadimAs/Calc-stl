import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal PDF writer: puts a raster picture (e.g. the quote card) on A4
/// pages. A tall picture is split over several pages.
class PdfImage {
  static const double _pageW = 595.28, _pageH = 841.89, _margin = 36;

  /// [rgba] is raw RGBA (as from `ui.Image.toByteData(rawRgba)`).
  static Uint8List build(Uint8List rgba, int width, int height, {String title = 'Документ'}) { // no-tr
    // RGBA over white → RGB, then Flate.
    final rgb = Uint8List(width * height * 3);
    for (int i = 0, j = 0; i + 3 < rgba.length && j + 2 < rgb.length; i += 4, j += 3) {
      final a = rgba[i + 3];
      if (a == 255) {
        rgb[j] = rgba[i];
        rgb[j + 1] = rgba[i + 1];
        rgb[j + 2] = rgba[i + 2];
      } else {
        rgb[j] = (rgba[i] * a + 255 * (255 - a)) ~/ 255;
        rgb[j + 1] = (rgba[i + 1] * a + 255 * (255 - a)) ~/ 255;
        rgb[j + 2] = (rgba[i + 2] * a + 255 * (255 - a)) ~/ 255;
      }
    }
    final data = Uint8List.fromList(ZLibCodec(level: 6).encode(rgb));

    final drawW = _pageW - 2 * _margin;
    final scale = drawW / width;
    final drawH = height * scale;
    final usableH = _pageH - 2 * _margin;
    final pages = (drawH / usableH).ceil().clamp(1, 50).toInt();

    final out = BytesBuilder();
    final offsets = <int>[];
    void raw(String s) => out.add(latin1.encode(s));
    void obj(int n, String body, [Uint8List? stream]) {
      offsets.add(out.length);
      raw('$n 0 obj\n$body');
      if (stream != null) {
        raw('\nstream\n');
        out.add(stream);
        raw('\nendstream');
      }
      raw('\nendobj\n');
    }

    // Objects: 1 catalog, 2 pages, 3 image, 4 info, then (page, content) pairs.
    raw('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n');
    final kids = [for (int p = 0; p < pages; p++) '${5 + p * 2} 0 R'].join(' ');
    obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
    obj(2, '<< /Type /Pages /Kids [$kids] /Count $pages >>');
    obj(
      3,
      '<< /Type /XObject /Subtype /Image /Width $width /Height $height /ColorSpace /DeviceRGB '
      '/BitsPerComponent 8 /Filter /FlateDecode /Length ${data.length} >>',
      data,
    );
    obj(4, '<< /Title ${_pdfString(title)} /Producer (STL Vaga) >>');
    for (int p = 0; p < pages; p++) {
      // The picture's top on this page sits p*usableH above the page top.
      final top = _pageH - _margin + p * usableH;
      final y = top - drawH;
      final clipH = p == pages - 1 ? drawH - p * usableH : usableH;
      final content = latin1.encode('q ${_n(_margin)} ${_n(_pageH - _margin - clipH)} ${_n(drawW)} ${_n(clipH)} re W n '
          '${_n(drawW)} 0 0 ${_n(drawH)} ${_n(_margin)} ${_n(y)} cm /Im1 Do Q\n');
      obj(
        5 + p * 2,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${_n(_pageW)} ${_n(_pageH)}] '
        '/Resources << /XObject << /Im1 3 0 R >> >> /Contents ${6 + p * 2} 0 R >>',
      );
      obj(6 + p * 2, '<< /Length ${content.length} >>', Uint8List.fromList(content));
    }
    final xref = out.length;
    final count = offsets.length + 1;
    raw('xref\n0 $count\n0000000000 65535 f \n');
    for (final o in offsets) {
      raw('${o.toString().padLeft(10, '0')} 00000 n \n');
    }
    raw('trailer\n<< /Size $count /Root 1 0 R /Info 4 0 R >>\nstartxref\n$xref\n%%EOF\n');
    return out.toBytes();
  }

  static String _n(double v) => v.toStringAsFixed(2);

  /// UTF-16BE hex string so Cyrillic titles work.
  static String _pdfString(String s) {
    final b = StringBuffer('<FEFF');
    for (final c in s.codeUnits) {
      b.write(c.toRadixString(16).padLeft(4, '0').toUpperCase());
    }
    b.write('>');
    return b.toString();
  }
}
