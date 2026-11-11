import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import '../widgets/app_icon.dart';
import '../widgets/motion_policy.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../services/omr/omr_geometry.dart';
import '../services/omr/omr_scanner.dart';
import '../services/omr/omr_store.dart';
import 'omr_analytics_screen.dart';
import 'omr_live_scan_screen.dart';
import '../services/app_settings.dart';
import '../services/app_version.dart';
import '../services/app_style.dart';
import '../services/paper_library.dart';
import '../services/paper_pdf.dart';
import '../services/subscription_guard.dart';
import '../models/subscription_entitlement.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../widgets/app_button.dart';
import '../widgets/glass_card.dart';
import '../widgets/problem_dialog.dart';
import '../widgets/workflow_progress.dart';
import '../widgets/omr_answer_review.dart';

/// OMR স্ক্যানার — ফটো থেকে ভরাট করা OMR শিট পড়ে, answer key-এর
/// সাথে মিলিয়ে মার্ক করে এবং ছাপার-যোগ্য স্কোর কার্ড দেয়।
class OMrScannerScreen extends StatefulWidget {
  /// Pre-loaded answer key (option index per question) — passed when the
  /// tutor scans a paper they just generated in the app.
  final List<int>? initialKey;

  /// Paper title used on the scorecard (and for the key draft).
  final String paperTitle;

  /// Subject name, pre-filled when the scanner is opened from a saved paper.
  final String initialSubject;

  const OMrScannerScreen({
    super.key,
    this.initialKey,
    this.paperTitle = '',
    this.initialSubject = '',
  });

  @override
  State<OMrScannerScreen> createState() => _OMrScannerScreenState();
}

class _OMrScannerScreenState extends State<OMrScannerScreen> {
  static const _letters = ['ক', 'খ', 'গ', 'ঘ'];

  Uint8List? _photoBytes;
  ui.Image? _photoImage;

  int _total = 30;
  late List<int> _key;
  late final TextEditingController _titleCtrl;
  late final TextEditingController _subjectCtrl;

  bool _busy = false;
  bool _accessChecked = false;
  int _step = 0;
  String? _activeRecordId;
  OmScanResult? _result;

  OmGraded? _graded;
  Uint8List? _overlayJpg;
  int? _scanMs;

  List<OmScanRecord> _history = const [];

  // ── batch (whole-class) scan state ──
  bool _batchMode = false;
  List<OmScanRecord> _batch = [];

  /// Result overlays accumulated during a camera batch (one per _batch
  /// entry; null when a sheet's overlay could not be rendered).
  List<Uint8List?> _batchOverlays = [];
  String? _batchProgress;
  List<OmScanRecord>? _batchDone;

  /// Overlays for _batchDone (parallel list — same index, may be null).
  List<Uint8List?> _batchDoneOverlays = const [];

  @override
  void initState() {
    super.initState();
    AppStyle.mood.value = WorkspaceMood.omr;
    final seed = widget.initialKey;
    if (seed != null && seed.isNotEmpty) {
      _total = seed.length;
      _key = List<int>.of(seed);
    } else {
      _key = List<int>.filled(30, -1);
    }
    // Default name from Settings fills the title when no paper is chosen.
    _titleCtrl = TextEditingController(
      text: widget.paperTitle.isNotEmpty
          ? widget.paperTitle
          : AppSettings.defaultName,
    );
    _subjectCtrl = TextEditingController(text: widget.initialSubject);
    _loadHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final allowed = await SubscriptionGuard.require(
        context,
        PremiumFeature.omrScanner,
      );
      if (!mounted) return;
      if (!allowed) {
        Navigator.of(context).maybePop();
        return;
      }
      setState(() => _accessChecked = true);
    });
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<bool> _canUseScanner() =>
      SubscriptionGuard.require(context, PremiumFeature.omrScanner);

  Future<void> _loadHistory() async {
    final h = await OmrStore.loadHistory();
    if (mounted) setState(() => _history = h);
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _subjectCtrl.dispose();
    super.dispose();
  }

  // ── photo ─────────────────────────────────────────────────────────

  Future<void> _pickPhoto(ImageSource source) async {
    if (!await _canUseScanner()) return;
    try {
      final xfile = await ImagePicker().pickImage(
        source: source,
        imageQuality: 90,
        maxWidth: 4096,
      );
      if (xfile == null) return;
      final bytes = await xfile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return; // picker + decode can outlive the screen
      setState(() {
        _photoBytes = bytes;
        _photoImage = frame.image;
        _result = null;
        _graded = null;
        _overlayJpg = null;
      });
    } catch (e) {
      await _problem('Could not load image', '$e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// The standard red, animated problem dialog — every error the user must
  /// act on uses this (never a plain snackbar).
  Future<void> _problem(String title, String message, {String? detail}) {
    if (!mounted) return Future<void>.value();
    return showProblemDialog(
      context,
      title: title,
      message: message,
      detail: detail,
    );
  }

  /// Primary capture path: Google's ML Kit document scanner — live corner
  /// tracking, auto-capture and a crop step, all inside Google's own
  /// scanner UI. It hands back an already-rectified page, so the OMR read
  /// only has to find the four corner marks on a straight sheet (or none
  /// at all — a markless page aligns on its own edges).
  ///
  /// The scanner UI and models live in an installable Google Play
  /// services "module", so the phone is asked about it before launch and
  /// every failure mode is explained instead of crashing the native side:
  ///   ready            → launch the scanner
  ///   downloadable     → offer the one-time download
  ///   no scanner API   → Play services update dialog
  ///
  /// filter mode (not full): full mode additionally downloads Google's
  /// stain/finger-cleaning ML models from Play services — an extra
  /// failure point for clean printed OMR sheets that never use it.
  Future<void> _openCamera() async {
    // ML Kit's document scanner is Android-only. Windows uses the app's
    // webcam preview and manual shutter instead of invoking Play services.
    if (_isDesktop) {
      await _openLiveScan();
      return;
    }
    if (!await _canUseScanner()) return;
    if (_key.any((k) => k < 0)) {
      await _problem(
        'Answer key incomplete',
        'Complete the answer key first — or tap "Use saved paper".',
      );
      return;
    }
    final (status, statusError) = await _scannerModuleStatus();
    if (status == -2) {
      // The scanner client could not even be constructed on this phone.
      // Show the installed Play services version and the exact error so
      // the cause is visible, not guessed.
      final v = await _gmsVersion();
      final version = v > 0 ? ' (version ${_fmtGmsVersion(v)})' : '';
      await _googleScannerUnavailable(
        'The Google scanner could not be initialized on this phone'
        '$version.',
        detail: statusError ?? 'The scanner client failed to construct.',
      );
      return;
    }
    if (status == 0) {
      // The scanner module is not on this phone yet — offer the
      // one-time download before launching.
      final download = await _offerScannerModuleDownload();
      if (download != true) return; // in-app camera chosen / cancelled
    }
    try {
      final scanner = DocumentScanner(
        options: DocumentScannerOptions(
          documentFormats: {DocumentFormat.jpeg},
          mode: ScannerMode.filter,
          pageLimit: 1,
          isGalleryImport: false,
        ),
      );
      try {
        final result = await scanner.scanDocument();
        final images = result.images;
        if (images == null || images.isEmpty) return; // cancelled
        // The page comes back straight and cropped to the sheet's
        // edges — the scan may anchor on the page boundary when the
        // sheet has no (or too few) printed corner marks.
        await _loadAndScan(images.first, rectified: true);
      } finally {
        await scanner.close();
      }
    } catch (e) {
      if (!mounted) return;
      final why = e.toString().replaceFirst('PlatformException(', '');
      await _googleScannerUnavailable(
        'It could not start on this phone. Updating Google Play '
        'services usually fixes this.',
        detail: why,
      );
    }
  }

  /// Google scanner module status on this phone: 1 = ready, 0 =
  /// downloadable from Play services, -1 = unknown (query failed — try
  /// the launch anyway and let the real error surface), -2 = the scanner
  /// client could not be constructed. The second value carries the
  /// underlying error text when there is one.
  Future<(int, String?)> _scannerModuleStatus() async {
    try {
      final m = await _appChannel.invokeMethod<dynamic>('scannerModuleStatus');
      if (m is Map) {
        return ((m['status'] as int?) ?? -1, m['error'] as String?);
      }
      return (-1, null);
    } catch (_) {
      return (-1, null);
    }
  }

  /// Installed Play services version code (0 = none installed).
  Future<int> _gmsVersion() async {
    try {
      final v = await _appChannel.invokeMethod<int>('gmsVersion');
      return v ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Best-effort human form of a Play services version code
  /// (e.g. 233119325 → "23.31.19 (build 325)").
  static String _fmtGmsVersion(int v) {
    final s = v.toString();
    if (s.length == 9) {
      return '${s.substring(0, 2)}.${s.substring(2, 4)}.${s.substring(4, 6)}'
          ' (build ${s.substring(6)})';
    }
    if (s.length == 8) {
      return '${s.substring(0, 2)}.${s.substring(2, 4)}.${s.substring(4, 8)}';
    }
    return s;
  }

  /// Asks to download the scanner module from Play services; returns
  /// true only when the module is ready afterwards (downloaded, or
  /// already there). Anything else means "do not launch the scanner".
  Future<bool?> _offerScannerModuleDownload() async {
    if (!mounted) return null;
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Download scanner module'),
        content: const Text(
          'The Google scanner keeps its scanning module inside Google '
          'Play services, and this phone does not have it yet. '
          'Downloading it is a one-time step of a few megabytes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Use in-app camera'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (proceed != true) return proceed;
    if (!mounted) return null;
    // Busy dialog for the download; PopScope keeps the back button from
    // dismissing it mid-download.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: const AlertDialog(
          title: Text('Downloading scanner…'),
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: ActivityIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Text('This can take a moment on slow connections.'),
              ),
            ],
          ),
        ),
      ),
    );
    bool ok;
    String? failedWhy;
    try {
      final r = await _appChannel.invokeMethod<int>('installScannerModule');
      ok = r == 0 || r == 1; // already installed, or downloaded
    } catch (e) {
      ok = false;
      failedWhy = e.toString().replaceFirst('PlatformException(', '');
    }
    if (mounted) Navigator.of(context).pop(); // busy dialog
    if (!ok) {
      await _googleScannerUnavailable(
        'The scanner module could not be downloaded from Play services.',
        detail: failedWhy,
      );
      return null;
    }
    return true;
  }

  /// Shown when the Google scanner cannot start: offers the Play Store
  /// fix, or the in-app camera. The fallback only happens when the user
  /// actually chose it — after "Open Play Store" the phone must be fixed,
  /// and the next Camera tap gets to try the Google scanner for real.
  Future<void> _googleScannerUnavailable(
    String reason, {
    String? detail,
  }) async {
    if (!mounted) return;
    // Professional problem popup (scale+fade card, red blinking warning
    // icon) so this failure can't be missed.
    await showProblemDialog(
      context,
      title: 'Google scanner unavailable',
      message: reason,
      detail: detail != null ? 'Error: $detail' : null,
      dismissible: false,
      actions: [
        ProblemAction('Open Play Store', () async {
          try {
            await _appChannel.invokeMethod('openPlayServices');
          } catch (_) {}
        }),
        ProblemAction('Use in-app camera', _openLiveScan, primary: true),
      ],
    );
  }

  static const MethodChannel _appChannel = MethodChannel(
    'com.tutorsdesk.app/storage',
  );

  /// Guided live-camera capture: the in-app preview shows an A4 guide,
  /// sheet/marks/sharp indicators and auto-captures a steady frame.
  Future<void> _openLiveScan() async {
    if (!await _canUseScanner()) return;
    if (_key.any((k) => k < 0)) {
      await _problem(
        'Answer key incomplete',
        'Complete the answer key first — or tap "Use saved paper".',
      );
      return;
    }
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const OmLiveScanScreen()));
    if (result == null) return;
    if (result == 'system') {
      _pickPhoto(ImageSource.camera);
      return;
    }
    await _loadAndScan(result);
  }

  Future<void> _loadAndScan(String path, {bool rectified = false}) async {
    try {
      final bytes = await File(path).readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _photoBytes = bytes;
        _photoImage = frame.image;
        _result = null;
        _graded = null;
        _overlayJpg = null;
      });
      _scan(rectified: rectified);
    } catch (e) {
      await _problem('Could not load photo', '$e');
    }
  }

  // ── key editor ────────────────────────────────────────────────────

  void _setTotal(int total) {
    setState(() {
      final old = _key;
      _total = total;
      _key = List<int>.filled(total, -1);
      for (var i = 0; i < total && i < old.length; i++) {
        _key[i] = old[i];
      }
      _result = null;
      _graded = null;
    });
  }

  int get _keyDone => _key.where((k) => k >= 0).length;

  // ── scan ──────────────────────────────────────────────────────────

  Future<void> _scan({bool rectified = false}) async {
    if (!await _canUseScanner()) return;
    final photo = _photoBytes;
    if (photo == null) {
      await _problem(
        'No sheet to scan',
        'Take a clear photo of the OMR sheet first.',
      );
      return;
    }
    if (_key.any((k) => k < 0)) {
      await _problem(
        'Answer key incomplete',
        '${_total - _keyDone} answer key question(s) still empty.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _result = null;
      _graded = null;
    });
    try {
      final sw = Stopwatch()..start();
      final res = await _runOmScan(photo, rectified: rectified);
      if (!res.ok) {
        if (!mounted) return;
        setState(() => _busy = false);
        if (mounted) {
          await showProblemDialog(
            context,
            title: 'Could not read this OMR sheet',
            message: res.error ?? 'Scan failed',
            detail: 'Version $kAppVersion',
          );
        }
        return;
      }
      final graded = OMrScanner.grade(res, _key);
      _scanMs = sw.elapsedMilliseconds;
      final overlay = await _buildOverlay(res, graded);
      // Results remain provisional until the teacher reviews and confirms them.
      if (!mounted) return;
      setState(() {
        _step = 2;
        _activeRecordId = null;
        _result = res;
        _graded = graded;
        _overlayJpg = overlay;
        _busy = false;
      });
      _loadHistory();
    } on OmDecodeException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (mounted) {
        await showProblemDialog(
          context,
          title: 'Image could not be read',
          message: e.detail,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      if (mounted) {
        await showProblemDialog(
          context,
          title: 'Scan error',
          message: '$e',
          detail: 'Version $kAppVersion',
        );
      }
    }
  }

  /// Runs the scan in a background isolate, and — if that isolate cannot
  /// decode the image (a quirk of some Android builds; the UI isolate has
  /// already decoded these exact bytes for the preview, so it can) —
  /// retries the same scan on the UI isolate. A second or two of jank
  /// in exchange for a correct result.
  Future<OmScanResult> _runOmScan(
    Uint8List photo, {
    required bool rectified,
  }) async {
    try {
      return await compute(
        omrScanIsolateEntry,
        OmScanRequest(photo, _total, rectified),
      );
    } on OmDecodeException {
      return OMrScanner.scan(photo, total: _total, rectified: rectified);
    }
  }

  OmScanRecord _recordOf(OmScanResult res, OmGraded g, {String? id}) =>
      OmScanRecord(
        id: id ?? 's_${DateTime.now().microsecondsSinceEpoch}',
        date: DateTime.now(),
        paperTitle: _titleCtrl.text.trim().isEmpty
            ? AppSettings.defaultName
            : _titleCtrl.text.trim(),
        subjectName: _subjectCtrl.text.trim(),
        roll: res.roll,
        registration: res.registration,
        // Prefill off (Settings) → ignore the sheet's printed codes.
        subjectCode: AppSettings.omrPrefill ? res.subjectCode : '',
        setCode: AppSettings.omrPrefill && res.setCode >= 0
            ? _letters[res.setCode]
            : '—',
        total: _total,
        score: g.score,
        correct: g.correct,
        wrong: g.wrong,
        blank: g.blank,
        ambiguous: g.ambiguous,
        answers: List.of(res.answers),
        correctedIndices: res.correctedIndices,
        key: List.of(_key),
        durationMs: _scanMs ?? 0,
      );

  /// Draws the verdict on top of the photo: each marked bubble gets a
  /// filled circle in the verdict colour (green = correct, red = wrong,
  /// orange = double-marked, grey = blank row), exactly the size of the
  /// sheet's own printed bubble; a wrong/blank question also gets a
  /// filled green disc on the correct option.
  Future<Uint8List?> _buildOverlay(
    OmScanResult res,
    OmGraded g, {
    Uint8List? photoBytes,
  }) async {
    // Batch items are scanned from their own photos, not the current
    // _photoBytes — decode the item's bytes when given.
    // When the scan produced an auto-cropped (rectified) sheet, prefer
    // that: the user gets the same "cropped sheet" look the camera
    // scanner gives, and markers are placed in plain page coordinates.
    ui.Image? img;
    bool cropped = false;
    if (res.rectifiedJpeg != null) {
      try {
        final frame = await (await ui.instantiateImageCodec(
          res.rectifiedJpeg!,
        ))
            .getNextFrame();
        img = frame.image;
        cropped = true;
      } catch (_) {
        img = null;
      }
    }
    if (img == null) {
      if (photoBytes != null) {
        try {
          final frame = await (await ui.instantiateImageCodec(
            photoBytes,
          ))
              .getNextFrame();
          img = frame.image;
        } catch (_) {
          img = null;
        }
      } else {
        img = _photoImage;
      }
    }
    if (img == null) return null;
    try {
      const maxSide = 1500.0;
      final s = maxSide / math.max(img.width, img.height);
      final w = (img.width * s).round();
      final h = (img.height * s).round();
      // Cropped image is A4-proportioned (page space); the original
      // photo is the work grid — the two need different display factors.
      final k =
          cropped ? (w / OMrGeometry.pageW) : (w / res.workWidth.toDouble());
      final geo = OMrGeometry(_total);
      // Marker placement: cropped mode maps page points straight to the
      // display; photo mode runs them through the scan's homography.
      Offset _mp(Offset pagePt) => cropped
          ? pagePt * k
          : OMrScanner.applyHomography(res.homography, pagePt) * k;
      final cornerPts = cropped
          ? [
              OMrGeometry.markCenter(0),
              OMrGeometry.markCenter(1),
              OMrGeometry.markCenter(2),
              OMrGeometry.markCenter(3),
            ]
          : res.photoCorners.map((c) => c.point).toList();

      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      // Scale the full-resolution photo down to the canvas size. The
      // markers below are positioned in *device* pixels with the
      // work→display factor k, so the canvas must NOT be pre-scaled —
      // a canvas.scale(s) here stretched every marker by s away from
      // the top-left corner (a few percent on phone screenshots: small
      // near the top-left, clearly visible at the bottom-right — the
      // "slightly off" overlay look). drawImageRect scales the photo
      // without scaling the coordinate system.
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        Paint()..filterQuality = FilterQuality.medium,
      );

      final br = OMrGeometry.bubbleRadiusPx * k; // bubble radius, display px
      final ringPaint = ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 3.0;

      // Registration corners — the circle is sized to the corner mark
      // itself, so it sits concentric on the printed square.
      ringPaint.color = const Color(0xB3000000);
      for (final c in cornerPts) {
        canvas.drawCircle(c * k, OMrGeometry.markSize / 2 * k + 2, ringPaint);
      }

      for (var i = 0; i < _total; i++) {
        final status = g.status[i];
        final a = i < res.answers.length ? res.answers[i] : -1;
        Color verdict;
        switch (status) {
          case 0:
            verdict = const Color(0xFF12A150);
          case 1:
            verdict = const Color(0xFFE5484D);
          case 3:
            verdict = const Color(0xFFE08700);
          default:
            verdict = const Color(0xFF8A93A6);
        }
        ringPaint.color = verdict;
        if (a >= 0) {
          // Filled disc at exactly the printed bubble's radius — an
          // oversized ring reads as sitting "off" the bubble, while a
          // concentric, same-size fill makes any misalignment visible
          // (and makes the verdict legible).
          final c2 = _mp(geo.questionBubble(i + 1, a));
          canvas.drawCircle(
            c2,
            br,
            ui.Paint()..color = verdict.withOpacity(.35),
          );
          canvas.drawCircle(c2, br, ringPaint);
        } else {
          // blank / unread: draw a dim line across the row
          final p0 = _mp(geo.questionBubble(i + 1, 0));
          final p3 = _mp(geo.questionBubble(i + 1, 3));
          final dim = ui.Paint()
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = 2.0
            ..color = verdict.withOpacity(.65);
          canvas.drawLine(p0, p3, dim);
        }
        // The key marker for wrong/blank answers — a filled disc at
        // exactly the printed bubble's size, in its own green (the read
        // answer's disc carries the verdict colour, so the two stay
        // distinct).
        if (status == 1 || (status == 2 && g.key[i] >= 0)) {
          final pc = _mp(geo.questionBubble(i + 1, g.key[i]));
          canvas.drawCircle(
            pc,
            br,
            ui.Paint()..color = const Color(0x6612A150),
          );
          canvas.drawCircle(
            pc,
            br,
            ui.Paint()
              ..style = ui.PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = const Color(0xCC12A150),
          );
        }
      }

      final picture = rec.endRecording();
      final out = await picture.toImage(w, h);
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _printScorecard() async {
    if (!await _canUseScanner()) return;
    final res = _result;
    final g = _graded;
    if (res == null || g == null) return;
    try {
      await PaperPdf.printOmScorecard(
        title: _titleCtrl.text.trim().isEmpty
            ? (AppSettings.defaultName.isNotEmpty
                ? AppSettings.defaultName
                : 'OMR Test')
            : _titleCtrl.text.trim(),
        subject: _subjectCtrl.text.trim(),
        roll: res.roll,
        registration: res.registration,
        subjectCode: res.subjectCode,
        setCode: res.setCode >= 0 ? _letters[res.setCode] : '—',
        total: _total,
        score: g.score,
        correct: g.correct,
        wrong: g.wrong,
        blank: g.blank,
        ambiguous: g.ambiguous,
        answers: res.answers,
        key: _key,
      );
    } catch (e) {
      if (mounted) {
        await showProblemDialog(context, title: 'Print error', message: '$e');
      }
    }
  }

  Future<void> _saveKey() async {
    await OmrStore.saveKeyDraft(
      OmKeyDraft(
        paperTitle: _titleCtrl.text.trim(),
        total: _total,
        key: _key,
        savedAt: DateTime.now(),
      ),
    );
    if (!mounted) return; // the save can outlive the screen
    _snack('Answer key saved.');
  }

  void _scanNext() {
    setState(() {
      _step = 1;
      _activeRecordId = null;
      _photoBytes = null;
      _photoImage = null;
      _result = null;
      _graded = null;
      _overlayJpg = null;
    });
  }

  Future<void> _confirmReview() async {
    if (_busy || _result == null) return;
    if (!await _canUseScanner()) return;
    setState(() => _busy = true);
    try {
      final result = _result!;
      final graded = OMrScanner.grade(result, _key);
      final overlay = await _buildOverlay(result, graded);
      if (!mounted) return;
      final record = _recordOf(result, graded, id: _activeRecordId);
      await OmrStore.addRecord(record);
      if (!mounted) return;
      if (_batchMode) {
        final index = _batch.indexWhere((r) => r.id == record.id);
        if (index < 0) {
          _batch.add(record);
          _batchOverlays.add(overlay);
        } else {
          _batch[index] = record;
          _batchOverlays[index] = overlay;
        }
      }
      setState(() {
        _activeRecordId = record.id;
        _graded = graded;
        _overlayJpg = overlay;
        _step = 3;
      });
      await _loadHistory();
    } catch (e) {
      if (mounted) await _problem('Could not save this review', '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ═══════════════════ UI ═══════════════════

  @override
  Widget build(BuildContext context) {
    if (!_accessChecked) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final result = _result;
    final graded = _graded;
    return Scaffold(
      appBar: AppBar(
        title: const Text('OMR Scanner'),
        actions: [
          IconButton(
            tooltip: 'Analytics & leaderboard',
            onPressed: () async {
              if (!await SubscriptionGuard.require(
                context,
                PremiumFeature.omrScanner,
              )) return;
              if (!mounted) return;
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OMrAnalyticsScreen()),
              );
            },
            icon: const AppDuotoneIcon(PhosphorIcons.chartBarDuotone),
          ),
          IconButton(
            tooltip: 'Key draft restore',
            onPressed: _busy || _step != 0 ? null : _restoreKeyDraft,
            icon: const AppDuotoneIcon(
              PhosphorIcons.clockCounterClockwiseDuotone,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 30),
          children: [
            WorkflowProgress(
              steps: const [
                'Choose paper',
                'Capture sheet',
                'Review answers',
                'Grade & save',
              ],
              current: _step,
            ),
            if (_step > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : () => setState(() => _step--),
                  icon: const AppDuotoneIcon(
                    PhosphorIcons.arrowLeftDuotone,
                    size: 16,
                  ),
                  label: const Text('Back'),
                ),
              ),
            if (_step == 0) ...[
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Paper & answer key',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Text(
                          '$_keyDone/$_total filled',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _keyDone == _total
                                ? AppTheme.success
                                : AppTheme.warning,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _titleCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Paper title',
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _subjectCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Subject (optional)',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.omr,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        onPressed: _busy ? null : _pickSavedPaper,
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.bookmarksSimpleDuotone,
                          size: 18,
                        ),
                        label: const Text(
                          'Use saved paper (key auto-loads)',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text(
                          'মোট প্রশ্ন',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed:
                              _total > 5 ? () => _setTotal(_total - 5) : null,
                          icon: const AppDuotoneIcon(
                            PhosphorIcons.minusCircleDuotone,
                          ),
                        ),
                        SizedBox(
                          width: 44,
                          child: Center(
                            child: Text(
                              '$_total',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed:
                              _total < 100 ? () => _setTotal(_total + 5) : null,
                          icon: const AppDuotoneIcon(
                            PhosphorIcons.plusCircleDuotone,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _key.any((k) => k >= 0) ? _clearKey : null,
                          child: const Text('Clear all'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _keyGrid(),
                  ],
                ),
              ),
              FilledButton(
                onPressed: _busy || _keyDone != _total
                    ? null
                    : () => setState(() => _step = 1),
                child: const Text('Continue to capture'),
              ),
            ],
            if (_step == 1) ...[
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Capture the OMR sheet',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    const Text(
                      'Keep the whole sheet in frame with all four corner marks visible, in even light.',
                      style: TextStyle(fontSize: 11.5, color: AppTheme.muted),
                    ),
                    const SizedBox(height: 10),
                    if (_photoBytes == null)
                      Row(
                        children: [
                          Expanded(
                            child: AppButton(
                              label: 'Camera',
                              icon: PhosphorIcons.cameraDuotone,
                              onPressed: _busy ? null : _openCamera,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: AppButton(
                              label: 'Gallery',
                              icon: PhosphorIcons.imagesDuotone,
                              outlined: true,
                              onPressed: _busy
                                  ? null
                                  : () => _pickPhoto(ImageSource.gallery),
                            ),
                          ),
                        ],
                      )
                    else
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(_photoBytes!, fit: BoxFit.fitWidth),
                      ),
                    if (_step == 1 && _photoBytes != null) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () => _scanNext(),
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.xDuotone,
                          size: 16,
                        ),
                        label: const Text('Change / remove photo'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _batchDialog,
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.usersThreeDuotone,
                          size: 18,
                        ),
                        label: const Text('Batch scan'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_step == 2 && result != null) ...[
              if (_photoBytes != null)
                SizedBox(
                  height: 280,
                  child: InteractiveViewer(
                    maxScale: 5,
                    child: Image.memory(_photoBytes!, fit: BoxFit.contain),
                  ),
                ),
              AbsorbPointer(
                absorbing: _busy,
                child: OmrAnswerReview(
                  result: result,
                  onChanged: (r) => setState(() {
                    _result = r;
                    _graded = OMrScanner.grade(r, _key);
                  }),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _confirmReview,
                child: const Text('Confirm answers, grade & save'),
              ),
            ],
            if (_step == 1 && _photoBytes != null) ...[
              const SizedBox(height: 12),
              AppButton(
                label: 'Read answers for review',
                icon: PhosphorIcons.qrCodeDuotone,
                onPressed: _busy ? null : _scan,
              ),
            ],
            if (_batchMode) ...[
              const SizedBox(height: 12),
              GlassCard(
                padding: const EdgeInsets.all(14),
                highlighted: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const AppDuotoneIcon(
                          PhosphorIcons.usersThreeDuotone,
                          color: AppColors.omr,
                          secondaryColor: AppColors.light,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Batch scan on — ${_batch.length} sheet(s) graded. Scan the next student, then finish.',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            label: 'Cancel batch',
                            icon: PhosphorIcons.xDuotone,
                            outlined: true,
                            onPressed: _cancelBatch,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: AppButton(
                            label: 'Finish batch',
                            icon: PhosphorIcons.flagDuotone,
                            onPressed: _batch.isEmpty ? null : _finishBatch,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (_busy)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    const ActivityIndicator(color: AppColors.omr),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(_batchProgress ?? 'শিট পড়া হচ্ছে...'),
                    ),
                  ],
                ),
              ),
            if (_step == 3 && result != null && graded != null) ...[
              GlassCard(
                padding: const EdgeInsets.all(16),
                highlighted: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${graded.score} / ${graded.total}   (${graded.percent.toStringAsFixed(1)}%)',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: AppColors.omr,
                      ),
                    ),
                    if ((_scanMs ?? 0) > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Scanned in ${(_scanMs! / 1000).toStringAsFixed(1)}s',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.muted,
                          ),
                        ),
                      ),
                    if (graded.ambiguous > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Double-marked questions are invalid and count as wrong.',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.warning,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip('সঠিক ${graded.correct}', AppTheme.success),
                        _chip('ভুল ${graded.wrong}', AppTheme.danger),
                        _chip('খালি ${graded.blank}', AppTheme.muted),
                        if (graded.ambiguous > 0)
                          _chip(
                            'দ্বি-দাগ ${graded.ambiguous}',
                            AppTheme.warning,
                          ),
                        _chip('রোল ${result.roll}', AppColors.omr),
                        _chip(
                          'রেজিস্ট্রেশন ${result.registration}',
                          result.registration.contains('?')
                              ? AppTheme.warning
                              : AppColors.omr,
                        ),
                        // Prefill off in Settings → sheet codes are not used.
                        if (AppSettings.omrPrefill) ...[
                          _chip(
                            'বিষয় কোড ${result.subjectCode}',
                            AppColors.omr,
                          ),
                          _chip(
                            'সেট ${result.setCode >= 0 ? _letters[result.setCode] : '—'}',
                            AppColors.omr,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (result.registration.contains('?'))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'Registration no. unclear: ${result.registration}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: AppTheme.warning,
                          ),
                        ),
                      ),
                    if (_overlayJpg != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(_overlayJpg!, fit: BoxFit.fitWidth),
                      ),
                    const SizedBox(height: 12),
                    _verdictGrid(graded),
                    TextButton.icon(
                      onPressed: _busy ? null : () => setState(() => _step = 2),
                      icon: const AppDuotoneIcon(
                        PhosphorIcons.pencilSimpleDuotone,
                      ),
                      label: const Text('Review / correct readings'),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: AppButton(
                            label: 'Print scorecard',
                            icon: PhosphorIcons.printerDuotone,
                            onPressed: _printScorecard,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: AppButton(
                            label: 'Save key',
                            icon: PhosphorIcons.floppyDiskDuotone,
                            outlined: true,
                            onPressed: _saveKey,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _scanNext,
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.userDuotone,
                          size: 18,
                        ),
                        label: const Text("Scan next student's OMR sheet"),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // ── batch results ──
            if (_batchDone != null && _batchDone!.isNotEmpty) ...[
              const SizedBox(height: 14),
              GlassCard(
                padding: const EdgeInsets.all(16),
                highlighted: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Batch results',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _closeBatchResults,
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_batchDoneOverlays.isNotEmpty) ...[
                      _batchSheetPager(),
                      const SizedBox(height: 12),
                    ],
                    _batchSummary(),
                    const SizedBox(height: 10),
                    for (var i = 0; i < _batchDone!.length; i++)
                      _batchRow(i, _batchDone![i]),
                    const SizedBox(height: 8),
                    const Text(
                      'Every result is also saved in the scan history below.',
                      style: TextStyle(fontSize: 11, color: AppTheme.muted),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // History
            if (_history.isNotEmpty) ...[
              Row(
                children: [
                  const Text(
                    'স্ক্যান হিস্টরি',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      for (final r in _history) {
                        await OmrStore.deleteRecord(r.id);
                      }
                      _loadHistory();
                    },
                    child: const Text('Clear all'),
                  ),
                ],
              ),
              for (final r in _history)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor:
                            r.score * 100 ~/ math.max(1, r.total) >= 50
                                ? AppTheme.success
                                : AppTheme.warning,
                        child: Text(
                          '${r.score}/${r.total}',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.roll.isEmpty ? 'রোল —' : 'রোল ${r.roll}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${r.paperTitle.isEmpty ? '—' : r.paperTitle} • সেট ${r.setCode} • ${_dateStr(r.date)}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.muted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => _showRecord(r),
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.eyeDuotone,
                          size: 18,
                          color: AppColors.omr,
                          secondaryColor: AppColors.light,
                        ),
                      ),
                      IconButton(
                        onPressed: () async {
                          await OmrStore.deleteRecord(r.id);
                          _loadHistory();
                        },
                        icon: const AppDuotoneIcon(
                          PhosphorIcons.trashDuotone,
                          size: 18,
                          color: AppTheme.danger,
                          secondaryColor: AppColors.light,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  String _dateStr(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: color),
        ),
      );

  // ── batch results helpers ──

  double _pct(OmScanRecord r) => r.score * 100.0 / math.max(1, r.total);

  /// Swipeable pager over every graded sheet of the batch (swipe
  /// right-to-left, or left-to-right). Each page = the sheet's result
  /// overlay with a roll/score caption.
  Widget _batchSheetPager() {
    final n = _batchDoneOverlays.length;
    return Column(
      children: [
        SizedBox(
          height: 460,
          child: PageView.builder(
            itemCount: n,
            itemBuilder: (c, i) {
              final rec = _batchDone![i];
              final overlay = _batchDoneOverlays[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: overlay == null
                            ? const Center(
                                child: Text(
                                  'শিটের ছবি পাওয়া যায়নি — ফল নিচের সারিতে',
                                  style: TextStyle(color: AppTheme.muted),
                                ),
                              )
                            : Image.memory(overlay, fit: BoxFit.contain),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${i + 1}/$n • '
                      '${rec.roll.isEmpty ? 'রোল —' : 'রোল ${rec.roll}'} • '
                      '${rec.score}/${rec.total} • '
                      '${rec.correct} সঠিক • ${rec.wrong} ভুল',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: AppTheme.muted,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '⟵  স্লাইড করে পরের শিট দেখুন  ⟶',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: AppTheme.muted),
        ),
      ],
    );
  }

  Widget _batchSummary() {
    final items = _batchDone!;
    final n = items.length;
    final avg = items.fold<double>(0, (s, r) => s + _pct(r)) / n;
    var best = items.first;
    var low = items.first;
    for (final r in items) {
      if (_pct(r) > _pct(best)) best = r;
      if (_pct(r) < _pct(low)) low = r;
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _chip('Sheets $n', AppColors.omr),
        _chip('Avg ${avg.toStringAsFixed(1)}%', AppColors.omr),
        _chip('Best ${best.score}/${best.total}', AppTheme.success),
        _chip('Lowest ${low.score}/${low.total}', AppTheme.warning),
      ],
    );
  }

  Widget _batchRow(int i, OmScanRecord r) {
    final pass = _pct(r) >= 50;
    return InkWell(
      onTap: () => _showRecord(r),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppTheme.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text(
                '${i + 1}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.muted,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.roll.isEmpty ? 'Roll —' : 'Roll ${r.roll}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${r.correct}✓',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTheme.success,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${r.wrong}✗',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTheme.danger,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${r.blank}·',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppTheme.muted,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: (pass ? AppTheme.success : AppTheme.warning).withOpacity(
                  .14,
                ),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: pass ? AppTheme.success : AppTheme.warning,
                ),
              ),
              child: Text(
                '${r.score}/${r.total}',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _keyGrid() {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisExtent: 58,
        crossAxisSpacing: 10,
        mainAxisSpacing: 6,
      ),
      itemCount: _total,
      itemBuilder: (context, i) {
        final chosen = _key[i];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: chosen >= 0
                ? AppColors.omr.withOpacity(.08)
                : AppTheme.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  chosen >= 0 ? AppColors.omr.withOpacity(.5) : AppTheme.border,
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.muted,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              for (var o = 0; o < 4; o++)
                Expanded(
                  child: GestureDetector(
                    onTap: _busy
                        ? null
                        : () => setState(() {
                              _key[i] = o;
                              _result = null;
                              _graded = null;
                              _activeRecordId = null;
                            }),
                    child: Center(
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: chosen == o ? AppColors.omr : Colors.white,
                          border: Border.all(
                            color:
                                chosen == o ? AppColors.omr : AppTheme.border,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            _letters[o],
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: chosen == o
                                  ? Colors.white
                                  : AppTheme.textDark,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _clearKey() {
    setState(() => _key = List<int>.filled(_total, -1));
  }

  // ── saved-paper link (no manual key entry) ──────────────────────

  /// Opens the list of papers saved from the in-app builder and loads the
  /// chosen one's title, subject, total and full answer key.
  Future<void> _pickSavedPaper() async {
    final papers = await PaperLibrary.loadSavedPapers();
    if (papers.isEmpty) {
      await _problem(
        'No saved papers',
        'No saved papers yet. Generate a paper and tap "Save paper".',
      );
      return;
    }
    if (!mounted) return;
    final p = await showDialog<SavedPaper>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use a saved paper'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              children: [
                for (final sp in papers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      sp.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${sp.subject} • ${sp.total} questions'
                      '${sp.setCode != '—' ? ' • set ${sp.setCode}' : ''}',
                    ),
                    onTap: () => Navigator.pop(c, sp),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (p == null) return;
    if (!mounted) return; // loading + dialog can outlive the screen
    setState(() {
      _total = p.total;
      _key = List<int>.of(p.key);
      _titleCtrl.text = p.title;
      _subjectCtrl.text = p.subject;
      _result = null;
      _graded = null;
      _overlayJpg = null;
    });
    _snack('Answer key loaded — ${p.total} questions, ready to scan.');
  }

  // ── batch (whole-class) scan ────────────────────────────────────

  /// Entry point for batch scanning: pick the source for the whole class.
  Future<void> _batchDialog() async {
    if (!await _canUseScanner()) return;
    if (_key.any((k) => k < 0)) {
      await _problem(
        'Answer key incomplete',
        'Complete the answer key first — or tap "Use saved paper".',
      );
      return;
    }
    final mode = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Batch scan'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Every sheet is graded with the current answer key and saved to the scan history.',
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              icon: const AppDuotoneIcon(
                PhosphorIcons.imagesDuotone,
                color: AppColors.onColor,
                secondaryColor: AppColors.light,
                size: 18,
              ),
              label: const Text('Gallery (pick many)'),
              onPressed: () => Navigator.pop(c, 'gallery'),
            ),
            const SizedBox(height: 10),
            FilledButton.icon(
              icon: const AppDuotoneIcon(
                PhosphorIcons.cameraDuotone,
                color: AppColors.onColor,
                secondaryColor: AppColors.light,
                size: 18,
              ),
              label: const Text('Camera (one by one)'),
              onPressed: () => Navigator.pop(c, 'camera'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (mode == 'gallery') {
      await _runBatchGallery();
    } else if (mode == 'camera' && mounted) {
      setState(() {
        _batchMode = true;
        _batch = [];
        _batchOverlays = [];
        _batchDone = null;
        _batchDoneOverlays = const [];
      });
      _snack('Batch mode on — scan each student, then tap Finish batch.');
    }
  }

  /// Gallery batch: pick many photos at once, scan + grade each in order.
  Future<void> _runBatchGallery() async {
    final picked = await ImagePicker().pickMultiImage(
      imageQuality: 90,
      maxWidth: 4096,
    );
    if (picked.isEmpty || !mounted) return;
    final items = <OmScanRecord>[];
    final overlays = <Uint8List?>[];
    setState(() {
      _busy = true;
      _batchProgress = 'Scanning 0/${picked.length}…';
    });
    var idx = 0;
    for (final f in picked) {
      idx++;
      if (!mounted) return;
      setState(() => _batchProgress = 'Scanning $idx/${picked.length}…');
      try {
        final bytes = await f.readAsBytes();
        OmScanResult res;
        try {
          res = await compute(
            omrScanIsolateEntry,
            OmScanRequest(bytes, _total),
          );
        } on OmDecodeException {
          // Background isolate can't decode it — retry on the UI isolate.
          res = await OMrScanner.scan(bytes, total: _total);
        }
        if (!res.ok) continue; // unreadable sheet — skip, keep going
        if (!mounted) return;
        final reviewed = await reviewOmrSheet(
          context,
          res,
          title: 'Review sheet $idx of ${picked.length}',
        );
        if (reviewed == null) continue;
        if (!mounted) return;
        res = reviewed;
        final g = OMrScanner.grade(res, _key);
        final rec = _recordOf(res, g);
        // Overlay for the batch review (swipe through every sheet).
        final overlay = await _buildOverlay(res, g, photoBytes: bytes);
        items.add(rec);
        overlays.add(overlay);
        await OmrStore.addRecord(rec);
      } catch (_) {
        // Skip this sheet and continue the batch.
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _batchProgress = null;
      _step = 3;
      _batchDone = items;
      _batchDoneOverlays = overlays;
      _batchMode = false;
    });
    _loadHistory();
    if (items.isEmpty && mounted) {
      await showProblemDialog(
        context,
        title: 'No sheet could be read',
        message: 'None of the selected photos could be aligned to the OMR '
            'grid.',
        detail:
            'Check that each sheet is flat, fills the frame with a small margin, and the bubbles are clearly filled — then try again.',
      );
    }
  }

  void _finishBatch() {
    setState(() {
      _batchDone = _batch;
      _batchDoneOverlays = _batchOverlays;
      _batchMode = false;
      _batch = [];
      _batchOverlays = [];
    });
  }

  void _cancelBatch() {
    setState(() {
      _batchMode = false;
      _batch = [];
    });
  }

  void _closeBatchResults() {
    setState(() {
      _batchDone = null;
      _batchDoneOverlays = const [];
    });
  }

  Widget _verdictGrid(OmGraded g) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const Text(
            'প্রশ্নভিত্তিক ফল',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            children: [
              for (var i = 0; i < g.total; i++)
                Text(
                  '${i + 1}.${_choiceLetter(i, g)}${_glyph(g.status[i])}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: g.status[i] == 0
                        ? AppTheme.success
                        : (g.status[i] == 1 ? AppTheme.danger : AppTheme.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _choiceLetter(int i, OmGraded g) =>
      i < g.answers.length && g.answers[i] >= 0
          ? _letters[g.answers[i]]
          : (i < g.answers.length && g.answers[i] == -2 ? '?' : '—');

  String _glyph(int status) =>
      status == 0 ? '✓' : (status == 1 ? '✗' : (status == 2 ? '·' : '?'));

  Future<void> _showRecord(OmScanRecord r) async {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          'রোল ${r.roll.isEmpty ? '—' : r.roll} • ${r.score}/${r.total}',
        ),
        content: SizedBox(
          height: 200,
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                for (var i = 0; i < r.key.length; i++)
                  Text(
                    '${i + 1}.${i < r.answers.length && r.answers[i] >= 0 ? _letters[r.answers[i]] : '—'}',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: i < r.answers.length && r.answers[i] == r.key[i]
                          ? AppTheme.success
                          : AppTheme.danger,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreKeyDraft() async {
    final draft = await OmrStore.loadKeyDraft();
    if (draft == null || draft.key.isEmpty) {
      await _problem('No saved key', 'No saved key found.');
      return;
    }
    if (!mounted) return; // the load can outlive the screen
    setState(() {
      _total = draft.total;
      _key = List<int>.filled(draft.total, -1);
      for (var i = 0; i < draft.total && i < draft.key.length; i++) {
        _key[i] = draft.key[i];
      }
      if (draft.paperTitle.isNotEmpty) _titleCtrl.text = draft.paperTitle;
    });
    _snack('Saved key restored (${draft.total} questions).');
  }
}
