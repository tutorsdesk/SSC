import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../widgets/app_icon.dart';
import '../widgets/motion_policy.dart';
import '../theme/design_tokens.dart';
import 'package:printing/printing.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/paper_library.dart';
import '../services/subscription_guard.dart';
import '../models/subscription_entitlement.dart';
import 'omr_scanner_screen.dart';
import '../services/paper_to_document.dart';
import 'paper_editor_screen.dart';

class SavedPaperScreen extends StatefulWidget {
  final PaperEntry entry;
  const SavedPaperScreen({super.key, required this.entry});
  @override
  State<SavedPaperScreen> createState() => _SavedPaperScreenState();
}

class _SavedPaperScreenState extends State<SavedPaperScreen> {
  List<Uint8List>? pages;
  String? error;
  bool busy = false;
  SavedPaper? saved;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      saved = await PaperLibrary.savedPaper(widget.entry.id);
      var images = <Uint8List>[];
      // The saved record has the current page count; the list entry can be
      // older (the paper's pages may have been replaced by an edit).
      final count = (saved?.pages ?? 0) > 0 ? saved!.pages : widget.entry.pages;
      for (var i = 1; widget.entry.kind != 'pdf' && i <= count; i++) {
        final bytes = await PaperLibrary.pageBytes(widget.entry.id, i);
        if (bytes == null)
          throw StateError(
            'A page is missing. Restore this paper from backup.',
          );
        images.add(bytes);
      }
      if (images.isEmpty) {
        final bytes = await PaperLibrary.pdfBytes(widget.entry.id);
        if (bytes != null) {
          images = [];
          await for (final page in Printing.raster(bytes, dpi: 120)) {
            images.add(await page.toPng());
          }
        }
      }
      if (images.isEmpty)
        throw StateError(
          'No printable pages are available. Restore this paper from backup or create it again.',
        );
      if (mounted) setState(() => pages = images);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> action(bool print) async {
    setState(() => busy = true);
    try {
      if (print)
        await PaperLibrary.printEntry(widget.entry);
      else
        await PaperLibrary.shareEntry(widget.entry);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not export: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Opens an editable copy of this paper in the paper editor. The saved
  /// paper and its answer key stay as they are.
  Future<void> _editCopy() async {
    final current = saved;
    if (current == null || current.questions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This paper has no question text to edit.'),
        ),
      );
      return;
    }
    if (!await SubscriptionGuard.require(
      context,
      PremiumFeature.paperEditor,
      title: 'Question Paper Editor',
    )) {
      return;
    }
    if (!mounted) return;
    final doc = await SavedPaperEditing.openCopy(current);
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => PaperEditorScreen(document: doc)),
    );
    // Edits to the copy may have replaced this paper's pages.
    if (!mounted) return;
    setState(() {
      pages = null;
      error = null;
    });
    await load();
  }

  Future<void> _scanSaved() async {
    final current = saved;
    if (current == null || !mounted) return;
    if (!await SubscriptionGuard.require(context, PremiumFeature.omrScanner)) {
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OMrScannerScreen(
          initialKey: current.key,
          paperTitle: widget.entry.title,
          initialSubject: widget.entry.subject,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.entry.title),
          actions: [
            IconButton(
              tooltip: 'Edit a copy',
              onPressed: busy || saved == null ? null : _editCopy,
              icon: const AppIcon(PhosphorIcons.notePencil),
            ),
            IconButton(
              tooltip: 'Print',
              onPressed: busy || pages == null ? null : () => action(true),
              icon: const AppDuotoneIcon(
                PhosphorIcons.printerDuotone,
                color: AppColors.primary,
                secondaryColor: AppColors.secondary,
              ),
            ),
            IconButton(
              tooltip: 'Share PDF',
              onPressed: busy || pages == null ? null : () => action(false),
              icon: const AppDuotoneIcon(
                PhosphorIcons.shareDuotone,
                color: AppColors.primary,
                secondaryColor: AppColors.secondary,
              ),
            ),
          ],
        ),
        body: error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(error!),
                ),
              )
            : pages == null
                ? const Center(child: ActivityIndicator())
                : Column(
                    children: [
                      if (busy) const ActivityBar(),
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('Scroll to view every page at full size'),
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
                              itemCount: pages!.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 28),
                              itemBuilder: (_, i) => Column(
                                children: [
                                  Text(
                                    'Page ${i + 1} of ${pages!.length}',
                                    style: const TextStyle(
                                      color: AppColors.muted,
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
                                          border: Border.all(
                                            color: AppColors.border,
                                          ),
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
                                          pages![i],
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
                  ),
        bottomNavigationBar: saved?.key.isNotEmpty == true
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: OutlinedButton.icon(
                    onPressed: _scanSaved,
                    icon: const AppDuotoneIcon(
                      PhosphorIcons.scanDuotone,
                      color: AppColors.primary,
                      secondaryColor: AppColors.secondary,
                    ),
                    label: const Text('Scan answers for this paper'),
                  ),
                ),
              )
            : null,
      );
}
