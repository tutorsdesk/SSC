import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../controllers/paper_controller.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_icon.dart';
import '../widgets/app_logo.dart';
import '../services/app_style.dart';
import '../widgets/reference_ui.dart';
import '../navigation/app_routes.dart';
import '../services/auth_service.dart';
import '../services/paper_library.dart';
import '../services/promotion_service.dart';
import '../services/subscription_guard.dart';
import '../models/subscription_entitlement.dart';
import '../services/subscription_state.dart';
import '../theme/app_theme.dart';
import 'ai_tools_screen.dart';
import 'omr_scanner_screen.dart';
import 'omr_analytics_screen.dart';
import 'profile_screen.dart';
import 'subscription_screen.dart';
import 'papers_library_screen.dart';
import 'paper_editor_screen.dart';

/// Reference-style teacher dashboard. Product workflows remain real screens;
/// the dashboard only changes the presentation and entry points.
class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});
  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen>
    with WidgetsBindingObserver {
  String? draftTitle;
  int loadGeneration = 0;
  List<PaperEntry> recent = [];
  PromotionFeed promotions = const PromotionFeed();
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    AppStyle.mood.value = WorkspaceMood.home;
    WidgetsBinding.instance.addObserver(this);
    SubscriptionState.instance.addListener(_subscriptionChanged);
    load();
  }

  void _subscriptionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SubscriptionState.instance.removeListener(_subscriptionChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  Future<void> _refreshByUser() async {
    SubscriptionState.instance.cycleDiagnosticPlan(
      accountEmail: AuthService.email,
    );
    await load();
  }

  Future<void> load() async {
    final generation = ++loadGeneration;
    final subscription = SubscriptionState.instance;
    if (!subscription.initialized) {
      await subscription.initialize(refresh: false);
    }
    unawaited(subscription.refresh());
    String? storedTitle;
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(PaperController.scopedDraftKey);
      if (raw == null) {
        raw = prefs.getString(PaperController.draftKey);
        if (raw != null) {
          await prefs.setString(PaperController.scopedDraftKey, raw);
          await prefs.remove(PaperController.draftKey);
        }
      }
      if (raw != null) {
        final snapshot = jsonDecode(raw) as Map<String, dynamic>;
        // A draft becomes a Recent only after an exact composed-paper snapshot
        // exists. Merely choosing a title or counts must not create a recent.
        if (snapshot['version'] == 1 &&
            snapshot['draft'] is Map &&
            snapshot['paper'] is Map) {
          final title = (snapshot['draft']['title'] as String?)?.trim();
          storedTitle =
              title == null || title.isEmpty ? 'Generated paper' : title;
        }
      }
    } catch (_) {
      // A corrupt draft must not hide the saved-paper library.
    }
    // Keep promotions independent from the local paper library. A slow or
    // corrupt paper index must not prevent a newly signed-in account from
    // receiving an active in-app offer popup.
    List<PaperEntry> entries = const [];
    var libraryFailed = false;
    try {
      entries = await PaperLibrary.loadEntries();
    } catch (_) {
      libraryFailed = true;
    }
    PromotionFeed feed = const PromotionFeed();
    try {
      feed = await PromotionService.load();
    } catch (_) {
      // Promotions are optional network content; they must never hide papers.
    }
    if (mounted && generation == loadGeneration) {
      setState(() {
        draftTitle = storedTitle;
        recent = entries.take(8).toList();
        promotions = feed;
        loading = false;
        error = libraryFailed
            ? 'Your papers could not be loaded. Pull down to retry.'
            : null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == loadGeneration) _showOfferPopup(feed);
      });
    }
  }

  Future<void> _showOfferPopup(PromotionFeed feed) async {
    // A promotion may be text-only. Requiring an image here made valid active
    // ads silently disappear even though the database and RLS query succeeded.
    if (feed.ads.isEmpty) return;
    final ad = feed.ads.first;
    final prefs = await SharedPreferences.getInstance();
    // Seen state belongs to the account, not only the physical device: a new
    // tutor signing in on a shared phone must still receive the offer.
    final account = AuthService.userId ?? 'signed_out';
    final safeAccount = account.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final seenKey = 'promotion_ad_seen_${safeAccount}_${ad.id}';
    if (prefs.getBool(seenKey) == true || !mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    await prefs.setBool(seenKey, true);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(ad.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ad.imageUrl.startsWith('https://')) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    ad.imageUrl,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    cacheWidth: 1080,
                    errorBuilder: (_, __, ___) => const SizedBox(
                      height: 120,
                      child: Center(child: AppIcon(PhosphorIcons.imageBroken)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (ad.body.trim().isNotEmpty)
                Text(ad.body)
              else
                const Text('Open this offer to learn more.'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              if (ad.buttonUrl == '/plans' && mounted)
                Navigator.pushNamed(context, AppRoutes.plans);
            },
            child: Text(ad.buttonText),
          ),
        ],
      ),
    );
  }

  Future<void> create({bool quick = false}) async {
    await Navigator.pushNamed(
      context,
      AppRoutes.createPaper,
      arguments: quick ? const CreatePaperArgs(quickStart: true) : null,
    );
    // The editor can move the workspace tint (English is pink); coming back to
    // the desk restores the accent for the tab the teacher is actually on.
    AppStyle.mood.value = WorkspaceMood.home;
    if (mounted) load();
  }

  Widget? _expiryWarning() {
    final entitlement = SubscriptionState.instance.entitlement;
    if (!entitlement.renewalDueSoon()) return null;
    final days = entitlement.renewalDaysRemaining()!;
    return ReferenceCard(
      onTap: () => Navigator.pushNamed(context, AppRoutes.plans),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          const ReferenceIcon(PhosphorIcons.warningCircle, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Subscription payment due soon',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  days == 1
                      ? 'Your plan expires within 1 day. Pay your monthly bill to keep access.'
                      : 'Your plan expires within $days days. Pay your monthly bill to keep access.',
                  style: const TextStyle(color: ReferencePalette.mutedInk),
                ),
              ],
            ),
          ),
          const ReferenceIcon(PhosphorIcons.caretRight, size: 22),
        ],
      ),
    );
  }

  Widget _notificationCard(AppNotificationItem item) => ReferenceCard(
        onTap: item.actionUrl == '/plans'
            ? () => Navigator.pushNamed(context, AppRoutes.plans)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const ReferenceIcon(PhosphorIcons.bellRinging, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.message,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: ReferencePalette.mutedInk),
                  ),
                ],
              ),
            ),
            if (item.actionUrl == '/plans')
              const ReferenceIcon(PhosphorIcons.caretRight, size: 22),
          ],
        ),
      );

  Widget _prizeCard(PromotionPrize prize) => ReferenceCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (prize.imageUrl.startsWith('https://'))
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  prize.imageUrl,
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  cacheWidth: 132,
                  cacheHeight: 132,
                  errorBuilder: (_, __, ___) =>
                      const ReferenceIcon(PhosphorIcons.trophy, size: 32),
                ),
              )
            else
              const ReferenceIcon(PhosphorIcons.trophy, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prize.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if ([
                    prize.valueText,
                    prize.description,
                  ].any((text) => text.trim().isNotEmpty))
                    Text(
                      [
                        prize.valueText,
                        prize.description,
                      ].where((text) => text.trim().isNotEmpty).join(' · '),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: ReferencePalette.mutedInk),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  Future<void> _openScreen(Widget screen) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
    if (mounted) load();
  }

  Future<void> _openSettings() async {
    await Navigator.pushNamed(context, AppRoutes.settings);
    if (mounted) load();
  }

  Future<void> _openPremium(Widget screen, PremiumFeature feature) async {
    if (!mounted) return;
    if (await SubscriptionGuard.require(context, feature)) {
      await _openScreen(screen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      backgroundColor: ReferencePalette.background,
      body: SafeArea(child: desktop ? _desktopHome() : home()),
      bottomNavigationBar:
          desktop ? null : ReferenceBottomBar(onSettings: _openSettings),
    );
  }

  Widget _desktopHome() => Row(
        children: [
          Container(
            width: 232,
            decoration: const BoxDecoration(
              color: ReferencePalette.surface,
              border: Border(right: BorderSide(color: Color(0xFFE1E0DC))),
            ),
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _referenceBrand(),
                const SizedBox(height: 44),
                _desktopNavItem(PhosphorIcons.house, 'Overview',
                    selected: true),
                _desktopNavItem(
                  PhosphorIcons.filePlus,
                  'Create paper',
                  onTap: () => create(),
                ),
                _desktopNavItem(
                  PhosphorIcons.bookmarkSimple,
                  'My papers',
                  onTap: () => _openScreen(const PapersLibraryScreen()),
                ),
                _desktopNavItem(
                  PhosphorIcons.notePencil,
                  'Editor',
                  onTap: () => _openPremium(
                    const PaperEditorListScreen(),
                    PremiumFeature.paperEditor,
                  ),
                ),
                _desktopNavItem(
                  PhosphorIcons.magicWand,
                  'AI assistant',
                  onTap: () => _openPremium(
                    const AiToolsScreen(),
                    PremiumFeature.aiAssistant,
                  ),
                ),
                _desktopNavItem(
                  PhosphorIcons.scan,
                  'OMR scanner',
                  onTap: () => _openPremium(
                    const OMrScannerScreen(),
                    PremiumFeature.omrScanner,
                  ),
                ),
                const Spacer(),
                _desktopNavItem(
                  PhosphorIcons.wallet,
                  'Plans',
                  onTap: () => _openScreen(const SubscriptionScreen()),
                ),
                _desktopNavItem(
                  PhosphorIcons.gear,
                  'Settings',
                  onTap: _openSettings,
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 82,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  decoration: const BoxDecoration(
                    color: ReferencePalette.surface,
                    border:
                        Border(bottom: BorderSide(color: Color(0xFFE1E0DC))),
                  ),
                  child: Row(
                    children: [
                      const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'TEACHER WORKSPACE',
                            style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.5,
                              color: ReferencePalette.mutedInk,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Overview',
                            style: TextStyle(
                              fontSize: 23,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      _referenceHeader(),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refreshByUser,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(32),
                      children: [
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1080),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Ready for your next class?',
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineMedium
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Create, review and manage every paper from one focused desk.',
                                  style: TextStyle(
                                      color: ReferencePalette.mutedInk),
                                ),
                                const SizedBox(height: 28),
                                _desktopDashboard(),
                                if (_expiryWarning() case final warning?) ...[
                                  const SizedBox(height: 18),
                                  warning,
                                ],
                                if (error != null) ...[
                                  const SizedBox(height: 18),
                                  ReferenceCard(
                                      onTap: load, child: Text(error!)),
                                ],
                              ],
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
        ],
      );

  Widget _desktopNavItem(
    IconData icon,
    String label, {
    bool selected = false,
    VoidCallback? onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Material(
          color: selected ? const Color(0xFF111111) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              child: Row(
                children: [
                  AppIcon(
                    icon,
                    size: 19,
                    color: selected ? Colors.white : ReferencePalette.ink,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.white : ReferencePalette.ink,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _desktopDashboard() {
    final actions = <Widget>[
      ReferenceActionCard(
        icon: PhosphorIcons.filePlus,
        label: 'CREATE PAPER',
        onTap: () => create(),
      ),
      ReferenceActionCard(
        icon: PhosphorIcons.magicWand,
        label: 'AI Assistant',
        locked: !SubscriptionState.instance.canUse(PremiumFeature.aiAssistant),
        onTap: () => _openPremium(
          const AiToolsScreen(),
          PremiumFeature.aiAssistant,
        ),
      ),
      ReferenceActionCard(
        icon: PhosphorIcons.bookmarkSimple,
        label: 'My Papers',
        onTap: () => _openScreen(const PapersLibraryScreen()),
      ),
      ReferenceActionCard(
        icon: PhosphorIcons.clock,
        label: 'Recents',
        onTap: _showRecents,
      ),
      ReferenceActionCard(
        icon: PhosphorIcons.chartBar,
        label: 'Statistics',
        locked: !SubscriptionState.instance.canUse(PremiumFeature.omrScanner),
        onTap: () => _openPremium(
          const OMrAnalyticsScreen(),
          PremiumFeature.omrScanner,
        ),
      ),
      ReferenceActionCard(
        icon: PhosphorIcons.scan,
        label: 'OMR Scanner',
        locked: !SubscriptionState.instance.canUse(PremiumFeature.omrScanner),
        onTap: () => _openPremium(
          const OMrScannerScreen(),
          PremiumFeature.omrScanner,
        ),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => GridView.count(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        crossAxisCount: constraints.maxWidth >= 960 ? 3 : 2,
        childAspectRatio: 1.65,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        children: actions,
      ),
    );
  }

  Widget home() => Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: Container(
              height: 138,
              color: ReferencePalette.surface,
              padding: const EdgeInsets.fromLTRB(18, 18, 20, 22),
              child: Stack(
                children: [
                  Align(alignment: Alignment.topLeft, child: _referenceBrand()),
                  Align(
                      alignment: Alignment.topRight, child: _referenceHeader()),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              color: ReferencePalette.ink,
              backgroundColor: ReferencePalette.surface,
              onRefresh: _refreshByUser,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
                children: [
                  _referenceDashboard(),
                  if (_expiryWarning() case final warning?) ...[
                    const SizedBox(height: 12),
                    warning,
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 360),
                        child: SizedBox(
                          height: 108,
                          child: ReferenceActionCard(
                            icon: PhosphorIcons.wallet,
                            label: 'BUY PLANS',
                            onTap: () =>
                                _openScreen(const SubscriptionScreen()),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (promotions.notifications.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    for (final item in promotions.notifications.take(3))
                      _notificationCard(item),
                  ],
                  if (promotions.prizes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _prizeCard(promotions.prizes.first),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    ReferenceCard(
                      onTap: load,
                      child: Row(
                        children: [
                          const ReferenceIcon(
                            PhosphorIcons.warningCircle,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(error!)),
                          const ReferenceIcon(
                            PhosphorIcons.arrowClockwise,
                            size: 22,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      );

  Future<void> _showRecents() async {
    final saved = recent.take(8).toList(growable: false);
    final draft = draftTitle?.trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (sheetContext) => Scaffold(
          backgroundColor: ReferencePalette.surface,
          appBar: AppBar(title: const Text('Recents')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
              child: ListView(
                children: [
                  if (draft != null && draft.isNotEmpty) ...[
                    ReferenceCard(
                      onTap: () {
                        Navigator.pop(sheetContext);
                        create();
                      },
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          const ReferenceIcon(
                            PhosphorIcons.pencilSimple,
                            size: 28,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Unsaved paper',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                                Text(
                                  draft,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: ReferencePalette.mutedInk,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const ReferenceIcon(PhosphorIcons.caretRight,
                              size: 20),
                        ],
                      ),
                    ),
                    if (saved.isNotEmpty) const SizedBox(height: 10),
                  ],
                  if (saved.isEmpty && (draft == null || draft.isEmpty))
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          'No saved or unsaved papers yet',
                          style: TextStyle(color: ReferencePalette.mutedInk),
                        ),
                      ),
                    )
                  else
                    ...saved.map(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ReferenceCard(
                          onTap: () {
                            Navigator.pop(sheetContext);
                            _openScreen(const PapersLibraryScreen());
                          },
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              const ReferenceIcon(
                                PhosphorIcons.fileText,
                                size: 28,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      entry.title.isEmpty
                                          ? 'Untitled paper'
                                          : entry.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      '${entry.subject.isEmpty ? entry.kindLabel : entry.subject} · ${_recentDate(entry.createdAt)}',
                                      style: const TextStyle(
                                        color: ReferencePalette.mutedInk,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const ReferenceIcon(
                                PhosphorIcons.caretRight,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _recentDate(DateTime date) {
    final d = date.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  void _showNotifications() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ReferencePalette.surface,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          children: [
            const Text(
              'Notifications',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            if (promotions.notifications.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    ReferenceIcon(PhosphorIcons.bellRinging, size: 34),
                    SizedBox(height: 10),
                    Text(
                      'No new notifications',
                      style: TextStyle(color: ReferencePalette.mutedInk),
                    ),
                  ],
                ),
              )
            else
              for (final item in promotions.notifications.take(5))
                _notificationCard(item),
          ],
        ),
      ),
    );
  }

  Widget _referenceBrand() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppLogo(size: 42),
          const SizedBox(width: 10),
          const Text(
            "Tutor's Desk",
            style: TextStyle(
              color: ReferencePalette.ink,
              fontFamily: 'Bartino Outline',
              fontSize: 23,
              fontWeight: FontWeight.w700,
              letterSpacing: .1,
            ),
          ),
        ],
      );

  Widget _referenceHeader() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: _showNotifications,
            icon: const ReferenceIcon(PhosphorIcons.bellRinging, size: 27),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: () => _openScreen(const ProfileScreen()),
            borderRadius: BorderRadius.circular(32),
            child: const CircleAvatar(
              radius: 23,
              backgroundColor: Color(0xFFD7D6DB),
              child: ClipOval(
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: AppIcon(
                    PhosphorIcons.user,
                    size: 34,
                    color: ReferencePalette.ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      );

  Widget _referenceDashboard() => SizedBox(
        width: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              children: [
                SizedBox(
                  height: 180,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ReferenceActionCard(
                          large: true,
                          icon: PhosphorIcons.filePlus,
                          label: 'CREATE PAPER',
                          onTap: () => create(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(
                              child: ReferenceActionCard(
                                icon: PhosphorIcons.magicWand,
                                label: 'Assistant',
                                locked: !SubscriptionState.instance.canUse(
                                  PremiumFeature.aiAssistant,
                                ),
                                onTap: () => _openPremium(
                                  const AiToolsScreen(),
                                  PremiumFeature.aiAssistant,
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: ReferenceActionCard(
                                icon: PhosphorIcons.bookmarkSimple,
                                label: 'My Papers',
                                onTap: () =>
                                    _openScreen(const PapersLibraryScreen()),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 108,
                  child: Row(
                    children: [
                      Expanded(
                        child: ReferenceActionCard(
                          icon: PhosphorIcons.clock,
                          label: 'Recents',
                          onTap: _showRecents,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ReferenceActionCard(
                          icon: PhosphorIcons.chartBar,
                          label: 'Statistics',
                          locked: !SubscriptionState.instance.canUse(
                            PremiumFeature.omrScanner,
                          ),
                          onTap: () => _openPremium(
                            const OMrAnalyticsScreen(),
                            PremiumFeature.omrScanner,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 108,
                  child: ReferenceActionCard(
                    icon: PhosphorIcons.scan,
                    label: 'OMR Scanner',
                    multiline: true,
                    locked: !SubscriptionState.instance.canUse(
                      PremiumFeature.omrScanner,
                    ),
                    onTap: () => _openPremium(
                      const OMrScannerScreen(),
                      PremiumFeature.omrScanner,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 108,
                  child: ReferenceActionCard(
                    icon: PhosphorIcons.notePencil,
                    label: 'Editor',
                    multiline: true,
                    locked: !SubscriptionState.instance.canUse(
                      PremiumFeature.paperEditor,
                    ),
                    onTap: () => _openPremium(
                      const PaperEditorListScreen(),
                      PremiumFeature.paperEditor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
