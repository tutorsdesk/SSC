import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/paper_document.dart';
import '../services/paper_document_layout.dart';
import '../services/paper_document_render.dart';
import '../services/paper_document_store.dart';
import '../services/paper_to_document.dart';
import '../services/paper_image_codec.dart';
import '../services/paper_spell.dart';
import '../theme/design_tokens.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';
import '../widgets/app_icon.dart';

typedef _FormField = ({String key, String label, String initial});

const List<double> _fontSizes = [10, 11, 12, 13, 14, 16, 18, 20, 24];

const List<ParaKind> _styleKinds = [
  ParaKind.title,
  ParaKind.heading,
  ParaKind.normal,
  ParaKind.instruction,
  ParaKind.question,
  ParaKind.option,
];

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.day}/${t.month}/${t.year} ${_two(t.hour)}:${_two(t.minute)}';

TextAlign _textAlignOf(ParaAlign a) => switch (a) {
      ParaAlign.left => TextAlign.left,
      ParaAlign.center => TextAlign.center,
      ParaAlign.right => TextAlign.right,
      ParaAlign.justify => TextAlign.justify,
    };

bool _sameStyles(List<CharStyle> a, List<CharStyle> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Word-style editor for one question paper.
///
/// The page is an editable column of paragraphs. The ribbon (Home, Insert,
/// Layout) applies formatting to the selected text or the focused paragraph.
/// Changes autosave to the tutor's account; PDF export uses the same layout
/// rules as the printed page.
class PaperEditorScreen extends StatefulWidget {
  /// The document to open, or null to start a new one.
  final PaperDocument? document;

  const PaperEditorScreen({super.key, this.document});

  @override
  State<PaperEditorScreen> createState() => _PaperEditorScreenState();
}

class _PaperEditorScreenState extends State<PaperEditorScreen> {
  late PaperDocument _doc;
  final List<PaperDocument> _undo = [];
  final List<PaperDocument> _redo = [];
  final Map<String, GlobalKey<_ParagraphFieldState>> _keys = {};
  DateTime _lastEdit = DateTime.fromMillisecondsSinceEpoch(0);
  String? _focusId;
  CharStyle _active = CharStyle.plain;
  String _tab = 'Home';
  double _zoom = 1.0;
  bool _busy = false;
  bool _dirty = false;
  int _editSerial = 0;
  Timer? _saveTimer;
  String _status = 'Not saved yet';

  @override
  void initState() {
    super.initState();
    _doc = widget.document ?? PaperDocument.blank(id: newDocId());
    if (widget.document != null) _status = 'Saved';
    PaperSpell.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    if (_dirty) {
      // Keep edits made just before leaving the screen.
      _persist();
    }
    super.dispose();
  }

  // ── State helpers ──────────────────────────────────────────────

  DocParagraph? get _focusPara {
    final id = _focusId;
    if (id == null) return null;
    final i = _doc.indexOf(id);
    return i < 0 ? null : _doc.paragraphs[i];
  }

  _ParagraphFieldState? get _fieldState {
    final id = _focusId;
    if (id == null) return null;
    return _keys[id]?.currentState;
  }

  GlobalKey<_ParagraphFieldState> _keyFor(String id) =>
      _keys.putIfAbsent(id, () => GlobalKey<_ParagraphFieldState>());

  void _focusLater(String id, {bool atEnd = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = _keys[id]?.currentState;
      if (state == null) return;
      if (atEnd) {
        state.focusEnd();
      } else {
        state.focusStart();
      }
    });
  }

  // ── Document changes ───────────────────────────────────────────

  void _commit(PaperDocument next, {bool coalesce = false}) {
    final now = DateTime.now();
    final merge = coalesce &&
        _undo.isNotEmpty &&
        now.difference(_lastEdit).inMilliseconds < 1200;
    setState(() {
      if (!merge) {
        _undo.add(_doc);
        if (_undo.length > 200) _undo.removeAt(0);
      }
      _redo.clear();
      _doc = next;
    });
    _lastEdit = now;
    _editSerial++;
    _dirty = true;
    _status = 'Unsaved changes';
    _scheduleSave();
  }

  void _undoStep() {
    if (_undo.isEmpty) return;
    setState(() {
      _redo.add(_doc);
      _doc = _undo.removeLast();
    });
    _editSerial++;
    _dirty = true;
    _status = 'Unsaved changes';
    _scheduleSave();
  }

  void _redoStep() {
    if (_redo.isEmpty) return;
    setState(() {
      _undo.add(_doc);
      _doc = _redo.removeLast();
    });
    _editSerial++;
    _dirty = true;
    _status = 'Unsaved changes';
    _scheduleSave();
  }

  /// Text typed into a paragraph or table cell. Top-level paragraphs may
  /// split on newlines; table cells keep them inside the cell.
  void _onParagraphText(String id, String text, CharStyle? typing) {
    final current = findParagraph(_doc.paragraphs, id);
    if (current == null) return;
    final inCell = locateCell(_doc.paragraphs, id) != null;
    final pieces = editParagraphText(
      current,
      text,
      typing: typing,
      split: !inCell,
    );
    if (inCell) {
      _commit(
        _doc.copyWith(
          paragraphs: replaceById(_doc.paragraphs, id, pieces.first),
        ),
        coalesce: true,
      );
      return;
    }
    final i = _doc.indexOf(id);
    if (i < 0) return;
    _commit(
      _doc.copyWith(paragraphs: replaceParagraph(_doc.paragraphs, i, pieces)),
      coalesce: pieces.length == 1,
    );
    if (pieces.length > 1) {
      _focusId = pieces.last.id;
      _focusLater(pieces.last.id);
    }
  }

  /// Formatting change of one paragraph's (or cell's) characters.
  void _onRestyle(DocParagraph next) {
    if (findParagraph(_doc.paragraphs, next.id) == null) return;
    _commit(
      _doc.copyWith(
        paragraphs: replaceById(_doc.paragraphs, next.id, next),
      ),
    );
  }

  void _onFieldActive(String id, CharStyle active) {
    if (_focusId == id && _active == active) return;
    setState(() {
      _focusId = id;
      _active = active;
    });
  }

  void _selectBlock(String id) => setState(() => _focusId = id);

  void _setKind(ParaKind kind) {
    final p = _focusPara;
    if (p == null || p.kind == kind) return;
    final i = _doc.indexOf(p.id);
    _commit(
      _doc.copyWith(
        paragraphs: replaceParagraph(
          _doc.paragraphs,
          i,
          [p.copyWith(kind: kind)],
        ),
      ),
    );
  }

  void _setAlign(ParaAlign align) {
    final p = _focusPara;
    if (p == null || p.align == align) return;
    final i = _doc.indexOf(p.id);
    _commit(
      _doc.copyWith(
        paragraphs: replaceParagraph(
          _doc.paragraphs,
          i,
          [p.copyWith(align: align)],
        ),
      ),
    );
  }

  void _insertAfterFocus(List<DocParagraph> items, {int focus = 0}) {
    final fi = _focusId == null ? -1 : _doc.indexOf(_focusId!);
    final at = fi < 0 ? _doc.paragraphs.length : fi + 1;
    final list = [
      ..._doc.paragraphs.sublist(0, at),
      ...items,
      ..._doc.paragraphs.sublist(at),
    ];
    _commit(_doc.copyWith(paragraphs: list));
    final target = items[focus];
    _focusId = target.id;
    _focusLater(target.id);
  }

  void _deleteFocused() {
    final p = _focusPara;
    if (p == null) return;
    final i = _doc.indexOf(p.id);
    var list = [..._doc.paragraphs]..removeAt(i);
    if (list.isEmpty) {
      list = [DocParagraph(id: newParaId(), kind: ParaKind.normal)];
    }
    final target = list[i > 0 ? i - 1 : 0];
    _keys.remove(p.id);
    _commit(_doc.copyWith(paragraphs: list));
    _focusId = target.id;
    _focusLater(target.id, atEnd: true);
  }

  void _moveFocused(int delta) {
    final p = _focusPara;
    if (p == null) return;
    final i = _doc.indexOf(p.id);
    final j = i + delta;
    if (j < 0 || j >= _doc.paragraphs.length) return;
    final list = [..._doc.paragraphs];
    final tmp = list[i];
    list[i] = list[j];
    list[j] = tmp;
    _commit(_doc.copyWith(paragraphs: list));
  }

  // ── Dialogs ────────────────────────────────────────────────────

  // ── Tables, pictures, spelling, copies and backups ─────────────

  CellRef? get _cellRef {
    final id = _focusId;
    return id == null ? null : locateCell(_doc.paragraphs, id);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _editBlock(String id, DocParagraph Function(DocParagraph p) edit) {
    final p = findParagraph(_doc.paragraphs, id);
    if (p == null) return;
    _commit(
      _doc.copyWith(paragraphs: replaceById(_doc.paragraphs, id, edit(p))),
    );
  }

  void _editTable(String tableId, DocTable Function(DocTable t) edit) {
    _editBlock(tableId, (p) {
      final t = p.table;
      return t == null ? p : p.copyWith(table: edit(t));
    });
  }

  void _tableOp(DocTable Function(DocTable t, CellRef ref) edit) {
    final ref = _cellRef;
    if (ref == null) return;
    _editTable(ref.tableId, (t) => edit(t, ref));
  }

  void _insertTable() {
    _insertAfterFocus([
      DocParagraph(id: newParaId(), table: DocTable.blank(3, 3)),
    ]);
  }

  void _removeBlock(String id) {
    final i = _doc.indexOf(id);
    if (i < 0) return;
    final list = [..._doc.paragraphs]..removeAt(i);
    _focusId = null;
    _commit(
      _doc.copyWith(
        paragraphs: list.isEmpty ? [DocParagraph(id: newParaId())] : list,
      ),
    );
  }

  void _deleteTable() {
    final ref = _cellRef;
    if (ref != null) _removeBlock(ref.tableId);
  }

  Future<void> _insertPicture() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Insert picture',
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      _snack('Could not read that picture.');
      return;
    }
    final prepared = await PaperImageCodec.prepare(bytes);
    if (prepared == null) {
      _snack('That file is not a picture this editor can read.');
      return;
    }
    if (!mounted) return;
    _insertAfterFocus([
      DocParagraph(
        id: newParaId(),
        image: DocImage(bytes: prepared.bytes, aspect: prepared.aspect),
      ),
    ]);
  }

  void _setPictureWidth(double fraction) {
    final id = _focusId;
    if (id == null) return;
    _editBlock(
      id,
      (p) => p.image == null
          ? p
          : p.copyWith(image: p.image!.copyWith(widthFraction: fraction)),
    );
  }

  Future<void> _spellCheck() async {
    await PaperSpell.load();
    final found = <String>{};
    for (final p in _doc.allTextBlocks) {
      for (final r in PaperSpell.misspellings(p.text)) {
        found.add(p.text.substring(r.$1, r.$2));
      }
    }
    if (!mounted) return;
    if (found.isEmpty) {
      _snack('No spelling problems found.');
      return;
    }
    final words = found.toList()..sort();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Spelling (${words.length})'),
        content: SizedBox(
          width: 380,
          child: ListView(
            shrinkWrap: true,
            children: [for (final w in words.take(60)) _spellRow(ctx, w)],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _spellRow(BuildContext ctx, String word) {
    final options = PaperSpell.suggestions(word);
    return ListTile(
      dense: true,
      title: Text(word),
      subtitle: Text(
        options.isEmpty
            ? 'No suggestion'
            : 'Suggestions: ${options.join(', ')}',
      ),
      trailing: options.isEmpty
          ? null
          : TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                var fix = options.first;
                if (word[0] == word[0].toUpperCase()) {
                  fix = fix[0].toUpperCase() + fix.substring(1);
                }
                _commit(
                  _doc.copyWith(
                    paragraphs:
                        replaceWordEverywhere(_doc.paragraphs, word, fix),
                  ),
                );
              },
              child: const Text('Replace'),
            ),
    );
  }

  Future<void> _exportCopy() async {
    await _persist();
    try {
      final path = await PaperDocumentStore.exportDocument(_doc);
      if (path != null) _snack('Copy saved: $path');
    } catch (e) {
      _snack('Could not save the copy: $e');
    }
  }

  Future<void> _importCopy() async {
    await _persist();
    try {
      final doc = await PaperDocumentStore.importDocument();
      if (doc == null) {
        _snack('Nothing imported. Choose a .tdpaper or .json paper copy.');
        return;
      }
      await PaperDocumentStore.save(doc);
      _snack('Imported "${doc.title}". Open it from your saved papers.');
    } catch (e) {
      _snack('Could not import: $e');
    }
  }

  Future<void> _showBackups() async {
    await _persist();
    final files = await PaperDocumentStore.backups(_doc.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backups of this paper'),
        content: SizedBox(
          width: 380,
          child: files.isEmpty
              ? const Text(
                  'No backups yet. A backup is kept each time the paper is saved.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in files)
                      ListTile(
                        dense: true,
                        title: Text(_stamp(f.lastModifiedSync())),
                        trailing: TextButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _restore(f);
                          },
                          child: const Text('Restore'),
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(File file) async {
    final restored = await PaperDocumentStore.readBackup(file);
    if (restored == null || restored.id != _doc.id) {
      _snack('That backup cannot be restored.');
      return;
    }
    _commit(restored);
    _snack('Restored the backup from ${_stamp(file.lastModifiedSync())}.');
  }

  void _zoomBy(double delta) {
    setState(() => _zoom = (_zoom + delta).clamp(0.6, 1.6).toDouble());
  }

  Future<Map<String, String>?> _formDialog(
    String title,
    List<_FormField> fields,
  ) async {
    final controllers = <String, TextEditingController>{
      for (final f in fields) f.key: TextEditingController(text: f.initial),
    };
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextField(
                      controller: controllers[f.key],
                      decoration: InputDecoration(
                        labelText: f.label,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, {
              for (final e in controllers.entries) e.key: e.value.text,
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Dispose after the dialog's exit animation has finished.
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      for (final c in controllers.values) {
        c.dispose();
      }
    });
    return result;
  }

  Future<void> _editDetails() async {
    final h = _doc.header;
    final r = await _formDialog('Paper details', [
      (key: 'school', label: 'School / institution', initial: h.school),
      (key: 'exam', label: 'Exam name', initial: h.exam),
      (key: 'subject', label: 'Subject', initial: h.subject),
      (key: 'time', label: 'Time (e.g. 2 hours 30 minutes)', initial: h.time),
      (key: 'marks', label: 'Full marks', initial: h.marks),
    ]);
    if (r == null) return;
    _commit(
      _doc.copyWith(
        header: PaperHeader(
          school: r['school'] ?? '',
          exam: r['exam'] ?? '',
          subject: r['subject'] ?? '',
          time: r['time'] ?? '',
          marks: r['marks'] ?? '',
        ),
      ),
    );
  }

  Future<void> _editPageSetup() async {
    final r = await _formDialog('Header and footer', [
      (
        key: 'header',
        label: 'Small text at the top of each page',
        initial: _doc.pageHeader,
      ),
      (
        key: 'footer',
        label: 'Small text at the bottom of each page',
        initial: _doc.pageFooter,
      ),
    ]);
    if (r == null) return;
    _commit(
      _doc.copyWith(
        pageHeader: r['header'] ?? '',
        pageFooter: r['footer'] ?? '',
      ),
    );
  }

  Future<void> _rename() async {
    final r = await _formDialog('Document name', [
      (key: 'title', label: 'Name', initial: _doc.title),
    ]);
    final title = (r?['title'] ?? '').trim();
    if (r == null || title.isEmpty) return;
    _commit(_doc.copyWith(title: title));
  }

  // ── Saving and export ──────────────────────────────────────────

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () => _saveNow());
  }

  /// Back button with unsaved edits: save first, and stay on the editor if
  /// the save fails, so no work is lost.
  Future<void> _leaveAfterSave() async {
    _saveTimer?.cancel();
    final error = await _persist();
    if (!mounted) return;
    if (error != null) {
      setState(() => _status = 'Could not save. Try again.');
      _snack('Could not save (${error.runtimeType}). Try again.');
      return;
    }
    Navigator.of(context).pop();
  }

  /// Saves now. Failures are always shown; success is shown when [announce]
  /// is set (the Save button and Ctrl+S), so autosave stays quiet.
  Future<void> _saveNow({bool announce = false}) async {
    _saveTimer?.cancel();
    final error = await _persist();
    if (!mounted) return;
    setState(() {
      _status = error == null
          ? 'Saved ${_two(DateTime.now().hour)}:${_two(DateTime.now().minute)}'
          : 'Could not save. Try again.';
    });
    if (error != null) {
      _snack('Could not save (${error.runtimeType}). Try again.');
    } else if (announce) {
      _snack('Saved');
    }
  }

  /// Returns null on success, or the error that stopped the save.
  Future<Object?> _persist() async {
    final serial = _editSerial;
    final edited = _dirty;
    try {
      final doc = _doc.copyWith(updatedAt: DateTime.now());
      await PaperDocumentStore.save(doc);
      if (serial == _editSerial) _dirty = false;
      // Only real edits update a saved paper, so opening a copy never
      // replaces its original pages.
      if (edited && doc.id.startsWith('saved_')) {
        await SavedPaperEditing.publishPages(doc);
      }
      return null;
    } catch (e) {
      return e;
    }
  }

  Future<void> _export({required bool print}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _persist();
      if (print) {
        await PaperDocumentRender.printDocument(_doc);
      } else {
        await PaperDocumentRender.shareDocument(_doc);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not make the PDF: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving with unsaved edits waits for the save (and the saved paper's
      // page update) first, so the screen behind never reads old pages.
      canPop: !_dirty,
      onPopInvoked: (didPop) {
        if (!didPop) unawaited(_leaveAfterSave());
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceAlt,
        appBar: AppBar(
          titleSpacing: 0,
          title: InkWell(
            onTap: _rename,
            child: Text(
              _doc.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Save',
              onPressed: () => _saveNow(announce: true),
              icon: const AppIcon(PhosphorIcons.floppyDisk),
            ),
            IconButton(
              tooltip: 'Print',
              onPressed: _busy ? null : () => _export(print: true),
              icon: const AppIcon(PhosphorIcons.printer),
            ),
            IconButton(
              tooltip: 'Share PDF',
              onPressed: _busy ? null : () => _export(print: false),
              icon: const AppIcon(PhosphorIcons.shareNetwork),
            ),
          ],
        ),
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
                _saveNow(announce: true),
            const SingleActivator(LogicalKeyboardKey.keyP, control: true): () {
              if (!_busy) _export(print: true);
            },
            const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
                _fieldState?.applyFlag(TextFlag.bold),
            const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
                _fieldState?.applyFlag(TextFlag.italic),
            const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
                _fieldState?.applyFlag(TextFlag.underline),
            const SingleActivator(LogicalKeyboardKey.keyY, control: true):
                _redoStep,
          },
          child: SafeArea(
            child: Column(
              children: [
                _ribbon(),
                Expanded(child: _sheet()),
                _statusBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Tab names: the fixed tabs, plus contextual Table and Picture tabs when
  /// the focus is in a table cell or on a picture.
  List<String> _tabNames() => [
        'File',
        'Home',
        'Insert',
        'Layout',
        'Review',
        'View',
        if (_cellRef != null) 'Table',
        if (_focusPara?.image != null) 'Picture',
      ];

  List<Widget> _toolsFor(String tab) => switch (tab) {
        'File' => _fileTools(),
        'Insert' => _insertTools(),
        'Layout' => _layoutTools(),
        'Review' => _reviewTools(),
        'View' => _viewTools(),
        'Table' => _tableTools(),
        'Picture' => _pictureTools(),
        _ => _homeTools(),
      };

  Widget _ribbon() {
    final tabs = _tabNames();
    final current = tabs.contains(_tab) ? _tab : 'Home';
    final List<Widget> tools = _toolsFor(current);
    return Material(
      color: AppColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final name in tabs)
                  InkWell(
                    onTap: () => setState(() => _tab = name),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            width: 2,
                            color: current == name
                                ? AppColors.primary
                                : Colors.transparent,
                          ),
                        ),
                      ),
                      child: Text(
                        name,
                        style: TextStyle(
                          fontWeight: current == name
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: current == name
                              ? AppColors.primary
                              : AppColors.muted,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          SizedBox(
            height: 52,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(children: tools),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  Widget _tool(
    Object icon,
    String tip,
    VoidCallback? onTap, {
    bool on = false,
  }) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? AppColors.light : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(
            icon,
            size: 20,
            color: onTap == null ? AppColors.disabled : AppColors.text,
          ),
        ),
      ),
    );
  }

  Widget _chip(Object icon, String label, VoidCallback? onTap) {
    return TextButton.icon(
      onPressed: onTap,
      icon: AppIcon(icon, size: 18),
      label: Text(label),
      style: TextButton.styleFrom(foregroundColor: AppColors.text),
    );
  }

  Widget _sep() => Container(
        width: 1,
        height: 28,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppColors.border,
      );

  Widget _styleDropdown() {
    final kind = _focusPara?.kind;
    final editable = kind != null && kind != ParaKind.pageBreak;
    return SizedBox(
      width: 130,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ParaKind>(
          value: editable ? kind : null,
          hint: const Text('Style'),
          isExpanded: true,
          items: [
            for (final k in _styleKinds)
              DropdownMenuItem(value: k, child: Text(k.label)),
          ],
          onChanged: editable
              ? (k) {
                  if (k != null) _setKind(k);
                }
              : null,
        ),
      ),
    );
  }

  Widget _sizeDropdown() {
    final size = _active.size;
    return SizedBox(
      width: 74,
      child: DropdownButtonHideUnderline(
        child: DropdownButton<double>(
          value: size != null && _fontSizes.contains(size) ? size : null,
          hint: const Text('Size'),
          isExpanded: true,
          items: [
            for (final v in _fontSizes)
              DropdownMenuItem(value: v, child: Text(v.toStringAsFixed(0))),
          ],
          onChanged: _fieldState == null
              ? null
              : (v) {
                  if (v != null) _fieldState?.applySize(v);
                },
        ),
      ),
    );
  }

  List<Widget> _homeTools() {
    final hasField = _fieldState != null;
    final para = _focusPara;
    final hasPara = para != null && para.kind != ParaKind.pageBreak;
    void flag(TextFlag f) => _fieldState?.applyFlag(f);
    void align(ParaAlign a) => _setAlign(a);
    return [
      _tool(
          PhosphorIcons.arrowUUpLeft, 'Undo', _undo.isEmpty ? null : _undoStep),
      _tool(PhosphorIcons.arrowUUpRight, 'Redo',
          _redo.isEmpty ? null : _redoStep),
      _sep(),
      _styleDropdown(),
      const SizedBox(width: 6),
      _sizeDropdown(),
      _sep(),
      _tool(
        PhosphorIcons.textB,
        'Bold',
        hasField ? () => flag(TextFlag.bold) : null,
        on: _active.bold,
      ),
      _tool(
        PhosphorIcons.textItalic,
        'Italic',
        hasField ? () => flag(TextFlag.italic) : null,
        on: _active.italic,
      ),
      _tool(
        PhosphorIcons.textUnderline,
        'Underline',
        hasField ? () => flag(TextFlag.underline) : null,
        on: _active.underline,
      ),
      _tool(
        PhosphorIcons.eraser,
        'Clear formatting',
        hasField ? () => _fieldState?.clearFormat() : null,
      ),
      _sep(),
      _tool(
        PhosphorIcons.textAlignLeft,
        'Align left',
        hasPara ? () => align(ParaAlign.left) : null,
        on: para?.align == ParaAlign.left,
      ),
      _tool(
        PhosphorIcons.textAlignCenter,
        'Align centre',
        hasPara ? () => align(ParaAlign.center) : null,
        on: para?.align == ParaAlign.center,
      ),
      _tool(
        PhosphorIcons.textAlignRight,
        'Align right',
        hasPara ? () => align(ParaAlign.right) : null,
        on: para?.align == ParaAlign.right,
      ),
      _tool(
        PhosphorIcons.textAlignJustify,
        'Justify',
        hasPara ? () => align(ParaAlign.justify) : null,
        on: para?.align == ParaAlign.justify,
      ),
    ];
  }

  List<Widget> _insertTools() {
    return [
      _chip(
        PhosphorIcons.question,
        'Question',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.question),
        ]),
      ),
      _chip(
        PhosphorIcons.checkCircle,
        'MCQ options (4)',
        () => _insertAfterFocus([
          for (var i = 0; i < 4; i++)
            DocParagraph(id: newParaId(), kind: ParaKind.option),
        ]),
      ),
      _chip(
        PhosphorIcons.textHOne,
        'Heading',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.heading),
        ]),
      ),
      _chip(
        PhosphorIcons.paragraph,
        'Instruction',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.instruction),
        ]),
      ),
      _chip(
        PhosphorIcons.notepad,
        'Normal text',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.normal),
        ]),
      ),
      _sep(),
      _chip(
        PhosphorIcons.divide,
        'Page break',
        () => _insertAfterFocus(
          [
            DocParagraph(id: newParaId(), kind: ParaKind.pageBreak),
            DocParagraph(id: newParaId(), kind: ParaKind.normal),
          ],
          focus: 1,
        ),
      ),
      _sep(),
      _chip(PhosphorIcons.table, 'Table (3 × 3)', _insertTable),
      _chip(PhosphorIcons.image, 'Picture', _insertPicture),
    ];
  }

  List<Widget> _fileTools() => [
        _chip(PhosphorIcons.floppyDisk, 'Save', () => _saveNow(announce: true)),
        _sep(),
        _chip(
            PhosphorIcons.downloadSimple, 'Save a copy to a file', _exportCopy),
        _chip(
            PhosphorIcons.uploadSimple, 'Open a copy from a file', _importCopy),
        _chip(PhosphorIcons.clockCounterClockwise, 'Backups of this paper',
            _showBackups),
        _sep(),
        _chip(
          PhosphorIcons.printer,
          'Print',
          _busy ? null : () => _export(print: true),
        ),
        _chip(
          PhosphorIcons.shareNetwork,
          'Share PDF',
          _busy ? null : () => _export(print: false),
        ),
      ];

  List<Widget> _reviewTools() => [
        _chip(PhosphorIcons.textAa, 'Check spelling', _spellCheck),
      ];

  List<Widget> _viewTools() => [
        _tool(
          PhosphorIcons.magnifyingGlassMinus,
          'Zoom out',
          _zoom > 0.61 ? () => _zoomBy(-0.1) : null,
        ),
        _chip(PhosphorIcons.arrowsOutSimple, '${(_zoom * 100).round()}%',
            () => setState(() => _zoom = 1.0)),
        _tool(
          PhosphorIcons.magnifyingGlassPlus,
          'Zoom in',
          _zoom < 1.59 ? () => _zoomBy(0.1) : null,
        ),
      ];

  List<Widget> _tableTools() => [
        _chip(PhosphorIcons.arrowLineUp, 'Insert row above',
            () => _tableOp((t, r) => t.insertRow(r.row))),
        _chip(PhosphorIcons.arrowLineDown, 'Insert row below',
            () => _tableOp((t, r) => t.insertRow(r.row + 1))),
        _sep(),
        _chip(PhosphorIcons.caretLeft, 'Insert column left',
            () => _tableOp((t, r) => t.insertColumn(r.col))),
        _chip(PhosphorIcons.caretRight, 'Insert column right',
            () => _tableOp((t, r) => t.insertColumn(r.col + 1))),
        _sep(),
        _chip(PhosphorIcons.minus, 'Delete row',
            () => _tableOp((t, r) => t.deleteRow(r.row))),
        _chip(PhosphorIcons.columns, 'Delete column',
            () => _tableOp((t, r) => t.deleteColumn(r.col))),
        _sep(),
        _chip(PhosphorIcons.trash, 'Delete table', _deleteTable),
      ];

  List<Widget> _pictureTools() => [
        _chip(PhosphorIcons.image, 'Picture at 50% width',
            () => _setPictureWidth(0.5)),
        _chip(PhosphorIcons.image, 'Picture at 75% width',
            () => _setPictureWidth(0.75)),
        _chip(PhosphorIcons.image, 'Picture at full width',
            () => _setPictureWidth(1.0)),
        _sep(),
        _chip(PhosphorIcons.trash, 'Delete picture', _deleteFocused),
      ];

  List<Widget> _layoutTools() {
    final para = _focusPara;
    final hasPara = para != null;
    return [
      _chip(PhosphorIcons.info, 'Paper details', _editDetails),
      _chip(PhosphorIcons.rows, 'Header and footer', _editPageSetup),
      _chip(
        PhosphorIcons.listNumbers,
        _doc.showPageNumbers ? 'Page numbers: on' : 'Page numbers: off',
        () => _commit(
          _doc.copyWith(showPageNumbers: !_doc.showPageNumbers),
        ),
      ),
      _sep(),
      _tool(
        PhosphorIcons.arrowUp,
        'Move paragraph up',
        hasPara ? () => _moveFocused(-1) : null,
      ),
      _tool(
        PhosphorIcons.arrowDown,
        'Move paragraph down',
        hasPara ? () => _moveFocused(1) : null,
      ),
      _tool(
        PhosphorIcons.trash,
        'Delete paragraph',
        hasPara ? _deleteFocused : null,
      ),
    ];
  }

  Widget _sheet() {
    return LayoutBuilder(
      builder: (context, c) {
        final base = (c.maxWidth - 24).clamp(280.0, 760.0).toDouble();
        final pageW = base * _zoom;
        final s = pageW / PaperPage.widthPt;
        final layout = PaperLayout.compute(_doc, s);
        return Container(
          color: AppColors.surfaceAlt,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: c.maxWidth),
                child: Column(
                  children: [
                    for (var p = 0; p < layout.pageCount; p++)
                      _pageView(layout, p, s, pageW),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// One A4 page. Blocks sit at the positions the shared layout computed, so
  /// the page breaks here are the same as in the PDF.
  Widget _pageView(PaperLayout layout, int page, double s, double pageW) {
    final pageH = PaperPage.heightPt * s;
    final left = PaperPage.marginLeftPt * s;
    final top = PaperPage.marginTopPt * s;
    final contentW = PaperPage.contentWidthPt * s;
    final numbers = _doc.questionNumbers;
    final options = _doc.optionLabels;
    final headerText = _doc.pageHeader.trim();
    final footer = [
      _doc.pageFooter.trim(),
      if (_doc.showPageNumbers)
        'Page ${toBanglaNumber(page + 1)} of ${toBanglaNumber(layout.pageCount)}',
    ].where((t) => t.isNotEmpty).join('     |     ');
    final note = TextStyle(
      fontFamily: PaperPage.fontFamily,
      fontFamilyFallback: PaperPage.fallbackFonts,
      fontSize: 9 * s,
      color: AppColors.muted,
    );
    return Container(
      width: pageW,
      height: pageH,
      margin: const EdgeInsets.only(bottom: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipRect(
        child: Stack(
          children: [
            if (page == 0 && headerLinesOf(_doc.header).isEmpty)
              Positioned(
                left: left,
                width: contentW,
                top: top * 0.35,
                child: InkWell(
                  onTap: _editDetails,
                  child: Text(
                    'Tap to add paper details (school, exam, subject, time, marks)',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12 * s, color: AppColors.muted),
                  ),
                ),
              ),
            if (headerText.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                top: (PaperPage.marginTopPt - 30) * s,
                child: Text(
                  headerText,
                  textAlign: TextAlign.center,
                  style: note,
                ),
              ),
            if (footer.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                top: (PaperPage.heightPt - 44) * s,
                child: Text(footer, textAlign: TextAlign.center, style: note),
              ),
            for (final item in layout.pages[page])
              Positioned(
                left: left,
                top: top + item.top,
                width: contentW,
                child: SizedBox(
                  height: item.height,
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: contentW,
                    maxWidth: contentW,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: _blockWidget(item.index, numbers, options, s),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _blockWidget(
    int index,
    List<int?> numbers,
    List<String?> options,
    double s,
  ) {
    if (index < 0) return _headerBlock(s);
    final p = _doc.paragraphs[index];
    if (p.kind == ParaKind.pageBreak) {
      return _PageBreakRow(
        selected: _focusId == p.id,
        onTap: () => _selectBlock(p.id),
        onDelete: _focusId == p.id ? _deleteFocused : null,
      );
    }
    if (p.table != null) {
      return _TableBlock(
        para: p,
        scale: s,
        keyFor: _keyFor,
        onActive: _onFieldActive,
        onText: _onParagraphText,
        onRestyle: _onRestyle,
      );
    }
    if (p.image != null) {
      return _ImageBlock(
        para: p,
        scale: s,
        selected: _focusId == p.id,
        onTap: () => _selectBlock(p.id),
      );
    }
    return _rowFor(p, numbers[index], options[index], s);
  }

  Widget _rowFor(DocParagraph p, int? number, String? option, double s) {
    final String? label;
    if (number != null) {
      label = '${toBanglaNumber(number)}.';
    } else if (option != null) {
      label = '$option)';
    } else {
      label = null;
    }
    return _ParagraphField(
      key: _keyFor(p.id),
      para: p,
      label: label,
      hint: _hintFor(p.kind),
      scale: s,
      onActive: _onFieldActive,
      onText: _onParagraphText,
      onRestyle: _onRestyle,
    );
  }

  String _hintFor(ParaKind kind) => switch (kind) {
        ParaKind.title => 'Title',
        ParaKind.heading => 'Heading',
        ParaKind.instruction => 'Instruction',
        ParaKind.question => 'Type the question',
        ParaKind.option => 'Type the option',
        _ => 'Type here',
      };

  Widget _headerBlock(double s) {
    final lines = headerLinesOf(_doc.header);
    return InkWell(
      onTap: _editDetails,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            Padding(
              padding: EdgeInsets.only(bottom: line.afterPt * s),
              child: Text(
                line.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: PaperPage.fontFamily,
                  fontFamilyFallback: PaperPage.fallbackFonts,
                  fontSize: line.pt * s,
                  height: 1.4,
                  color: AppColors.text,
                  fontWeight: line.bold ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    final pages = PaperLayout.compute(_doc, 1).pageCount;
    final tables = _doc.tableCount;
    final pictures = _doc.pictureCount;
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$pages ${pages == 1 ? 'page' : 'pages'}  ·  '
              '${_doc.wordCount} words  ·  ${_doc.questionCount} questions  ·  '
              '$tables ${tables == 1 ? 'table' : 'tables'}  ·  '
              '$pictures ${pictures == 1 ? 'picture' : 'pictures'}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            _busy ? 'Making PDF...' : _status,
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ],
      ),
    );
  }
}

/// One editable paragraph: a gutter label (question or option number) and a
/// multi-line field whose characters carry the document's formatting.
class _ParagraphField extends StatefulWidget {
  final DocParagraph para;
  final String? label;
  final String hint;
  final void Function(String id, CharStyle active) onActive;
  final void Function(String id, String text, CharStyle? typing) onText;
  final void Function(DocParagraph next) onRestyle;

  /// Pixels per point, so the text matches the page layout.
  final double scale;

  /// True for a table cell: no label, no paragraph spacing.
  final bool inCell;

  const _ParagraphField({
    super.key,
    required this.para,
    required this.label,
    required this.hint,
    required this.onActive,
    required this.onText,
    required this.onRestyle,
    this.scale = 1.0,
    this.inCell = false,
  });

  @override
  State<_ParagraphField> createState() => _ParagraphFieldState();
}

class _ParagraphFieldState extends State<_ParagraphField> {
  late final _StyledController _ctl;
  final FocusNode _focus = FocusNode();
  CharStyle? _pending;
  bool _quiet = false;
  String _lastText = '';
  TextSelection _lastSel = const TextSelection.collapsed(offset: -1);

  @override
  void initState() {
    super.initState();
    _ctl = _StyledController(
      widget.para.text,
      widget.para.styles,
      scale: widget.scale,
    );
    _lastText = widget.para.text;
    _lastSel = _ctl.selection;
    _ctl.addListener(_onControllerChanged);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _ParagraphField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final p = widget.para;
    _quiet = true;
    _ctl.scale = widget.scale;
    if (p.text != _ctl.text) {
      _ctl.value = TextEditingValue(
        text: p.text,
        selection: TextSelection.collapsed(offset: p.text.length),
      );
    }
    if (!_sameStyles(p.styles, _ctl.styles)) {
      _ctl.setStyles(p.styles);
    }
    _quiet = false;
    _lastText = _ctl.text;
    _lastSel = _ctl.selection;
  }

  @override
  void dispose() {
    _ctl.removeListener(_onControllerChanged);
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_quiet) return;
    final sel = _ctl.selection;
    if (_ctl.text == _lastText && sel != _lastSel) {
      // The caret moved without typing: new text uses the style at the caret.
      _pending = null;
    }
    _lastText = _ctl.text;
    _lastSel = sel;
    _report();
  }

  void _onFocusChanged() {
    if (_focus.hasFocus) _report();
  }

  /// Tells the screen which paragraph is active and its style at the caret.
  /// Deferred to a microtask so it never runs during a build.
  void _report() {
    if (!mounted) return;
    final style = _pending ?? _styleAtCaret();
    final id = widget.para.id;
    Future<void>.microtask(() {
      if (mounted) widget.onActive(id, style);
    });
  }

  void _reportAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _report();
    });
  }

  CharStyle _styleAtCaret() {
    final styles = _ctl.styles;
    if (styles.isEmpty) return CharStyle.plain;
    final caret = _ctl.selection.isValid ? _ctl.selection.start : 0;
    if (caret > 0 && caret <= styles.length) return styles[caret - 1];
    return styles[0];
  }

  void _handleChanged(String text) {
    widget.onText(widget.para.id, text, _pending);
  }

  // ── Formatting commands (called from the ribbon) ───────────────

  void applyFlag(TextFlag flag) {
    final sel = _ctl.selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      final current = _pending ?? _styleAtCaret();
      _pending = current.withFlag(flag, !current.hasFlag(flag));
      _report();
      return;
    }
    final start = sel.start;
    final end = sel.end;
    var allOn = true;
    for (var i = start; i < end; i++) {
      if (!_ctl.styles[i].hasFlag(flag)) {
        allOn = false;
        break;
      }
    }
    widget.onRestyle(
      widget.para.restyle(start, end, (s) => s.withFlag(flag, !allOn)),
    );
    _reportAfterFrame();
  }

  void applySize(double size) {
    final sel = _ctl.selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      final current = _pending ?? _styleAtCaret();
      _pending = current.copyWith(size: size);
      _report();
      return;
    }
    widget.onRestyle(
      widget.para.restyle(
        sel.start,
        sel.end,
        (s) => s.copyWith(size: size),
      ),
    );
    _reportAfterFrame();
  }

  void clearFormat() {
    final sel = _ctl.selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed) {
      _pending = CharStyle.plain;
      _report();
      return;
    }
    widget.onRestyle(
      widget.para.restyle(sel.start, sel.end, (_) => CharStyle.plain),
    );
    _reportAfterFrame();
  }

  void focusStart() {
    _focus.requestFocus();
    _ctl.selection = const TextSelection.collapsed(offset: 0);
  }

  void focusEnd() {
    _focus.requestFocus();
    _ctl.selection = TextSelection.collapsed(offset: _ctl.text.length);
  }

  // ── Build ──────────────────────────────────────────────────────

  TextStyle _baseStyle(ParaKind kind) => TextStyle(
        fontFamily: 'Noto Serif Bengali',
        fontFamilyFallback: const ['Hind Siliguri', 'DejaVu Sans'],
        fontSize: kind.basePt * widget.scale,
        height: 1.5,
        color: AppColors.text,
        fontWeight: kind.bold ? FontWeight.w700 : FontWeight.w400,
        fontStyle: kind.italic ? FontStyle.italic : FontStyle.normal,
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.para;
    final base = _baseStyle(p.kind);
    final label = widget.label;
    final field = TextField(
      controller: _ctl,
      focusNode: _focus,
      minLines: 1,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textAlign: _textAlignOf(p.align),
      style: base,
      cursorColor: AppColors.primaryDark,
      decoration: InputDecoration.collapsed(
        hintText: widget.hint,
        hintStyle: base.copyWith(
          color: AppColors.disabled,
          fontWeight: FontWeight.w400,
          fontStyle: FontStyle.italic,
        ),
      ),
      onChanged: _handleChanged,
    );
    final s = widget.scale;
    // Spacing before and after a block is part of the page layout, so only
    // the left indent is applied here.
    return Padding(
      padding: EdgeInsets.only(
        left: !widget.inCell && p.kind == ParaKind.option
            ? PaperPage.optionIndentPt * s
            : 0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            SizedBox(
              width: PaperPage.gutterPt * s,
              child: Text(
                label,
                style: base.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          Expanded(child: field),
        ],
      ),
    );
  }
}

/// Text controller that paints each character with its own formatting.
class _StyledController extends TextEditingController {
  _StyledController(String text, List<CharStyle> styles, {this.scale = 1.0})
      : _styles = styles,
        super(text: text);

  List<CharStyle> _styles;

  /// Pixels per point for character sizes.
  double scale;

  List<CharStyle> get styles => _styles;

  void setStyles(List<CharStyle> next) {
    _styles = next;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final t = text;
    // While the user is typing, the styles can lag one update behind.
    if (t.isEmpty || _styles.length != t.length) {
      return TextSpan(style: style, text: t);
    }
    // Misspelled words get a red wavy underline.
    final wrong = List<bool>.filled(t.length, false);
    for (final r in PaperSpell.misspellings(t)) {
      for (var k = r.$1; k < r.$2; k++) {
        wrong[k] = true;
      }
    }
    final children = <TextSpan>[];
    var i = 0;
    while (i < t.length) {
      final s = _styles[i];
      final bad = wrong[i];
      var j = i + 1;
      while (j < t.length && _styles[j] == s && wrong[j] == bad) {
        j++;
      }
      children.add(
        TextSpan(
          text: t.substring(i, j),
          style: TextStyle(
            fontWeight: s.bold ? FontWeight.w700 : null,
            fontStyle: s.italic ? FontStyle.italic : null,
            decoration: (s.underline || bad) ? TextDecoration.underline : null,
            decorationStyle: bad ? TextDecorationStyle.wavy : null,
            decorationColor: bad ? const Color(0xFFD32F2F) : null,
            fontSize: s.size == null ? null : s.size! * scale,
          ),
        ),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
  }
}

/// A table: a grid of cells, each an editable field. The layout measures
/// each row by its tallest cell, the same as the page painter.
class _TableBlock extends StatelessWidget {
  final DocParagraph para;
  final double scale;
  final GlobalKey<_ParagraphFieldState> Function(String id) keyFor;
  final void Function(String id, CharStyle active) onActive;
  final void Function(String id, String text, CharStyle? typing) onText;
  final void Function(DocParagraph next) onRestyle;

  const _TableBlock({
    required this.para,
    required this.scale,
    required this.keyFor,
    required this.onActive,
    required this.onText,
    required this.onRestyle,
  });

  @override
  Widget build(BuildContext context) {
    final table = para.table;
    if (table == null) return const SizedBox.shrink();
    final pad = PaperPage.cellPadPt * scale;
    final edge = BorderSide(color: PaperPage.rule, width: 0.8);
    return Column(
      children: [
        for (final row in table.rows)
          IntrinsicHeight(
            child: Row(
              children: [
                for (final cell in row)
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.all(pad),
                      decoration: BoxDecoration(
                        border: Border(
                          top: edge,
                          left: edge,
                          right: edge,
                          bottom: edge,
                        ),
                      ),
                      child: _ParagraphField(
                        key: keyFor(cell.id),
                        para: cell,
                        label: null,
                        hint: '',
                        scale: scale,
                        inCell: true,
                        onActive: onActive,
                        onText: onText,
                        onRestyle: onRestyle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A picture, drawn at its chosen share of the text width.
class _ImageBlock extends StatelessWidget {
  final DocParagraph para;
  final double scale;
  final bool selected;
  final VoidCallback onTap;

  const _ImageBlock({
    required this.para,
    required this.scale,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final image = para.image;
    if (image == null) return const SizedBox.shrink();
    final w = PaperPage.contentWidthPt * scale * image.widthFraction;
    return InkWell(
      onTap: onTap,
      child: Container(
        alignment: Alignment.topCenter,
        decoration: selected
            ? BoxDecoration(
                border: Border.all(color: AppColors.primary, width: 1.5),
              )
            : null,
        child: SizedBox(
          width: w,
          height: w * image.aspect,
          child: Image.memory(
            image.bytes,
            fit: BoxFit.fill,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class _PageBreakRow extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _PageBreakRow({
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.zero,
        color: selected ? AppColors.surfaceAlt : null,
        child: Row(
          children: [
            const Expanded(child: Divider(color: AppColors.border)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'Page break',
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ),
            const Expanded(child: Divider(color: AppColors.border)),
            if (onDelete != null)
              IconButton(
                tooltip: 'Remove page break',
                onPressed: onDelete,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                icon: const AppIcon(PhosphorIcons.trash, size: 18),
              ),
          ],
        ),
      ),
    );
  }
}

/// Saved documents, newest first. Opens the editor for one document or for a
/// new one.
class PaperEditorListScreen extends StatefulWidget {
  const PaperEditorListScreen({super.key});

  @override
  State<PaperEditorListScreen> createState() => _PaperEditorListScreenState();
}

class _PaperEditorListScreenState extends State<PaperEditorListScreen> {
  List<PaperDocument>? _docs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final docs = await PaperDocumentStore.list();
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _open(PaperDocument? doc) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => PaperEditorScreen(document: doc)),
    );
    if (mounted) _load();
  }

  Future<void> _delete(PaperDocument doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('"${doc.title}" will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await PaperDocumentStore.delete(doc.id);
    if (mounted) _load();
  }

  Widget _body() {
    if (_error != null) {
      return Center(child: Text('Could not load documents: $_error'));
    }
    final docs = _docs;
    if (docs == null) return const Center(child: CircularProgressIndicator());
    if (docs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No documents yet.\nTap New document to write a question paper '
            'in a Word-style editor.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: docs.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final d = docs[i];
        return Card(
          child: ListTile(
            leading: const AppIcon(PhosphorIcons.fileText),
            title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${d.questionCount} questions  ·  ${d.wordCount} words  ·  '
              'edited ${_stamp(d.updatedAt)}',
            ),
            onTap: () => _open(d),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: const AppIcon(PhosphorIcons.trash),
              onPressed: () => _delete(d),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paper Editor')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(null),
        icon: const AppIcon(PhosphorIcons.plus),
        label: const Text('New document'),
      ),
      body: _body(),
    );
  }
}
