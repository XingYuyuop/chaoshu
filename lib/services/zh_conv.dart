import 'package:flutter/services.dart' show rootBundle;

/// 简繁转换（OpenCC 词库，资源文件加载）。
/// 简→繁：词组优先（最长 8 字匹配），再按单字；
/// 繁→简：词组优先 + 单字映射。
class ZhConv {
  static bool _ready = false;
  static final Map<String, String> _s2tChars = {};
  static final Map<String, String> _s2tPhrases = {};
  static final Map<String, String> _t2sChars = {};
  static final Map<String, String> _t2sPhrases = {};

  /// 应用启动时调用一次；失败时保持直通（不转换）。
  static Future<void> init() async {
    if (_ready) return;
    try {
      await Future.wait([
        _load('assets/zhconv/s2t_chars.txt', _s2tChars),
        _load('assets/zhconv/s2t_phrases.txt', _s2tPhrases),
        _load('assets/zhconv/t2s_chars.txt', _t2sChars),
        _load('assets/zhconv/t2s_phrases.txt', _t2sPhrases),
      ]);
      _ready = true;
    } catch (_) {
      // 词库加载失败：保持未初始化，转换为恒等
      _ready = false;
    }
  }

  static Future<void> _load(String asset, Map<String, String> out) async {
    final raw = await rootBundle.loadString(asset);
    for (final line in raw.split('\n')) {
      final tab = line.indexOf('\t');
      if (tab <= 0) continue;
      final from = line.substring(0, tab);
      final rest = line.substring(tab + 1).trim();
      if (rest.isEmpty) continue;
      // 多候选取第一个（首选）
      final space = rest.indexOf(' ');
      final to = space > 0 ? rest.substring(0, space) : rest;
      out[from] = to;
    }
  }

  static String toTraditional(String text) => _convert(text, true);
  static String toSimplified(String text) => _convert(text, false);

  static String _convert(String text, bool s2t) {
    if (!_ready || text.isEmpty) return text;
    final chars = s2t ? _s2tChars : _t2sChars;
    final phrases = s2t ? _s2tPhrases : _t2sPhrases;
    final buf = StringBuffer();
    int i = 0;
    while (i < text.length) {
      // 词组优先（最长 8 字）
      final maxLen = (i + 8) <= text.length ? 8 : text.length - i;
      var matched = false;
      for (int len = maxLen; len >= 2; len--) {
        final rep = phrases[text.substring(i, i + len)];
        if (rep != null) {
          buf.write(rep);
          i += len;
          matched = true;
          break;
        }
      }
      if (matched) continue;
      final ch = text[i];
      buf.write(chars[ch] ?? ch);
      i++;
    }
    return buf.toString();
  }
}
