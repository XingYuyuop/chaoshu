import 'dart:typed_data';

import 'package:epubx/epubx.dart' as epub;

import 'html_to_text.dart';
import 'txt_parser.dart';

/// EPUB 解析器（纯 Dart，可在 Isolate 中运行）。
/// 解析目录结构、封面、元数据（书名/作者/简介），按原生章节划分练习单元。
class EpubParser {
  static Future<ParsedBook> parse(Uint8List bytes, String fileName) async {
    final book = await epub.EpubReader.readBook(bytes);

    final title = (book.Title ?? '').trim().isNotEmpty
        ? book.Title!.trim()
        : _baseName(fileName);

    String author = (book.Author ?? '').trim();
    if (author.isEmpty) {
      final list = book.AuthorList;
      if (list != null && list.isNotEmpty) {
        author = list.whereType<String>().join(', ');
      }
    }

    String description = '';
    try {
      final desc = book.Schema?.Package?.Metadata?.Description;
      if (desc != null && desc.trim().isNotEmpty) {
        final paras = HtmlToText.paragraphs(desc);
        description = paras.join('\n');
      }
    } catch (_) {
      description = '';
    }

    // ---- 章节树展开：叶子章节按 Spine 顺序排列 ----
    final chapters = <ParsedChapter>[];
    final spineOrder = _spineFileOrder(book);
    final leafChapters = <epub.EpubChapter>[];
    _collectLeaves(book.Chapters ?? [], leafChapters);

    if (leafChapters.isNotEmpty) {
      // 同一 HTML 文件的多个叶子章节合并处理（锚点切分暂以整文件为准）
      // 顺序：优先按 spine 顺序排列文件，文件内按目录层级。
      final byFile = <String, List<epub.EpubChapter>>{};
      for (final ch in leafChapters) {
        final file = _normalizeFile(ch.ContentFileName ?? '');
        byFile.putIfAbsent(file, () => []).add(ch);
      }
      final orderedFiles = <String>[];
      for (final f in spineOrder) {
        if (byFile.containsKey(f)) orderedFiles.add(f);
      }
      // 兜底：目录中有但 spine 缺失的文件
      for (final f in byFile.keys) {
        if (!orderedFiles.contains(f)) orderedFiles.add(f);
      }

      for (final file in orderedFiles) {
        final html = _htmlFileContent(book, file);
        if (html == null) continue;
        final paragraphs = HtmlToText.paragraphs(html);
        for (final ch in byFile[file]!) {
          final chTitle = (ch.Title ?? '').trim();
          final chParas = List<String>.from(paragraphs);
          // 章节标题本身若出现在正文首段之前，不重复；无正文则用标题
          if (chParas.isEmpty) {
            if (chTitle.isNotEmpty) chParas.add(chTitle);
          }
          if (chParas.isEmpty) continue;
          final displayTitle = chTitle.isEmpty ? '第 ${chapters.length + 1} 节' : chTitle;
          chapters.add(ParsedChapter(displayTitle, chParas));
        }
      }
    }

    // ---- 无目录：每个 spine 文件一章 ----
    if (chapters.isEmpty) {
      for (final file in spineOrder) {
        final html = _htmlFileContent(book, file);
        if (html == null) continue;
        final paragraphs = HtmlToText.paragraphs(html);
        if (paragraphs.isEmpty) continue;
        chapters.add(ParsedChapter(
          '第 ${chapters.length + 1} 节',
          paragraphs,
        ));
      }
    }

    if (chapters.isEmpty) {
      chapters.add(ParsedChapter(title, [title]));
    }

    // ---- 封面 ----
    // 原样保存（jpg/png/webp Flutter 均可原生显示），不做重编码
    Uint8List? coverBytes;
    String coverExt = 'png';
    try {
      coverBytes = _coverBytes(book);
      if (coverBytes != null) {
        coverExt = _coverExt(book);
      }
    } catch (_) {
      coverBytes = null;
    }

    return ParsedBook(
      title: title,
      author: author,
      description: description,
      chapters: chapters,
      coverBytes: coverBytes,
      coverExt: coverExt,
    );
  }

  static String _baseName(String fileName) =>
      fileName.replaceAll(RegExp(r'\.[eE][pP][uU][bB]$'), '').trim();

  static String _normalizeFile(String href) {
    var h = href.replaceAll('\\', '/');
    if (h.contains('/')) h = h.substring(h.lastIndexOf('/') + 1);
    return Uri.decodeComponent(h).toLowerCase();
  }

  static List<String> _spineFileOrder(epub.EpubBook book) {
    final result = <String>[];
    try {
      final spine = book.Schema?.Package?.Spine;
      final manifest = book.Schema?.Package?.Manifest;
      if (spine == null || manifest == null) return result;
      final byId = <String, String>{}; // id -> filename
      for (final item in manifest.Items ?? []) {
        if ((item.MediaType ?? '').contains('html') ||
            (item.Href ?? '').toLowerCase().endsWith(('.xhtml')) ||
            (item.Href ?? '').toLowerCase().endsWith(('.html'))) {
          byId[item.Id ?? ''] = _normalizeFile(item.Href ?? '');
        }
      }
      for (final s in spine.Items ?? []) {
        final f = byId[s.Idref ?? ''];
        if (f != null && !result.contains(f)) result.add(f);
      }
    } catch (_) {}
    return result;
  }

  static String? _htmlFileContent(epub.EpubBook book, String fileName) {
    final html = book.Content?.Html;
    if (html == null) return null;
    // 直接命中
    final direct = html[fileName] ?? html['OEBPS/$fileName'] ?? html['EPUB/$fileName'];
    if (direct != null) return direct.Content;
    // 模糊匹配：key 以 fileName 结尾
    for (final entry in html.entries) {
      if (entry.key.toLowerCase().endsWith(fileName)) return entry.value.Content;
    }
    return null;
  }

  static void _collectLeaves(List<epub.EpubChapter> list, List<epub.EpubChapter> out) {
    for (final ch in list) {
      final subs = ch.SubChapters;
      if (subs != null && subs.isNotEmpty) {
        _collectLeaves(subs, out);
      } else {
        out.add(ch);
      }
    }
  }

  static Uint8List? _coverBytes(epub.EpubBook book) {
    // 方式1：meta name="cover" content="<imageId>"
    String? coverId;
    try {
      for (final meta in book.Schema?.Package?.Metadata?.MetaItems ?? []) {
        if ((meta.Name ?? '') == 'cover' && (meta.Content ?? '').isNotEmpty) {
          coverId = meta.Content;
          break;
        }
      }
      if (coverId != null) {
        final f = book.Content?.Images?[coverId];
        if (f?.Content != null) return Uint8List.fromList(f!.Content!);
      }
    } catch (_) {}

    // 方式2：文件名包含 cover 的图片
    final images = book.Content?.Images;
    if (images != null) {
      for (final entry in images.entries) {
        if (entry.key.toLowerCase().contains('cover')) {
          return Uint8List.fromList(entry.value.Content ?? []);
        }
      }
      // 方式3：第一张图片
      for (final entry in images.entries) {
        final c = entry.value.Content;
        if (c != null && c.isNotEmpty) return Uint8List.fromList(c);
      }
    }
    return null;
  }

  static String _coverExt(epub.EpubBook book) {
    try {
      final images = book.Content?.Images;
      if (images == null) return 'png';
      for (final entry in images.entries) {
        if (entry.key.toLowerCase().contains('cover')) {
          return _extOf(entry.key);
        }
      }
      for (final entry in images.entries) {
        if (entry.value.Content != null && entry.value.Content!.isNotEmpty) {
          return _extOf(entry.key);
        }
      }
    } catch (_) {}
    return 'png';
  }

  static String _extOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'png';
    final e = name.substring(dot + 1).toLowerCase();
    return (e == 'jpg' || e == 'jpeg' || e == 'png' || e == 'webp') ? e : 'png';
  }
}
