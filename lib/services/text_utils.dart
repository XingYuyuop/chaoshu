/// 文本规范化与段落切分工具。
class TextUtils {
  /// 不可见字符 / 控制字符 / 组合标记（EPUB、TXT 常混入零宽空格、
  /// 变体选择符、软连字符等，导致逐字比对永远失败）。
  static final _invisibleRe = RegExp(r'[\p{C}\p{M}]', unicode: true);

  /// 全角 / 变体字符 → 规范形式（两侧同映射，输入与目标等价即可）。
  static const _charMap = <String, String>{
    // 全角 ASCII 区
    '！': '!', '＂': '"', '＃': '#', '＄': r'$', '％': '%', '＆': '&',
    '＇': "'", '（': '(', '）': ')', '＊': '*', '＋': '+', '，': ',',
    '－': '-', '．': '.', '／': '/', '：': ':', '；': ';', '＜': '<',
    '＝': '=', '＞': '>', '？': '?', '＠': '@', '［': '[', '＼': '\\',
    '］': ']', '＾': '^', '＿': '_', '｀': '`', '｛': '{', '｜': '|',
    '｝': '}', '～': '~',
    // 引号变体
    '‘': '\'', '’': '\'', '‚': '\'', '‛': '\'', '«': '"', '»': '"',
    '“': '"', '”': '"', '„': '"', '‟': '"', '❝': '"', '❞': '"',
    // 破折号 / 连字符变体
    '‐': '-', '‑': '-', '‒': '-', '–': '-', '—': '-', '―': '-',
    // 省略号变体
    '⋯': '…', '⋯⋯': '…',
    // 间隔号变体
    '・': '·', '‧': '·', '∙': '·', '•': '·',
  };

  /// 将章节文本切分为段落：按空行分段；单个换行也视为分段。
  static List<String> splitParagraphs(String text) {
    final raw = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parts = raw.split('\n');
    final result = <String>[];
    for (final p in parts) {
      final norm = normalizeParagraph(p);
      if (norm.isNotEmpty) result.add(norm);
    }
    return result;
  }

  /// 规范化一个练习目标段：
  /// - 去首尾空白
  /// - 移除不可见字符（零宽空格、变体选择符、控制符等）
  /// - 段内所有空白字符移除（打字目标不含空格，输入时空格自动忽略）
  static String normalizeParagraph(String p) {
    var s = p.replaceAll(_invisibleRe, '');
    s = s.replaceAll(RegExp(r'[\s\u3000]+'), '');
    return s;
  }

  /// 用户输入中的空白字符移除（空格全角空格制表符换行）。
  static String stripWhitespace(String s) {
    return s.replaceAll(RegExp(r'[\s\u3000]+'), '');
  }

  /// 等价类映射：全角/半角、引号/破折号/省略号变体统一。
  static String canonical(String s) {
    final buf = StringBuffer();
    for (final ch in s.runes) {
      // 全角 ASCII 区（FF01–FF5E）→ 半角
      if (ch >= 0xFF01 && ch <= 0xFF5E) {
        buf.writeCharCode(ch - 0xFEE0);
        continue;
      }
      final c = String.fromCharCode(ch);
      buf.write(_charMap[c] ?? c);
    }
    return buf.toString();
  }
}
