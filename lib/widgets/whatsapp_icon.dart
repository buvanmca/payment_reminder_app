import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Brand-recognisable WhatsApp logo rendered with CustomPaint so we don't
/// need to ship an extra asset or pull in font_awesome. The shape is the
/// stock WhatsApp speech-bubble with a white phone handset, painted at the
/// requested size.
class WhatsAppIcon extends StatelessWidget {
  const WhatsAppIcon({super.key, this.size = 24, this.color});
  final double size;
  final Color? color;

  static const Color brandGreen = Color(0xFF25D366);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _WhatsAppIconPainter(color: color ?? brandGreen),
      ),
    );
  }
}

class _WhatsAppIconPainter extends CustomPainter {
  _WhatsAppIconPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = math.min(size.width, size.height);
    final bg = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final bubbleCenter = Offset(s * 0.52, s * 0.48);
    final bubbleRadius = s * 0.46;
    canvas.drawCircle(bubbleCenter, bubbleRadius, bg);

    final tail = Path()
      ..moveTo(s * 0.20, s * 0.60)
      ..lineTo(s * 0.04, s * 0.96)
      ..lineTo(s * 0.44, s * 0.84)
      ..close();
    canvas.drawPath(tail, bg);

    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    canvas.save();
    canvas.translate(bubbleCenter.dx, bubbleCenter.dy);
    canvas.rotate(-math.pi / 8);

    final earpiece = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(-s * 0.14, -s * 0.12),
        width: s * 0.20,
        height: s * 0.20,
      ),
      Radius.circular(s * 0.06),
    );
    final mouthpiece = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(s * 0.14, s * 0.12),
        width: s * 0.20,
        height: s * 0.20,
      ),
      Radius.circular(s * 0.06),
    );
    canvas.drawRRect(earpiece, white);
    canvas.drawRRect(mouthpiece, white);

    final neck = Path()
      ..moveTo(-s * 0.10, -s * 0.04)
      ..lineTo(s * 0.04, -s * 0.18)
      ..lineTo(s * 0.18, -s * 0.04)
      ..lineTo(s * 0.04, s * 0.10)
      ..close();
    canvas.drawPath(neck, white);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WhatsAppIconPainter oldDelegate) =>
      oldDelegate.color != color;
}
