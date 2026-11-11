import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/app_settings.dart';
import '../services/app_version.dart';
import '../services/local_diagnostics.dart';
import '../theme/app_theme.dart';
import '../services/app_updater.dart';
import '../widgets/app_update_dialogs.dart';
import '../widgets/glass_card.dart';
import 'profile_screen.dart';
import '../widgets/app_icon.dart';

/// Settings — profile (moved here from the home screen), OMR scanner
/// preferences and the default paper name.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _nameCtrl;
  String? _savedMsg;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: AppSettings.defaultName);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  /// Persists the typed name (called on submit / focus loss / back).
  Future<void> _persistName() async {
    final t = _nameCtrl.text.trim();
    if (t == AppSettings.defaultName) return;
    await AppSettings.setDefaultPaperName(t);
    if (!mounted) return;
    setState(() => _savedMsg = t);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _savedMsg = null);
    });
  }

  Future<void> _diagnostics() async {
    final report = await LocalDiagnostics.report();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Local diagnostics'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Only error types, app code locations, build and platform are stored. No messages, account details or attachments. Nothing is sent automatically.',
              ),
              const SizedBox(height: 16),
              SelectableText(report, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await LocalDiagnostics.clear();
              if (dialog.mounted) Navigator.pop(dialog);
            },
            child: const Text('Clear records'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Settings',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppTheme.textDark),
      ),
      body: SafeArea(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.card,
            onRefresh: _persistName,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
              children: [
                _section(
                  'Accessibility',
                  icon: PhosphorIcons.user,
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AppSettings.reduceMotion,
                      builder: (context, value, _) => SwitchListTile(
                        title: const Text('Reduce motion'),
                        subtitle: const Text(
                          'Use still transitions and loading indicators. Your device’s reduce-motion preference is always respected.',
                        ),
                        value: value,
                        onChanged: AppSettings.setReduceMotion,
                      ),
                    ),
                  ),
                ),
                _section(
                  'App updates',
                  icon: PhosphorIcons.arrowsClockwise,
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      title: const Text('Check for updates'),
                      subtitle: Text('Version $kAppVersion'),
                      trailing: const AppIcon(PhosphorIcons.caretRight),
                      onTap: () => AppUpdateDialogs.checkNow(context),
                    ),
                  ),
                ),
                _section(
                  'Privacy & diagnostics',
                  icon: PhosphorIcons.shield,
                  child: GlassCard(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      title: const Text('Local diagnostics'),
                      subtitle: const Text(
                        'On this device only · Remote reporting off',
                      ),
                      trailing: const AppIcon(PhosphorIcons.caretRight),
                      onTap: _diagnostics,
                    ),
                  ),
                ),
                _section(
                  'Profile',
                  icon: PhosphorIcons.user,
                  child: GlassCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ProfileScreen()),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withOpacity(.10),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: AppTheme.primary.withOpacity(.35),
                            ),
                          ),
                          child: const AppIcon(
                            PhosphorIcons.user,
                            color: AppTheme.primary,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Profile & account',
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Details, workspace theme, Pro sync, sign out',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppTheme.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        AppIcon(
                          PhosphorIcons.caretRight,
                          color: AppTheme.muted,
                        ),
                      ],
                    ),
                  ),
                ),
                _section(
                  'OMR scanner',
                  icon: PhosphorIcons.qrCode,
                  child: GlassCard(
                    padding: const EdgeInsets.all(14),
                    child: ValueListenableBuilder<bool>(
                      valueListenable: AppSettings.omrPrefillCodes,
                      builder: (context, on, _) => Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppTheme.secondary.withOpacity(.10),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: AppTheme.secondary.withOpacity(.35),
                              ),
                            ),
                            child: const AppIcon(
                              PhosphorIcons.table,
                              color: AppTheme.secondary,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Prefill set & subject code in OMR',
                                  style: TextStyle(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  on
                                      ? 'OMR sheets print the set & subject code already filled, and scan results show them'
                                      : 'OMR sheets print the set & subject code blank (students fill it in) and scan results leave it blank',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppTheme.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch(
                            value: on,
                            onChanged: (v) => AppSettings.setOmriPrefill(v),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _section(
                  'Default paper name',
                  icon: PhosphorIcons.fileText,
                  child: GlassCard(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Used as the default title for new question papers and OMR tests',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.muted,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _nameCtrl,
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                          onSubmitted: (_) => _persistName(),
                          onEditingComplete: _persistName,
                          decoration: InputDecoration(
                            hintText: 'e.g. Model Test — First Phase',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: AppTheme.border,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: AppTheme.border,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(
                                color: AppTheme.primary,
                                width: 1.4,
                              ),
                            ),
                          ),
                        ),
                        if (_savedMsg != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text(
                              'Saved ✓',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.success,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _section(
    String title, {
    required IconData icon,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
          child: Row(
            children: [
              AppIcon(icon, size: 18, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textDark,
                ),
              ),
            ],
          ),
        ),
        child,
      ],
    );
  }
}
