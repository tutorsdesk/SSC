import 'dart:async';
import 'dart:convert';
import '../widgets/app_icon.dart';
import '../controllers/ai_controller.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../controllers/paper_controller.dart';
import '../data/questions_data.dart';
import '../data/english_paper_sync.dart';
import '../models/paper_draft.dart';
import '../models/subscription_entitlement.dart';
import '../models/subject_info.dart';
import '../theme/design_tokens.dart';
import '../services/app_style.dart';
import '../services/auth_service.dart';
import '../services/paper_composer.dart';
import '../services/paper_export.dart';
import '../services/paper_library.dart';
import '../services/paper_to_document.dart';
import '../services/paper_usage_service.dart';
import '../services/paper_pdf.dart';
import '../services/subscription_guard.dart';
import '../services/subscription_state.dart';
import '../services/subject_entitlement_service.dart';
import '../services/ai/teacher_ai_client.dart';
import '../theme/app_theme.dart';
import '../widgets/paper_question_card.dart';
import '../widgets/written_question_card.dart';
import '../widgets/workflow_progress.dart';
import '../widgets/motion_policy.dart';
import 'omr_scanner_screen.dart';
import 'subscription_screen.dart';
import 'ai_tools_screen.dart';

class CreatePaperScreen extends StatefulWidget {
  final bool quickStart;
  final String? initialSubjectId;
  final PaperFormat? initialFormat;
  final List<Question>? initialQuestions;
  const CreatePaperScreen({
    super.key,
    this.quickStart = false,
    this.initialSubjectId,
    this.initialFormat,
    this.initialQuestions,
  });
  @override
  State<CreatePaperScreen> createState() => _CreatePaperScreenState();
}

class _CreatePaperScreenState extends State<CreatePaperScreen> {
  late final PaperController c;
  final title = TextEditingController();
  int step = 0;
  RenderedPaper? preview;
  bool _subjectChosen = false;
  final SubjectEntitlementService subjectEntitlements =
      SubjectEntitlementService();
  static const steps = [
    'Subject',
    'Chapters & format',
    'Question counts',
    'Review questions',
    'Paper preview',
  ];
  @override
  void initState() {
    super.initState();
    final sid = widget.initialSubjectId ?? 'physics';
    final counts = PaperComposer.defaults(sid);
    c = PaperController(
      composer: PaperComposer(
        mcqBank: allMCQs,
        saqBank: allSAQs,
        cqBank: allCQs,
      ),
      initial: PaperDraft(
        subjectId: sid,
        format: widget.initialFormat ?? PaperFormat.board,
        mcqCount: counts.$1,
        saqCount: counts.$2,
        cqCount: counts.$3,
      ),
      paperUsage: PaperUsageService(),
    );
    _subjectChosen = widget.initialSubjectId != null ||
        widget.initialQuestions?.isNotEmpty == true;
    c.addListener(sync);
    unawaited(initialize());
  }

  Future<void> initialize() async {
    final subscription = SubscriptionState.instance;
    if (!subscription.initialized) {
      await subscription.initialize(refresh: AuthService.isLoggedIn);
    } else if (AuthService.isLoggedIn) {
      // A direct create-paper route must resolve the current server plan
      // before subject and paper-size limits are evaluated.
      await subscription.refresh();
    }
    await c.initialize(
      restore: widget.initialSubjectId == null &&
          widget.initialFormat == null &&
          widget.initialQuestions == null,
    );
    if (_isFreePlan && c.draft.format != PaperFormat.board) {
      // A stale deep link or restored draft must not bypass the Free format
      // policy. Model Test is the only Free generation format.
      c.update(c.draft.copyWith(format: PaperFormat.board, chapters: []));
    }
    await subjectEntitlements.load();
    if (!_subjectChosen &&
        subjectEntitlements.selectedSubjects.isEmpty &&
        mounted) {
      await _promptForInitialSubjects();
    }
    if (_subjectChosen) {
      // A subject supplied by another flow is still checked against the same
      // server-authoritative subject allowance before it can generate.
      final result = await subjectEntitlements.select(c.draft.subjectId);
      if (!result.allowed) _subjectChosen = false;
    }
    if (!mounted) return;
    if (_subjectChosen && widget.initialQuestions?.isNotEmpty == true) {
      c.useAiQuestions(widget.initialQuestions!);
      step = 3;
    }
    if (widget.quickStart &&
        _subjectChosen &&
        widget.initialQuestions == null) {
      if (await c.generate() &&
          await c.confirmSuccessfulGeneration() &&
          mounted) {
        step = 3;
      }
    }
    sync();
  }

  Future<void> _promptForInitialSubjects() async {
    final limit = SubscriptionState.instance.entitlement.subjectLimit;
    final chosen = <String>{};
    final result = await showDialog<Set<String>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('Choose your subjects'),
          content: SizedBox(
            width: 520,
            height: MediaQuery.sizeOf(context).height * .58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  limit == null
                      ? 'Select the subjects you want to unlock and use.'
                      : 'Your plan lets you unlock up to $limit subjects. Choose carefully.',
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: [
                      for (final subject in allSubjects)
                        CheckboxListTile(
                          value: chosen.contains(subject.id),
                          secondary: const AppIcon(PhosphorIcons.bookOpen),
                          title: Text(subject.name),
                          subtitle: Text(subject.bengaliName),
                          onChanged: (selected) {
                            updateDialog(() {
                              if (selected == true &&
                                  (limit == null || chosen.length < limit)) {
                                chosen.add(subject.id);
                              } else if (selected != true) {
                                chosen.remove(subject.id);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: chosen.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, Set.of(chosen)),
              child: const Text('Unlock subjects'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    for (final id in result) {
      final selection = await subjectEntitlements.select(id);
      if (!selection.allowed) break;
    }
    if (!mounted || result.isEmpty) return;
    c.selectSubject(result.first);
    _subjectChosen = true;
  }

  bool get _isFreePlan =>
      SubscriptionState.instance.plan == SubscriptionPlan.free;

  bool _subjectIsLocked(String id) {
    final entitlement = SubscriptionState.instance.entitlement;
    final selected = subjectEntitlements.selectedSubjects;
    return !selected.contains(id) &&
        entitlement.subjectLimit != null &&
        selected.length >= entitlement.subjectLimit!;
  }

  bool _formatIsLocked(PaperFormat format) =>
      (_isFreePlan && format != PaperFormat.board) ||
      (PaperComposer.isEnglish(c.draft.subjectId) &&
          format != PaperFormat.board);

  Future<void> _explainLockedFormat(PaperFormat format) async {
    final englishLocked = PaperComposer.isEnglish(c.draft.subjectId) &&
        format != PaperFormat.board;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Format locked'),
        content: Text(
          englishLocked
              ? 'English papers use the randomized full question pool. This format is not available for English.'
              : 'Free includes exactly two Model Test generations per Asia/Dhaka month. Upgrade to unlock Chapter Test, Custom Paper, and MCQ + OMR.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
          if (!englishLocked)
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
                );
              },
              child: const Text('Upgrade Plan'),
            ),
        ],
      ),
    );
  }

  void _selectFormat(PaperFormat format) {
    if (_formatIsLocked(format)) {
      unawaited(_explainLockedFormat(format));
      return;
    }
    c.update(c.draft.copyWith(format: format, chapters: []));
  }

  Widget _subjectTile(SubjectInfo subject) {
    final locked = _subjectIsLocked(subject.id);
    final english = PaperComposer.isEnglish(subject.id);
    return Card(
      child: RadioListTile<String>(
        // Locked subjects remain tappable so the upgrade explanation is
        // available instead of making the plan boundary look like missing data.
        secondary: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              PhosphorIcons.bookOpen,
              color: english ? AppColors.writing : AppTheme.muted,
            ),
            if (locked) ...[
              const SizedBox(width: 8),
              const AppIcon(PhosphorIcons.lock, size: 18),
            ],
          ],
        ),
        activeColor: english ? AppColors.writing : AppTheme.primary,
        title: Text(subject.name),
        subtitle: Text(
          '${subject.bengaliName} · ${english ? 'English sections available' : 'SSC question bank'}${locked ? ' · Upgrade to unlock' : ''}',
        ),
        value: subject.id,
        groupValue: _subjectChosen ? c.draft.subjectId : null,
        onChanged: (id) {
          if (id != null) _selectSubject(id);
        },
      ),
    );
  }

  Future<void> _selectSubject(String id) async {
    final result = await subjectEntitlements.select(id);
    if (!mounted) return;
    if (!result.allowed) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Subject limit reached'),
          content: Text(result.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SubscriptionScreen()),
                );
              },
              child: const Text('Upgrade Plan'),
            ),
          ],
        ),
      );
      return;
    }
    _subjectChosen = true;
    c.selectSubject(id);
    AppStyle.mood.value = PaperComposer.isEnglish(id)
        ? WorkspaceMood.english
        : WorkspaceMood.home;
  }

  void sync() {
    if (!mounted) return;
    if (title.text != c.draft.title)
      title.value = TextEditingValue(
        text: c.draft.title,
        selection: TextSelection.collapsed(offset: c.draft.title.length),
      );
    setState(() {});
  }

  @override
  void dispose() {
    c.removeListener(sync);
    c.dispose();
    title.dispose();
    super.dispose();
  }

  Future<void> next() async {
    if (step == 0 && !_subjectChosen) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a subject before continuing.')),
      );
      return;
    }
    if (step == 2) {
      if (c.paper == null && !await c.generate()) return;
      // Reaching Review questions is the successful-generation boundary. Only
      // now is the monthly allowance consumed for these exact questions.
      if (!await c.confirmSuccessfulGeneration()) return;
    }
    if (step == 3) {
      if (c.paper == null) return;
      final ok = await c.run('Rendering the exact print layout…', () async {
        final result = await PaperExport.render(
          c.draft,
          c.paper!,
          watermark: SubscriptionState.instance.shouldShowWatermark,
        );
        if (mounted) preview = result;
      });
      if (!ok) return;
    }
    if (mounted) setState(() => step = (step + 1).clamp(0, 4).toInt());
  }

  Future<bool> allowExport(String action) async {
    final state = SubscriptionState.instance;
    if (!state.initialized) await state.initialize(refresh: false);
    if (action == 'omr' && mounted) {
      return SubscriptionGuard.require(context, PremiumFeature.omrScanner);
    }
    // Free and Basic may export with a watermark. Entitlements decide the
    // watermark itself; export is not silently blocked by the pricing UI.
    return mounted;
  }

  Future<void> export(String action) async {
    if (c.busy || preview == null || c.paper == null) return;
    if (!await allowExport(action)) return;
    await c.run(
      action == 'save' ? 'Saving your paper…' : 'Preparing export…',
      () async {
        final d = c.draft;
        final p = c.paper!;
        if (action == 'save') {
          await PaperLibrary.addSavedPaper(
            SavedPaper(
              id: 'sp_${DateTime.now().microsecondsSinceEpoch}',
              title: d.title,
              subject: c.subject!.bengaliName,
              subjectId: d.subjectId,
              subjectCode: PaperComposer.codes[d.subjectId] ?? '',
              setCode: d.setCode,
              total: p.mcqs.length,
              key: p.mcqs.map((q) => q.correctIndex).toList(),
              questions: [
                for (final q in p.mcqs)
                  SavedQuestion(
                    text: q.questionText,
                    options: q.options,
                    answer: q.correctIndex,
                  ),
              ],
              createdAt: DateTime.now(),
              pages: preview!.pages.length,
              document: SavedPaperEditing.fullDocument(
                title: d.title,
                subject: c.subject!.bengaliName,
                marks: '${p.marks}',
                paper: p,
              ).toJson(),
            ),
            pageImages: preview!.pages,
          );
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Saved in My Papers with its answer key.'),
              ),
            );
        } else if (action == 'omr') {
          await PaperPdf.printOmrSheet(
            total: p.mcqs.length,
            title: d.title,
            subjectCode: PaperComposer.codes[d.subjectId],
            setCode: d.setCode,
          );
        } else if (action == 'print') {
          await Printing.layoutPdf(onLayout: (_) async => preview!.pdf);
        } else {
          await Printing.sharePdf(
            bytes: preview!.pdf,
            filename: 'question-paper.pdf',
          );
        }
      },
    );
  }

  Future<void> _draftShortAnswerKey(int index, ShortQuestion q) async {
    if (!await SubscriptionGuard.require(context, PremiumFeature.aiAssistant)) {
      return;
    }
    if (!mounted) return;
    final client = TeacherAiClient();
    try {
      final response = await client.request(
        {
          'action': 'draft_answer_key',
          'subjectId': q.subjectId,
          'chapters': [q.chapter],
          'count': 1,
          'difficulty': 'mixed',
          'text': jsonEncode({'question': q.questionText}),
          'instruction':
              'Draft a concise, mark-aware answer. It must be reviewed by the teacher before use.',
        },
        (message) {
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
        },
      );
      final draft = response['answerKey'];
      if (response['kind'] != 'answer_key' ||
          response['draft'] != true ||
          draft is! String ||
          draft.trim().isEmpty) {
        throw StateError('The AI answer-key draft was incomplete. Try again.');
      }
      if (mounted) {
        c.editWritten(
          index,
          ShortQuestion(
            id: q.id,
            subjectId: q.subjectId,
            chapter: q.chapter,
            questionText: q.questionText,
            answer: q.answer,
            answerKey: draft.trim(),
            explanation: q.explanation,
            source: q.source,
            sourceLabel: q.sourceLabel,
            figure: q.figure,
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI draft key added. Review it before publishing.'),
          ),
        );
      }
    } on TeacherAiError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not draft the answer key: $error')),
        );
      }
    } finally {
      client.close();
    }
  }

  Future<void> _draftCreativeAnswerKey(int index, CreativeQuestion q) async {
    if (!await SubscriptionGuard.require(context, PremiumFeature.aiAssistant)) {
      return;
    }
    if (!mounted) return;
    final client = TeacherAiClient();
    try {
      final response = await client.request(
        {
          'action': 'draft_answer_key',
          'subjectId': q.subjectId,
          'chapters': [q.chapter],
          'count': 1,
          'difficulty': 'mixed',
          'text': jsonEncode({
            'stem': q.stem,
            'ক': q.questionK,
            'খ': q.questionKh,
            'গ': q.questionG,
            if (q.questionGh.trim().isNotEmpty) 'ঘ': q.questionGh,
            'marks': q.marks,
          }),
          'instruction':
              'Give a concise, mark-aware draft answer for each visible part. It must be reviewed by the teacher before use.',
        },
        (message) {
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(message)));
        },
      );
      final draft = response['answerKey'];
      if (response['kind'] != 'answer_key' ||
          response['draft'] != true ||
          draft is! String ||
          draft.trim().isEmpty) {
        throw StateError('The AI answer-key draft was incomplete. Try again.');
      }
      final updated = CreativeQuestion(
        id: q.id,
        subjectId: q.subjectId,
        chapter: q.chapter,
        stem: q.stem,
        questionK: q.questionK,
        questionKh: q.questionKh,
        questionG: q.questionG,
        questionGh: q.questionGh,
        answerKey: draft.trim(),
        marks: q.marks,
        source: q.source,
        sourceLabel: q.sourceLabel,
        figure: q.figure,
      );
      if (mounted) {
        c.editWritten(index, updated);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('AI draft key added. Review it before publishing.'),
          ),
        );
      }
    } on TeacherAiError catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.userMessage)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not draft the answer key: $error')),
        );
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: step == 0 && !c.busy,
        onPopInvoked: (didPop) {
          if (!didPop && !c.busy && step > 0) setState(() => step--);
        },
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Create Paper'),
            actions: [
              IconButton(
                tooltip: 'Undo',
                onPressed: c.canUndo
                    ? () {
                        c.undo();
                        if (step == 4) setState(() => step = 3);
                      }
                    : null,
                icon: const AppIcon(PhosphorIcons.arrowCounterClockwise),
              ),
              IconButton(
                tooltip: 'Redo',
                onPressed: c.canRedo
                    ? () {
                        c.redo();
                        if (step == 4) setState(() => step = 3);
                      }
                    : null,
                icon: const AppIcon(PhosphorIcons.arrowClockwise),
              ),
            ],
          ),
          body: !c.initialized
              ? const Center(child: ActivityIndicator(size: 24))
              : Column(
                  children: [
                    WorkflowProgress(steps: steps, current: step),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          const AppDuotoneIcon(
                            PhosphorIcons.floppyDiskDuotone,
                            size: 14,
                            color: AppTheme.muted,
                            secondaryColor: AppColors.secondary,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              c.saveError ??
                                  (c.savedAt == null
                                      ? 'Draft saves automatically on this device'
                                      : 'Auto-saved ${TimeOfDay.fromDateTime(c.savedAt!).format(context)}'),
                              style: TextStyle(
                                fontSize: 11,
                                color: c.saveError == null
                                    ? AppTheme.muted
                                    : AppTheme.danger,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: AbsorbPointer(
                        absorbing: c.busy,
                        child: step == 4
                            ? previewBody()
                            : ListView(
                                padding: const EdgeInsets.all(20),
                                children: [
                                  OperationNotice(
                                    error: c.error,
                                    activity: c.activity,
                                  ),
                                  if (step == 0) subjectStep(),
                                  if (step == 1) chapterStep(),
                                  if (step == 2) countsStep(),
                                  if (step == 3) reviewStep(),
                                ],
                              ),
                      ),
                    ),
                    if (step == 4)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: OperationNotice(
                          error: c.error,
                          activity: c.activity,
                        ),
                      ),
                  ],
                ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: step < 4
                  ? Row(
                      children: [
                        if (step > 0)
                          TextButton(
                            onPressed:
                                c.busy ? null : () => setState(() => step--),
                            child: const Text('Back'),
                          ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: c.busy || !c.initialized ? null : next,
                          icon: c.busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: ActivityIndicator(strokeWidth: 2),
                                )
                              : AppIcon(
                                  step == 3
                                      ? PhosphorIcons.eye
                                      : PhosphorIcons.arrowRight,
                                  size: 18,
                                ),
                          label: Text(
                            c.busy
                                ? 'Working…'
                                : step == 2
                                    ? 'Select questions'
                                    : step == 3
                                        ? 'Preview paper'
                                        : 'Continue',
                          ),
                        ),
                      ],
                    )
                  : Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: c.busy ? null : () => export('pdf'),
                          icon: const AppDuotoneIcon(
                            PhosphorIcons.filePdfDuotone,
                            color: AppColors.onColor,
                            secondaryColor: AppColors.light,
                            size: 18,
                          ),
                          label: const Text('Export PDF'),
                        ),
                        OutlinedButton.icon(
                          onPressed: c.busy ? null : () => export('save'),
                          icon: const AppDuotoneIcon(
                            PhosphorIcons.bookmarkSimpleDuotone,
                            color: AppTheme.primary,
                            secondaryColor: AppColors.secondary,
                            size: 18,
                          ),
                          label: const Text('Save'),
                        ),
                        IconButton(
                          tooltip: 'Print',
                          onPressed: c.busy ? null : () => export('print'),
                          icon: const AppDuotoneIcon(
                            PhosphorIcons.printerDuotone,
                            color: AppTheme.primary,
                            secondaryColor: AppColors.secondary,
                          ),
                        ),
                        if (c.paper?.mcqs.isNotEmpty == true)
                          PopupMenuButton<String>(
                            enabled: !c.busy,
                            onSelected: (value) async {
                              if (!await SubscriptionGuard.require(
                                context,
                                PremiumFeature.omrScanner,
                              )) {
                                return;
                              }
                              if (value == 'scan')
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => OMrScannerScreen(
                                      initialKey: c.paper!.mcqs
                                          .map((q) => q.correctIndex)
                                          .toList(),
                                      paperTitle: c.draft.title,
                                      initialSubject: c.subject!.bengaliName,
                                    ),
                                  ),
                                );
                              else
                                await export('omr');
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'omr',
                                child: Text('Print OMR sheet'),
                              ),
                              PopupMenuItem(
                                value: 'scan',
                                child: Text('Scan answers'),
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
          ),
        ),
      );

  Widget subjectStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _subjectChosen
                ? 'What are you teaching?'
                : 'Choose a subject first',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Choose a subject. Questions come from the saved SSC bank. Your plan controls how many subjects you can keep selected.',
          ),
          const SizedBox(height: 20),
          for (final s in allSubjects) _subjectTile(s),
        ],
      );
  Widget chapterStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Choose the paper format',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          if (PaperComposer.isEnglish(c.draft.subjectId)) ...[
            DropdownButtonFormField<String>(
              value: EnglishPaperSync.choices(
                c.draft.subjectId,
              ).containsKey(c.draft.englishPaperId)
                  ? c.draft.englishPaperId
                  : '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Randomized English model pool',
              ),
              items: const [
                DropdownMenuItem(
                    value: '', child: Text('Randomized practice set')),
              ],
              onChanged: (id) => c.update(
                c.draft
                    .copyWith(englishPaperId: id, clearEnglishPaper: id == ''),
              ),
            ),
            const SizedBox(height: 16),
          ],
          for (final f in PaperFormat.values)
            Card(
              child: RadioListTile<PaperFormat>(
                secondary: _formatIsLocked(f)
                    ? const AppIcon(PhosphorIcons.lock)
                    : null,
                title: Text(switch (f) {
                  PaperFormat.board =>
                    _isFreePlan ? 'Model Test' : 'Board Pattern',
                  PaperFormat.chapter => 'Chapter Test',
                  PaperFormat.custom => 'Custom Paper',
                  PaperFormat.mcq => 'MCQ + OMR',
                }),
                subtitle: Text(switch (f) {
                  PaperFormat.board => _isFreePlan
                      ? 'Two server-verified generations per Asia/Dhaka month'
                      : 'Complete subject pattern from the saved bank',
                  PaperFormat.chapter => _formatIsLocked(f)
                      ? 'Upgrade to unlock this format'
                      : 'Practice selected chapters',
                  PaperFormat.custom => _formatIsLocked(f)
                      ? 'Upgrade to unlock this format'
                      : 'Choose your MCQ, short-answer and CQ counts',
                  PaperFormat.mcq => _formatIsLocked(f)
                      ? 'Upgrade to unlock this format'
                      : 'Up to 100 MCQs with an answer key',
                }),
                value: f,
                groupValue: c.draft.format,
                onChanged: (next) {
                  if (next != null) _selectFormat(next);
                },
              ),
            ),
          if (c.draft.format != PaperFormat.board) ...[
            const SizedBox(height: 20),
            Text('Chapters', style: Theme.of(context).textTheme.titleLarge),
            Text(
              c.draft.format == PaperFormat.chapter
                  ? 'Select at least one chapter.'
                  : 'Leave all unchecked to use the whole bank.',
            ),
            if (c.chapters.isEmpty)
              const OperationNotice(
                error: 'No questions are available for this subject yet.',
              ),
            for (final ch in c.chapters)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(ch),
                value: c.draft.chapters.contains(ch),
                onChanged: (selected) {
                  final next = [...c.draft.chapters];
                  if (selected == true)
                    next.add(ch);
                  else
                    next.remove(ch);
                  c.update(c.draft.copyWith(chapters: next));
                },
              ),
          ],
        ],
      );
  Widget countsStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Set up your paper',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 18),
          TextField(
            controller: title,
            decoration: const InputDecoration(labelText: 'Paper title'),
            onChanged: (v) =>
                c.update(c.draft.copyWith(title: v), preserveQuestions: true),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<String>(
            value: c.draft.setCode,
            decoration: const InputDecoration(labelText: 'Set code'),
            items: [
              for (final s in const ['ক', 'খ', 'গ', 'ঘ'])
                DropdownMenuItem(value: s, child: Text(s)),
            ],
            onChanged: (s) =>
                c.update(c.draft.copyWith(setCode: s), preserveQuestions: true),
          ),
          const SizedBox(height: 16),
          if (c.draft.format == PaperFormat.board)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  PaperComposer.isEnglish(c.draft.subjectId)
                      ? 'Reading / Grammar and Writing • 100 marks. Complete English sections are preserved.'
                      : '${_isFreePlan ? 'Model Test' : 'Board Pattern'} uses the subject’s fixed distribution and answer counts. Practical marks are not part of the printed theory paper.',
                ),
              ),
            )
          else ...[
            count(
              'MCQ',
              c.draft.mcqCount,
              100,
              (v) => c.update(c.draft.copyWith(mcqCount: v)),
            ),
            if (c.draft.format != PaperFormat.mcq) ...[
              count(
                'Short answer · 2 marks',
                c.draft.saqCount,
                30,
                (v) => c.update(c.draft.copyWith(saqCount: v)),
              ),
              count(
                'Creative question · 10 marks',
                c.draft.cqCount,
                15,
                (v) => c.update(c.draft.copyWith(cqCount: v)),
              ),
            ],
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Include answer key in PDF'),
            subtitle: const Text(
              'Includes available MCQ, SQ and reviewed/AI-draft CQ keys.',
            ),
            value: c.draft.answerKey,
            onChanged: (v) => c.update(c.draft.copyWith(answerKey: v),
                preserveQuestions: true),
          ),
        ],
      );
  Widget count(String label, int value, int max, ValueChanged<int> change) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(child: Text(label)),
              IconButton(
                tooltip: 'Fewer $label',
                onPressed: value > 0 ? () => change(value - 1) : null,
                icon: const AppIcon(PhosphorIcons.minusCircle),
              ),
              SizedBox(
                width: 32,
                child: Text('$value', textAlign: TextAlign.center),
              ),
              IconButton(
                tooltip: 'More $label',
                onPressed: value < max ? () => change(value + 1) : null,
                icon: const AppIcon(PhosphorIcons.plusCircle),
              ),
            ],
          ),
        ),
      );
  Widget reviewStep() {
    final p = c.paper;
    if (p == null)
      return Column(
        children: [
          const Text('Choose counts and select questions to continue.'),
          TextButton(
            onPressed: () => setState(() => step = 2),
            child: const Text('Back to counts'),
          ),
        ],
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Review before printing',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          '${p.marks} marks · ${p.minutes} minutes · ${p.mcqs.length} MCQ · ${p.saqs.length} short · ${p.cqs.length} CQ',
        ),
        const SizedBox(height: 8),
        const Text(
          'Verify the question wording and answer key. Undo is available for every change.',
          style: TextStyle(color: AppTheme.muted),
        ),
        if (!PaperComposer.isEnglish(c.draft.subjectId))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: OutlinedButton.icon(
              onPressed: () async {
                if (!await SubscriptionGuard.require(
                  context,
                  PremiumFeature.aiAssistant,
                )) return;
                final questions = await Navigator.push<List<Question>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AiToolsScreen(
                      subjectId: c.draft.subjectId,
                      chapter: c.draft.chapters.isEmpty
                          ? null
                          : c.draft.chapters.first,
                      currentPaper: p.mcqs,
                      forSelection: true,
                    ),
                  ),
                );
                if (mounted && questions != null) c.addAiQuestions(questions);
              },
              icon: const AppDuotoneIcon(
                PhosphorIcons.magicWandDuotone,
                color: AppTheme.primary,
                secondaryColor: AppColors.secondary,
                size: 18,
              ),
              label: const Text('Add reviewed AI questions'),
            ),
          ),
        for (var i = 0; i < p.mcqs.length; i++)
          PaperQuestionCard(
            question: p.mcqs[i],
            onReplace: () => c.replaceQuestion(i),
            onImprove: () async {
              if (!await SubscriptionGuard.require(
                context,
                PremiumFeature.aiAssistant,
              )) return;
              final q = p.mcqs[i];
              final edited = await Navigator.push<List<Question>>(
                context,
                MaterialPageRoute(
                  builder: (_) => AiToolsScreen(
                    subjectId: q.subjectId,
                    chapter: q.chapter,
                    currentPaper: p.mcqs,
                    forSelection: true,
                    replaceSelection: true,
                    initialCommand: TeacherCommand.improve,
                    initialText: jsonEncode({
                      'question': q.questionText,
                      'options': q.options,
                    }),
                  ),
                ),
              );
              if (mounted && edited?.length == 1)
                c.editQuestion(i, edited!.single);
            },
            onEdit: (q) => c.editQuestion(i, q),
            onDelete: c.draft.format == PaperFormat.board
                ? null
                : () => c.removeQuestion(i),
          ),
        if (p.saqs.isNotEmpty)
          Text(
            'Short answers · answer ${p.saqAnswers}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        for (var i = 0; i < p.saqs.length; i++)
          WrittenQuestionCard(
            question: p.saqs[i],
            onDraftAnswerKey: () => _draftShortAnswerKey(i, p.saqs[i]),
            onEdit: (q) => c.editWritten(i, q),
            onReplace: () => c.replaceWritten(i, creative: false),
            onDelete: c.draft.format == PaperFormat.board
                ? null
                : () => c.removeWritten(i, creative: false),
          ),
        if (p.cqs.isNotEmpty)
          Text(
            'সৃজনশীল প্রশ্ন · answer ${p.cqAnswers}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        for (var i = 0; i < p.cqs.length; i++)
          WrittenQuestionCard(
            question: p.cqs[i],
            onDraftAnswerKey: () => _draftCreativeAnswerKey(i, p.cqs[i]),
            onEdit: (q) => c.editWritten(i, q),
            onReplace: () => c.replaceWritten(i, creative: true),
            onDelete: c.draft.format == PaperFormat.board
                ? null
                : () => c.removeWritten(i, creative: true),
          ),
        if (p.english.isNotEmpty ||
            p.literature.isNotEmpty ||
            p.written.isNotEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Language-paper sections are preserved in full. Review their complete layout in the next step.',
              ),
            ),
          ),
      ],
    );
  }

  Widget previewBody() {
    if (preview == null)
      return const Center(child: Text('Return to review to render the paper.'));
    return Column(
      children: [
        Semantics(
          liveRegion: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const AppIcon(
                  PhosphorIcons.checkCircle,
                  color: AppTheme.success,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  'PDF ready · ${preview!.pages.length} pages',
                  style: const TextStyle(
                    color: AppTheme.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            'Scroll to view every page at full size',
            style: TextStyle(color: AppTheme.muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final desktop = constraints.maxWidth >= 700;
              return ListView.separated(
                padding: EdgeInsets.fromLTRB(
                  desktop ? 24 : 16,
                  4,
                  desktop ? 24 : 16,
                  32,
                ),
                itemCount: preview!.pages.length,
                separatorBuilder: (_, __) => const SizedBox(height: 28),
                itemBuilder: (_, i) => Column(
                  children: [
                    Text(
                      'Page ${i + 1} of ${preview!.pages.length}',
                      style: const TextStyle(
                        color: AppTheme.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: desktop ? 1000 : 720,
                        ),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: AppColors.border),
                            boxShadow: desktop
                                ? const [
                                    BoxShadow(
                                      color: Color(0x16000000),
                                      blurRadius: 18,
                                      offset: Offset(0, 7),
                                    ),
                                  ]
                                : null,
                          ),
                          child: Image.memory(
                            preview!.pages[i],
                            width: double.infinity,
                            fit: BoxFit.fitWidth,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
