import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'ai/ai_text_formatter.dart';

import '../data/bangla_1st/bangla_1st_literature_questions.dart';
import '../data/bangla_2nd/bangla_2nd_written_questions.dart';
import '../data/question_figure.dart';
import '../data/questions_data.dart';
import 'app_settings.dart';
import 'omr/omr_geometry.dart';
import '../theme/design_tokens.dart';
import 'mcq_stimulus.dart';

/// একটি স্ট্যাকড ভগ্নাংশ (লব উপরে, দাগ মাঝে, হর নিচে)
class _Frac {
  final String n, d;
  const _Frac(this.n, this.d);
}

/// রেন্ডার-সময়ে একটি সাজানো ভগ্নাংশের পেইন্টার-জোড়া
typedef _FracP = ({TextPainter n, TextPainter d, double w, double h});

/// একটি প্যারাগ্রাফের ফল: মূল TextPainter + ভেতরের ভগ্নাংশগুলো
typedef _RichLine = ({TextPainter tp, List<_FracP> fr});

/// বাংলা প্রশ্নপত্র → PDF / প্রিন্ট (v3 ইঞ্জিন)
///
/// v2: প্রতিটি A4 পেজ আগে Flutter-এর TextPainter (Skia/Harfbuzz) দিয়ে আঁকা
/// হয় — বাংলা যুক্তাক্ষর ১০০% ঠিক থাকে; তারপর পেজটি PNG হিসেবে PDF এ বসে।
///
/// v3-এ নতুন:
///  ১) DejaVu Sans চিহ্ন-ফন্ট যুক্ত — α θ π Δ, ∩∪∈∅⊂⊆ √ ∠ ∥ ⊥ ′, সুপার-
///     স্ক্রিপ্ট (² ⁿ ⁻), সাবস্ক্রিপ্ট (₁₂ₐ) সব *আসল চিহ্নে* ছাপে
///     (আগে "থেটা", "x^-2" লিখে ফেলত)।
///  ২) স্ট্যাকড ভগ্নাংশ রেন্ডারার — "1/2", "(a+b)/ab", "১/২" সব স্কুল-
///     বইয়ের মতো লব-দাগ-হর আকারে আঁকা হয়।
///  ৩) "নাম ঃ" টাইপে স্পেস+ঃ বসলে ফন্ট-শেপার ডটেড-সার্কেল বসিয়ে দেয়
///     (যেটা "O:" দেখায়) — তাই সব 'ঃ' আগের শব্দের সাথে লেগে রাখা হয়েছে।
///  ৪) গণিত/উচ্চতর গণিতের সৃজনশীল নতুন নিয়মে ক(২)+খ(৪)+গ(৪) — ৩ ভাগ।
///
/// ফন্ট (assets/fonts/): NotoSerifBengali-Regular/Bold.ttf (বাংলা ও সংখ্যা),
/// HindSiliguri-Regular.ttf (অতিরিক্ত সেফটি), DejaVuSans.ttf ও
/// DejaVuSans-Bold.ttf (গাণিতিক/বৈজ্ঞানিক চিহ্ন)।
class PaperPdf {
  static const _optionLetters = ['ক', 'খ', 'গ', 'ঘ'];

  // ── রেন্ডার সেটিং ─────────────────────────────────────────────
  static const double _dpi = 200; // প্রিন্টের জন্য যথেষ্ট
  static const double _k = _dpi / 72; // pt → px গুণক
  static const int _W = 1654; // A4 প্রস্থ @200dpi (px)
  static const int _H = 2339; // A4 উচ্চতা @200dpi (px)
  static const double _margin = 40 * _k; // মার্জিন ≈ 14 মিমি

  // ফন্ট ফ্যামিলি (FontLoader দিয়ে রেজিস্টার করা নাম):
  //  HSPDF-Regular/Bold = Noto Serif Bengali — বাংলা অক্ষর ও সংখ্যা
  //  HSPDF-Sym          = Hind Siliguri — সর্বশেষ সেফটি ফলব্যাক
  //  DVPDF / DVPDF-Bold = DejaVu Sans — গ্রিক/গাণিতিক চিহ্ন, সুপার-সাবস্ক্রিপ্ট
  static String? _regular;
  static String? _bold;
  static String? _sym;
  static String? _dv;
  static String? _dvb;
  static bool _fontsTried = false;

  /// Cache of decoded figure pictures, keyed by file name.
  static final Map<String, ui.Image> _figureImageCache = {};

  /// Decodes every `FigureKind.image` picture referenced by [figures].
  ///
  /// paintFig runs synchronously while the page is being drawn, so the bytes
  /// have to be turned into ui.Image objects before rendering begins. A
  /// missing or unreadable file is skipped — paintFig then draws a visible
  /// placeholder instead of failing the whole paper.
  static Future<Map<String, ui.Image>> _decodeFigureImages(
    Iterable<QuestionFigure?> figures,
  ) async {
    final names = <String>{
      for (final f in figures)
        if (f != null && f.kind == FigureKind.image && f.imagePath != null)
          f.imagePath!,
    };
    final out = <String, ui.Image>{};
    for (final name in names) {
      final cached = _figureImageCache[name];
      if (cached != null) {
        out[name] = cached;
        continue;
      }
      try {
        Uint8List bytes;
        if (name.startsWith('http://') || name.startsWith('https://')) {
          // Published from the web panel: the picture lives in Supabase
          // Storage, not in the APK. Fetch it once, then keep a base64 copy
          // so later papers print offline.
          bytes = await _remoteFigureBytes(name);
        } else {
          final data = await rootBundle.load('assets/question_figures/$name');
          bytes = data.buffer.asUint8List();
        }
        final codec = await ui.instantiateImageCodec(bytes);
        final frame = await codec.getNextFrame();
        _figureImageCache[name] = frame.image;
        out[name] = frame.image;
      } catch (e) {
        // Leave it out; paintFig shows a '[ছবি পাওয়া যায়নি]' box.
        debugPrint('PaperPdf: figure unavailable ($name): $e');
      }
    }
    return out;
  }

  /// Downloads a figure published from the web panel, caching the bytes in
  /// SharedPreferences so a paper still prints when offline later.
  static Future<Uint8List> _remoteFigureBytes(String url) async {
    final key = 'figure_cache_${url.hashCode}';
    final prefs = await SharedPreferences.getInstance();

    final cached = prefs.getString(key);
    if (cached != null && cached.isNotEmpty) {
      try {
        return base64Decode(cached);
      } catch (_) {
        await prefs.remove(key);
      }
    }

    final res =
        await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final bytes = res.bodyBytes;
    // Keep the cache sane: skip anything unusually large.
    if (bytes.lengthInBytes <= 2 * 1024 * 1024) {
      await prefs.setString(key, base64Encode(bytes));
    }
    return bytes;
  }

  static Future<void> _loadFonts() async {
    if (_fontsTried) return; // একবার চেষ্টা করলেই যথেষ্ট
    _fontsTried = true;
    try {
      final lr = FontLoader('HSPDF-Regular')
        ..addFont(rootBundle.load('assets/fonts/NotoSerifBengali-Regular.ttf'));
      await lr.load();
      _regular = 'HSPDF-Regular';
    } catch (_) {}
    try {
      final lb = FontLoader('HSPDF-Bold')
        ..addFont(rootBundle.load('assets/fonts/NotoSerifBengali-Bold.ttf'));
      await lb.load();
      _bold = 'HSPDF-Bold';
    } catch (_) {}
    try {
      final ls = FontLoader('HSPDF-Sym')
        ..addFont(rootBundle.load('assets/fonts/HindSiliguri-Regular.ttf'));
      await ls.load();
      _sym = 'HSPDF-Sym';
    } catch (_) {}
    try {
      final ld = FontLoader('DVPDF')
        ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      await ld.load();
      _dv = 'DVPDF';
    } catch (_) {}
    try {
      final ldb = FontLoader('DVPDF-Bold')
        ..addFont(rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
      await ldb.load();
      _dvb = 'DVPDF-Bold';
    } catch (_) {}
    // কোনো ফাইল না পেলে সেই স্তর বাদ পড়বে — প্রিন্ট তবু কাজ করবে
  }

  /// কোন গ্লিফ কোন ফন্ট থেকে আসবে — ফলব্যাক শৃঙ্খলা
  static List<String>? _fb(bool bold) {
    final l = <String>[
      if (bold && _dvb != null) _dvb!,
      if (_dv != null) _dv!,
      if (_sym != null) _sym!,
    ];
    return l.isEmpty ? null : l;
  }

  // DejaVu-তে থাকা সব চিহ্ন এখন আর বদলানো হয় না — সরাসরি ছাপে।
  // শুধু যেগুলো কোনো ফন্টেই নেই/ভগ্নাংশে রূপান্তর দরকার সেগুলোই বদলায়।
  static String _safe(String s, {bool preserveSpaces = false}) {
    s = AiTextFormatter.format(s, trim: false);
    const single = <String, String>{
      '½': '1/2', '¼': '1/4', '¾': '3/4', // ভগ্নাংশ রেন্ডারারে যাবে
      '⟂': '⊥', // U+27C2 কোনো ফন্টেই নেই — সমার্থক ⊥ (লম্ব) দিয়ে
    };
    single.forEach((k, v) => s = s.replaceAll(k, v));
    return preserveSpaces ? s : s.replaceAll(RegExp(' +'), ' ');
  }

  // ═══════════ স্ট্যাকড ভগ্নাংশ বিভাজক ═══════════
  // "x + 1/x = 4" → ["x + ", Frac(1,x), " = 4"]
  // পাশে স্পেস থাকলে (1 / sin x), একক হলে (m/s², kg/m³), হর শুদ্ধ ত্রিকোণমিতি
  // হলে (30/tan 30°), বা দুই পাশই বাংলা হলে (উচ্চতা/দূরত্ব) — ভগ্নাংশ হয় না।
  static const String _tokChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
      '0123456789০১২৩৪৫৬৭৮৯√πθ°.·−-²³¹⁴⁵⁶⁷⁸⁹⁰ⁿ₁₂₀ₐ';
  static const String _supChars = '²³¹⁴⁵⁶⁷⁸⁹⁰ⁿ⁻⁺ᵐ';
  static const String _mathyChars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
      '0123456789০১২৩৪৫৬৭৮৯√πθ°';
  static const Set<String> _unitFracs = {
    'm/s',
    'm/s²',
    'kg/m³',
    'g/cm³',
    'N/m²',
    'N/kg',
    'W/m²',
    'km/h',
    'kg·m/s',
    'kg·m/s²',
  };
  static const Set<String> _trigNames = {
    'sin',
    'cos',
    'tan',
    'sec',
    'cosec',
    'cot',
    'log',
  };

  static bool _hasMathChar(String t) {
    for (int i = 0; i < t.length; i++) {
      if (_mathyChars.contains(t[i])) return true;
    }
    return false;
  }

  static String _stripParens(String t) {
    if (t.length >= 2 && t[0] == '(' && t[t.length - 1] == ')') {
      var depth = 0;
      var closedAtEnd = true;
      for (int i = 0; i < t.length; i++) {
        if (t[i] == '(') depth++;
        if (t[i] == ')') {
          depth--;
          if (depth == 0 && i != t.length - 1) closedAtEnd = false;
        }
      }
      if (closedAtEnd && depth == 0) return t.substring(1, t.length - 1);
    }
    return t;
  }

  static List<Object> _splitFractions(String s) {
    final out = <Object>[];
    final buf = StringBuffer();
    int i = 0;
    void flush() {
      if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }

    while (i < s.length) {
      if (s[i] != '/') {
        buf.write(s[i]);
        i++;
        continue;
      }
      final rawLs = i - 1;
      if (rawLs < 0 || i + 1 >= s.length) {
        buf.write('/');
        i++;
        continue;
      }
      // স্পেস-ঘেরা '/': দুই পাশ প্যারেন্থেসিস-বন্ধ গাণিতিক রাশি হলেই ভগ্নাংশ,
      // যেমন (2y + 1) / (2y - 1); নাহলে (m / s টাইপ) প্লেইন রাখা হয়
      var ls = rawLs;
      var rs = i + 1;
      var spaced = false;
      while (ls >= 0 && s[ls] == ' ') {
        ls--;
        spaced = true;
      }
      while (rs < s.length && s[rs] == ' ') {
        rs++;
        spaced = true;
      }
      if (ls < 0 || rs >= s.length) {
        buf.write('/');
        i++;
        continue;
      }
      if (spaced && !(s[ls] == ')' && s[rs] == '(')) {
        buf.write('/');
        i++;
        continue;
      }
      if (spaced) {
        final t = buf.toString();
        buf.clear();
        buf.write(t.trimRight());
      }
      // ── বাম পাশ (লব) ──
      String num;
      int leftStart;
      int k = ls;
      while (k >= 0 && _supChars.contains(s[k])) {
        k--;
      }
      final bool supTail = k < ls;
      if ((supTail && k >= 0 && s[k] == ')') || (!supTail && s[ls] == ')')) {
        // বন্ধনী-গোষ্ঠী (সুপারস্ক্রিপ্ট থাকলে সেটা-সহ): (a + b)²/…
        final closeIdx = supTail ? k : ls;
        var depth = 0;
        var j = closeIdx;
        while (j >= 0) {
          if (s[j] == ')') depth++;
          if (s[j] == '(') {
            depth--;
            if (depth == 0) break;
          }
          j--;
        }
        if (j < 0) {
          buf.write('/');
          i++;
          continue;
        }
        leftStart = j;
        num = s.substring(j, ls + 1);
      } else {
        var j = ls;
        var cnt = 0;
        while (j >= 0 && _tokChars.contains(s[j]) && cnt < 18) {
          j--;
          cnt++;
        }
        leftStart = j + 1;
        num = s.substring(leftStart, ls + 1);
      }
      // ── ডান পাশ (হর) ──
      String den;
      int rightEnd;
      final r = rs;
      if (s[r] == '(') {
        var depth = 0;
        var j = r;
        while (j < s.length) {
          if (s[j] == '(') depth++;
          if (s[j] == ')') {
            depth--;
            if (depth == 0) break;
          }
          j++;
        }
        if (j >= s.length) {
          buf.write('/');
          i++;
          continue;
        }
        den = s.substring(r, j + 1);
        rightEnd = j + 1;
      } else {
        var j = r;
        var cnt = 0;
        while (j < s.length && _tokChars.contains(s[j]) && cnt < 18) {
          j++;
          cnt++;
        }
        den = s.substring(r, j);
        rightEnd = j;
      }
      final nc = _stripParens(num);
      final dc = _stripParens(den);
      if (nc.isEmpty ||
          dc.isEmpty ||
          !_hasMathChar(nc) ||
          !_hasMathChar(dc) ||
          _unitFracs.contains('$num/$den') ||
          _trigNames.contains(dc.toLowerCase())) {
        buf.write('/');
        i++;
        continue;
      }
      // বাফারে লেখা বাম-টোকেন ফেরত নিই (সেটা ভগ্নাংশে চলে যাবে)
      final leftLen = ls + 1 - leftStart;
      final cur = buf.toString();
      buf.clear();
      buf.write(cur.substring(0, cur.length - leftLen));
      flush();
      out.add(_Frac(nc, dc));
      i = rightEnd;
    }
    flush();
    return out;
  }

  /// মূল এন্ট্রি পয়েন্ট — আগের মতোই + নতুন ঐচ্ছিক প্যারামিটার।
  static Future<void> printPaper({
    required String title,
    required String modeLine,
    String? subjectName,
    required List<Question> mcqs,
    required List<CreativeQuestion> cqs,
    List<LiteratureQuestion> literatureQuestions = const <LiteratureQuestion>[],
    String? literatureNote,
    List<Bangla2WrittenQuestion> bangla2WrittenQuestions =
        const <Bangla2WrittenQuestion>[],
    String headerLine1 = 'মডেল টেস্ট পরীক্ষা — ২০২৭',
    String headerLine2 = 'দশম শ্রেণি',
    String time = '৩ ঘণ্টা',
    String marks = '১০০',
    int cqAnswerCount = 7,
    List<Question> saqs = const [],
    int saqAnswerCount = 10,
    String? cqNote,
    String? writtenTime,
    String? writtenMarks,
    String? mcqTime,
    String? mcqMarks,
    bool mathCqThreePart = false, // গণিত: সৃজনশীল ক(২)+খ(৪)+গ(৪)
    String? subjectCode, // বিষয় কোড বাক্সে আগে থেকে লেখা (যেমন '১০৯')
    String? setCode, // সেট কোড বাক্সে (যেমন 'ক')
  }) async {
    await _loadFonts();

    final pages = await _renderPages(
      title: title,
      modeLine: modeLine,
      subjectName: subjectName,
      mcqs: mcqs,
      cqs: cqs,
      literatureQuestions: literatureQuestions,
      literatureNote: literatureNote,
      bangla2WrittenQuestions: bangla2WrittenQuestions,
      headerLine1: headerLine1,
      headerLine2: headerLine2,
      time: time,
      marks: marks,
      cqAnswerCount: cqAnswerCount,
      saqs: saqs,
      saqAnswerCount: saqAnswerCount,
      cqNote: cqNote,
      writtenTime: writtenTime,
      writtenMarks: writtenMarks,
      mcqTime: mcqTime,
      mcqMarks: mcqMarks,
      mathCqThreePart: mathCqThreePart,
      subjectCode: subjectCode,
      setCode: setCode,
    );

    // রাস্টার পেজগুলো PDF এ বসাও
    final doc = pw.Document();
    for (final png in pages) {
      final img = pw.MemoryImage(png);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            img,
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    final bytes = await doc.save();
    try {
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (_) {
      // কিছু ফোনে system print dialog খোলে না (print service off/incompatible)।
      // তখন PDF সরাসরি Share/Save sheet-এ পাঠাই — সেখান থেকে save/print যায়।
      await Printing.sharePdf(bytes: bytes, filename: 'tutors_desk_paper.pdf');
    }
  }

  /// 👁️ স্ক্রিন-প্রিভিউর জন্য: প্রিন্টের ***ঠিক সেই*** রাস্টার পেজগুলো
  /// (PNG bytes) ফেরত দেয় — প্রিভিউ ১০০% মিলে যায় PDF-এর সঙ্গে।
  static Future<List<Uint8List>> renderPages({
    required String title,
    required String modeLine,
    String? subjectName,
    required List<Question> mcqs,
    required List<CreativeQuestion> cqs,
    List<LiteratureQuestion> literatureQuestions = const <LiteratureQuestion>[],
    String? literatureNote,
    List<Bangla2WrittenQuestion> bangla2WrittenQuestions =
        const <Bangla2WrittenQuestion>[],
    String headerLine1 = 'মডেল টেস্ট পরীক্ষা — ২০২৭',
    String headerLine2 = 'দশম শ্রেণি',
    String time = '৩ ঘণ্টা',
    String marks = '১০০',
    int cqAnswerCount = 7,
    List<Question> saqs = const [],
    int saqAnswerCount = 10,
    String? cqNote,
    String? writtenTime,
    String? writtenMarks,
    String? mcqTime,
    String? mcqMarks,
    bool mathCqThreePart = false,
    String? subjectCode,
    String? setCode,
  }) async {
    await _loadFonts();
    return _renderPages(
      title: title,
      modeLine: modeLine,
      subjectName: subjectName,
      mcqs: mcqs,
      cqs: cqs,
      literatureQuestions: literatureQuestions,
      literatureNote: literatureNote,
      bangla2WrittenQuestions: bangla2WrittenQuestions,
      headerLine1: headerLine1,
      headerLine2: headerLine2,
      time: time,
      marks: marks,
      cqAnswerCount: cqAnswerCount,
      saqs: saqs,
      saqAnswerCount: saqAnswerCount,
      cqNote: cqNote,
      writtenTime: writtenTime,
      writtenMarks: writtenMarks,
      mcqTime: mcqTime,
      mcqMarks: mcqMarks,
      mathCqThreePart: mathCqThreePart,
      subjectCode: subjectCode,
      setCode: setCode,
    );
  }

  // ১ম অংশ (লিখিত পত্র): সৃজনশীল + সংক্ষিপ্ত-উত্তর, মান ডান কলামে।
  // ২য় অংশ (বহুনির্বাচনি পত্র): স্কুল-বোর্ড স্টাইল হেডার (প্রাপ্ত নম্বর ও
  // কোড বাক্স, নাম/রোল/শাখা লাইন, দ্রষ্টব্য বাক্স) + দুই কলাম MCQ।
  /// The rendering loops below do seconds of continuous text layout
  /// (TextPainter) on the UI thread. Yield to the event loop roughly every
  /// 8 ms so the UI can paint the loading spinner and keep responding to
  /// touch — prevents the Android "app not responding" dialog while a paper
  /// is being rendered.
  static int _lastYieldAt = 0;
  static Future<void> _yieldToUi() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastYieldAt >= 8) {
      await Future<void>.delayed(Duration.zero);
      _lastYieldAt = DateTime.now().millisecondsSinceEpoch;
    }
  }

  static Future<List<Uint8List>> _renderPages({
    required String title,
    required String modeLine,
    String? subjectName,
    required List<Question> mcqs,
    required List<CreativeQuestion> cqs,
    List<LiteratureQuestion> literatureQuestions = const <LiteratureQuestion>[],
    String? literatureNote,
    List<Bangla2WrittenQuestion> bangla2WrittenQuestions =
        const <Bangla2WrittenQuestion>[],
    required String headerLine1,
    required String headerLine2,
    required String time,
    required String marks,
    required int cqAnswerCount,
    required List<Question> saqs,
    required int saqAnswerCount,
    String? cqNote,
    String? writtenTime,
    String? writtenMarks,
    String? mcqTime,
    String? mcqMarks,
    bool mathCqThreePart = false,
    String? subjectCode,
    String? setCode,
  }) async {
    // Decode every picture up front. paintFig is synchronous, so images have
    // to be ready before any drawing starts.
    final figureImages = await _decodeFigureImages([
      ...mcqs.map((q) => q.figure),
      ...cqs.map((q) => q.figure),
      ...saqs.map((q) => q.figure),
    ]);

    final pages = <Uint8List>[];
    const double sw = 1654.0;
    const double sh = 2339.0;
    final double bottomY = sh - _margin;
    final double contentW = sw - 2 * _margin;

    final wt = _safe(writtenTime ?? time);
    final wm = _safe(writtenMarks ?? marks);
    final mt = _safe(mcqTime ?? '৩০ মিনিট');
    final mm = _safe(mcqMarks ?? _bn(mcqs.length));

    late ui.PictureRecorder rec;
    late Canvas canvas;
    late double y;

    void begin() {
      rec = ui.PictureRecorder();
      canvas = Canvas(rec, Rect.fromLTWH(0, 0, sw, sh));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, sw, sh),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      y = _margin;
    }

    Future<void> commit() async {
      final stamp = TextPainter(
        text: TextSpan(
          text: 'AL·v25',
          style: TextStyle(
            fontFamily: _regular,
            fontSize: 7 * _k,
            color: const Color(0xFFAAAAAA),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      stamp.paint(canvas, Offset(_margin, sh - 6 * _k));
      final img = await rec.endRecording().toImage(_W, _H);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      pages.add(bd!.buffer.asUint8List());
    }

    TextStyle st(double size, bool isBold, double lineHeight) => TextStyle(
          fontFamily: isBold ? (_bold ?? _regular) : _regular,
          fontFamilyFallback: _fb(isBold),
          fontWeight:
              (isBold && _bold == null) ? FontWeight.w700 : FontWeight.w400,
          fontSize: size * _k,
          height: lineHeight,
          color: const Color(0xFF000000),
        );

    TextPainter makePainter(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.left,
      double lineHeight = 1.4,
    }) {
      return TextPainter(
        text: TextSpan(text: text, style: st(size, isBold, lineHeight)),
        textDirection: TextDirection.ltr,
        textAlign: align,
      );
    }

    double mx(double a, double b) => a > b ? a : b;

    // ── রিচ লাইন: টেক্সটের ভেতরে স্ট্যাকড ভগ্নাংশ বসানো ──
    // ভগ্নাংশগুলো placeholder হিসেবে TextPainter-এ জায়গা নেয়; লে-আউটের পর
    // সেই ঘরগুলোতে লব-দাগ-হর আলাদা করে আঁকা হয়। কোনো ঝামেলা হলে নিরাপদে
    // প্লেইন টেক্সটে ফিরে যায়।
    _RichLine rich(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.left,
      double lineHeight = 1.4,
      bool preserveSpaces = false,
      required double maxWidth,
    }) {
      try {
        final safe = _safe(text, preserveSpaces: preserveSpaces);
        final segs = _splitFractions(safe);
        if (segs.length == 1 && segs.first is String) {
          final tp = makePainter(
            segs.first as String,
            size,
            isBold: isBold,
            align: align,
            lineHeight: lineHeight,
          );
          tp.layout(maxWidth: maxWidth);
          return (tp: tp, fr: const []);
        }
        final children = <InlineSpan>[];
        final frs = <_FracP>[];
        for (final seg in segs) {
          if (seg is String) {
            if (seg.isNotEmpty) children.add(TextSpan(text: seg));
          } else {
            final f = seg as _Frac;
            final small = size * 0.72;
            final tn = TextPainter(
              text: TextSpan(text: f.n, style: st(small, isBold, 1.1)),
              textDirection: TextDirection.ltr,
            )..layout();
            final td = TextPainter(
              text: TextSpan(text: f.d, style: st(small, isBold, 1.1)),
              textDirection: TextDirection.ltr,
            )..layout();
            final w = mx(tn.width, td.width) + 1.6 * _k;
            final h = tn.height + td.height + 2.0 * _k;
            frs.add((n: tn, d: td, w: w, h: h));
            children.add(
              const WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: SizedBox.shrink(),
              ),
            );
          }
        }
        final tp = TextPainter(
          text: TextSpan(
            style: st(size, isBold, lineHeight),
            children: children,
          ),
          textDirection: TextDirection.ltr,
          textAlign: align,
        );
        tp.setPlaceholderDimensions([
          for (final f in frs)
            PlaceholderDimensions(
              size: Size(f.w, f.h),
              alignment: PlaceholderAlignment.middle,
            ),
        ]);
        tp.layout(maxWidth: maxWidth);
        return (tp: tp, fr: frs);
      } catch (_) {
        final tp = makePainter(
          _safe(text),
          size,
          isBold: isBold,
          align: align,
          lineHeight: lineHeight,
        );
        tp.layout(maxWidth: maxWidth);
        return (tp: tp, fr: const []);
      }
    }

    void paintRich(_RichLine line, double x, double y0) {
      line.tp.paint(canvas, Offset(x, y0));
      if (line.fr.isEmpty) return;
      final boxes = line.tp.inlinePlaceholderBoxes;
      if (boxes == null || boxes.length < line.fr.length) return;
      for (int fi = 0; fi < line.fr.length; fi++) {
        final f = line.fr[fi];
        final r = boxes[fi].toRect().translate(x, y0);
        final nh = f.n.height;
        final dh = f.d.height;
        final ny = r.top + 0.3 * _k; // লবের উপরের কিনারা
        final dy2 = r.bottom - 0.3 * _k - dh; // হরের উপরের কিনারা
        f.n.paint(canvas, Offset(r.left + (r.width - f.n.width) / 2, ny));
        f.d.paint(canvas, Offset(r.left + (r.width - f.d.width) / 2, dy2));
        final yb = (ny + nh + dy2) / 2; // ভগ্নাংশ-দাগ মাঝখানে
        canvas.drawLine(
          Offset(r.left + 0.35 * _k, yb),
          Offset(r.right - 0.35 * _k, yb),
          Paint()
            ..color = const Color(0xFF000000)
            ..strokeWidth = 0.6 * _k
            ..strokeCap = StrokeCap.butt,
        );
      }
    }

    void strokeRect(Rect r, {double thick = 1.2}) {
      canvas.drawRect(
        r,
        Paint()
          ..color = const Color(0xFF000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = thick * _k,
      );
    }

    // ── চিত্র/সারণি (ফিগার) রেন্ডারার ─────────────────────────────
    // প্রশ্ন বা উদ্দীপকের সাথে দরকারি ছক-তালিকা, ত্রিভুজ চিত্র ও বার-চার্ট
    // সরাসরি পেজে আঁকে। figH ও paintFig সবসময় একই উচ্চতা হিসেব করে।
    double figH(QuestionFigure f, double w) {
      final pad = (f.caption != null ? 19.0 : 5.0) * _k;
      switch (f.kind) {
        case FigureKind.table:
          final rows = (f.headers.isEmpty ? 0 : 1) + f.rows.length;
          return rows * 15 * _k + pad;
        case FigureKind.triangle:
          return 120 * _k + pad;
        case FigureKind.barChart:
          return 132 * _k + pad;
        case FigureKind.image:
          // The picture is drawn at the column width, so its height follows
          // from the stored aspect ratio. Capped so one photo cannot swallow
          // a whole page.
          final aspect = (f.aspect ?? 1.4).clamp(0.35, 4.0);
          final h = w / aspect;
          final maxH = 300.0 * _k;
          return (h > maxH ? maxH : h) + pad;
      }
    }

    void paintFig(QuestionFigure f, double x, double y0, double w) {
      final line = Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9 * _k;
      double bodyH = 0;

      if (f.kind == FigureKind.table) {
        final headerRow = f.headers.isNotEmpty;
        final grid = <List<String>>[if (headerRow) f.headers, ...f.rows];
        if (grid.isNotEmpty) {
          final nCol = grid.first.length;
          final cellH = 15 * _k;
          // কলামের প্রস্থ: সব ঘরের লেখা মেপে সর্বোচ্চ + প্যাডিং
          final colW = List<double>.filled(nCol, 0);
          for (int c = 0; c < nCol; c++) {
            for (int r = 0; r < grid.length; r++) {
              if (c >= grid[r].length) continue;
              final tp = makePainter(
                _safe(grid[r][c]),
                9.5,
                isBold: headerRow && r == 0,
              );
              tp.layout();
              if (tp.width > colW[c]) colW[c] = tp.width;
            }
            colW[c] += 10 * _k;
          }
          var totalW = colW.fold<double>(0, (a, b) => a + b);
          final maxW = w * 0.92;
          if (totalW > maxW) {
            final s = maxW / totalW;
            for (int c = 0; c < nCol; c++) {
              colW[c] *= s;
            }
            totalW = maxW;
          }
          final startX = x + (w - totalW) / 2;
          bodyH = grid.length * cellH;
          strokeRect(Rect.fromLTWH(startX, y0, totalW, bodyH), thick: 1.1);
          double vx = startX;
          for (int c = 0; c < nCol - 1; c++) {
            vx += colW[c];
            canvas.drawLine(Offset(vx, y0), Offset(vx, y0 + bodyH), line);
          }
          for (int r = 1; r < grid.length; r++) {
            final hy = y0 + r * cellH;
            canvas.drawLine(
              Offset(startX, hy),
              Offset(startX + totalW, hy),
              line,
            );
          }
          for (int r = 0; r < grid.length; r++) {
            double cx = startX;
            for (int c = 0; c < nCol; c++) {
              if (c >= grid[r].length) break;
              final tp = makePainter(
                _safe(grid[r][c]),
                9.5,
                isBold: headerRow && r == 0,
              );
              tp.layout(maxWidth: colW[c] - 4 * _k);
              tp.paint(
                canvas,
                Offset(
                  cx + (colW[c] - tp.width) / 2,
                  y0 + r * cellH + (cellH - tp.height) / 2,
                ),
              );
              cx += colW[c];
            }
          }
        }
      } else if (f.kind == FigureKind.triangle) {
        bodyH = 120 * _k;
        final cx = x + w / 2;
        var halfW = w * 0.26;
        final maxHw = 100 * _k;
        final minHw = 50 * _k;
        if (halfW > maxHw) halfW = maxHw;
        if (halfW < minHw) halfW = minHw;
        final top = y0 + 16 * _k;
        final base = y0 + bodyH - 20 * _k;
        final a = Offset(cx, top); // শীর্ষবিন্দু (উপরে)
        final b = Offset(cx - halfW, base); // বামে-নিচ
        final c = Offset(cx + halfW, base); // ডানে-নিচ
        final tri = Paint()
          ..color = const Color(0xFF000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3 * _k;
        canvas.drawLine(a, b, tri);
        canvas.drawLine(b, c, tri);
        canvas.drawLine(c, a, tri);
        final v = f.headers; // শীর্ষের লেবেল
        if (v.isNotEmpty && v[0].isNotEmpty) {
          final tp = makePainter(_safe(v[0]), 10.5, isBold: true);
          tp.layout();
          tp.paint(
            canvas,
            Offset(a.dx - tp.width / 2, a.dy - tp.height - 1.5 * _k),
          );
        }
        if (v.length > 1 && v[1].isNotEmpty) {
          final tp = makePainter(_safe(v[1]), 10.5, isBold: true);
          tp.layout();
          tp.paint(canvas, Offset(b.dx - tp.width - 2 * _k, b.dy + 1 * _k));
        }
        if (v.length > 2 && v[2].isNotEmpty) {
          final tp = makePainter(_safe(v[2]), 10.5, isBold: true);
          tp.layout();
          tp.paint(canvas, Offset(c.dx + 2 * _k, c.dy + 1 * _k));
        }
        final s = f.sides; // বাহুর লেবেল
        if (s.isNotEmpty && s[0].isNotEmpty) {
          final tp = makePainter(_safe(s[0]), 9.5);
          tp.layout();
          final mx2 = (a.dx + b.dx) / 2;
          final my2 = (a.dy + b.dy) / 2;
          tp.paint(
            canvas,
            Offset(mx2 - tp.width - 2.5 * _k, my2 - tp.height / 2),
          );
        }
        if (s.length > 1 && s[1].isNotEmpty) {
          final tp = makePainter(_safe(s[1]), 9.5);
          tp.layout();
          final mx2 = (b.dx + c.dx) / 2;
          final my2 = (b.dy + c.dy) / 2;
          tp.paint(canvas, Offset(mx2 - tp.width / 2, my2 + 1.5 * _k));
        }
        if (s.length > 2 && s[2].isNotEmpty) {
          final tp = makePainter(_safe(s[2]), 9.5);
          tp.layout();
          final mx2 = (c.dx + a.dx) / 2;
          final my2 = (c.dy + a.dy) / 2;
          tp.paint(canvas, Offset(mx2 + 2.5 * _k, my2 - tp.height / 2));
        }
        final an = f.angles; // কোণের লেবেল
        if (an.isNotEmpty && an[0].isNotEmpty) {
          final tp = makePainter(_safe(an[0]), 9);
          tp.layout();
          tp.paint(canvas, Offset(a.dx + 2 * _k, a.dy + 4 * _k));
        }
        if (an.length > 1 && an[1].isNotEmpty) {
          final tp = makePainter(_safe(an[1]), 9);
          tp.layout();
          tp.paint(canvas, Offset(b.dx + 3.5 * _k, b.dy - tp.height - 2 * _k));
        }
        if (an.length > 2 && an[2].isNotEmpty) {
          final tp = makePainter(_safe(an[2]), 9);
          tp.layout();
          tp.paint(
            canvas,
            Offset(c.dx - tp.width - 3.5 * _k, c.dy - tp.height - 2 * _k),
          );
        }
        // সমকোণ চিহ্ন
        final ra = f.rightAngleAt;
        if (ra != null && ra.isNotEmpty) {
          final sz = 7 * _k;
          if (v.length > 1 && ra == v[1]) {
            canvas.drawLine(
              Offset(b.dx + sz, b.dy),
              Offset(b.dx + sz, b.dy - sz),
              tri,
            );
            canvas.drawLine(
              Offset(b.dx + sz, b.dy - sz),
              Offset(b.dx, b.dy - sz),
              tri,
            );
          } else if (v.length > 2 && ra == v[2]) {
            canvas.drawLine(
              Offset(c.dx - sz, c.dy),
              Offset(c.dx - sz, c.dy - sz),
              tri,
            );
            canvas.drawLine(
              Offset(c.dx - sz, c.dy - sz),
              Offset(c.dx, c.dy - sz),
              tri,
            );
          } else if (v.isNotEmpty && ra == v[0]) {
            canvas.drawLine(
              Offset(a.dx - sz, a.dy + sz),
              Offset(a.dx, a.dy + sz),
              tri,
            );
            canvas.drawLine(
              Offset(a.dx, a.dy + sz),
              Offset(a.dx + sz, a.dy + sz),
              tri,
            );
          }
        }
      } else if (f.kind == FigureKind.barChart) {
        bodyH = 132 * _k;
        var maxV = 0;
        for (final e in f.values) {
          if (e > maxV) maxV = e;
        }
        if (maxV > 0) {
          final base = y0 + bodyH - 18 * _k;
          final top = y0 + 8 * _k;
          var chartW = w * 0.6;
          final maxCw = 240 * _k;
          if (chartW > maxCw) chartW = maxCw;
          if (chartW > w) chartW = w;
          final startX = x + (w - chartW) / 2;
          canvas.drawLine(
            Offset(startX - 4 * _k, top - 2 * _k),
            Offset(startX - 4 * _k, base),
            line,
          ); // y-অক্ষ
          canvas.drawLine(
            Offset(startX - 4 * _k, base),
            Offset(startX + chartW, base),
            line,
          ); // x-অক্ষ
          final n = f.values.length;
          final slot = chartW / n;
          final barW = slot * 0.5;
          final fill = Paint()..color = const Color(0xFFDDDDDD);
          for (int i = 0; i < n; i++) {
            final bh = (f.values[i] / maxV) * (base - top);
            final bx = startX + slot * i + (slot - barW) / 2;
            final rect = Rect.fromLTWH(bx, base - bh, barW, bh);
            canvas.drawRect(rect, fill);
            canvas.drawRect(rect, line);
            final vt = makePainter(_bn(f.values[i]), 9);
            vt.layout();
            vt.paint(
              canvas,
              Offset(
                bx + (barW - vt.width) / 2,
                base - bh - vt.height - 1 * _k,
              ),
            );
            if (i < f.headers.length) {
              final lt = makePainter(_safe(f.headers[i]), 8.5);
              lt.layout(maxWidth: slot);
              lt.paint(
                canvas,
                Offset(
                  startX + slot * i + (slot - lt.width) / 2,
                  base + 2 * _k,
                ),
              );
            }
          }
        }
      } else if (f.kind == FigureKind.image) {
        // A whole question captured as one picture. The bytes were decoded
        // before rendering started (see _figureImages) because this painter
        // is synchronous.
        final img = figureImages[f.imagePath];
        final aspect = (f.aspect ?? 1.4).clamp(0.35, 4.0);
        var drawW = w;
        var drawH = drawW / aspect;
        final maxH = 300.0 * _k;
        if (drawH > maxH) {
          drawH = maxH;
          drawW = drawH * aspect;
        }
        bodyH = drawH;
        final dx = x + (w - drawW) / 2;
        if (img != null) {
          canvas.drawImageRect(
            img,
            Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
            Rect.fromLTWH(dx, y0, drawW, drawH),
            Paint()..filterQuality = FilterQuality.high,
          );
        } else {
          // Missing file: leave a labelled placeholder rather than a blank
          // gap, so the problem is obvious on the printed page.
          canvas.drawRect(Rect.fromLTWH(dx, y0, drawW, drawH), line);
          final tp = makePainter(
            '[ছবি পাওয়া যায়নি]',
            9.5,
            align: TextAlign.center,
          );
          tp.layout(maxWidth: drawW);
          tp.paint(
            canvas,
            Offset(dx + (drawW - tp.width) / 2, y0 + drawH / 2 - tp.height / 2),
          );
        }
      }

      // ক্যাপশন (থাকলে) বডির নিচে মাঝখানে
      if (f.caption != null) {
        final tp = makePainter(_safe(f.caption!), 9.5, align: TextAlign.center);
        tp.layout(maxWidth: w);
        tp.paint(canvas, Offset(x + (w - tp.width) / 2, y0 + bodyH + 3 * _k));
      }
    }

    // ── বেসিক প্যারাগ্রাফ ──
    Future<void> para(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.left,
      double gapBefore = 0,
      double indent = 0,
      bool preserveSpaces = false,
    }) async {
      await PaperPdf._yieldToUi();
      final line = rich(
        text,
        size,
        isBold: isBold,
        align: align,
        preserveSpaces: preserveSpaces,
        maxWidth: contentW - indent * _k,
      );
      if (y + gapBefore * _k + line.tp.height > bottomY + 1) {
        await commit();
        begin();
      }
      y += gapBefore * _k;
      paintRich(line, _margin + indent * _k, y);
      y += line.tp.height;
    }

    // ── মান ডান কলামে এমন প্যারাগ্রাফ (স্কুল-স্টাইল) ──
    Future<void> paraMark(
      String text,
      double size,
      String mark, {
      bool isBold = false,
      double gapBefore = 0,
      double indent = 0,
    }) async {
      await PaperPdf._yieldToUi();
      final markW = 26 * _k; // মান কলাম ≈ ৯ মিমি
      final line = rich(
        text,
        size,
        isBold: isBold,
        maxWidth: contentW - indent * _k - markW,
      );
      final tm = makePainter(_safe(mark), size);
      tm.layout(maxWidth: markW);
      final h = mx(line.tp.height, tm.height);
      if (y + gapBefore * _k + h > bottomY + 1) {
        await commit();
        begin();
      }
      y += gapBefore * _k;
      paintRich(line, _margin + indent * _k, y);
      tm.paint(canvas, Offset(_margin + contentW - tm.width, y));
      y += h;
    }

    // ── অনুভূমিক রেখা ──
    Future<void> rule({
      double gapBefore = 0,
      double gapAfter = 0,
      double thick = 1.2,
    }) async {
      final need = (gapBefore + gapAfter + 4) * _k;
      if (y + need > bottomY + 1) {
        await commit();
        begin();
      }
      y += (gapBefore + 2) * _k;
      canvas.drawLine(
        Offset(_margin, y),
        Offset(sw - _margin, y),
        Paint()
          ..color = const Color(0xFF000000)
          ..strokeWidth = thick * _k,
      );
      y += (gapAfter + 2) * _k;
    }

    Future<void> doubleRule({double gapBefore = 8}) async {
      await rule(gapBefore: gapBefore);
      await rule(gapBefore: 2);
    }

    // ── বাম-ডান দুই টেক্সট এক লাইনে ──
    Future<void> row2(
      String left,
      String right,
      double size, {
      double gapBefore = 0,
      bool isBold = false,
    }) async {
      final tl = makePainter(_safe(left), size, isBold: isBold);
      tl.layout(maxWidth: contentW / 2);
      final tr = makePainter(_safe(right), size, isBold: isBold);
      tr.layout(maxWidth: contentW / 2);
      final h = mx(tl.height, tr.height);
      if (y + gapBefore * _k + h > bottomY + 1) {
        await commit();
        begin();
      }
      y += gapBefore * _k;
      tl.paint(canvas, Offset(_margin, y));
      tr.paint(canvas, Offset(sw - _margin - tr.width, y));
      y += h;
    }

    // ── প্রাপ্ত নম্বর + বিষয়/সেট কোড বাক্স ──
    Future<void> codeBoxes() async {
      final h = 2 * 9.0 * 1.4 * _k + 8 * _k; // দুই লাইনের উচ্চতা
      if (y + 5 * _k + h > bottomY + 1) {
        await commit();
        begin();
      }
      y += 5 * _k;
      // বামে: প্রাপ্ত নম্বর বাক্স
      final leftW = 62 * _k;
      strokeRect(Rect.fromLTWH(_margin, y, leftW, h), thick: 1.0);
      final t1 = makePainter('প্রাপ্ত নম্বরঃ', 9);
      t1.layout(maxWidth: leftW - 6 * _k);
      t1.paint(canvas, Offset(_margin + 4 * _k, y + (h - t1.height) / 2));
      // ডানে: বিষয় কোড / সেট কোড বাক্স (কোড থাকলে আগে থেকেই লেখা)
      final rightW = 62 * _k;
      final rx = sw - _margin - rightW;
      strokeRect(Rect.fromLTWH(rx, y, rightW, h), thick: 1.0);
      final t2 = makePainter('বিষয় কোডঃ', 9);
      t2.layout(maxWidth: rightW - 10 * _k);
      t2.paint(canvas, Offset(rx + 4 * _k, y + 4 * _k));
      if (subjectCode != null && subjectCode!.isNotEmpty) {
        final c1 = makePainter(_safe(subjectCode!), 9.5, isBold: true);
        c1.layout();
        c1.paint(
          canvas,
          Offset(
            rx + 6 * _k + t2.width,
            y + 4 * _k + (t2.height - c1.height) / 2,
          ),
        );
      }
      final t3 = makePainter('সেট কোডঃ', 9);
      t3.layout(maxWidth: rightW - 10 * _k);
      t3.paint(canvas, Offset(rx + 4 * _k, y + h - t3.height - 4 * _k));
      if (setCode != null && setCode!.isNotEmpty) {
        final c2 = makePainter(_safe(setCode!), 10.5, isBold: true);
        c2.layout();
        c2.paint(
          canvas,
          Offset(
            rx + 6 * _k + t3.width,
            y + h - t3.height - 4 * _k + (t3.height - c2.height) / 2,
          ),
        );
      }
      y += h;
    }

    // ── নাম / রোল নং / শাখা লাইন ──
    Future<void> nameRollLine() async {
      const size = 10.0;
      final ln = makePainter('নামঃ', size);
      ln.layout(maxWidth: contentW * 0.2);
      final lr = makePainter('রোল নংঃ', size);
      lr.layout(maxWidth: contentW * 0.2);
      final ls = makePainter('শাখাঃ', size);
      ls.layout(maxWidth: contentW * 0.15);
      final h = ln.height;
      if (y + 5 * _k + h > bottomY + 1) {
        await commit();
        begin();
      }
      y += 5 * _k;
      final lineY = y + h - 1.5 * _k;
      void ul(double x1, double x2) => canvas.drawLine(
            Offset(x1, lineY),
            Offset(x2, lineY),
            Paint()
              ..color = const Color(0xFF000000)
              ..strokeWidth = 0.8 * _k,
          );
      ln.paint(canvas, Offset(_margin, y));
      final nameEnd = _margin + contentW * 0.52;
      ul(_margin + ln.width + 2 * _k, nameEnd);
      final rx = nameEnd + 6 * _k;
      lr.paint(canvas, Offset(rx, y));
      final rollEnd = rx + lr.width + 20 * _k;
      ul(rx + lr.width + 2 * _k, rollEnd);
      final sx = rollEnd + 6 * _k;
      ls.paint(canvas, Offset(sx, y));
      ul(sx + ls.width + 2 * _k, sw - _margin);
      y += h;
    }

    // ── দ্রষ্টব্য বাক্স ──
    Future<void> noteBox(String text) async {
      final tp = makePainter(_safe(text), 9.5);
      tp.layout(maxWidth: contentW - 10 * _k);
      final h = tp.height + 6 * _k;
      if (y + 4 * _k + h > bottomY + 1) {
        await commit();
        begin();
      }
      y += 4 * _k;
      strokeRect(Rect.fromLTWH(_margin, y, contentW, h), thick: 1.0);
      tp.paint(canvas, Offset(_margin + 5 * _k, y + 3 * _k));
      y += h;
    }

    // ── অংশের হেডার (লিখিত / বহুনির্বাচনি) ──
    Future<void> partHeader({
      required String subjLine,
      required String tLeft,
      required String tRight,
      bool mcqStyle = false,
    }) async {
      await para(headerLine1, 17, isBold: true, align: TextAlign.center);
      await para(headerLine2, 12, align: TextAlign.center, gapBefore: 1);
      await para(
        subjLine,
        11.5,
        isBold: true,
        align: TextAlign.center,
        gapBefore: 3,
      );
      if (mcqStyle) await codeBoxes();
      await row2(tLeft, tRight, 10.5, gapBefore: 5, isBold: true);
      if (mcqStyle) await nameRollLine();
      await doubleRule(gapBefore: 6);
    }

    // ── সেকশন টাইটেল ──
    Future<void> sectionTitle(
      String title2,
      String? note, {
      double gapBefore = 8,
    }) async {
      await para(
        title2,
        12.5,
        isBold: true,
        align: TextAlign.center,
        gapBefore: gapBefore,
      );
      if (note != null) {
        await para(note, 9.5, align: TextAlign.center, gapBefore: 2);
      }
    }

    final subject =
        subjectName?.trim().isNotEmpty == true ? subjectName!.trim() : title;
    final subj =
        'বিষয়ঃ $subject${modeLine.isNotEmpty ? '  —  $modeLine' : ''}';
    final hasWritten = cqs.isNotEmpty ||
        saqs.isNotEmpty ||
        literatureQuestions.isNotEmpty ||
        bangla2WrittenQuestions.isNotEmpty;

    // ══════════════ ১ম অংশ: লিখিত পত্র ══════════════
    if (hasWritten) {
      begin();
      await partHeader(
        subjLine: subj,
        tLeft: 'সময়ঃ $wt',
        tRight: 'পূর্ণমানঃ $wm',
      );

      if (bangla2WrittenQuestions.isNotEmpty) {
        const writtenSections = <(Bangla2WrittenType, String, String)>[
          (
            Bangla2WrittenType.paragraph,
            'অনুচ্ছেদ রচনা',
            'দুইটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
          (
            Bangla2WrittenType.letterOrReport,
            'চিঠিপত্র / সংবাদ প্রতিবেদন',
            'দুইটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
          (
            Bangla2WrittenType.summaryOrGist,
            'সারাংশ / সারমর্ম',
            'দুইটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
          (
            Bangla2WrittenType.thoughtExpansion,
            'ভাব-সম্প্রসারণ',
            'দুইটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
          (
            Bangla2WrittenType.translation,
            'বাংলায় অনুবাদ',
            'দুইটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
          (
            Bangla2WrittenType.composition,
            'প্রবন্ধ / রচনা',
            'তিনটি প্রশ্ন থেকে যেকোনো একটি প্রশ্নের উত্তর দাও।',
          ),
        ];
        var writtenNumber = 0;
        for (final section in writtenSections) {
          final questions = bangla2WrittenQuestions
              .where((question) => question.type == section.$1)
              .toList(growable: false);
          if (questions.isEmpty) continue;
          await sectionTitle(section.$2, section.$3, gapBefore: 10);
          for (final question in questions) {
            writtenNumber++;
            await paraMark(
              '${_bn(writtenNumber)}। ${question.prompt}',
              11,
              _bn(question.marks),
              gapBefore: 7,
            );
            if (question.sourceText?.trim().isNotEmpty == true) {
              await para(
                question.sourceText!.trim(),
                10.5,
                indent: 12,
                gapBefore: 2,
              );
            }
          }
        }
      }

      if (cqs.isNotEmpty) {
        await sectionTitle(
          'সৃজনশীল প্রশ্ন',
          cqNote ??
              '(যেকোনো ${_bn(cqAnswerCount)}টি প্রশ্নের উত্তর দাও। প্রতিটি প্রশ্নের মান ১০)',
        );
        for (int i = 0; i < cqs.length; i++) {
          final cq = cqs[i];
          await para('${_bn(i + 1)}। ${cq.stem}', 11, gapBefore: 9);
          if (cq.figure != null) {
            final fh = figH(cq.figure!, contentW);
            if (y + fh > bottomY + 1) {
              await commit();
              begin();
            }
            y += 2 * _k;
            paintFig(cq.figure!, _margin, y, contentW);
            y += fh;
          }
          // গণিত/উচ্চতর গণিত (নতুন নিয়ম): ক(২) খ(৪) গ(৪) — ৩ ভাগ;
          // অন্য বিষয়: আগের মতো ব্যাংকের মান হিসেবে ৪ ভাগ পর্যন্ত।
          await paraMark(
            'ক) ${cq.questionK}',
            10.5,
            cq.marks.length == 3
                ? '২'
                : _bn(cq.marks.isNotEmpty ? cq.marks[0] : 1),
            indent: 10,
            gapBefore: 2.5,
          );
          await paraMark(
            'খ) ${cq.questionKh}',
            10.5,
            cq.marks.length == 3
                ? '৪'
                : _bn(cq.marks.length > 1 ? cq.marks[1] : 2),
            indent: 10,
            gapBefore: 1.5,
          );
          await paraMark(
            'গ) ${cq.questionG}',
            10.5,
            cq.marks.length == 3
                ? '৪'
                : _bn(cq.marks.length > 2 ? cq.marks[2] : 3),
            indent: 10,
            gapBefore: 1.5,
          );
          if (cq.marks.length != 3) {
            await paraMark(
              'ঘ) ${cq.questionGh}',
              10.5,
              _bn(cq.marks.length > 3 ? cq.marks[3] : 4),
              indent: 10,
              gapBefore: 1.5,
            );
          }
        }
      }

      if (saqs.isNotEmpty) {
        await sectionTitle(
          'সংক্ষিপ্ত-উত্তর প্রশ্ন',
          '(যেকোনো ${_bn(saqAnswerCount)}টি প্রশ্নের উত্তর দাও। প্রতিটি প্রশ্নের মান ২)',
          gapBefore: 12,
        );
        for (int i = 0; i < saqs.length; i++) {
          await paraMark(
            '${_bn(cqs.length + i + 1)}। ${saqs[i].questionText}',
            11,
            _bn(2),
            gapBefore: 7,
          );
        }
      }

      if (literatureQuestions.isNotEmpty) {
        await sectionTitle(
          'উপন্যাস ও নাটক',
          literatureNote ??
              '(উপন্যাস থেকে ১টি এবং নাটক থেকে ১টি প্রশ্নের উত্তর দাও। ক-এর মান ৩ এবং খ-এর মান ৭।)',
          gapBefore: 12,
        );
        for (int i = 0; i < literatureQuestions.length; i++) {
          final question = literatureQuestions[i];
          final number = cqs.length + saqs.length + i + 1;
          await para(
            '${_bn(number)}। [${question.section}: ${question.sourceTitle}] ${question.stem}',
            11,
            gapBefore: 9,
          );
          await paraMark(
            'ক) ${question.questionK}',
            10.5,
            _bn(question.marks.isNotEmpty ? question.marks[0] : 3),
            indent: 10,
            gapBefore: 2.5,
          );
          await paraMark(
            'খ) ${question.questionKh}',
            10.5,
            _bn(question.marks.length > 1 ? question.marks[1] : 7),
            indent: 10,
            gapBefore: 1.5,
          );
        }
      }
    }

    // ══════════════ ২য় অংশ: বহুনির্বাচনি পত্র (দুই কলাম) ══════════════
    if (mcqs.isNotEmpty) {
      if (hasWritten) await commit();
      begin();
      await partHeader(
        subjLine: '$subj (বহুনির্বাচনি)',
        tLeft: 'সময়ঃ $mt',
        tRight: 'পূর্ণমানঃ $mm',
        mcqStyle: true,
      );
      await noteBox(
        'বিশেষ দ্রষ্টব্যঃ সবগুলো প্রশ্নের উত্তর দিতে হবে। প্রতিটি প্রশ্নের মান ১। উত্তরপত্রে প্রশ্নের ক্রমিক নম্বরের বিপরীতে প্রদত্ত বর্ণ সন্নিবেশিত বৃত্তসমূহ ভরাট করতে হবে।',
      );
      y += 6 * _k;

      final double gutter = 16 * _k;
      final double colW = (contentW - gutter) / 2;
      final colX = [_margin, _margin + colW + gutter];
      final colY = [y, y];
      int cur = 0;

      Future<void> placeMcq(int no, Question q) async {
        final fh = q.figure != null ? figH(q.figure!, colW) : 0.0;
        final split = splitMcqStimulus(q.questionText);
        final stim = split.stimulus == null
            ? null
            : rich(split.stimulus!, 10, maxWidth: colW);
        final qt = rich('${_bn(no)}। ${split.body}', 10.5, maxWidth: colW);
        final opts = <_RichLine>[];
        for (int o = 0; o < q.options.length; o++) {
          opts.add(
            rich(
              '${_optionLetters[o]}) ${q.options[o]}',
              10,
              preserveSpaces: true,
              maxWidth: colW - 7 * _k,
            ),
          );
        }
        final half = (colW - 7 * _k) / 2;
        final bool grid = q.options.length == 4 &&
            opts.every((o) => o.tp.width <= half - 2 * _k);
        double optH;
        double rowA = 0, rowB = 0;
        if (grid) {
          rowA = mx(opts[0].tp.height, opts[1].tp.height);
          rowB = mx(opts[2].tp.height, opts[3].tp.height);
          optH = rowA + rowB + 1.5 * _k;
        } else {
          optH = opts.fold<double>(0, (a, o) => a + o.tp.height + 0.6 * _k);
        }
        final stimH = stim == null ? 0.0 : stim.tp.height + 3 * _k;
        final need = stimH + qt.tp.height + fh + 2 * _k + optH + 4 * _k;
        if (colY[cur] + need > bottomY) {
          if (cur == 0) {
            cur = 1;
          } else {
            await commit();
            begin();
            colY[0] = colY[1] = _margin;
            cur = 0;
          }
        }
        final x = colX[cur];
        double yy = colY[cur];
        if (stim != null) {
          paintRich(stim, x, yy);
          yy += stim.tp.height + 3 * _k;
        }
        paintRich(qt, x, yy);
        yy += qt.tp.height + 2 * _k;
        if (q.figure != null) {
          paintFig(q.figure!, x, yy, colW);
          yy += fh;
        }
        if (grid) {
          paintRich(opts[0], x + 7 * _k, yy);
          paintRich(opts[1], x + 7 * _k + half, yy);
          yy += rowA + 1.5 * _k;
          paintRich(opts[2], x + 7 * _k, yy);
          paintRich(opts[3], x + 7 * _k + half, yy);
          yy += rowB;
        } else {
          for (final o in opts) {
            paintRich(o, x + 7 * _k, yy);
            yy += o.tp.height + 0.6 * _k;
          }
        }
        colY[cur] = yy + 4 * _k;
      }

      for (int i = 0; i < mcqs.length; i++) {
        await placeMcq(i + 1, mcqs[i]);
      }
      y = mx(colY[0], colY[1]);
    }

    await doubleRule(gapBefore: 10);
    await para('- শেষ -', 10, align: TextAlign.center, gapBefore: 4);
    await commit();

    // ══════════════ OMR SHEET — deterministic geometry, scanner-locked ══════════════
    // The sheet is drawn from OMrGeometry — the exact same coordinates the
    // OMR scanner samples — so every printed sheet can be scanned.
    if (mcqs.isNotEmpty) {
      pages.addAll(
        await renderOmrSheetPages(
          title: title,
          total: mcqs.length,
          subjectCode: subjectCode,
          setCode: setCode,
        ),
      );
    }

    return pages;
  }

  static String _bn(int n) {
    const d = ['০', '১', '২', '৩', '৪', '৫', '৬', '৭', '৮', '৯'];
    return n.toString().split('').map((c) {
      final code = c.codeUnitAt(0);
      return (code >= 48 && code <= 57) ? d[code - 48] : c;
    }).join();
  }

  // ══════════════ English পেপার — "as usual like other subjects" ══════════════
  /// পুরোটা ফ্লাটার-ইঞ্জিনে আঁকা (printing প্লাগিনের raster না) — তাই যে ফোনে
  /// Printing.raster/layoutPdf ভাঙে সেখানেও প্রিভিউ ও প্রিন্ট দুটোই চলে।
  static Future<List<Uint8List>> renderEnglishPages({
    required String paperTitle, // ইউজারের লেখা টাইটেল / 'Model Test'
    required String subTitle, // 'English (Compulsory)–First Paper …'
    required List<EnglishSection> sections,
    String setCode = 'ক',
    String classLine = 'Class Ten (SSC Exam–2027)',
    String time = 'Time: 3 hours',
    String marks = 'Full Marks: 100',
    String answerNote =
        'Answer all the questions. Figures in the right margin indicate full marks.',
  }) async {
    await _loadFonts();

    final pages = <Uint8List>[];
    const double sw = 1654.0;
    const double sh = 2339.0;
    final double bottomY = sh - _margin;
    final double contentW = sw - 2 * _margin;

    late ui.PictureRecorder rec;
    late Canvas canvas;
    late double y;

    TextStyle st(double size, bool isBold, double lh) => TextStyle(
          fontFamily: isBold ? (_bold ?? _regular) : _regular,
          fontFamilyFallback: _fb(isBold),
          fontWeight:
              (isBold && _bold == null) ? FontWeight.w700 : FontWeight.w400,
          fontSize: size * _k,
          height: lh,
          color: const Color(0xFF000000),
        );

    void begin() {
      rec = ui.PictureRecorder();
      canvas = Canvas(rec, Rect.fromLTWH(0, 0, sw, sh));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, sw, sh),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      y = _margin;
    }

    Future<void> commit() async {
      final stamp = TextPainter(
        text: TextSpan(
          text: 'AL·v25',
          style: st(7, false, 1.0).copyWith(color: const Color(0xFFAAAAAA)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      stamp.paint(canvas, Offset(_margin, sh - 6 * _k));
      final img = await rec.endRecording().toImage(_W, _H);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      pages.add(bd!.buffer.asUint8List());
    }

    Future<void> para(
      String text,
      double size, {
      bool isBold = false,
      double indent = 0,
      double gapBefore = 0,
      double gapAfter = 2,
      TextAlign align = TextAlign.left,
    }) async {
      await PaperPdf._yieldToUi();
      final tp = TextPainter(
        text: TextSpan(text: _safe(text), style: st(size, isBold, 1.45)),
        textDirection: TextDirection.ltr,
        textAlign: align,
      )..layout(maxWidth: contentW - indent);
      if (y + gapBefore * _k + tp.height > bottomY + 1) {
        await commit();
        begin();
      }
      y += gapBefore * _k;
      tp.paint(canvas, Offset(_margin + indent, y));
      y += tp.height + gapAfter * _k;
    }

    void hline(double t) => canvas.drawLine(
          Offset(_margin, y),
          Offset(_margin + contentW, y),
          Paint()
            ..color = const Color(0xFF000000)
            ..strokeWidth = t,
        );

    Future<void> doubleRule() async {
      y += 3 * _k;
      hline(1.4 * _k);
      y += 2.2 * _k;
      hline(0.8 * _k);
      y += 4 * _k;
    }

    // ── হেডার (অন্যান্য বিষয়ের মতোই স্টাইল) ──
    begin();
    if (setCode.isNotEmpty) {
      await para(
        'Set Code:  $setCode',
        11,
        isBold: true,
        align: TextAlign.right,
        gapAfter: 1,
      );
    }
    await para(
      paperTitle.isEmpty ? 'Model Test' : paperTitle,
      17,
      isBold: true,
      align: TextAlign.center,
      gapAfter: 1,
    );
    await para(classLine, 12, align: TextAlign.center, gapAfter: 1);
    await para(
      subTitle,
      12.5,
      isBold: true,
      align: TextAlign.center,
      gapAfter: 2,
    );
    final tl = TextPainter(
      text: TextSpan(text: _safe(time), style: st(10.5, true, 1.2)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: contentW / 2 - 6 * _k);
    final tr = TextPainter(
      text: TextSpan(text: _safe(marks), style: st(10.5, true, 1.2)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.right,
    )..layout(maxWidth: contentW / 2 - 6 * _k);
    final rowH = tl.height > tr.height ? tl.height : tr.height;
    if (y + rowH > bottomY) {
      await commit();
      begin();
    }
    tl.paint(canvas, Offset(_margin, y));
    tr.paint(canvas, Offset(_margin + contentW / 2 + 6 * _k, y));
    y += rowH + 1 * _k;
    await doubleRule();
    if (answerNote.isNotEmpty) {
      await para(answerNote, 9.8, align: TextAlign.center, gapAfter: 4);
    }

    // ── বর্ডারওয়ালা আসল টেবিল (Q2/Q4/Q6 ম্যাচিং-টেবিলের জন্য) ──
    Future<void> drawTable(
      List<List<String>> rows, {
      double indent = 10,
      bool centered = false,
    }) async {
      if (rows.isEmpty) return;
      var cols = 0;
      for (final r in rows) {
        if (r.length > cols) cols = r.length;
      }
      if (cols == 0) return;
      final tableW = contentW - indent;
      final colW = tableW / cols;
      final cellPad = 2.2 * _k;
      final border = Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9 * _k;
      for (var ri = 0; ri < rows.length; ri++) {
        final cps = <TextPainter>[];
        var rowH = 0.0;
        for (var ci = 0; ci < cols; ci++) {
          final txt = ci < rows[ri].length ? rows[ri][ci] : '';
          final tp = TextPainter(
            text: TextSpan(text: _safe(txt), style: st(9.6, ri == 0, 1.35)),
            textDirection: TextDirection.ltr,
            textAlign:
                (centered || cols == 1) ? TextAlign.center : TextAlign.left,
          )..layout(maxWidth: colW - 2 * cellPad);
          cps.add(tp);
          if (tp.height > rowH) rowH = tp.height;
        }
        rowH += 2 * cellPad;
        if (y + rowH > bottomY + 1) {
          await commit();
          begin();
        }
        canvas.drawRect(
          Rect.fromLTWH(_margin + indent, y, tableW, rowH),
          border,
        );
        for (var ci = 0; ci < cols; ci++) {
          final x = _margin + indent + colW * ci;
          if (ci > 0) {
            canvas.drawLine(Offset(x, y), Offset(x, y + rowH), border);
          }
          cps[ci].paint(canvas, Offset(x + cellPad, y + cellPad));
        }
        y += rowH;
      }
      y += 2 * _k;
    }

    // ── সেকশনগুলো ──
    for (final s in sections) {
      if (s.lines.isEmpty && s.table == null) {
        await para(
          s.head,
          12.5,
          isBold: true,
          align: TextAlign.center,
          gapBefore: 8,
          gapAfter: 3,
        );
        continue;
      }
      await para(s.head, 11.3, isBold: true, gapBefore: 8, gapAfter: 2);
      if (s.table != null) await drawTable(s.table!, centered: s.centerTable);
      for (final l in s.lines) {
        if (l.trim().isEmpty) {
          y += 4 * _k;
          continue;
        }
        await para(l, 10.3, indent: 10, gapAfter: 1.5);
      }
    }

    await commit();
    return pages;
  }

  /// 🖨️ English পেপার প্রিন্ট — প্রিভিউ-এর ঠিক সেই পেজ (share-fallback সহ)।
  static Future<void> printEnglishPaper({
    required String paperTitle,
    required String subTitle,
    required List<EnglishSection> sections,
    String setCode = 'ক',
    String classLine = 'Class Ten (SSC Exam–2027)',
    String time = 'Time: 3 hours',
    String marks = 'Full Marks: 100',
    String answerNote =
        'Answer all the questions. Figures in the right margin indicate full marks.',
  }) async {
    final pages = await renderEnglishPages(
      paperTitle: paperTitle,
      subTitle: subTitle,
      sections: sections,
      setCode: setCode,
      classLine: classLine,
      time: time,
      marks: marks,
      answerNote: answerNote,
    );
    final doc = pw.Document();
    for (final png in pages) {
      final img = pw.MemoryImage(png);
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            img,
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    final bytes = await doc.save();
    try {
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (_) {
      // ফোনের system print dialog না খুললে PDF সরাসরি Share/Save sheet-এ।
      await Printing.sharePdf(bytes: bytes, filename: 'english_paper.pdf');
    }
  }

  // ══════════════ OMR answer sheet — standalone render & print ══════════════
  /// Drop-out template ink. The OMR sheet's printed *template* (bubble
  /// circles, grid/box borders, question numbers, option letters, labels,
  /// corner marks, rules) uses the requested bright pink. The scanner can
  /// tell it apart from the student's black/blue pen by hue: a pixel is
  /// treated as student ink only when it is dark AND neutral (see the
  /// drop-out test in `OMrScanner`).
  ///
  /// Keep the channel signature in sync with the scanner's drop-out test:
  /// `r > g + 25 && r > b + 10`.
  static const Color omrTemplateInk = AppColors.omrTemplateInk;

  /// Requested pale pink tint for the template's soft bands (header/zebra) —
  /// a background, not answer ink, so it never enters the scanner's mask.
  static const Color omrTemplateSoft = AppColors.omrTemplateSoft;

  /// Pre-filled code discs (subject code / set code) are printed "answers"
  /// the scanner must *read*, so they stay a neutral dark ink — NOT the
  /// drop-out pink — otherwise the subject/set codes would be excluded as
  /// template and come back blank.
  static const Color omrCodeInk = Color(0xFF1A1A1A);

  /// Renders the OMR answer sheet from [OMrGeometry].
  ///
  /// Every bubble and corner mark is placed at the exact coordinates the
  /// [OMrScanner] samples, so a printed sheet can always be scanned. The
  /// title auto-shrinks to a single line so the geometry below the fixed
  /// header band never moves.
  static Future<List<Uint8List>> renderOmrSheetPages({
    required String title,
    required int total,
    String? subjectCode,
    String? setCode,
  }) async {
    await _loadFonts();
    final geo = OMrGeometry(total.clamp(1, 100).toInt());
    // Settings → "Prefill set & subject code in OMR": when off, the
    // generated sheet leaves the set bubble & subject-code digits blank
    // (students fill them in) and the scanner leaves them blank too.
    final prefill = AppSettings.omrPrefill;

    final pages = <Uint8List>[];
    const double sw = 1654.0;
    const double sh = 2339.0;

    late ui.PictureRecorder rec;
    late Canvas canvas;

    void begin() {
      rec = ui.PictureRecorder();
      canvas = Canvas(rec, Rect.fromLTWH(0, 0, sw, sh));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, sw, sh),
        Paint()..color = const Color(0xFFFFFFFF),
      );
    }

    Future<void> commit() async {
      final stamp = TextPainter(
        text: TextSpan(
          text: 'AL·v25',
          style: TextStyle(
            fontFamily: _regular,
            fontSize: 7 * _k,
            color: const Color(0xFFAAAAAA),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      stamp.paint(canvas, Offset(OMrGeometry.margin, sh - 6 * _k));
      final img = await rec.endRecording().toImage(_W, _H);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      pages.add(bd!.buffer.asUint8List());
    }

    TextStyle st(double size, bool isBold, double lineHeight, {Color? color}) =>
        TextStyle(
          fontFamily: isBold ? (_bold ?? _regular) : _regular,
          fontFamilyFallback: _fb(isBold),
          fontWeight:
              (isBold && _bold == null) ? FontWeight.w700 : FontWeight.w400,
          fontSize: size * _k,
          height: lineHeight,
          color: color ?? omrTemplateInk,
        );

    TextPainter makePainter(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.left,
      Color? color,
    }) =>
        TextPainter(
          text: TextSpan(
            text: text,
            style: st(size, isBold, 1.4, color: color),
          ),
          textDirection: TextDirection.ltr,
          textAlign: align,
        );

    final ink = omrTemplateInk;
    final accent = omrTemplateInk;
    final accentSoft = omrTemplateSoft;
    final borderAccent = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 * _k;

    void bubble(double x, double yy, String value, {bool selected = false}) {
      final r = OMrGeometry.bubbleRadiusPx;
      // A pre-filled code disc is a printed "answer": neutral dark ink the
      // scanner reads like a pen mark (the drop-out pink would be excluded
      // as template). The rest of the template uses the bright pink.
      canvas.drawCircle(
        Offset(x, yy),
        r,
        Paint()..color = selected ? omrCodeInk : Colors.white,
      );
      canvas.drawCircle(
        Offset(x, yy),
        r,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = .8 * _k,
      );
      final t = makePainter(
        value,
        6.4,
        isBold: selected,
        align: TextAlign.center,
        color: selected ? Colors.white : null,
      )..layout();
      t.paint(canvas, Offset(x - t.width / 2, yy - t.height / 2));
    }

    begin();

    // Corner alignment marks — the scanner's registration squares.
    for (var i = 0; i < 4; i++) {
      final t = OMrGeometry.markTopLeft(i);
      canvas.drawRect(
        Rect.fromLTWH(t[0], t[1], OMrGeometry.markSize, OMrGeometry.markSize),
        Paint()..color = ink,
      );
    }

    // Header band — fixed geometry, title shrinks to fit one line.
    final titleText = title.trim().isEmpty ? 'Question Paper' : title.trim();
    var titleSize = 14.0;
    var titlePainter = makePainter(titleText, titleSize, isBold: true)
      ..layout();
    while (titlePainter.width > OMrGeometry.contentW && titleSize > 9.5) {
      titleSize -= 0.5;
      titlePainter = makePainter(titleText, titleSize, isBold: true)..layout();
    }
    titlePainter.paint(
      canvas,
      Offset(OMrGeometry.margin, OMrGeometry.titleTop),
    );
    final subtitle = makePainter(
      'নির্ধারিত স্থান ব্যতীত কোনো দাগ বা লেখা করা যাবে না। কালো বল-পয়েন্ট কলমে বৃত্ত ভরাট করো।',
      8.2,
      isBold: true,
    )..layout(maxWidth: OMrGeometry.contentW);
    subtitle.paint(canvas, Offset(OMrGeometry.margin, OMrGeometry.subtitleTop));
    canvas.drawLine(
      Offset(OMrGeometry.margin, OMrGeometry.ruleY),
      Offset(sw - OMrGeometry.margin, OMrGeometry.ruleY),
      Paint()
        ..color = ink
        ..strokeWidth = 1.2 * _k,
    );

    // ── Question boxes (one per column of OMrGeometry) ─────────────
    var placed = 0;
    for (var column = 0; column < geo.questionColumns; column++) {
      final remaining = total - placed;
      if (remaining <= 0) break;
      final count = remaining > geo.perColumn ? geo.perColumn : remaining;
      final x = geo.columnX(column);
      final top = OMrGeometry.questionsTop;
      final width = geo.questionWidth;
      final h = OMrGeometry.boxHeaderH + count * OMrGeometry.rowH + 4 * _k;
      canvas.drawRect(Rect.fromLTWH(x, top, width, h), borderAccent);
      canvas.drawRect(
        Rect.fromLTWH(x, top, width, OMrGeometry.boxHeaderH),
        Paint()..color = accentSoft,
      );
      final head = makePainter('প্রশ্ন', 7.4, isBold: true)..layout();
      head.paint(
        canvas,
        Offset(x + 4 * _k, top + (OMrGeometry.boxHeaderH - head.height) / 2),
      );
      for (var option = 0; option < 4; option++) {
        final letter = makePainter(
          _optionLetters[option],
          7.0,
          isBold: true,
          align: TextAlign.center,
        )..layout();
        final cx = x + OMrGeometry.bubbleLeft + option * geo.bubbleStep;
        letter.paint(
          canvas,
          Offset(
            cx - letter.width / 2,
            top + (OMrGeometry.boxHeaderH - letter.height) / 2,
          ),
        );
      }
      for (var i = 0; i < count; i++) {
        final rowTop = top + OMrGeometry.boxHeaderH + i * OMrGeometry.rowH;
        final yy = rowTop + OMrGeometry.rowH / 2;
        if (i.isOdd) {
          canvas.drawRect(
            Rect.fromLTWH(x + .5 * _k, rowTop, width - _k, OMrGeometry.rowH),
            Paint()..color = accentSoft.withOpacity(.55),
          );
        }
        final number = makePainter(_bn(placed + i + 1), 7.6)..layout();
        number.paint(canvas, Offset(x + 4 * _k, yy - number.height / 2));
        for (var option = 0; option < 4; option++) {
          bubble(
            x + OMrGeometry.bubbleLeft + option * geo.bubbleStep,
            yy,
            _optionLetters[option],
          );
        }
      }
      placed += count;
    }

    // ── Identity panels (roll / registration / subject code) ───────
    void digitPanel(int panel, String panelTitle, {String digits = ''}) {
      double x, w;
      int cols;
      switch (panel) {
        case 1:
          x = geo.registrationPanelX;
          w = geo.registrationPanelW;
          cols = 10;
          break;
        case 2:
          x = geo.subjectPanelX;
          w = geo.subjectPanelW;
          cols = 3;
          break;
        default:
          x = geo.rollPanelX;
          w = geo.rollPanelW;
          cols = 6;
      }
      final top = geo.identityTop;
      canvas.drawRect(
        Rect.fromLTWH(x, top, w, OMrGeometry.panelH),
        borderAccent,
      );
      canvas.drawRect(
        Rect.fromLTWH(x, top, w, OMrGeometry.labelBand),
        Paint()..color = accentSoft,
      );
      final label = makePainter(
        panelTitle,
        8.5,
        isBold: true,
        align: TextAlign.center,
      )..layout(maxWidth: w - 6 * _k);
      label.paint(canvas, Offset(x + (w - label.width) / 2, top + 2 * _k));
      for (var c = 0; c < cols; c++) {
        final wanted = c < digits.length ? digits[c] : '';
        for (var d = 0; d < 10; d++) {
          final p = geo.digitBubble(panel, c, d);
          bubble(p.dx, p.dy, '$d', selected: wanted == '$d');
        }
      }
    }

    digitPanel(0, 'রোল নম্বর');
    digitPanel(1, 'রেজিস্ট্রেশন নম্বর');
    digitPanel(
      2,
      'বিষয় কোড',
      digits: prefill ? _toLatinDigits(subjectCode ?? '') : '',
    );

    // ── Set code + instructions ────────────────────────────────────
    final setTop = geo.setTop;
    canvas.drawRect(
      Rect.fromLTWH(
        OMrGeometry.margin,
        setTop,
        OMrGeometry.setW,
        OMrGeometry.setH,
      ),
      borderAccent,
    );
    final setTitle = makePainter('সেট কোড', 8.2, isBold: true)..layout();
    setTitle.paint(
      canvas,
      Offset(
        OMrGeometry.margin + 5 * _k,
        setTop + (OMrGeometry.setH - setTitle.height) / 2,
      ),
    );
    for (var i = 0; i < 4; i++) {
      final p = geo.setBubble(i);
      bubble(
        p.dx,
        p.dy,
        _optionLetters[i],
        selected: prefill && setCode == _optionLetters[i],
      );
    }

    final rulesX = OMrGeometry.margin + OMrGeometry.setW + 12 * _k;
    final rulesW = OMrGeometry.contentW - OMrGeometry.setW - 12 * _k;
    const rules = [
      'নিয়মাবলি:',
      '১। বৃত্তের ভেতরের লেখা দেখা না যায় এমনভাবে ভরাট করো।',
      '২। কালো কালির বল-পয়েন্ট কলম ব্যবহার করো; পেন্সিল ব্যবহার কোরো না।',
      '৩। উত্তরপত্র ভাঁজ করা বা অপ্রয়োজনীয় দাগ দেওয়া যাবে না।',
      '৪। সেট কোড ভুল হলে উত্তরপত্র মূল্যায়ন করা যাবে না।',
    ];
    var rulesY = setTop;
    for (var i = 0; i < rules.length; i++) {
      final ruleText = makePainter(rules[i], i == 0 ? 9 : 7.5, isBold: i == 0)
        ..layout(maxWidth: rulesW);
      ruleText.paint(canvas, Offset(rulesX, rulesY));
      rulesY += ruleText.height + 2 * _k;
    }

    // Signature strip anchored to the bottom of the sheet.
    final sigA = setTop + OMrGeometry.setH + 22 * _k;
    final sigB = sh - OMrGeometry.margin - 30 * _k;
    final signatureY = sigA > sigB ? sigA : sigB;
    final signatureLine = Paint()
      ..color = ink
      ..strokeWidth = .8 * _k;
    final signWidth = OMrGeometry.contentW * .34;
    for (final entry in [
      ('পরীক্ষার্থীর স্বাক্ষর', OMrGeometry.margin),
      (
        'পরিদর্শকের স্বাক্ষর',
        OMrGeometry.margin + OMrGeometry.contentW - signWidth,
      ),
    ]) {
      canvas.drawLine(
        Offset(entry.$2, signatureY),
        Offset(entry.$2 + signWidth, signatureY),
        signatureLine,
      );
      final caption = makePainter(entry.$1, 7.5)..layout();
      caption.paint(canvas, Offset(entry.$2, signatureY + 3 * _k));
    }
    await commit();

    return pages;
  }

  /// Bangla digits → Latin, digits only (subject-code prefill + scanner).
  static String _toLatinDigits(String s) => s
      .replaceAll('০', '0')
      .replaceAll('১', '1')
      .replaceAll('২', '2')
      .replaceAll('৩', '3')
      .replaceAll('৪', '4')
      .replaceAll('৫', '5')
      .replaceAll('৬', '6')
      .replaceAll('৭', '7')
      .replaceAll('৮', '8')
      .replaceAll('৯', '9')
      .replaceAll(RegExp(r'[^0-9]'), '');

  /// Prints only the OMR answer sheet — [copies] identical pages, so a whole
  /// class can get sheets without printing the question paper N times.
  static Future<void> printOmrSheet({
    required String title,
    required int total,
    String? subjectCode,
    String? setCode,
    int copies = 1,
  }) async {
    final page = (await renderOmrSheetPages(
      title: title,
      total: total,
      subjectCode: subjectCode,
      setCode: setCode,
    ))
        .first;
    final doc = pw.Document();
    final n = copies.clamp(1, 200).toInt();
    for (var i = 0; i < n; i++) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            pw.MemoryImage(page),
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    final bytes = await doc.save();
    try {
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (_) {
      await Printing.sharePdf(bytes: bytes, filename: 'omr_sheet.pdf');
    }
  }

  /// Prints a printable scorecard (মার্কশিট) for one scanned OMR sheet.
  static Future<void> printOmScorecard({
    required String title,
    required String subject,
    required String roll,
    required String registration,
    required String subjectCode,
    required String setCode,
    required int total,
    required int score,
    required int correct,
    required int wrong,
    required int blank,
    required int ambiguous,
    required List<int> answers,
    required List<int> key,
  }) async {
    await _loadFonts();

    final pages = <Uint8List>[];
    const double sw = 1654.0;
    const double sh = 2339.0;
    final double margin = 40 * _k;
    final double bottomY = sh - margin;
    final double contentW = sw - 2 * margin;

    late ui.PictureRecorder rec;
    late Canvas canvas;
    double y = margin;

    void begin() {
      rec = ui.PictureRecorder();
      canvas = Canvas(rec, Rect.fromLTWH(0, 0, sw, sh));
      canvas.drawRect(
        Rect.fromLTWH(0, 0, sw, sh),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      y = margin;
    }

    Future<void> commit() async {
      final stamp = TextPainter(
        text: TextSpan(
          text: 'AL·v25',
          style: TextStyle(
            fontFamily: _regular,
            fontSize: 7 * _k,
            color: const Color(0xFFAAAAAA),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      stamp.paint(canvas, Offset(margin, sh - 6 * _k));
      final img = await rec.endRecording().toImage(_W, _H);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      pages.add(bd!.buffer.asUint8List());
    }

    TextStyle st(double size, bool isBold, double lineHeight) => TextStyle(
          fontFamily: isBold ? (_bold ?? _regular) : _regular,
          fontFamilyFallback: _fb(isBold),
          fontWeight:
              (isBold && _bold == null) ? FontWeight.w700 : FontWeight.w400,
          fontSize: size * _k,
          height: lineHeight,
          color: const Color(0xFF16203A),
        );

    TextPainter makePainter(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.left,
    }) =>
        TextPainter(
          text: TextSpan(text: text, style: st(size, isBold, 1.4)),
          textDirection: TextDirection.ltr,
          textAlign: align,
        );

    Future<void> para(
      String text,
      double size, {
      bool isBold = false,
      TextAlign align = TextAlign.center,
      double gapBefore = 0,
    }) async {
      final tp = makePainter(text, size, isBold: isBold, align: align)
        ..layout(maxWidth: contentW);
      if (y + gapBefore * _k + tp.height > bottomY + 1) {
        await commit();
        begin();
      }
      y += gapBefore * _k;
      tp.paint(canvas, Offset(margin + (contentW - tp.width) / 2, y));
      y += tp.height;
    }

    void rule({double gapBefore = 0, double thick = 1.2}) {
      final ry = y + gapBefore * _k + 2 * _k;
      canvas.drawLine(
        Offset(margin, ry),
        Offset(sw - margin, ry),
        Paint()
          ..color = const Color(0xFF16203A)
          ..strokeWidth = thick * _k,
      );
      y = ry + 2 * _k;
    }

    const optionLetters = ['ক', 'খ', 'গ', 'ঘ'];
    String letterOf(int a) =>
        a >= 0 && a < 4 ? optionLetters[a] : (a == -2 ? '?' : '—');
    String glyphOf(int status) =>
        status == 0 ? '✓' : (status == 1 ? '✗' : (status == 2 ? '–' : '?'));

    final now = DateTime.now();
    final dateStr =
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
    final pct = total == 0 ? 0.0 : score * 100.0 / total;

    begin();
    await para('OMR স্কোর কার্ড', 16, isBold: true);
    await para(title, 12.5, isBold: true, gapBefore: 2);
    await para(
      'বিষয়ঃ ${subject.isEmpty ? '—' : subject}   •   সেটঃ $setCode   •   তারিখঃ $dateStr',
      10.5,
      gapBefore: 2,
    );
    rule(gapBefore: 5);
    rule(gapBefore: 2, thick: .8);

    await para(
      'রোল নংঃ ${roll.isEmpty ? '—' : roll}      রেজিস্ট্রেশন নংঃ ${registration.isEmpty ? '—' : registration}      বিষয় কোডঃ ${subjectCode.isEmpty ? '—' : subjectCode}',
      10.5,
      gapBefore: 6,
    );

    // Score strip: six cells.
    final cells = <(String, String)>[
      ('প্রাপ্ত নম্বর', '$score / $total'),
      ('শতকরা', '${pct.toStringAsFixed(1)}%'),
      ('সঠিক', '$correct'),
      ('ভুল', '$wrong'),
      ('খালি', '$blank'),
      ('দ্বি-দাগ', '$ambiguous'),
    ];
    final cellGap = 6.0 * _k;
    final cellW = (contentW - 5 * cellGap) / 6;
    final cellH = 34 * _k;
    final stripY = y + 6 * _k;
    final cell = Paint()
      ..color = const Color(0xFF16203A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 * _k;
    for (var i = 0; i < cells.length; i++) {
      final cx = margin + i * (cellW + cellGap);
      canvas.drawRect(Rect.fromLTWH(cx, stripY, cellW, cellH), cell);
      final cap = makePainter(cells[i].$1, 8.5)
        ..layout(maxWidth: cellW - 6 * _k);
      cap.paint(canvas, Offset(cx + (cellW - cap.width) / 2, stripY + 4 * _k));
      final val = makePainter(
        cells[i].$2,
        11.5,
        isBold: true,
        align: TextAlign.center,
      )..layout(maxWidth: cellW - 6 * _k);
      val.paint(
        canvas,
        Offset(
          cx + (cellW - val.width) / 2,
          stripY + cellH - val.height - 4 * _k,
        ),
      );
    }
    y = stripY + cellH;

    // Per-question grid, 10 columns.
    y += 12 * _k;
    final cols = 10;
    final rowH = 20.0 * _k;
    for (var i = 0; i < key.length; i++) {
      if (i % cols == 0) {
        if (y + rowH > bottomY + 1) {
          await commit();
          begin();
          y += 4 * _k;
        }
      }
      final col = i % cols;
      final gx = margin + (contentW / cols) * col;
      final status = i < key.length
          ? (answers.isNotEmpty ? _statusOf(i, answers, key) : 2)
          : 2;
      final tp = makePainter(
        '${_bn(i + 1)}.${letterOf(i < answers.length ? answers[i] : -1)}${glyphOf(status)}',
        10,
        isBold: i < key.length && status == 0,
      )..layout(maxWidth: contentW / cols - 3 * _k);
      tp.paint(canvas, Offset(gx + 2 * _k, y));
      if (col == cols - 1) y += rowH;
    }

    y += 14 * _k;
    final signW = contentW * .34;
    final signLine = Paint()
      ..color = const Color(0xFF16203A)
      ..strokeWidth = .8 * _k;
    for (final entry in [
      ('পরীক্ষার্থীর স্বাক্ষর', margin),
      ('শিক্ষকের স্বাক্ষর', margin + contentW - signW),
    ]) {
      canvas.drawLine(
        Offset(entry.$2, y),
        Offset(entry.$2 + signW, y),
        signLine,
      );
      final caption = makePainter(entry.$1, 7.5)..layout();
      caption.paint(canvas, Offset(entry.$2, y + 3 * _k));
    }
    await commit();

    final doc = pw.Document();
    for (final png in pages) {
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(
            pw.MemoryImage(png),
            width: PdfPageFormat.a4.width,
            height: PdfPageFormat.a4.height,
            fit: pw.BoxFit.fill,
          ),
        ),
      );
    }
    final bytes = await doc.save();
    try {
      await Printing.layoutPdf(onLayout: (format) async => bytes);
    } catch (_) {
      await Printing.sharePdf(bytes: bytes, filename: 'omr_scorecard.pdf');
    }
  }

  /// Status of question [i]: 0 correct, 1 wrong, 2 blank, 3 double-marked.
  static int _statusOf(int i, List<int> answers, List<int> key) {
    final a = i < answers.length ? answers[i] : -1;
    if (a == -1) return 2;
    if (a == -2) return 3;
    return (a == key[i]) ? 0 : 1;
  }
}

/// English (as-usual) পেপারের একেকটা প্রশ্ন/সেকশন —
/// [head] = বোল্ড শিরোনাম; [lines] ও [table] দুটোই খালি থাকলে
/// head মাঝখানে পার্ট-শিরোনাম হয়। [table] দিলে বর্ডারওয়ালা ঘর আঁকা হয়।
class EnglishSection {
  final String head;
  final List<String> lines;
  final List<List<String>>? table;

  /// word-box (Q1/Q3)-এর মতো টেবিলে লেখা মাঝখানে রাখতে true করুন।
  final bool centerTable;
  const EnglishSection(
    this.head,
    this.lines, {
    this.table,
    this.centerTable = false,
  });
}
