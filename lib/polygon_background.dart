import 'package:flutter/material.dart';

class PolygonBackground extends StatelessWidget {
  final Widget child;

  const PolygonBackground({
    Key? key,
    required this.child,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        // Solid dark gradient fallback — no asset required
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF0D1B2A), // deep navy
            Color(0xFF1B2838), // dark slate
            Color(0xFF0A0F1E), // near-black
          ],
          stops: [0.0, 0.5, 1.0],
        ),
      ),
      child: Stack(
        children: [
          // Optional decorative polygon shapes drawn with CustomPaint
          Positioned.fill(child: CustomPaint(painter: _PolygonPainter())),
          // Try loading the background image; if missing, show nothing (no crash)
          Positioned.fill(
            child: Image(
              image: const AssetImage('assets/background.jpg'),
              fit: BoxFit.cover,
              color: Colors.black.withOpacity(0.5),
              colorBlendMode: BlendMode.darken,
              // errorBuilder swallows the "Asset not found" error gracefully
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Draws a few translucent polygon shapes as a subtle background pattern
class _PolygonPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Top-right hexagon
    paint.color = Colors.white.withOpacity(0.04);
    _drawHexagon(canvas, paint, Offset(size.width * 0.85, size.height * 0.1),
        size.width * 0.18);

    // Center-left hexagon
    paint.color = Colors.blue.withOpacity(0.06);
    _drawHexagon(canvas, paint, Offset(size.width * 0.12, size.height * 0.45),
        size.width * 0.14);

    // Bottom-right hexagon
    paint.color = Colors.white.withOpacity(0.03);
    _drawHexagon(canvas, paint, Offset(size.width * 0.78, size.height * 0.82),
        size.width * 0.22);

    // Diagonal line accents
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = Colors.white.withOpacity(0.05);

    for (int i = 0; i < 5; i++) {
      final y = size.height * (0.1 + i * 0.2);
      canvas.drawLine(Offset(0, y), Offset(size.width * 0.3, y + 60), paint);
    }
  }

  void _drawHexagon(
      Canvas canvas, Paint paint, Offset center, double radius) {
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (i * 60 - 30) * (3.14159 / 180);
      final x = center.dx + radius * cos(angle);
      final y = center.dy + radius * sin(angle);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  double cos(double radians) => _cos(radians);
  double sin(double radians) => _sin(radians);

  // Simple Taylor series approximation (avoids dart:math import issues)
  double _cos(double x) {
    x = x % (2 * 3.14159265);
    double result = 1;
    double term = 1;
    for (int i = 1; i <= 6; i++) {
      term *= -x * x / ((2 * i - 1) * (2 * i));
      result += term;
    }
    return result;
  }

  double _sin(double x) {
    x = x % (2 * 3.14159265);
    double result = x;
    double term = x;
    for (int i = 1; i <= 6; i++) {
      term *= -x * x / ((2 * i) * (2 * i + 1));
      result += term;
    }
    return result;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}