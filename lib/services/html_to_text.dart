import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as parser;

/// EPUB HTML 内容 → 纯文本段落。
class HtmlToText {
  static const _blockTags = {
    'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'li', 'blockquote', 'tr', 'section', 'article', 'figcaption',
  };
  static const _skipTags = {'script', 'style', 'head', 'svg'};

  /// 将 HTML 字符串转为段落列表。块级元素各成一段，<br> 换行，
  /// 实体自动解码，段内空白折叠。
  static List<String> paragraphs(String html) {
    final doc = parser.parse(html);
    final body = doc.body;
    if (body == null) return const [];
    final buf = _render(body);
    final result = <String>[];
    for (final line in buf.split('\n')) {
      final t = _collapse(line);
      if (t.isNotEmpty) result.add(t);
    }
    return result;
  }

  static String _render(dom.Node node) {
    if (node is dom.Text) return node.text;
    if (node is dom.Element) {
      final tag = node.localName?.toLowerCase() ?? '';
      if (_skipTags.contains(tag)) return '';
      if (tag == 'br') return '\n';
      final inner = node.nodes.map(_render).join();
      if (_blockTags.contains(tag)) return '\n$inner\n';
      return inner;
    }
    return '';
  }

  static String _collapse(String s) {
    // 段内空白折叠：中西文混排场景把空白折叠为单个空格，
    // 后续 normalizeParagraph 会统一去除。
    return s.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim();
  }
}
