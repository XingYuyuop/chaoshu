import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

import 'text_utils.dart';

class ParsedChapter {
  final String title;
  final List<String> paragraphs;
  ParsedChapter(this.title, this.paragraphs);
}

class ParsedBook {
  final String title;
  final String author;
  final String description;
  final List<ParsedChapter> chapters;
  final Uint8List? coverBytes;
  final String coverExt;

  ParsedBook({
    required this.title,
    this.author = '',
    this.description = '',
    required this.chapters,
    this.coverBytes,
    this.coverExt = 'png',
  });
}

/// 纯 Dart TXT 解析器（可在 Isolate 中运行）。
class TxtParser {
  /// 章节头正则：第X章/回/节/卷/部/篇/集、序章/楔子/引子/尾声/后记/番外、
  /// Chapter 1 / CHAPTER I / Ch. 1。
  /// 章节头标记后必须跟分隔符（空格/冒号等）或行尾，避免「第一章正文…」
  /// 这类正文行被误判。
  static final _chapterRe = RegExp(
    r'^\s*('
    r'第\s*[0-9零〇一二三四五六七八九十百千两]+\s*[章回节卷部篇集]([\s：:·、．.\-—]|$).{0,50}'
    r'|(CHAPTER|Chapter|Ch\.)\s+[0-9IVXLivxlc]+([\s：:·、．.\-—]|$).{0,50}'
    r'|(序章|楔子|引子|尾声|后记|番外)([\s：:·、．.\-—]|$).{0,50}'
    r')\s*$',
  );

  static const _maxCharsNoChapters = 600000;
  static const _virtualChapterChars = 5000;

  /// 解析 TXT 字节流。UTF-8 失败回退 GBK。
  static ParsedBook parse(Uint8List bytes, String fileName) {
    String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      try {
        text = gbk.decode(bytes);
      } catch (_) {
        text = utf8.decode(bytes, allowMalformed: true);
      }
    }
    // 去 BOM、统一换行
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final baseName =
        fileName.replaceAll(RegExp(r'\.(txt|TXT)$'), '').trim();
    final bookTitle = baseName.isEmpty ? '未命名书籍' : baseName;

    // 找章节头
    final lines = text.split('\n');
    final chapterStarts = <int>[];
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (_chapterRe.hasMatch(line)) chapterStarts.add(i);
    }

    List<ParsedChapter> chapters;
    if (chapterStarts.length >= 3) {
      chapters = _splitByChapters(lines, chapterStarts, bookTitle);
    } else {
      // 无有效章节头 → 整本单章；超长则切虚拟章
      final all = TextUtils.splitParagraphs(text);
      final total = all.fold<int>(0, (s, p) => s + p.length);
      if (total > _maxCharsNoChapters) {
        chapters = _virtualSplit(all, bookTitle);
      } else {
        chapters = [ParsedChapter(bookTitle, all)];
      }
    }

    // 过滤空章节（保留标题避免索引歧义则合并？直接过滤空段落章节）
    chapters.removeWhere((c) => c.paragraphs.isEmpty);
    if (chapters.isEmpty) {
      chapters = [ParsedChapter(bookTitle, [bookTitle])];
    }

    return ParsedBook(title: bookTitle, chapters: chapters);
  }

  static List<ParsedChapter> _splitByChapters(
    List<String> lines,
    List<int> starts,
    String fallbackTitle,
  ) {
    final chapters = <ParsedChapter>[];
    for (int s = 0; s < starts.length; s++) {
      final begin = starts[s];
      final end = s + 1 < starts.length ? starts[s + 1] : lines.length;
      final title = lines[begin].trim();
      final body = lines.sublist(begin + 1, end).join('\n');
      final paragraphs = TextUtils.splitParagraphs(body);
      // 章节头本身也可作为段落之一（抄书时通常跳过标题）：
      if (paragraphs.isEmpty) {
        paragraphs.add(title);
      }
      chapters.add(ParsedChapter(title, paragraphs));
    }
    return chapters;
  }

  static List<ParsedChapter> _virtualSplit(
    List<String> paragraphs,
    String bookTitle,
  ) {
    final chapters = <ParsedChapter>[];
    var buf = <String>[];
    var count = 0;
    var part = 1;
    for (final p in paragraphs) {
      buf.add(p);
      count += p.length;
      if (count >= _virtualChapterChars) {
        chapters.add(ParsedChapter('$bookTitle ($part)', buf));
        buf = <String>[];
        count = 0;
        part++;
      }
    }
    if (buf.isNotEmpty) {
      chapters.add(ParsedChapter('$bookTitle ($part)', buf));
    }
    return chapters;
  }
}
