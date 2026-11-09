import 'package:flutter_test/flutter_test.dart';

import 'package:tutors_desk/models/subscription_entitlement.dart';

void main() {
  test('renewal warning is limited to the final seven active days', () {
    final now = DateTime.utc(2026, 10, 5, 12);
    final dueSoon = SubscriptionEntitlement.defaults(
      SubscriptionPlan.pro,
      expiresAt: now.add(const Duration(days: 6, hours: 2)),
    );
    final notYetDue = SubscriptionEntitlement.defaults(
      SubscriptionPlan.pro,
      expiresAt: now.add(const Duration(days: 7, minutes: 1)),
    );
    final expired = SubscriptionEntitlement.defaults(
      SubscriptionPlan.pro,
      expiresAt: now.subtract(const Duration(minutes: 1)),
    );

    expect(dueSoon.renewalDueSoon(now: now), isTrue);
    expect(dueSoon.renewalDaysRemaining(now: now), 7);
    expect(notYetDue.renewalDueSoon(now: now), isFalse);
    expect(expired.renewalDueSoon(now: now), isFalse);
    expect(SubscriptionEntitlement.free().renewalDueSoon(now: now), isFalse);
  });

  group('SubscriptionEntitlement matrix', () {
    test('Free is limited, watermarked, and has no premium access', () {
      final e = SubscriptionEntitlement.defaults(SubscriptionPlan.free);
      expect(e.subjectLimit, SubscriptionEntitlement.freeSubjectLimit);
      expect(e.monthlyPaperLimit, 2);
      expect(e.noWatermark, isFalse);
      expect(e.aiDailyLimit, 0);
      expect(e.canUse(PremiumFeature.aiAssistant), isFalse);
      expect(e.canUse(PremiumFeature.omrScanner), isFalse);
    });

    test('Basic allows three subjects but no AI or OMR', () {
      final e = SubscriptionEntitlement.defaults(SubscriptionPlan.basic);
      expect(e.subjectLimit, 3);
      expect(e.noWatermark, isFalse);
      expect(e.aiAssistant, isFalse);
      expect(e.aiDailyLimit, 0);
      expect(e.omrScanner, isFalse);
    });

    test(
      'Pro allows five subjects, watermark-free export, and 20 AI requests',
      () {
        final e = SubscriptionEntitlement.defaults(SubscriptionPlan.pro);
        expect(e.subjectLimit, 5);
        expect(e.noWatermark, isTrue);
        expect(e.canUse(PremiumFeature.aiAssistant), isTrue);
        expect(e.aiDailyLimit, 20);
        expect(e.canUse(PremiumFeature.omrScanner), isFalse);
      },
    );

    test('the paper editor is available on Professional only', () {
      expect(
        SubscriptionEntitlement.free().canUse(PremiumFeature.paperEditor),
        isFalse,
      );
      expect(
        SubscriptionEntitlement.defaults(SubscriptionPlan.basic)
            .canUse(PremiumFeature.paperEditor),
        isFalse,
      );
      expect(
        SubscriptionEntitlement.defaults(SubscriptionPlan.pro)
            .canUse(PremiumFeature.paperEditor),
        isFalse,
      );
      final pro = SubscriptionEntitlement.defaults(
        SubscriptionPlan.professional,
      );
      expect(pro.canUse(PremiumFeature.paperEditor), isTrue);
      expect(
        pro.reasonFor(PremiumFeature.paperEditor),
        isNull,
      );
      expect(
        SubscriptionEntitlement.defaults(SubscriptionPlan.pro)
            .reasonFor(PremiumFeature.paperEditor),
        UpgradeReason.paperEditor,
      );
      final expired = SubscriptionEntitlement.defaults(
        SubscriptionPlan.professional,
        status: SubscriptionStatus.expired,
      );
      expect(expired.canUse(PremiumFeature.paperEditor), isFalse);
    });

    test('Professional has unlimited subjects and OMR', () {
      final e = SubscriptionEntitlement.defaults(SubscriptionPlan.professional);
      expect(e.subjectLimit, isNull);
      expect(e.noWatermark, isTrue);
      expect(e.aiDailyLimit, 50);
      expect(e.canUse(PremiumFeature.omrScanner), isTrue);
    });

    test(
      'expired, cancelled, and pending paid states immediately become Free',
      () {
        final expired = SubscriptionEntitlement.defaults(
          SubscriptionPlan.professional,
          expiresAt: DateTime.now().toUtc().subtract(
                const Duration(minutes: 1),
              ),
        );
        expect(expired.isExpired, isTrue);
        expect(expired.effective.plan, SubscriptionPlan.free);

        for (final status in [
          SubscriptionStatus.cancelled,
          SubscriptionStatus.pending,
          SubscriptionStatus.failed,
          SubscriptionStatus.expired,
        ]) {
          final e = SubscriptionEntitlement.defaults(
            SubscriptionPlan.pro,
            status: status,
            expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
          );
          expect(e.isActive, isFalse, reason: status.name);
          expect(e.effective.plan, SubscriptionPlan.free, reason: status.name);
          expect(e.effective.noWatermark, isFalse, reason: status.name);
        }
      },
    );

    test('legacy plan values map safely to Pro', () {
      expect(subscriptionPlanFromString('monthly'), SubscriptionPlan.pro);
      expect(subscriptionPlanFromString('yearly'), SubscriptionPlan.pro);
      expect(subscriptionPlanFromString('lifetime'), SubscriptionPlan.pro);
      expect(
        subscriptionPlanFromString('professional'),
        SubscriptionPlan.professional,
      );
      expect(subscriptionPlanFromString('unknown'), SubscriptionPlan.free);
    });

    test('server plan rows override configurable limits', () {
      final e = SubscriptionEntitlement.fromPlanRow({
        'id': 'pro',
        'subject_limit': 7,
        'no_watermark': true,
        'ai_assistant': true,
        'ai_daily_limit': 31,
        'omr_scanner': false,
      });
      expect(e.subjectLimit, 7);
      expect(e.aiDailyLimit, 31);
    });
  });
}
