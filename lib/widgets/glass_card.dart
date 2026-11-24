import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/app_settings.dart';
import '../theme/app_theme.dart';
import 'animations.dart';
import 'motion_policy.dart';
import 'app_icon.dart';

/// Quiet white reference surface used for every panel in the tutor portal.
/// The rounded border keeps long-form content readable over the shared
/// solid white page without introducing a second visual language.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double radius;
  final Color? tint;
  final bool highlighted;
  final VoidCallback? onTap;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.margin,
    this.radius = 16,
    this.tint,
    this.highlighted = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final border =
        highlighted ? AppTheme.textDark.withOpacity(.45) : AppTheme.border;
    // No BackdropFilter here on purpose. The card fill is 88-94% opaque, so
    // the blur behind it was barely visible, but it is one of the most
    // expensive things Flutter can draw — and during a page transition two
    // screens' worth of them render at once, which is what made navigation
    // feel laggy.
    final body = ValueListenableBuilder<bool>(
      valueListenable: AppSettings.glassEffect,
      builder: (context, glass, _) => ValueListenableBuilder<double>(
        valueListenable: AppSettings.glassIntensity,
        builder: (context, intensity, __) {
          final reduce = MotionPolicy.reduce(context);
          final surface = glass
              ? _glassSurface(context, border, intensity)
              : _plainSurface(context, border);
          final content = AnimatedContainer(
            duration:
                reduce ? Duration.zero : MotionPolicy.duration(context, 240),
            curve: Curves.easeOut,
            padding: padding,
            decoration: surface,
            child: child,
          );
          // Blur only when glass is on: it is costly, so the plain card stays
          // cheap, and strength follows the intensity slider.
          final framed = glass && intensity > 0
              ? BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: 2 + 12 * intensity,
                    sigmaY: 2 + 12 * intensity,
                  ),
                  child: content,
                )
              : content;
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: RepaintBoundary(child: framed),
          );
        },
      ),
    );

    final wrapped = Padding(padding: margin ?? EdgeInsets.zero, child: body);
    if (onTap == null) return wrapped;
    return PressableScale(onTap: onTap, child: wrapped);
  }

  BoxDecoration _plainSurface(BuildContext context, Color border) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: tint ?? AppTheme.surface,
      border: Border.all(color: border, width: highlighted ? 1.3 : 1),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(.035),
          blurRadius: 8,
          offset: const Offset(0, 3),
        ),
      ],
    );
  }

  /// Glossy glass: a translucent fill with a bright top sheen, a light rim
  /// and a soft shadow. Strength follows the user's intensity setting.
  BoxDecoration _glassSurface(
    BuildContext context,
    Color border,
    double intensity,
  ) {
    final base = tint ?? Colors.white;
    final fillAlpha = (0.92 - 0.35 * intensity).clamp(0.5, 0.95);
    final sheen = 0.35 + 0.5 * intensity;
    return BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      color: base.withOpacity(fillAlpha),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withOpacity(sheen),
          Colors.white.withOpacity(0.0),
          Colors.black.withOpacity(0.02 * intensity),
        ],
        stops: const [0.0, 0.55, 1.0],
      ),
      border: Border.all(
        color: Colors.white.withOpacity(0.55 + 0.4 * intensity),
        width: highlighted ? 1.4 : 1.1,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05 + 0.08 * intensity),
          blurRadius: 10 + 14 * intensity,
          offset: Offset(0, 4 + 4 * intensity),
        ),
      ],
    );
  }
}

/// Section heading with a small brand rule — used to break long forms up.
class SectionTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Object? icon;

  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: subtitle == null ? 20 : 36,
            margin: const EdgeInsets.only(right: 10, top: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppTheme.textDark, AppTheme.muted],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (icon != null) ...[
                      AppIcon(icon!, size: 17, color: AppTheme.primary),
                      const SizedBox(width: 7),
                    ],
                    Flexible(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textDark,
                          letterSpacing: .2,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    subtitle!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: AppTheme.muted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small rounded status pill (PRO / DEMO / counts / hints).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final Object? icon;

  const StatusPill({
    super.key,
    required this.label,
    this.color = AppTheme.primary,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: MotionPolicy.duration(context, 220),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(.11),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withOpacity(.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            AppIcon(icon!, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline feedback banner (success / error / info) with an entrance animation.
class InfoBanner extends StatelessWidget {
  final String text;
  final Color color;
  final IconData icon;

  const InfoBanner({
    super.key,
    required this.text,
    required this.color,
    this.icon = PhosphorIcons.info,
  });

  factory InfoBanner.success(String text) => InfoBanner(
        text: text,
        color: AppTheme.success,
        icon: PhosphorIcons.checkCircle,
      );

  factory InfoBanner.error(String text) => InfoBanner(
        text: text,
        color: AppTheme.danger,
        icon: PhosphorIcons.warningCircle,
      );

  @override
  Widget build(BuildContext context) {
    return FadeSlideIn(
      offset: const Offset(0, 10),
      duration: MotionPolicy.duration(context, 320),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: color.withOpacity(.09),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withOpacity(.32)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 12.8, height: 1.5, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-screen friendly empty / hint state.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    return FadeSlideIn(
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
        child: Column(
          children: [
            Pulse(
              min: .95,
              max: 1.05,
              period: const Duration(milliseconds: 1900),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.primary.withOpacity(.10),
                  border: Border.all(color: AppTheme.primary.withOpacity(.35)),
                ),
                child: AppIcon(icon, size: 34, color: AppTheme.primary),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w800,
                color: AppTheme.textDark,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 7),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.8,
                  height: 1.55,
                  color: AppTheme.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Branded busy indicator used while papers/PDFs are generated.
class BusyIndicator extends StatelessWidget {
  final String message;
  const BusyIndicator({super.key, this.message = 'Working...'});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 34),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 74,
              height: 74,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const HaloRing(size: 74, strokeWidth: 2.4),
                  Pulse(
                    enabled: true,
                    min: .88,
                    max: 1.06,
                    period: const Duration(milliseconds: 1100),
                    child: const AppIcon(
                      PhosphorIcons.magicWand,
                      color: AppTheme.primary,
                      size: 26,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13.2,
                height: 1.5,
                color: AppTheme.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
