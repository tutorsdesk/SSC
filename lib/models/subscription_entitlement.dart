/// Stable subscription identifiers shared by the app, database, and payment API.
enum SubscriptionPlan { free, basic, pro, professional }

int? _asInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');

SubscriptionPlan subscriptionPlanFromString(String? value) {
  switch (value?.trim().toLowerCase()) {
    case 'basic':
      return SubscriptionPlan.basic;
    case 'pro':
    case 'monthly':
    case 'yearly':
    case 'lifetime':
      // Legacy paid plans are retained as Pro during migration.
      return SubscriptionPlan.pro;
    case 'professional':
      return SubscriptionPlan.professional;
    default:
      return SubscriptionPlan.free;
  }
}

extension SubscriptionPlanX on SubscriptionPlan {
  String get id => name;

  String get displayName => switch (this) {
        SubscriptionPlan.free => 'Free',
        SubscriptionPlan.basic => 'Basic',
        SubscriptionPlan.pro => 'Pro',
        SubscriptionPlan.professional => 'Professional',
      };
}

enum SubscriptionStatus { active, pending, cancelled, failed, expired }

SubscriptionStatus subscriptionStatusFromString(String? value) {
  return SubscriptionStatus.values.firstWhere(
    (status) => status.name == value?.trim().toLowerCase(),
    orElse: () => SubscriptionStatus.expired,
  );
}

enum PremiumFeature { aiAssistant, omrScanner, watermarkFree, paperEditor }

enum UpgradeReason {
  aiAssistant,
  aiDailyLimit,
  omrScanner,
  subjectLimit,
  watermark,
  paperEditor,
}

/// The one entitlement object consumed by feature code.
///
/// The values are deliberately immutable. Screens must not infer access from
/// profile strings or payment status; they receive this object from the
/// subscription repository/view model instead.
class SubscriptionEntitlement {
  /// The existing free paper experience supports one selected subject. This
  /// is kept here rather than hidden in a screen so the free/demo policy is
  /// covered by the same subject gate as paid plans.
  static const int freeSubjectLimit = 1;
  static const int freeMonthlyPaperLimit = 2;
  static const int basicSubjectLimit = 3;
  static const int proSubjectLimit = 5;
  static const int proAiDailyLimit = 20;
  static const int professionalAiDailyLimit = 50;

  final SubscriptionPlan plan;
  final int? subjectLimit;
  final int? monthlyPaperLimit;
  final bool noWatermark;
  final bool aiAssistant;
  final int aiDailyLimit;
  final bool omrScanner;
  final SubscriptionStatus status;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final String? provider;
  final String? transactionId;
  final DateTime? lastVerifiedAt;

  const SubscriptionEntitlement({
    required this.plan,
    required this.subjectLimit,
    this.monthlyPaperLimit,
    required this.noWatermark,
    required this.aiAssistant,
    required this.aiDailyLimit,
    required this.omrScanner,
    this.status = SubscriptionStatus.active,
    this.startedAt,
    this.expiresAt,
    this.provider,
    this.transactionId,
    this.lastVerifiedAt,
  });

  factory SubscriptionEntitlement.free({DateTime? lastVerifiedAt}) =>
      SubscriptionEntitlement(
        plan: SubscriptionPlan.free,
        subjectLimit: freeSubjectLimit,
        monthlyPaperLimit: freeMonthlyPaperLimit,
        noWatermark: false,
        aiAssistant: false,
        aiDailyLimit: 0,
        omrScanner: false,
        status: SubscriptionStatus.active,
        lastVerifiedAt: lastVerifiedAt,
      );

  factory SubscriptionEntitlement.defaults(
    SubscriptionPlan plan, {
    SubscriptionStatus status = SubscriptionStatus.active,
    DateTime? startedAt,
    DateTime? expiresAt,
    String? provider,
    String? transactionId,
    DateTime? lastVerifiedAt,
  }) {
    switch (plan) {
      case SubscriptionPlan.free:
        return SubscriptionEntitlement.free(lastVerifiedAt: lastVerifiedAt);
      case SubscriptionPlan.basic:
        return SubscriptionEntitlement(
          plan: plan,
          subjectLimit: basicSubjectLimit,
          noWatermark: false,
          aiAssistant: false,
          aiDailyLimit: 0,
          omrScanner: false,
          status: status,
          startedAt: startedAt,
          expiresAt: expiresAt,
          provider: provider,
          transactionId: transactionId,
          lastVerifiedAt: lastVerifiedAt,
        );
      case SubscriptionPlan.pro:
        return SubscriptionEntitlement(
          plan: plan,
          subjectLimit: proSubjectLimit,
          noWatermark: true,
          aiAssistant: true,
          aiDailyLimit: proAiDailyLimit,
          omrScanner: false,
          status: status,
          startedAt: startedAt,
          expiresAt: expiresAt,
          provider: provider,
          transactionId: transactionId,
          lastVerifiedAt: lastVerifiedAt,
        );
      case SubscriptionPlan.professional:
        return SubscriptionEntitlement(
          plan: plan,
          subjectLimit: null,
          noWatermark: true,
          aiAssistant: true,
          aiDailyLimit: professionalAiDailyLimit,
          omrScanner: true,
          status: status,
          startedAt: startedAt,
          expiresAt: expiresAt,
          provider: provider,
          transactionId: transactionId,
          lastVerifiedAt: lastVerifiedAt,
        );
    }
  }

  /// Creates an entitlement from a server plan row. Unknown/missing values
  /// fall back to the safe built-in matrix until the plan table is reachable.
  factory SubscriptionEntitlement.fromPlanRow(
    Map<String, dynamic> row, {
    SubscriptionPlan? requestedPlan,
    SubscriptionStatus status = SubscriptionStatus.active,
    DateTime? startedAt,
    DateTime? expiresAt,
    String? provider,
    String? transactionId,
    DateTime? lastVerifiedAt,
  }) {
    final fallback = SubscriptionEntitlement.defaults(
      requestedPlan ?? subscriptionPlanFromString(row['id']?.toString()),
      status: status,
      startedAt: startedAt,
      expiresAt: expiresAt,
      provider: provider,
      transactionId: transactionId,
      lastVerifiedAt: lastVerifiedAt,
    );
    final rawLimit = row['subject_limit'];
    final rawAiLimit = row['ai_daily_limit'];
    return SubscriptionEntitlement(
      plan: fallback.plan,
      subjectLimit: _asInt(rawLimit) ?? fallback.subjectLimit,
      monthlyPaperLimit:
          _asInt(row['monthly_paper_limit']) ?? fallback.monthlyPaperLimit,
      noWatermark: row['no_watermark'] is bool
          ? row['no_watermark'] as bool
          : fallback.noWatermark,
      aiAssistant: row['ai_assistant'] is bool
          ? row['ai_assistant'] as bool
          : fallback.aiAssistant,
      aiDailyLimit: _asInt(rawAiLimit) ?? fallback.aiDailyLimit,
      omrScanner: row['omr_scanner'] is bool
          ? row['omr_scanner'] as bool
          : fallback.omrScanner,
      status: status,
      startedAt: startedAt,
      expiresAt: expiresAt,
      provider: provider,
      transactionId: transactionId,
      lastVerifiedAt: lastVerifiedAt,
    );
  }

  bool get isPaid => plan != SubscriptionPlan.free;

  bool get isActive =>
      !isPaid ||
      (status == SubscriptionStatus.active &&
          (expiresAt == null || expiresAt!.isAfter(DateTime.now().toUtc())));

  bool get isExpired => isPaid && !isActive;

  /// True during the final [days] before an active paid subscription expires.
  /// A lifetime plan (no expiry), Free plan, or already-expired plan never
  /// produces a payment warning.
  bool renewalDueSoon({int days = 7, DateTime? now}) {
    if (!isPaid || status != SubscriptionStatus.active || expiresAt == null) {
      return false;
    }
    final remaining = expiresAt!.toUtc().difference(
          (now ?? DateTime.now()).toUtc(),
        );
    return remaining > Duration.zero && remaining <= Duration(days: days);
  }

  int? renewalDaysRemaining({DateTime? now}) {
    if (!renewalDueSoon(now: now)) return null;
    final remaining = expiresAt!.toUtc().difference(
          (now ?? DateTime.now()).toUtc(),
        );
    return (remaining.inMinutes / Duration.minutesPerDay).ceil();
  }

  /// Returns the safe effective entitlement. A paid entitlement is usable only
  /// while its status is active and its expiry has not passed. Pending,
  /// cancelled, failed, and expired payments are always Free.
  SubscriptionEntitlement get effective => isActive
      ? this
      : SubscriptionEntitlement.free(lastVerifiedAt: lastVerifiedAt);

  bool canUse(PremiumFeature feature) {
    final current = effective;
    return switch (feature) {
      PremiumFeature.aiAssistant =>
        current.aiAssistant && current.aiDailyLimit > 0,
      PremiumFeature.omrScanner => current.omrScanner,
      PremiumFeature.watermarkFree => current.noWatermark,
      // The question paper editor is a Professional-only feature.
      PremiumFeature.paperEditor =>
        current.plan == SubscriptionPlan.professional,
    };
  }

  UpgradeReason? reasonFor(
    PremiumFeature feature, {
    bool dailyLimitReached = false,
  }) {
    final current = effective;
    if (feature == PremiumFeature.aiAssistant && dailyLimitReached) {
      return UpgradeReason.aiDailyLimit;
    }
    if (current.canUse(feature)) return null;
    return switch (feature) {
      PremiumFeature.aiAssistant => UpgradeReason.aiAssistant,
      PremiumFeature.omrScanner => UpgradeReason.omrScanner,
      PremiumFeature.watermarkFree => UpgradeReason.watermark,
      PremiumFeature.paperEditor => UpgradeReason.paperEditor,
    };
  }

  SubscriptionEntitlement copyWith({
    SubscriptionPlan? plan,
    int? subjectLimit,
    int? monthlyPaperLimit,
    bool? noWatermark,
    bool? aiAssistant,
    int? aiDailyLimit,
    bool? omrScanner,
    SubscriptionStatus? status,
    DateTime? startedAt,
    DateTime? expiresAt,
    String? provider,
    String? transactionId,
    DateTime? lastVerifiedAt,
  }) =>
      SubscriptionEntitlement(
        plan: plan ?? this.plan,
        subjectLimit: subjectLimit ?? this.subjectLimit,
        monthlyPaperLimit: monthlyPaperLimit ?? this.monthlyPaperLimit,
        noWatermark: noWatermark ?? this.noWatermark,
        aiAssistant: aiAssistant ?? this.aiAssistant,
        aiDailyLimit: aiDailyLimit ?? this.aiDailyLimit,
        omrScanner: omrScanner ?? this.omrScanner,
        status: status ?? this.status,
        startedAt: startedAt ?? this.startedAt,
        expiresAt: expiresAt ?? this.expiresAt,
        provider: provider ?? this.provider,
        transactionId: transactionId ?? this.transactionId,
        lastVerifiedAt: lastVerifiedAt ?? this.lastVerifiedAt,
      );

  Map<String, dynamic> toJson() => {
        'plan': plan.id,
        'subjectLimit': subjectLimit,
        'monthlyPaperLimit': monthlyPaperLimit,
        'noWatermark': noWatermark,
        'aiAssistant': aiAssistant,
        'aiDailyLimit': aiDailyLimit,
        'omrScanner': omrScanner,
        'status': status.name,
        'startedAt': startedAt?.toUtc().toIso8601String(),
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'provider': provider,
        'transactionId': transactionId,
        'lastVerifiedAt': lastVerifiedAt?.toUtc().toIso8601String(),
      };

  factory SubscriptionEntitlement.fromJson(Map<String, dynamic> json) {
    final plan = subscriptionPlanFromString(json['plan']?.toString());
    final fallback = SubscriptionEntitlement.defaults(plan);
    DateTime? date(String key) =>
        DateTime.tryParse(json[key]?.toString() ?? '');
    return SubscriptionEntitlement(
      plan: plan,
      subjectLimit: json.containsKey('subjectLimit')
          ? _asInt(json['subjectLimit'])
          : fallback.subjectLimit,
      monthlyPaperLimit: json.containsKey('monthlyPaperLimit')
          ? _asInt(json['monthlyPaperLimit'])
          : fallback.monthlyPaperLimit,
      noWatermark: json['noWatermark'] as bool? ?? fallback.noWatermark,
      aiAssistant: json['aiAssistant'] as bool? ?? fallback.aiAssistant,
      aiDailyLimit: _asInt(json['aiDailyLimit']) ?? fallback.aiDailyLimit,
      omrScanner: json['omrScanner'] as bool? ?? fallback.omrScanner,
      status: subscriptionStatusFromString(json['status']?.toString()),
      startedAt: date('startedAt'),
      expiresAt: date('expiresAt'),
      provider: json['provider']?.toString(),
      transactionId: json['transactionId']?.toString(),
      lastVerifiedAt: date('lastVerifiedAt'),
    );
  }
}
