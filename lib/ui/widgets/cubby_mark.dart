import 'package:flutter/material.dart';

import '../theme/cubby_theme.dart';

/// 4-스파이크 + cubby box 브랜드 마크. screens-1.jsx CubbyMark 기준.
class CubbyMark extends StatelessWidget {
  const CubbyMark({super.key, this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cubby = context.cubby;
    return CustomPaint(
      size: Size.square(size),
      painter: _CubbyMarkPainter(
        spike: scheme.primary,
        ink: scheme.onSurface,
        canvas: cubby.canvas,
      ),
    );
  }
}

class _CubbyMarkPainter extends CustomPainter {
  _CubbyMarkPainter({
    required this.spike,
    required this.ink,
    required this.canvas,
  });

  final Color spike;
  final Color ink;
  final Color canvas;

  @override
  void paint(Canvas c, Size size) {
    final s = size.width / 24.0;
    // spike (path)
    final spikePath = Path()
      ..moveTo(12 * s, 2 * s)
      ..lineTo(13.6 * s, 9.2 * s)
      ..lineTo(21 * s, 10.6 * s)
      ..lineTo(13.6 * s, 12.2 * s)
      ..lineTo(12 * s, 19.6 * s)
      ..lineTo(10.4 * s, 12.2 * s)
      ..lineTo(3 * s, 10.6 * s)
      ..lineTo(10.4 * s, 9.2 * s)
      ..close();
    c.drawPath(spikePath, Paint()..color = spike);

    // cubby box
    final box = RRect.fromRectAndRadius(
      Rect.fromLTWH(4 * s, 14.5 * s, 16 * s, 6 * s),
      Radius.circular(2 * s),
    );
    c.drawRRect(box, Paint()..color = canvas);
    c.drawRRect(
      box,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4 * s,
    );
  }

  @override
  bool shouldRepaint(covariant _CubbyMarkPainter old) =>
      old.spike != spike || old.ink != ink || old.canvas != canvas;
}
