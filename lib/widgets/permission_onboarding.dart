import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_icon.dart';

/// One-time permission prompt shown after a fresh install (Android only).
///
/// Lists the permissions the app relies on and lets the user allow them. It
/// never blocks the app: the user can always press Continue. Shown once per
/// install; the flag is stored only after the dialog closes.
abstract final class PermissionOnboarding {
  static const _doneKey = 'permissions_onboarded_v1';
  static bool _shownThisSession = false;

  static Future<void> showIfNeeded(BuildContext context) async {
    if (_shownThisSession || !Platform.isAndroid) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _shownThisSession = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_doneKey) == true) return;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PermissionDialog(),
    );
    await prefs.setBool(_doneKey, true);
  }
}

class _PermissionItem {
  const _PermissionItem({
    required this.permission,
    required this.title,
    required this.reason,
    required this.icon,
  });

  final Permission permission;
  final String title;
  final String reason;
  final IconData icon;
}

const _items = <_PermissionItem>[
  _PermissionItem(
    permission: Permission.camera,
    title: 'Camera',
    reason: 'Scan OMR answer sheets and take photos of question papers.',
    icon: PhosphorIcons.camera,
  ),
  _PermissionItem(
    permission: Permission.manageExternalStorage,
    title: 'All files access',
    reason:
        'Keep an automatic backup of your paper library so it survives reinstalls. Opens a system settings page.',
    icon: PhosphorIcons.fileText,
  ),
  _PermissionItem(
    permission: Permission.requestInstallPackages,
    title: 'Install apps',
    reason:
        'Install future app updates you approve. Opens a system settings page.',
    icon: PhosphorIcons.downloadSimple,
  ),
];

class _PermissionDialog extends StatefulWidget {
  const _PermissionDialog();

  @override
  State<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends State<_PermissionDialog>
    with WidgetsBindingObserver {
  final Map<Permission, bool> _granted = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Settings-based permissions are granted on another screen; re-read the
  // status when the user comes back to the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final results = <Permission, bool>{};
    for (final item in _items) {
      try {
        results[item.permission] = await item.permission.isGranted;
      } catch (_) {
        results[item.permission] = false;
      }
    }
    if (!mounted) return;
    setState(() {
      _granted.addAll(results);
    });
  }

  Future<void> _request(Permission permission) async {
    try {
      await permission.request();
    } catch (_) {
      // Platform refused or unavailable; the row stays "Not allowed".
    }
    await _refresh();
  }

  Future<void> _allowAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    for (final item in _items) {
      if (_granted[item.permission] == true) continue;
      await _request(item.permission);
    }
    if (mounted) setState(() => _busy = false);
  }

  bool get _allGranted => _items.every((i) => _granted[i.permission] == true);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Allow permissions'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tutor\'s Desk works best with these permissions. You can change them later in system settings.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            for (final item in _items)
              _PermissionRow(
                item: item,
                granted: _granted[item.permission] == true,
                busy: _busy,
                onAllow: () => _request(item.permission),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Continue'),
        ),
        FilledButton(
          onPressed: (_busy || _allGranted) ? null : _allowAll,
          child: Text(_allGranted ? 'All allowed' : 'Allow all'),
        ),
      ],
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.item,
    required this.granted,
    required this.busy,
    required this.onAllow,
  });

  final _PermissionItem item;
  final bool granted;
  final bool busy;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(item.icon, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(item.reason, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (granted)
            AppIcon(PhosphorIcons.checkCircle,
                color: theme.colorScheme.primary)
          else
            TextButton(
              onPressed: busy ? null : onAllow,
              child: const Text('Allow'),
            ),
        ],
      ),
    );
  }
}
