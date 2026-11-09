import 'dart:async';

import 'package:flutter/material.dart';

import '../models/subscription_entitlement.dart';
import 'auth_service.dart';
import 'subscription_state.dart';

/// Centralized UI gate. The route should remain discoverable, but every
/// action still calls the same entitlement check before doing work.
class SubscriptionGuard {
  static Future<bool> require(
    BuildContext context,
    PremiumFeature feature, {
    String? title,
  }) async {
    final state = SubscriptionState.instance;
    if (!state.initialized) {
      // Load the safe cached entitlement first so a Free user gets the lock
      // explanation immediately rather than waiting on a network round trip.
      await state.initialize(refresh: false);
    }
    if (!state.canUse(feature)) {
      final reason = state.reasonFor(feature);
      if (AuthService.isLoggedIn) unawaited(state.refresh());
      await _showUpgrade(context, reason, title);
      return false;
    }
    // A cached paid entitlement is still expiry-checked by the view model.
    // Allow the already-authorized tap immediately, then reconcile the server
    // state in the background so the overlay never feels delayed.
    if (AuthService.isLoggedIn) unawaited(state.refresh());
    return true;
  }

  static Future<void> _showUpgrade(
    BuildContext context,
    UpgradeReason? reason,
    String? title,
  ) async {
    final message = switch (reason) {
      UpgradeReason.aiDailyLimit =>
        'Daily AI limit reached. Resets at midnight.',
      UpgradeReason.aiAssistant =>
        'AI Assistant requires an active Pro or Professional plan.',
      UpgradeReason.omrScanner => 'OMR Scanner is available on Professional.',
      UpgradeReason.watermark => 'Upgrade to remove the PDF watermark.',
      UpgradeReason.paperEditor =>
        'The Question Paper Editor is available on the Professional plan.',
      UpgradeReason.subjectLimit =>
        'Your current plan has reached its subject limit.',
      null => 'This feature is not available on your current plan.',
    };
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title ?? 'Upgrade required'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.of(context).pushNamed('/plans');
              },
              child: const Text('Upgrade Plan'),
            ),
          ],
        ),
      );
    }
  }
}
