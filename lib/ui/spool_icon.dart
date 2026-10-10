import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../spools/spools.dart';

enum SpoolLook { spool, refill, refillMounted }

SpoolLook spoolLookOf(Spool s) => !s.refill ? SpoolLook.spool : (s.onSpool ? SpoolLook.refillMounted : SpoolLook.refill);

/// A filament spool drawn in its colour; the wound filament shrinks as the
/// spool empties. A refill is a bare coil with ties, a mounted refill sits on
/// a reusable spool with open spokes.
class SpoolIcon extends StatelessWidget {
  final int color;
  final double fraction;
  final SpoolLook look;
  final double size;

  const SpoolIcon({super.key, required this.color, this.fraction = 1, this.look = SpoolLook.spool, this.size = 40});

  factory SpoolIcon.of(Spool s, {double size = 40}) =>
      SpoolIcon(color: s.colorArgb, fraction: s.fraction, look: spoolLookOf(s), size: size);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SpoolPainter(Color(color), fraction, look, dark, theme.colorScheme.surfaceContainerLow)),
    );
  }
}

class _SpoolPainter extends CustomPainter {
  final Color color;
  final double fraction;
  final SpoolLook look;
  final bool dark;
  final Color hole;

  _SpoolPainter(this.color, this.fraction, this.look, this.dark, this.hole);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final hub = r * 0.30;
    final rimInner = r * 0.86;
    final fill = look == SpoolLook.refill ? rimInner : hub + (rimInner - hub) * fraction.clamp(0.06, 1.0);

    // Filament colour with a slightly darker edge so white stays visible.
    final hsl = HSLColor.fromColor(color);
    final edge = hsl.withLightness((hsl.lightness * 0.72).clamp(0.0, 1.0)).toColor();
    final strand = hsl.withLightness((hsl.lightness * 0.85).clamp(0.0, 1.0)).toColor();
    final outline = dark ? Colors.white24 : Colors.black26;

    if (look == SpoolLook.spool) {
      // Solid flange of an ordinary spool.
      canvas.drawCircle(c, r, Paint()..color = dark ? const Color(0xFF3A3A3F) : const Color(0xFF4A4A50));
      canvas.drawCircle(c, rimInner, Paint()..color = dark ? const Color(0xFF26262A) : const Color(0xFF6E6E75));
    } else if (look == SpoolLook.refillMounted) {
      // Reusable spool behind the coil: light outer ring.
      canvas.drawCircle(c, r, Paint()..color = dark ? const Color(0xFF8F949B) : const Color(0xFFC3C8CF));
      canvas.drawCircle(c, rimInner, Paint()..color = hole);
    }

    // Wound filament.
    canvas.drawCircle(c, fill, Paint()..color = color);
    canvas.drawCircle(
        c,
        fill,
        Paint()
          ..color = edge
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, r * 0.06));
    // Winding lines.
    final lines = Paint()
      ..color = strand.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.6, r * 0.03);
    for (double rr = hub + (fill - hub) * 0.33; rr < fill - 1; rr += (fill - hub) * 0.33) {
      canvas.drawCircle(c, rr, lines);
    }

    if (look == SpoolLook.refillMounted) {
      // Its spokes lie over the filament (open sides of a reusable spool).
      final spoke = Paint()
        ..color = dark ? const Color(0xFF8F949B) : const Color(0xFFC3C8CF)
        ..strokeWidth = r * 0.16
        ..strokeCap = StrokeCap.round;
      for (int i = 0; i < 3; i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / 3;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * hub, c + d * rimInner, spoke);
      }
    }

    if (look == SpoolLook.refill) {
      // Cable ties holding the bare coil.
      final tie = Paint()
        ..color = dark ? Colors.white70 : Colors.black87
        ..strokeWidth = r * 0.12
        ..strokeCap = StrokeCap.butt;
      for (int i = 0; i < 3; i++) {
        final a = -math.pi / 2 + i * 2 * math.pi / 3;
        final d = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(c + d * (hub + 1), c + d * (fill + r * 0.05), tie);
      }
    }

    // Hub hole (a bare refill has no hub, just the empty middle).
    if (look != SpoolLook.refill) {
      final hubColor = look == SpoolLook.spool
          ? (dark ? const Color(0xFF3A3A3F) : const Color(0xFF4A4A50))
          : (dark ? const Color(0xFF9EA3AA) : const Color(0xFFB7BCC3));
      canvas.drawCircle(c, hub, Paint()..color = hubColor);
      canvas.drawCircle(
          c,
          r - 0.5,
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1);
    }
    canvas.drawCircle(c, hub * (look == SpoolLook.refill ? 0.95 : 0.55),
        Paint()..color = hole);
  }

  @override
  bool shouldRepaint(_SpoolPainter old) =>
      old.color != color || old.fraction != fraction || old.look != look || old.dark != dark || old.hole != hole;
}
