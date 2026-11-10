import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/auth_service.dart';
import '../services/subscription_state.dart';
import '../widgets/animations.dart';
import 'auth_choice_screen.dart';
import 'teacher_home_screen.dart';
import '../widgets/app_logo.dart';
import '../widgets/motion_policy.dart';

/// App gatekeeper —
///  • not signed in → welcome / sign-in screen
///  • signed in     → the teacher (tutor) portal
///
/// Tutor's Desk is a teacher-only product, so there is no role branching:
/// every authenticated account lands in the tutor workspace.
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();

  /// Safest way back to the gate after signing in or out — clears the whole
  /// navigation stack so no authenticated screen stays behind.
  static void restart(BuildContext context) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const RootGate()),
      (_) => false,
    );
  }
}

class _RootGateState extends State<RootGate> {
  late Future<bool> _boot;
  StreamSubscription<AuthState>? _authSubscription;
  // Supabase emits an initial auth event even when there is no session. Do
  // not restart the root route for that normal anonymous startup event.
  bool _hadAuthenticatedSession = false;

  @override
  void initState() {
    super.initState();
    _boot = _prepare();
    _hadAuthenticatedSession = AuthService.isLoggedIn;
    if (AuthService.ready) {
      _authSubscription = AuthService.authChanges.listen((_) {
        if (!mounted) return;
        final loggedIn = AuthService.isLoggedIn;
        if (loggedIn) {
          _hadAuthenticatedSession = true;
          return;
        }
        if (!_hadAuthenticatedSession) return;
        _hadAuthenticatedSession = false;
        // A refresh-token revocation from a newer device is an ordinary sign
        // out from the user's point of view. Clear every authenticated route.
        RootGate.restart(context);
      });
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    super.dispose();
  }

  /// Warms up the profile/Pro state before showing the workspace so the
  /// home screen never flickers between logged-out and logged-in states.
  Future<bool> _prepare() async {
    if (!AuthService.ready || !AuthService.isLoggedIn) {
      SubscriptionState.instance.clear();
      return false;
    }
    if (!await AuthService.verifyCurrentSession()) {
      SubscriptionState.instance.clear();
      return false;
    }
    try {
      await AuthService.ensureTeacherProfile();
      // Cached entitlements are loaded before the first workspace frame. The
      // server refresh runs reactively and never holds the app at the splash.
      await SubscriptionState.instance.initialize(refresh: false);
      unawaited(SubscriptionState.instance.refresh());
    } catch (_) {
      // Profile hydration can be retried after the session check; the global
      // connectivity gate still blocks workspace interaction when offline.
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _boot,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const _BootSplash();
        }
        return SoftSwitcher(
          duration: const Duration(milliseconds: 180),
          child: snap.data == true
              ? const TeacherHomeScreen(key: ValueKey('teacher'))
              : const AuthChoiceScreen(key: ValueKey('auth')),
        );
      },
    );
  }
}

/// A short functional loading state, without a perpetual decorative animation.
class _BootSplash extends StatelessWidget {
  const _BootSplash();
  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppLogo(size: 64),
              SizedBox(height: 24),
              Text(
                "Tutor’s Desk",
                style: TextStyle(
                  color: Colors.black,
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 20),
              ActivityIndicator(size: 24, color: Colors.black),
              SizedBox(height: 12),
              Text('Opening your workspace…',
                  style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
}
