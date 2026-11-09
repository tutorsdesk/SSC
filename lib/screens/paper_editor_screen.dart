import 'dart:async';

import 'package:flutter/material.dart';

import '../models/paper_document.dart';
import '../services/paper_document_render.dart';
import '../services/paper_document_store.dart';
import '../theme/design_tokens.dart';

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
  int _tab = 0;
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

  /// Text typed into a paragraph (may split it on newlines).
  void _onParagraphText(String id, String text, CharStyle? typing) {
    final i = _doc.indexOf(id);
    if (i < 0) return;
    final pieces = editParagraphText(_doc.paragraphs[i], text, typing: typing);
    _commit(
      _doc.copyWith(
        paragraphs: replaceParagraph(_doc.paragraphs, i, pieces),
      ),
      coalesce: pieces.length == 1,
    );
    if (pieces.length > 1) {
      _focusId = pieces.last.id;
      _focusLater(pieces.last.id);
    }
  }

  /// Formatting change of one paragraph's characters.
  void _onRestyle(DocParagraph next) {
    final i = _doc.indexOf(next.id);
    if (i < 0) return;
    _commit(
      _doc.copyWith(paragraphs: replaceParagraph(_doc.paragraphs, i, [next])),
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
    _saveTimer = Timer(const Duration(milliseconds: 1200), _saveNow);
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    final ok = await _persist();
    if (!mounted) return;
    setState(() {
      _status = ok
          ? 'Saved ${_two(DateTime.now().hour)}:${_two(DateTime.now().minute)}'
          : 'Could not save. Try again.';
    });
  }

  Future<bool> _persist() async {
    final serial = _editSerial;
    try {
      await PaperDocumentStore.save(_doc.copyWith(updatedAt: DateTime.now()));
      if (serial == _editSerial) _dirty = false;
      return true;
    } catch (_) {
      return false;
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
    return Scaffold(
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
            onPressed: _saveNow,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: 'Print',
            onPressed: _busy ? null : () => _export(print: true),
            icon: const Icon(Icons.print_outlined),
          ),
          IconButton(
            tooltip: 'Share PDF',
            onPressed: _busy ? null : () => _export(print: false),
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ribbon(),
            Expanded(child: _sheet()),
            _statusBar(),
          ],
        ),
      ),
    );
  }

  Widget _ribbon() {
    const tabs = ['Home', 'Insert', 'Layout'];
    final List<Widget> tools = switch (_tab) {
      0 => _homeTools(),
      1 => _insertTools(),
      _ => _layoutTools(),
    };
    return Material(
      color: AppColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                InkWell(
                  onTap: () => setState(() => _tab = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: _tab == i
                              ? AppColors.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Text(
                      tabs[i],
                      style: TextStyle(
                        fontWeight:
                            _tab == i ? FontWeight.w700 : FontWeight.w500,
                        color: _tab == i ? AppColors.primary : AppColors.muted,
                      ),
                    ),
                  ),
                ),
            ],
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
    IconData icon,
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
          child: Icon(
            icon,
            size: 20,
            color: onTap == null ? AppColors.disabled : AppColors.text,
          ),
        ),
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback? onTap) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
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
      _tool(Icons.undo, 'Undo', _undo.isEmpty ? null : _undoStep),
      _tool(Icons.redo, 'Redo', _redo.isEmpty ? null : _redoStep),
      _sep(),
      _styleDropdown(),
      const SizedBox(width: 6),
      _sizeDropdown(),
      _sep(),
      _tool(
        Icons.format_bold,
        'Bold',
        hasField ? () => flag(TextFlag.bold) : null,
        on: _active.bold,
      ),
      _tool(
        Icons.format_italic,
        'Italic',
        hasField ? () => flag(TextFlag.italic) : null,
        on: _active.italic,
      ),
      _tool(
        Icons.format_underlined,
        'Underline',
        hasField ? () => flag(TextFlag.underline) : null,
        on: _active.underline,
      ),
      _tool(
        Icons.format_clear,
        'Clear formatting',
        hasField ? () => _fieldState?.clearFormat() : null,
      ),
      _sep(),
      _tool(
        Icons.format_align_left,
        'Align left',
        hasPara ? () => align(ParaAlign.left) : null,
        on: para?.align == ParaAlign.left,
      ),
      _tool(
        Icons.format_align_center,
        'Align centre',
        hasPara ? () => align(ParaAlign.center) : null,
        on: para?.align == ParaAlign.center,
      ),
      _tool(
        Icons.format_align_right,
        'Align right',
        hasPara ? () => align(ParaAlign.right) : null,
        on: para?.align == ParaAlign.right,
      ),
      _tool(
        Icons.format_align_justify,
        'Justify',
        hasPara ? () => align(ParaAlign.justify) : null,
        on: para?.align == ParaAlign.justify,
      ),
    ];
  }

  List<Widget> _insertTools() {
    return [
      _chip(
        Icons.quiz_outlined,
        'Question',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.question),
        ]),
      ),
      _chip(
        Icons.radio_button_checked,
        'MCQ options (4)',
        () => _insertAfterFocus([
          for (var i = 0; i < 4; i++)
            DocParagraph(id: newParaId(), kind: ParaKind.option),
        ]),
      ),
      _chip(
        Icons.title,
        'Heading',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.heading),
        ]),
      ),
      _chip(
        Icons.short_text,
        'Instruction',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.instruction),
        ]),
      ),
      _chip(
        Icons.notes,
        'Normal text',
        () => _insertAfterFocus([
          DocParagraph(id: newParaId(), kind: ParaKind.normal),
        ]),
      ),
      _sep(),
      _chip(
        Icons.horizontal_split,
        'Page break',
        () => _insertAfterFocus(
          [
            DocParagraph(id: newParaId(), kind: ParaKind.pageBreak),
            DocParagraph(id: newParaId(), kind: ParaKind.normal),
          ],
          focus: 1,
        ),
      ),
    ];
  }

  List<Widget> _layoutTools() {
    final para = _focusPara;
    final hasPara = para != null;
    return [
      _chip(Icons.info_outline, 'Paper details', _editDetails),
      _chip(Icons.view_headline, 'Header and footer', _editPageSetup),
      _chip(
        Icons.numbers,
        _doc.showPageNumbers ? 'Page numbers: on' : 'Page numbers: off',
        () => _commit(
          _doc.copyWith(showPageNumbers: !_doc.showPageNumbers),
        ),
      ),
      _sep(),
      _tool(
        Icons.arrow_upward,
        'Move paragraph up',
        hasPara ? () => _moveFocused(-1) : null,
      ),
      _tool(
        Icons.arrow_downward,
        'Move paragraph down',
        hasPara ? () => _moveFocused(1) : null,
      ),
      _tool(
        Icons.delete_outline,
        'Delete paragraph',
        hasPara ? _deleteFocused : null,
      ),
    ];
  }

  Widget _sheet() {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final pad = wide ? 64.0 : 18.0;
    final paras = _doc.paragraphs;
    final numbers = _doc.questionNumbers;
    final options = _doc.optionLabels;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(top: wide ? 24 : 0, bottom: 48),
          child: Container(
            color: AppColors.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: pad),
                  child: _headerBlock(),
                ),
                for (var i = 0; i < paras.length; i++)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: pad),
                    child: _rowFor(paras[i], numbers[i], options[i]),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowFor(DocParagraph p, int? number, String? option) {
    if (p.kind == ParaKind.pageBreak) {
      return _PageBreakRow(
        selected: _focusId == p.id,
        onTap: () => _selectBlock(p.id),
        onDelete: _focusId == p.id ? _deleteFocused : null,
      );
    }
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

  Widget _headerBlock() {
    final h = _doc.header;
    final details = [
      if (h.time.trim().isNotEmpty) 'Time: ${h.time.trim()}',
      if (h.marks.trim().isNotEmpty) 'Marks: ${h.marks.trim()}',
    ].join('     ');
    final lines = [h.school, h.exam, h.subject, details]
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return InkWell(
      onTap: _editDetails,
      child: Padding(
        padding: const EdgeInsets.only(top: 28, bottom: 12),
        child: lines.isEmpty
            ? Text(
                'Tap to add paper details (school, exam, subject, time, marks)',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.muted),
              )
            : Column(
                children: [
                  for (var i = 0; i < lines.length; i++)
                    Text(
                      lines[i],
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: i == 0 ? 17 : (i == 1 ? 14 : 13),
                        fontWeight:
                            i < 2 ? FontWeight.w700 : FontWeight.w400,
                        height: 1.5,
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _statusBar() {
    final breaks = _doc.pageBreakCount;
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_doc.wordCount} words  ·  ${_doc.questionCount} questions  ·  '
              '$breaks page ${breaks == 1 ? 'break' : 'breaks'}',
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

  const _ParagraphField({
    super.key,
    required this.para,
    required this.label,
    required this.hint,
    required this.onActive,
    required this.onText,
    required this.onRestyle,
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
    _ctl = _StyledController(widget.para.text, widget.para.styles);
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
        fontSize: kind.basePt,
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
    return Padding(
      padding: EdgeInsets.only(
        top: p.kind.beforePt,
        bottom: p.kind.afterPt,
        left: p.kind == ParaKind.option ? 20 : 0,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            SizedBox(
              width: 44,
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
  _StyledController(String text, List<CharStyle> styles)
      : _styles = styles,
        super(text: text);

  List<CharStyle> _styles;

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
    final children = <TextSpan>[];
    var i = 0;
    while (i < t.length) {
      final s = _styles[i];
      var j = i + 1;
      while (j < t.length && _styles[j] == s) {
        j++;
      }
      children.add(
        TextSpan(
          text: t.substring(i, j),
          style: TextStyle(
            fontWeight: s.bold ? FontWeight.w700 : null,
            fontStyle: s.italic ? FontStyle.italic : null,
            decoration: s.underline ? TextDecoration.underline : null,
            fontSize: s.size,
          ),
        ),
      );
      i = j;
    }
    return TextSpan(style: style, children: children);
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
        padding: const EdgeInsets.symmetric(vertical: 12),
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
                icon: const Icon(Icons.delete_outline, size: 20),
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
            leading: const Icon(Icons.description_outlined),
            title: Text(d.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${d.questionCount} questions  ·  ${d.wordCount} words  ·  '
              'edited ${_stamp(d.updatedAt)}',
            ),
            onTap: () => _open(d),
            trailing: IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
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
        icon: const Icon(Icons.add),
        label: const Text('New document'),
      ),
      body: _body(),
    );
  }
}
