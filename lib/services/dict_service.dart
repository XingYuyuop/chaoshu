import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 字典单字条目。
class DictEntry {
  final String char;
  final String pinyin;
  final String radical;
  final int strokes;
  final String explanation;

  const DictEntry({
    required this.char,
    required this.pinyin,
    required this.radical,
    required this.strokes,
    required this.explanation,
  });

  factory DictEntry.fromJson(Map<String, dynamic> json) => DictEntry(
        char: json['c'] as String? ?? '',
        pinyin: json['p'] as String? ?? '',
        radical: json['r'] as String? ?? '',
        strokes: (json['s'] as num?)?.toInt() ?? 0,
        explanation: json['e'] as String? ?? '',
      );
}

/// 内置字典查询（新华字形单字释义，资源文件加载）。
/// 懒加载：首次查询时读入内存 Map，之后直接查内存。
class DictService {
  DictService._();

  static final Map<String, DictEntry> _entries = {};
  static bool _ready = false;
  static Future<void>? _loading;

  /// 字典是否加载成功（失败后查询返回空结果）。
  static bool get ready => _ready;

  static Future<void> _ensureLoaded() {
    return _loading ??= _load();
  }

  static Future<void> _load() async {
    try {
      final raw = await rootBundle.loadString('assets/data/dict_chars.json');
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final entry = DictEntry.fromJson(item as Map<String, dynamic>);
        if (entry.char.isNotEmpty) _entries[entry.char] = entry;
      }
      _ready = _entries.isNotEmpty;
    } catch (_) {
      // 字典加载失败：保持未就绪，查询返回空结果
      _ready = false;
    }
  }

  /// 查询：单字精确查该字；多字依序返回每个字的条目（未收录的跳过）。
  static Future<List<DictEntry>> lookup(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    await _ensureLoaded();
    if (!_ready) return [];
    final results = <DictEntry>[];
    for (final rune in q.runes) {
      final entry = _entries[String.fromCharCode(rune)];
      if (entry != null) results.add(entry);
    }
    return results;
  }
}
