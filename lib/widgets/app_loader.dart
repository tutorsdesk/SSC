import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_logo.dart';
import 'motion_policy.dart';

/// One calm, glossy loading screen shared by app start-up and the workspace
/// splash. A soft gradient orb with a slow orbiting highlight frames the logo;
/// reduced motion keeps the same composition still.
class AppLoader extends StatefulWidget {
  final String? message;
  const AppLoader({super.key, this.message});

  @override
  State<AppLoader> createState() => _AppLoaderState();
}

class _AppLoaderState extends State<AppLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MotionPolicy.reduce(context);
    if (still) _spin.stop();
    if (!still && !_spin.isAnimating) _spin.repeat();

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 132,
              height: 132,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 132,
                    height: 132,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          Colors.white,
                          const Color(0xFFF1F1F1),
                          Colors.white.withOpacity(0),
                        ],
                        stops: const [0.0, 0.7, 1.0],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _spin,
                    builder: (context, _) => Transform.rotate(
                      angle: _spin.value * 2 * math.pi,
                      child: CustomPaint(
                        size: const Size(124, 124),
                        painter: _OrbitPainter(still ? 0 : 1),
                      ),
                    ),
                  ),
                  const AppLogo(size: 60),
                ],
              ),
            ),
            const SizedBox(height: 26),
            const Text(
              'Tutor’s Desk',
              style: TextStyle(
                color: Colors.black,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.message ?? 'Getting your workspace ready…',
              style: const TextStyle(color: Colors.grey, fontSize: 13.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin ring with a bright glossy arc that orbits the logo.
class _OrbitPainter extends CustomPainter {
  final double strength;
  const _OrbitPainter(this.strength);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.black.withOpacity(0.06);
    canvas.drawCircle(rect.center, size.width / 2 - 1, ring);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3
      ..shader = SweepGradient(
        colors: [
          Colors.black.withOpacity(0),
          Colors.black.withOpacity(0.15 * strength),
          Colors.black.withOpacity(0.85),
        ],
        stops: const [0.0, 0.6, 1.0],
      ).createShader(rect);
    canvas.drawArc(
      rect.deflate(1.5),
      -math.pi / 2,
      math.pi * 0.9,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter old) => old.strength != strength;
}
