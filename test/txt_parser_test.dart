import 'dart:convert';
import 'dart:typed_data';

import 'package:chaoshu/services/text_utils.dart';
import 'package:chaoshu/services/txt_parser.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextUtils', () {
    test('splitParagraphs 按换行分段并过滤空段', () {
      final ps = TextUtils.splitParagraphs('第一段\n\n\n第二段\n\n第三段');
      expect(ps, ['第一段', '第二段', '第三段']);
    });

    test('normalizeParagraph 移除所有空白', () {
      expect(TextUtils.normalizeParagraph(' 你 好 　世界 '), isNot(contains(' ')));
    });

    test('stripWhitespace 忽略全角空格与换行', () {
      expect(TextUtils.stripWhitespace('a　b\nc\td'), 'abcd');
    });
  });

  group('TxtParser', () {
    test('识别「第一章 / 第1章 / Chapter 1」章节头', () {
      const text = '序言很短。\n\n第一章 开始\n\n第一章正文一。\n\n第一章正文二。\n\n'
          '第2章 发展\n\n第二章正文。\n\n'
          'Chapter 3 End\n\n第三章正文。\n\n尾声\n\n尾声正文。';
      final book = TxtParser.parse(Uint8List.fromList(utf8.encode(text)), '测试书.txt');
      expect(book.title, '测试书');
      expect(book.chapters.length, 4);
      expect(book.chapters[0].title, '第一章 开始');
      expect(book.chapters[0].paragraphs, ['第一章正文一。', '第一章正文二。']);
      expect(book.chapters[1].title, '第2章 发展');
      expect(book.chapters[2].title, 'Chapter 3 End');
      expect(book.chapters[3].title, '尾声');
    });

    test('GBK 编码回退', () {
      const text = '第一章 测试\n\n这是GBK编码的内容。\n\n第二章 再测\n\n第二段内容。\n\n第三章 末尾\n\n第三段内容。';
      final gbkBytes = gbk.encode(text);
      final book = TxtParser.parse(Uint8List.fromList(gbkBytes), 'gbk书.txt');
      expect(book.chapters, hasLength(3));
      expect(book.chapters.first.paragraphs.first, contains('这是GBK编码的内容'));
    });

    test('无章节头 → 整本单章', () {
      const text = '这是没有章节标题的一本书。\n\n第二段。\n\n第三段。';
      final book = TxtParser.parse(Uint8List.fromList(utf8.encode(text)), '无章书.txt');
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.paragraphs, hasLength(3));
    });

    test('正文空白被规范化', () {
      const text = '第一章 A\n\n这 是　带 空 白 的 段\n\n普通段。\n\n第二章 B\n\n中段。\n\n第三章 C\n\n尾段。';
      final book =
          TxtParser.parse(Uint8List.fromList(utf8.encode(text)), 't.txt');
      expect(book.chapters.first.paragraphs.first, '这是带空白的段');
    });
  });
}
