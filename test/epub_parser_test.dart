import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chaoshu/services/epub_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List buildTestEpub() {
  List<int> u(String s) => utf8.encode(s);

  final files = <String, List<int>>{
    'mimetype': u('application/epub+zip'),
    'META-INF/container.xml': u('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    'OEBPS/content.opf': u('''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书籍</dc:title>
    <dc:creator>测试作者</dc:creator>
    <dc:description>这是一本&lt;b&gt;测试&lt;/b&gt;书籍。</dc:description>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch3" href="ch3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
    <itemref idref="ch3"/>
  </spine>
</package>'''),
    'OEBPS/toc.ncx': u('''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="test-uid"/></head>
  <docTitle><text>测试书籍</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第一章</text></navLabel><content src="ch1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第二章</text></navLabel><content src="ch2.xhtml"/></navPoint>
    <navPoint id="n3" playOrder="3"><navLabel><text>第三章</text></navLabel><content src="ch3.xhtml"/></navPoint>
  </navMap>
</ncx>'''),
    'OEBPS/ch1.xhtml': u('''<html><body>
<p>听了他的话，我禁不住反问：&amp;什么？</p>
<p>我以为自己听错了。</p>
</body></html>'''),
    'OEBPS/ch2.xhtml': u('''<html><body>
<div><p>第二章第一段。</p><p>第二章第二段。</p></div>
<p>换行后的段落。</p>
</body></html>'''),
    'OEBPS/ch3.xhtml': u('''<html><body>
<script>alert('skip');</script>
<p>第三章内容。</p>
</body></html>'''),
  };

  final archive = Archive();
  files.forEach((name, content) {
    archive.addFile(ArchiveFile(name, content.length, content.toList()));
  });
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded ?? []);
}

void main() {
  test('EPUB 解析：元数据、目录章节、HTML 转文本', () async {
    final parsed = await EpubParser.parse(buildTestEpub(), 'test.epub');

    expect(parsed.title, '测试书籍');
    expect(parsed.author, '测试作者');
    expect(parsed.description, contains('这是一本测试书籍。'));

    expect(parsed.chapters, hasLength(3));
    expect(parsed.chapters[0].paragraphs, hasLength(2));
    // 实体解码 & 空白规范化
    expect(parsed.chapters[0].paragraphs[0], contains('&什么？'));
    expect(parsed.chapters[1].paragraphs, hasLength(3));
    // script 内容被剔除
    expect(parsed.chapters[2].paragraphs, ['第三章内容。']);
  });
}
