import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/book.dart';
import 'epub_parser.dart';
import 'text_utils.dart';
import 'txt_parser.dart';

/// 本地书库存储：书籍索引、章节文本、封面、进度。
/// 目录结构：
///   `<appData>/books/<bookId>/chapters/0000.txt`
///   `<appData>/covers/<bookId>.png`
///   `<appData>/data/library.json`
///   `<appData>/data/progress.json`
class LibraryStore {
  // 非 final：允许重复 init（幂等）
  late Directory baseDir;

  /// 测试时可注入临时目录。
  final Directory? baseDirOverride;

  List<Book> _books = [];
  Map<String, BookProgress> _progress = {};

  LibraryStore({this.baseDirOverride});

  List<Book> get books => List.unmodifiable(_books);
  Map<String, BookProgress> get progress => Map.unmodifiable(_progress);

  File _file(String rel) => File(p.join(baseDir.path, rel));
  Directory _dir(String rel) => Directory(p.join(baseDir.path, rel));

  Future<void> init() async {
    final support = baseDirOverride ?? await getApplicationSupportDirectory();
    baseDir = Directory(p.join(support.path, 'chaoshu_data'));
    // Directory.create 幂等（已存在不报错）
    await _ensureDir('data');
    await _ensureDir('books');
    await _ensureDir('covers');
    await _loadLibrary();
    await _loadProgress();
    await _loadRegistry();
    await _cleanupGhostBooks();
    await _cleanupOrphanCovers();
  }

  /// 同名同作者书籍登记表（书名|作者 -> 历史书籍 id 列表）：
  /// 删除的书重导时凭它接续旧进度（书 B 相当于书 A 重新加入）。
  Map<String, List<String>> _registry = {};

  File get _registryFile => _file('data/book_registry.json');

  Future<void> _loadRegistry() async {
    final f = _registryFile;
    if (await f.exists()) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final entries = json['entries'] as Map<String, dynamic>?;
        _registry = entries?.map((k, v) =>
                MapEntry(k, ((v as List?) ?? const []).cast<String>())) ??
            {};
      } catch (_) {
        _registry = {};
      }
    }
  }

  Future<void> _saveRegistry() async {
    final f = _registryFile;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'entries': _registry}), flush: true);
  }

  /// 书籍身份键：书名+作者，忽略大小写与所有空白。
  static String identityKey(String title, String author) =>
      '$title|$author'.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// 本地是否存在某书的章节内容（同步时判断"已应用签名"是否可信）。
  bool hasBookContent(String bookId) {
    final dir = _dir('books/$bookId/chapters');
    if (!dir.existsSync()) return false;
    return dir
        .listSync()
        .whereType<File>()
        .any((f) => f.path.endsWith('.txt'));
  }

  /// 相对路径对应的本地内容是否存在。
  /// `books/<id>.json` 按章节目录判断：索引可能在而内容文件已被删除，
  /// 此时云端签名即使未变也要重新下载，否则会合并出"只有索引没有正文"的幽灵书。
  bool hasSyncedFile(String rel) {
    if (rel.startsWith('books/') && rel.endsWith('.json')) {
      return hasBookContent(rel.substring('books/'.length, rel.length - 5));
    }
    return _file(rel).existsSync();
  }

  /// 清理幽灵书籍：library.json 有索引但章节文件缺失（同步合并产生的
  /// 空壳），避免书架出现无内容书籍、同步上传 21 字节空书文件。
  /// 练习进度保留（同名书重导时可接续）。
  Future<void> _cleanupGhostBooks() async {
    final ghosts = _books.where((b) => !hasBookContent(b.id)).toList();
    if (ghosts.isEmpty) return;
    final ids = ghosts.map((b) => b.id).toSet();
    _books = _books.where((b) => !ids.contains(b.id)).toList();
    await _saveLibrary();
    for (final id in ids) {
      final dir = _dir('books/$id');
      if (dir.existsSync()) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 清理孤儿封面：书籍已删除但封面文件残留
  /// （旧版本删书时未清理封面，或同步从云端带回了已删书籍的封面）。
  Future<void> _cleanupOrphanCovers() async {
    final dir = _dir('covers');
    if (!await dir.exists()) return;
    final ids = _books.map((b) => b.id).toSet();
    for (final f in dir.listSync().whereType<File>()) {
      if (!ids.contains(p.basenameWithoutExtension(f.path))) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _ensureDir(String rel) async {
    final d = _dir(rel);
    // 兼容旧版本误创建的同名文件
    final stale = File(d.path);
    if (await stale.exists() && !await d.exists()) {
      try {
        await stale.delete();
      } catch (_) {}
    }
    await d.create(recursive: true);
  }

  // ---------- library.json ----------
  Future<void> _loadLibrary() async {
    final f = _file('data/library.json');
    if (await f.exists()) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _books = (json['books'] as List?)
                ?.map((e) => Book.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
      } catch (_) {
        _books = [];
      }
    }
  }

  Future<void> _saveLibrary() async {
    final f = _file('data/library.json');
    await f.writeAsString(
      jsonEncode({'books': _books.map((b) => b.toJson()).toList()}),
      flush: true,
    );
  }

  // ---------- progress.json ----------
  Future<void> _loadProgress() async {
    final f = _file('data/progress.json');
    if (await f.exists()) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        _progress = json.map(
          (k, v) => MapEntry(k, BookProgress.fromJson(v as Map<String, dynamic>)),
        );
      } catch (_) {
        _progress = {};
      }
    }
  }

  Future<void> saveProgress() async {
    final f = _file('data/progress.json');
    await f.writeAsString(
      jsonEncode(_progress.map((k, v) => MapEntry(k, v.toJson()))),
      flush: true,
    );
  }

  BookProgress progressOf(String bookId) =>
      _progress[bookId] ?? BookProgress();

  /// 更新某章进度（覆盖策略：新记录的 lastPracticedAt 更新时才覆盖）。
  Future<void> updateChapterProgress(
    String bookId,
    int chapterIndex,
    ChapterProgress cp,
  ) async {
    final bp = _progress[bookId] ?? BookProgress();
    final old = bp.chapters[chapterIndex];
    if (old != null && old.lastPracticedAtMs > cp.lastPracticedAtMs) return;
    final chapters = Map<int, ChapterProgress>.from(bp.chapters);
    chapters[chapterIndex] = cp;
    _progress[bookId] = bp.copyWith(
      chapters: chapters,
      lastChapterIndex: chapterIndex,
    );
    await saveProgress();
  }

  /// 合并远端进度：同章节"进度多者胜"——
  /// 段落数多（同段落比字数多）的一方覆盖少的一方，
  /// 与设备时间戳无关（设备时钟不准/先后打字顺序混乱都不会回退进度）。
  /// 同进度时才比较练习时间。lastChapterIndex 同步重算：
  /// 取进度最多的章节，保证"继续练习"与章节列表一致。
  Future<void> mergeProgress(Map<String, BookProgress> remote) async {
    int progOf(ChapterProgress cp) =>
        cp.paragraphIndex * 1000000 + cp.charIndex * 10 + (cp.completed ? 1 : 0);
    var changed = false;
    for (final e in remote.entries) {
      final local = _progress[e.key] ?? BookProgress();
      final chapters = Map<int, ChapterProgress>.from(local.chapters);
      for (final ce in e.value.chapters.entries) {
        final old = chapters[ce.key];
        if (old == null) {
          chapters[ce.key] = ce.value;
          changed = true;
        } else if (progOf(ce.value) > progOf(old) ||
            (progOf(ce.value) == progOf(old) &&
                old.lastPracticedAtMs < ce.value.lastPracticedAtMs)) {
          chapters[ce.key] = ce.value;
          changed = true;
        }
      }
      // 重算进度最多的章节作为"继续练习"目标
      var bestIdx = local.lastChapterIndex;
      var bestProg = -1;
      chapters.forEach((idx, cp) {
        final pr = progOf(cp);
        if (pr > bestProg) {
          bestProg = pr;
          bestIdx = idx;
        }
      });
      _progress[e.key] = local.copyWith(
        chapters: chapters,
        lastChapterIndex: bestIdx,
      );
    }
    if (changed) await saveProgress();
  }

  Map<String, BookProgress> get progressSnapshot =>
      _progress.map((k, v) => MapEntry(k, v));

  // ---------- 导入 ----------
  Future<Book> importBook(String fileName, Uint8List bytes) async {
    final ext = fileName.toLowerCase().endsWith('.epub') ? 'epub' : 'txt';

    late final ParsedBook parsed;
    if (ext == 'epub') {
      parsed = await Isolate.run(() async => await EpubParser.parse(bytes, fileName));
    } else {
      parsed = await Isolate.run(() => TxtParser.parse(bytes, fileName));
    }

    final id = md5.convert(utf8.encode(
      '$fileName|${bytes.length}|${DateTime.now().millisecondsSinceEpoch}',
    )).toString().substring(0, 16);

    final chapterDir = _dir('books/$id/chapters');
    await chapterDir.create(recursive: true);

    var charCount = 0;
    final titles = <String>[];
    for (int i = 0; i < parsed.chapters.length; i++) {
      final ch = parsed.chapters[i];
      titles.add(ch.title);
      charCount += ch.paragraphs.fold<int>(0, (s, p) => s + p.length);
      final f = _file('books/$id/chapters/${i.toString().padLeft(4, '0')}.txt');
      await f.writeAsString(ch.paragraphs.join('\n\n'), flush: true);
    }

    String? coverPath;
    if (parsed.coverBytes != null && parsed.coverBytes!.isNotEmpty) {
      coverPath = 'covers/$id.${parsed.coverExt}';
      await _file(coverPath).writeAsBytes(parsed.coverBytes!, flush: true);
    }

    final book = Book(
      id: id,
      title: parsed.title,
      author: parsed.author,
      description: parsed.description,
      coverPath: coverPath,
      sourceFormat: ext,
      sourceFileName: fileName,
      chapterTitles: titles,
      charCount: charCount,
      importedAt: DateTime.now(),
    );

    _books = [book, ..._books.where((b) => b.id != id)];
    await _saveLibrary();

    // 同名同作者识别：接管旧书的练习进度（删除重导 = 同一本书重新加入）。
    // 统计层面本就按书名+作者聚合，无需额外处理。
    final key = identityKey(book.title, book.author);
    final history = _registry[key] ?? const <String>[];
    for (final oldId in history.reversed) {
      if (oldId == id) continue;
      final old = _progress[oldId];
      if (old != null && old.chapters.isNotEmpty) {
        _progress[id] = old;
        await saveProgress();
        break;
      }
    }
    _registry[key] = [...history.where((e) => e != id), id];
    await _saveRegistry();
    return book;
  }

  Future<void> deleteBook(String bookId) async {
    _books = _books.where((b) => b.id != bookId).toList();
    await _saveLibrary();
    // 练习进度保留（与删除弹窗文案一致）：同名同作者的书重新导入时
    // 自动接续旧进度，相当于原书重新加入。
    final dir = _dir('books/$bookId');
    if (await dir.exists()) await dir.delete(recursive: true);
    final cover = _dir('covers').listSync().whereType<File>().where(
          (f) => p.basenameWithoutExtension(f.path) == bookId,
        );
    for (final f in cover) {
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> saveBook(Book book) async {
    _books = _books.map((b) => b.id == book.id ? book : b).toList();
    await _saveLibrary();
  }

  /// 标记某书刚被练习过（书架排序：最近练习的排最前，随同步传播）。
  Future<void> touchBook(String bookId) async {
    final idx = _books.indexWhere((b) => b.id == bookId);
    if (idx < 0) return;
    final b = _books[idx];
    _books[idx] = Book(
      id: b.id,
      title: b.title,
      author: b.author,
      description: b.description,
      coverPath: b.coverPath,
      sourceFormat: b.sourceFormat,
      sourceFileName: b.sourceFileName,
      chapterTitles: b.chapterTitles,
      charCount: b.charCount,
      importedAt: b.importedAt,
      lastOpenedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _saveLibrary();
  }

  // ---------- 章节内容读写 ----------
  Future<List<String>> readChapter(String bookId, int chapterIndex) async {
    final f = _file(
      'books/$bookId/chapters/${chapterIndex.toString().padLeft(4, '0')}.txt',
    );
    if (!await f.exists()) return const [];
    return TextUtils.splitParagraphs(await f.readAsString());
  }

  File? coverFile(Book book) {
    if (book.coverPath == null) return null;
    final f = _file(book.coverPath!);
    return f.existsSync() ? f : null;
  }

  // ---------- WebDAV 同步支持 ----------
  /// 收集需要同步的数据文件（相对路径 -> 字节）。
  Future<Map<String, Uint8List>> collectSyncFiles({
    required bool includeBooks,
  }) async {
    final files = <String, Uint8List>{};
    for (final rel in ['data/library.json', 'data/progress.json']) {
      final f = _file(rel);
      if (await f.exists()) files[rel] = Uint8List.fromList(await f.readAsBytes());
    }
    final sessions = _file('data/sessions.jsonl');
    if (await sessions.exists()) {
      files['data/sessions.jsonl'] =
          Uint8List.fromList(await sessions.readAsBytes());
    } else if (await _file('data/deleted_sessions.json').exists()) {
      // 统计已清空但有删除标记：上传空文件，让云端也清空
      files['data/sessions.jsonl'] = Uint8List(0);
    }
    final registry = _registryFile;
    if (await registry.exists()) {
      files['data/book_registry.json'] =
          Uint8List.fromList(await registry.readAsBytes());
    }
    final tombstones = _file('data/deleted_sessions.json');
    if (await tombstones.exists()) {
      files['data/deleted_sessions.json'] =
          Uint8List.fromList(await tombstones.readAsBytes());
    }
    if (includeBooks) {
      // 每本书打包为单个 JSON 文件（chapters 数组），避免按章节拆分上传。
      // 大书（几 MB）的读取+JSON 编码放进后台 Isolate：
      // 主线程执行会掉帧（退出练习页触发全量同步时的卡顿来源）。
      for (final b in _books) {
        final dir = _dir('books/${b.id}/chapters');
        final names = <String>[];
        if (await dir.exists()) {
          names.addAll(dir
              .listSync()
              .whereType<File>()
              .map((f) => p.basename(f.path))
              .where((n) => n.endsWith('.txt'))
              .toList()
            ..sort());
        }
        // 无章节内容的书不上传（防 21 字节空书文件残留在云端）
        if (names.isEmpty) continue;
        final paths = [
          for (final n in names) _file('books/${b.id}/chapters/$n').path
        ];
        final payload = await Isolate.run(() => _encodeBookPayload(paths));
        files['books/${b.id}.json'] = payload;
      }
      final coversDir = _dir('covers');
      if (await coversDir.exists()) {
        for (final f in coversDir.listSync().whereType<File>()) {
          final rel = p.relative(f.path, from: baseDir.path).replaceAll('\\', '/');
          files[rel] = Uint8List.fromList(await f.readAsBytes());
        }
      }
    }
    return files;
  }

  /// 将同步下来的文件落盘合并。
  /// [replace] 覆盖模式：书籍/进度整体替换为远端数据（与来源设备完全一致），
  /// 本地多出的书籍文件会被清理。
  Future<void> applySyncFiles(Map<String, Uint8List> files,
      {bool replace = false}) async {
    final libraryRemote = files['data/library.json'];
    if (libraryRemote != null) {
      try {
        final remoteBooks = (jsonDecode(utf8.decode(libraryRemote))
                as Map<String, dynamic>)['books'] as List?;
        final remote = remoteBooks
                ?.map((e) => Book.fromJson(e as Map<String, dynamic>))
                .toList() ??
            [];
        if (replace) {
          // 覆盖模式：书库与远端完全一致，清理本地多出的书籍与封面
          final remoteIds = remote.map((b) => b.id).toSet();
          _books = remote;
          final booksDir = _dir('books');
          if (await booksDir.exists()) {
            for (final d in booksDir.listSync().whereType<Directory>()) {
              if (!remoteIds.contains(p.basename(d.path))) {
                try {
                  await d.delete(recursive: true);
                } catch (_) {}
              }
            }
          }
          final coversDir = _dir('covers');
          if (await coversDir.exists()) {
            for (final f in coversDir.listSync().whereType<File>()) {
              if (!remoteIds
                  .contains(p.basenameWithoutExtension(f.path))) {
                try {
                  await f.delete();
                } catch (_) {}
              }
            }
          }
        } else {
          // 按 id 取并集，本地优先保留。
          // 远端独有书籍必须有对应内容（本次拉到的书文件或本地已有章节）
          // 才合并进来：否则"只有索引没有正文"的空壳书会进书架，
          // 下次同步还会上传 21 字节空书文件（删除的书被索引复活）。
          final byId = <String, Book>{};
          for (final b in remote) {
            final knownLocally =
                _books.any((x) => x.id == b.id) || hasBookContent(b.id);
            if (knownLocally || files.containsKey('books/${b.id}.json')) {
              byId[b.id] = b;
            }
          }
          for (final b in _books) {
            byId[b.id] = b;
          }
          _books = byId.values.toList();
        }
        await _saveLibrary();
      } catch (_) {}
    }

    final progressRemote = files['data/progress.json'];
    if (progressRemote != null) {
      try {
        final json = jsonDecode(utf8.decode(progressRemote))
            as Map<String, dynamic>;
        final remote = json.map(
          (k, v) => MapEntry(k, BookProgress.fromJson(v as Map<String, dynamic>)),
        );
        if (replace) {
          _progress = remote;
          await saveProgress();
        } else {
          await mergeProgress(remote);
        }
      } catch (_) {}
    }

    // 同名同作者登记表：按 key 合并（历史 id 取并集，顺序保留）
    final registryRemote = files['data/book_registry.json'];
    if (registryRemote != null) {
      try {
        final json =
            jsonDecode(utf8.decode(registryRemote)) as Map<String, dynamic>;
        final entries =
            json['entries'] as Map<String, dynamic>? ?? const {};
        var changed = false;
        entries.forEach((key, value) {
          final ids = ((value as List?) ?? const []).cast<String>();
          final cur = _registry[key] ?? const <String>[];
          final merged = [...cur];
          for (final idv in ids) {
            if (!merged.contains(idv)) merged.add(idv);
          }
          if (merged.length != cur.length) {
            _registry[key] = merged;
            changed = true;
          }
        });
        if (changed) await _saveRegistry();
      } catch (_) {}
    }

    for (final e in files.entries) {
      if (e.key.startsWith('data/')) continue;
      // 旧版按章节拆分的远端文件，忽略（新版为 books/<id>.json 整文件）
      if (e.key.contains('/chapters/')) continue;

      if (e.key.startsWith('books/') && e.key.endsWith('.json')) {
        // 整书文件：还原为章节目录
        final id = e.key.substring('books/'.length, e.key.length - 5);
        try {
          final json = jsonDecode(utf8.decode(e.value)) as Map<String, dynamic>;
          final chapters = (json['chapters'] as List?) ?? const [];
          final chapterDir = _dir('books/$id/chapters');
          await chapterDir.create(recursive: true);
          for (int i = 0; i < chapters.length; i++) {
            final paras = (chapters[i] as String).split('\n\n');
            await _file('books/$id/chapters/${i.toString().padLeft(4, '0')}.txt')
                .writeAsString(paras.join('\n'), flush: true);
          }
        } catch (_) {}
        continue;
      }
      final f = _file(e.key);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(e.value, flush: true);
    }
  }
}

/// 按传入的章节文件路径顺序读取内容，打包为单文件书籍 JSON 载荷。
/// 顶层函数供 Isolate.run 在后台执行（章节文件内段落以单换行分隔，
/// 载荷内段落以空行分隔，与旧版字节级一致）。
Uint8List _encodeBookPayload(List<String> paths) {
  final chapters = <String>[];
  for (final path in paths) {
    final raw = File(path).readAsStringSync();
    chapters.add(raw.split('\n').where((s) => s.isNotEmpty).join('\n\n'));
  }
  return Uint8List.fromList(utf8.encode(jsonEncode({'v': 1, 'chapters': chapters})));
}
