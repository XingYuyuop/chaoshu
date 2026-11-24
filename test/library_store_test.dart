import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chaoshu/models/book.dart';
import 'package:chaoshu/services/library_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late Directory temp;
  late LibraryStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chaoshu_test');
    store = LibraryStore(baseDirOverride: temp);
    await store.init();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('init 可重复执行且不报错（目录已存在）', () async {
    await store.init(); // 第二次 init
    expect(await Directory(p.join(temp.path, 'chaoshu_data')).exists(), isTrue);
  });

  test('导入 TXT 并读取章节内容', () async {
    const txt = '第一章 开端\n\n正文第一段。\n\n正文第二段。\n\n第二章 发展\n\n第二章正文。\n\n第三章 结局\n\n第三章正文。';
    final book = await store.importBook('测试书.txt', bytes(txt));

    expect(book.title, '测试书');
    expect(book.chapterTitles, hasLength(3));

    // 章节文件必须是目录结构，且内容可读
    final paras = await store.readChapter(book.id, 0);
    expect(paras, hasLength(2));
    expect(paras.first, '正文第一段。');

    final paras1 = await store.readChapter(book.id, 1);
    expect(paras1, ['第二章正文。']);

    final paras2 = await store.readChapter(book.id, 2);
    expect(paras2, ['第三章正文。']);
  });

  test('重复 init 后再次导入（模拟重启应用）', () async {
    final book1 = await store.importBook('a.txt', bytes('第一章 A\n\n内容A。\n\n第一章B段。\n\n第一章C段。'));
    // 重建实例模拟应用重启
    final store2 = LibraryStore(baseDirOverride: temp);
    await store2.init();
    expect(store2.books.map((b) => b.id), contains(book1.id));
    final book2 = await store2.importBook('b.txt', bytes('第一章 B\n\n内容B。\n\nB2。\n\nB3。'));
    final paras = await store2.readChapter(book2.id, 0);
    expect(paras, isNotEmpty);
  });

  test('删除书籍后章节文件与索引同步清理', () async {
    final book = await store.importBook('d.txt', bytes('第一章 D\n\n内容D。\n\nD2。\n\nD3。'));
    await store.deleteBook(book.id);
    expect(store.books.where((b) => b.id == book.id), isEmpty);
    expect(
      await Directory(p.join(temp.path, 'chaoshu_data', 'books', book.id)).exists(),
      isFalse,
    );
  });

  test('进度保存与恢复', () async {
    final book = await store.importBook('p.txt', bytes('第一章 P\n\n内容P。\n\nP2。\n\nP3。'));
    await store.updateChapterProgress(
      book.id,
      0,
      ChapterProgress(
        paragraphIndex: 1,
        charIndex: 2,
        completed: false,
        lastPracticedAtMs: 100,
      ),
    );
    final store2 = LibraryStore(baseDirOverride: temp);
    await store2.init();
    final cp = store2.progressOf(book.id).chapters[0];
    expect(cp?.paragraphIndex, 1);
    expect(cp?.charIndex, 2);
  });

  test('删除书籍后进度保留，重导同名同作者书自动接续进度', () async {
    final bookA = await store.importBook('x.txt', bytes('第一章 X\n\n内容X。\n\nX2。\n\nX3。'));
    await store.updateChapterProgress(
      bookA.id,
      0,
      ChapterProgress(
        paragraphIndex: 2,
        charIndex: 1,
        completed: false,
        lastPracticedAtMs: 200,
      ),
    );
    // 删除书 A：进度保留（供重导接续）
    await store.deleteBook(bookA.id);
    expect(store.progressOf(bookA.id).chapters[0]?.paragraphIndex, 2);

    // 重新导入同书名同作者（模拟删除后重新导入同一本书）
    final bookB = await store.importBook('x.txt', bytes('第一章 X\n\n内容X。\n\nX2。\n\nX3。'));
    expect(bookB.id, isNot(bookA.id));
    // 书 B 自动接管书 A 的进度
    final cp = store.progressOf(bookB.id).chapters[0];
    expect(cp?.paragraphIndex, 2);
    expect(cp?.charIndex, 1);
  });

  test('幽灵书（索引在而章节文件缺失）在 init 时被清理', () async {
    final book = await store.importBook('g.txt', bytes('第一章 G\n\n内容G。\n\nG2。\n\nG3。'));
    // 手工制造幽灵书：删除章节文件，保留索引
    await Directory(p.join(temp.path, 'chaoshu_data', 'books', book.id))
        .delete(recursive: true);
    final store2 = LibraryStore(baseDirOverride: temp);
    await store2.init();
    expect(store2.books.where((b) => b.id == book.id), isEmpty);
  });

  test('applySyncFiles 不合并无内容的远端书籍（幽灵书防御）', () async {
    final local = await store.importBook('l.txt', bytes('第一章 L\n\n内容L。\n\nL2。\n\nL3。'));
    final ghostJson = jsonEncode({
      'books': [
        {
          'id': 'ghost123',
          'title': '幽灵书',
          'author': '某人',
          'description': '',
          'coverPath': null,
          'sourceFormat': 'txt',
          'sourceFileName': 'ghost.txt',
          'chapterTitles': ['第一章'],
          'charCount': 10,
          'importedAt': DateTime.now().toIso8601String(),
          'lastOpenedAtMs': 0,
        },
        local.toJson(),
      ]
    });
    await store.applySyncFiles({'data/library.json': bytes(ghostJson)});
    expect(store.books.map((b) => b.id), isNot(contains('ghost123')));
    expect(store.books.map((b) => b.id), contains(local.id));
  });
}
