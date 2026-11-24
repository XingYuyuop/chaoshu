import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import '../models/app_settings.dart';
import '../models/practice_session.dart';
import '../state/settings_provider.dart';
import 'library_store.dart';
import 'stats_service.dart';

/// 启动增强同步的书籍差异统计（合并前按书 id 对比本地与云端 library.json）。
class SyncDiffInfo {
  /// 本机有而云端没有的书籍数量。
  final int localOnlyBooks;

  /// 云端有而本机没有的书籍数量。
  final int cloudOnlyBooks;

  const SyncDiffInfo({
    required this.localOnlyBooks,
    required this.cloudOnlyBooks,
  });

  bool get hasDiff => localOnlyBooks > 0 || cloudOnlyBooks > 0;
}

/// WebDAV 同步：把练习进度、统计数据、书籍配置（可选含书籍文件）、显示设置
/// 同步到用户指定服务器，实现多设备互通。
///
/// 合并策略：
/// - library.json：按 bookId 取并集（本地优先）
/// - progress.json：按章节 lastPracticedAtMs 新者胜
/// - sessions.jsonl：按 sessionId 去重并集
/// - settings.json：显示设置远端新者胜（settingsUpdatedAt 时间戳），
///   设备特有项与账号字段保留本地
/// - 覆盖同步（overwrite.flag）：来源设备的绝对快照——
///   其他设备同步后书籍/进度/统计/设置与来源设备完全一致（账号字段除外）
class WebDavSync {
  final LibraryStore _store;
  final StatsService _stats;

  /// 设置 Provider（main 启动时注入），用于同步显示设置。
  SettingsProvider? settingsProv;

  WebDavSync(this._store, this._stats);

  String? _lastError;
  DateTime? _lastSyncAt;

  /// 最近一次普通全量同步的书籍差异（合并前统计；覆盖同步/快照替换时为 null）。
  /// 启动增强同步据此在首页提示用户。
  SyncDiffInfo? lastStartupDiff;

  /// 在途操作守卫（借鉴 fast-note-sync 的串行合并思想）：
  /// 已有同步在途时，后续请求【等待它完成】而不是被静默跳过。
  /// 旧版用 bool 互斥直接 return，会导致"打开章节时的拉取被跳过
  /// → 从陈旧数据恢复 → 推送又把旧进度盖回云端"的致命竞态。
  Future<void>? _inflight;

  /// 上传去重表（md5）与远端签名缓存（mTime|size），持久化到本地
  /// data/upload_hashes.json：进程重启后仍记得"哪些文件云端已是最新"，
  /// 避免每次启动后的第一次全量同步把几 MB 的书籍重传/重下载一遍。
  final Map<String, String> _uploadedHashes = {};
  File? _hashCache;

  void _loadHashCaches() {
    if (_hashCache != null) return;
    final f = File(p.join(_store.baseDir.path, 'data', 'upload_hashes.json'));
    _hashCache = f;
    try {
      if (f.existsSync()) {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        final up = m['uploads'] as Map<String, dynamic>?;
        final rs = m['remoteSigs'] as Map<String, dynamic>?;
        if (up != null) {
          _uploadedHashes.addAll(up.map((k, v) => MapEntry(k, v as String)));
        } else if (rs == null) {
          // 旧版格式：整个文件就是上传哈希表
          _uploadedHashes.addAll(m.map((k, v) => MapEntry(k, v as String)));
        }
        if (rs != null) {
          _appliedRemoteSigs.addAll(rs.map((k, v) => MapEntry(k, v as String)));
        }
      }
    } catch (_) {}
  }

  void _saveHashCaches() {
    final f = _hashCache;
    if (f == null) return;
    try {
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({'uploads': _uploadedHashes, 'remoteSigs': _appliedRemoteSigs}),
        flush: true,
      );
    } catch (_) {}
  }

  String? get lastError => _lastError;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get syncing => _inflight != null;

  Future<void> _guarded(Future<void> Function() run) {
    final cur = _inflight;
    if (cur != null) {
      // 在途：把新操作串到在途操作之后执行（等待而非丢弃新请求）
      return cur.whenComplete(() => _guarded(run));
    }
    final f = run();
    _inflight = f;
    return f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
  }

  Future<void> sync(AppSettings settings, {bool overwrite = false}) {
    return _guarded(() async {
    if (settings.webdavUrl.trim().isEmpty) {
      _lastError = '未配置 WebDAV 服务器';
      return;
    }
    _lastError = null;
    lastStartupDiff = null;
    _loadHashCaches();
    try {
      var url = settings.webdavUrl.trim();
      if (!url.endsWith('/')) url += '/';
      final client = webdav.newClient(
        url,
        user: settings.webdavUser,
        password: settings.webdavPassword,
        debug: false,
      );
      client.setHeaders({'accept-charset': 'utf-8'});

      final base = settings.webdavBaseDir.startsWith('/')
          ? settings.webdavBaseDir
          : '/${settings.webdavBaseDir}';
      await _ensureDir(client, base);

      // 1. 拉取远端文件（递归列出全部：data/*、books/*.json、covers/*）
      final remoteFiles = <String, Uint8List>{};
      final remoteEntries = await _listAll(client, base);
      for (final f in remoteEntries) {
        final path = f.path ?? '';
        var rel = path;
        if (base.isNotEmpty && rel.startsWith(base)) {
          rel = rel.substring(base.length);
        }
        rel = rel.replaceAll(RegExp(r'^/+'), '').replaceAll('\\', '/');
        if (rel.isEmpty) continue;
        // 忽略旧版按章节拆分的远端文件（新版为 books/<id>.json 整文件）
        if (rel.contains('/chapters/')) continue;
        // apk/ 目录是安装包，仅供检测更新使用，同步时不下载
        if (rel.startsWith('apk/')) continue;
        // 覆盖模式（本机为源）：书籍/封面不上传也不下载
        if (overwrite &&
            !rel.startsWith('data/')) {
          continue;
        }
        // 云端未变化（修改时间/大小均相同）则跳过下载，避免来回传输；
        // progress.json 例外：它是断点关键数据，永远下载（见 pullProgress）。
        // library.json 例外：启动增强同步需要在合并前对比云端书籍 id，
        // 签名未变时也要拉取（索引文件体量小，全量拉取代价可忽略）。
        // 书籍/封面属于内容文件：本地内容已不存在时即使签名未变也要重新
        // 下载——否则删除书籍后 library.json 并集会把"只有索引没有正文"
        // 的幽灵书合并回来，并上传 21 字节空书文件。
        final sig =
            '${f.mTime?.millisecondsSinceEpoch ?? 0}|${f.size ?? 0}';
        final isContent =
            rel.startsWith('books/') || rel.startsWith('covers/');
        if (rel != 'data/progress.json' &&
            rel != 'data/library.json' &&
            _appliedRemoteSigs[rel] == sig &&
            (!isContent || _store.hasSyncedFile(rel))) {
          continue;
        }
        final bytes = await _readRemote(client, path);
        if (bytes != null) {
          remoteFiles[rel] = bytes;
          _appliedRemoteSigs[rel] = sig;
        }
      }

      // 2. 合并到本地
      // 覆盖模式：本地为准，不拉取远端书籍/封面（否则本地删除的书会被同步回来），
      // 仅合并远端进度与统计
      // 覆盖标记：其他设备执行覆盖同步后，本机同步时整体替换（绝对快照语义）
      final overwriteReceived =
          overwrite ? false : await _consumeOverwriteFlag(client, base);

      // 书籍差异统计（必须在合并前取本地书库快照）：按书 id 对比本地
      // 与云端 library.json。覆盖上传与其他设备快照替换场景下语义不符，
      // 不统计（lastStartupDiff 保持 null）。
      SyncDiffInfo? diff;
      if (!overwrite && !overwriteReceived) {
        final localIds = _store.books.map((b) => b.id).toSet();
        final remoteLib = remoteFiles['data/library.json'];
        if (remoteLib != null) {
          try {
            final remoteBooks = (jsonDecode(utf8.decode(remoteLib))
                    as Map<String, dynamic>)['books'] as List?;
            final remoteIds = remoteBooks
                    ?.map((e) => (e as Map<String, dynamic>)['id'] as String?)
                    .whereType<String>()
                    .toSet() ??
                <String>{};
            diff = SyncDiffInfo(
              localOnlyBooks: localIds.difference(remoteIds).length,
              cloudOnlyBooks: remoteIds.difference(localIds).length,
            );
          } catch (_) {}
        }
      }
      lastStartupDiff = diff;

      final applyFiles = overwrite
          ? Map.fromEntries(remoteFiles.entries
              .where((e) => e.key == 'data/progress.json' ||
                  e.key == 'data/sessions.jsonl'))
          : remoteFiles;
      await _store.applySyncFiles(applyFiles, replace: overwriteReceived);
      // 先应用删除墓碑，再合并统计：被删除的记录不会被云端并集"复活"
      final remoteTombstones = remoteFiles['data/deleted_sessions.json'];
      if (remoteTombstones != null) {
        await _stats.applyRemoteTombstones(_parseTombstones(remoteTombstones));
      }
      final remoteSessions = remoteFiles['data/sessions.jsonl'];
      if (remoteSessions != null && !overwrite) {
        final list = _parseSessions(remoteSessions);
        if (overwriteReceived) {
          await _stats.replaceSessions(list);
        } else {
          await _stats.mergeSessions(list);
        }
      }
      final remoteSettings = remoteFiles['data/settings.json'];
      if (remoteSettings != null) {
        await _applyRemoteSettings(remoteSettings, replace: overwriteReceived);
      }

      // 3. 推送本地文件（合并后的最新状态；未变化的文件跳过）
      // 远端缺失校验：远端被手动删除/更换服务器时，哈希缓存失效自动重传。
      // 注意必须对照【完整远端列表】而不是本轮下载过的 remoteFiles——
      // 签名未变化被跳过下载的文件也在云端存在，误删其哈希会导致
      // 每轮全量同步都把书籍/封面重新上传一遍。
      final remoteRels = <String>{};
      for (final f in remoteEntries) {
        var rel = f.path ?? '';
        if (base.isNotEmpty && rel.startsWith(base)) {
          rel = rel.substring(base.length);
        }
        rel = rel.replaceAll(RegExp(r'^/+'), '').replaceAll('\\', '/');
        if (rel.isNotEmpty) remoteRels.add(rel);
      }
      for (final key in _uploadedHashes.keys.toList()) {
        if (!remoteRels.contains(key)) _uploadedHashes.remove(key);
      }
      // 覆盖同步：强制全量上传（以本地为准重建云端）
      if (overwrite) _uploadedHashes.clear();
      final localFiles = await _store.collectSyncFiles(
        includeBooks: settings.webdavSyncBooks,
      );
      // 显示设置随同步上传（剔除账号字段，云端不含任何账号信息）
      if (settingsProv != null) {
        localFiles['data/settings.json'] = _localSettingsBytes();
      }
      for (final e in localFiles.entries) {
        final hash = md5.convert(e.value).toString();
        if (_uploadedHashes[e.key] == hash) continue; // 未变化
        final path = '$base/${e.key}';
        final dir = path.substring(0, path.lastIndexOf('/'));
        await _ensureDir(client, dir);
        // 整文件一次性上传（字节体，带 Content-Length）
        await client.write(path, e.value, onProgress: (c, t) {});
        _uploadedHashes[e.key] = hash;
      }
      _saveHashCaches();

      // 4. 覆盖模式：删除云端多余文件（本地已删除的书籍/封面）
      // 仅在同步书籍文件开启时执行，避免误删未同步的远端书籍
      if (overwrite && settings.webdavSyncBooks) {
        final localKeys = localFiles.keys.toSet();
        for (final f in remoteEntries) {
          final path = f.path ?? '';
          var rel = path;
          if (base.isNotEmpty && rel.startsWith(base)) {
            rel = rel.substring(base.length);
          }
          rel = rel.replaceAll(RegExp(r'^/+'), '').replaceAll('\\', '/');
          if (rel.isEmpty) continue;
          final isBookData =
              rel.startsWith('books/') || rel.startsWith('covers/');
          if (!isBookData || localKeys.contains(rel)) continue;
          try {
            await client.remove(path);
          } catch (_) {}
        }
      }
      // 4.5 常规同步：以本地书架为准清理云端——
      // 已删除书籍的 books/<id>.json 与对应封面从云端移除，
      // 否则 pull 阶段会把删除的书"还原"回来、孤儿封面反复重传。
      // 仅同步书籍文件开启时执行。
      if (!overwrite && settings.webdavSyncBooks) {
        final localIds = _store.books.map((b) => b.id).toSet();
        for (final f in remoteEntries) {
          final path = f.path ?? '';
          var rel = path;
          if (base.isNotEmpty && rel.startsWith(base)) {
            rel = rel.substring(base.length);
          }
          rel = rel.replaceAll(RegExp(r'^/+'), '').replaceAll('\\', '/');
          final isBook = rel.startsWith('books/') && rel.endsWith('.json');
          final isCover = rel.startsWith('covers/');
          if (!isBook && !isCover) continue;
          final id = p.basenameWithoutExtension(rel);
          if (localIds.contains(id)) continue;
          try {
            await client.remove(path);
            _uploadedHashes.remove(rel);
            _appliedRemoteSigs.remove(rel);
          } catch (_) {}
        }
        _saveHashCaches();
      }
      // 覆盖同步：写标记，其他设备同步时以本机统计为准整体替换
      if (overwrite) {
        await _ensureDir(client, '$base/data');
        final flagTs = DateTime.now().millisecondsSinceEpoch;
        await client.write(
          '$base/data/overwrite.flag',
          Uint8List.fromList(utf8.encode('$flagTs')),
          onProgress: (c, t) {},
        );
        // 记录的是标记自身的时间戳而非本机 now()：
        // 本机时钟偏差会让 now() 比标记偏大/偏小，破坏"每台设备
        // 消费一次"的一次性语义（偏大→漏消费，偏小→反复消费）
        await _markOverwriteSeen(flagTs);
      }
      _lastSyncAt = DateTime.now();
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    }
    });
  }

  /// 轻量进度推送：上传 data/*（进度/统计/书库索引/设置），
  /// md5 未变化的文件直接跳过、零网络请求。
  /// 写前合并（merge-on-write，借鉴 fast-note-sync 的"云端数据单调不减"）：
  /// 上传前先取云端 progress.json 合并进本地，再上传合并结果——
  /// 旧数据设备只会把云端进度往上加，绝不会把新进度盖回旧值。
  Future<void> pushProgress(AppSettings settings) {
    return _guarded(() async {
    if (settings.webdavUrl.trim().isEmpty) return;
    try {
      var url = settings.webdavUrl.trim();
      if (!url.endsWith('/')) url += '/';
      final client = webdav.newClient(
        url,
        user: settings.webdavUser,
        password: settings.webdavPassword,
        debug: false,
      );
      client.setHeaders({'accept-charset': 'utf-8'});
      final base = settings.webdavBaseDir.startsWith('/')
          ? settings.webdavBaseDir
          : '/${settings.webdavBaseDir}';

      // 覆盖标记未消费：云端是来源设备的绝对快照，本轮不上传任何
      // data/*，防止本地旧状态冲掉快照（已删记录/书索引复活）。
      // 等 pull/全量同步消费标记按快照替换本地后再恢复推送
      if (await _overwriteFlagPending(client, base)) {
        return;
      }

      // 1. 写前合并：取云端 progress.json 与本地合并（进度多者胜），
      //    云端领先的进度自动落到本地，随后上传的就是合并后的最新状态。
      //    只多一次几 KB 的 GET，无 PROPFIND。
      String? remoteHash;
      try {
        final remoteProgress =
            await _readRemote(client, '$base/data/progress.json');
        if (remoteProgress != null) {
          remoteHash = md5.convert(remoteProgress).toString();
          await _store.applySyncFiles(
              {'data/progress.json': remoteProgress},
              replace: false);
        }
      } catch (_) {
        // 云端暂时读不到：退化为盲上传，下次推送再合并
      }

      // 2. 收集合并后的本地文件并上传
      _loadHashCaches();
      final localFiles = await _store.collectSyncFiles(includeBooks: false);
      if (settingsProv != null) {
        localFiles['data/settings.json'] = _localSettingsBytes();
      }
      var pushed = 0;
      for (final e in localFiles.entries) {
        final hash = md5.convert(e.value).toString();
        if (e.key == 'data/progress.json') {
          if (hash == remoteHash) continue; // 与云端一致：无需上传
        } else if (_uploadedHashes[e.key] == hash) {
          continue; // 无变化：零网络请求
        }
        final path = '$base/${e.key}';
        await _ensureDir(client, path.substring(0, path.lastIndexOf('/')));
        await client.write(path, e.value, onProgress: (c, t) {});
        _uploadedHashes[e.key] = hash;
        pushed++;
      }
      if (pushed > 0) _saveHashCaches();
      if (pushed > 0) _lastSyncAt = DateTime.now();
    } catch (_) {
      // 后台推送静默失败：下次触发时自动重试
    }
    });
  }

  /// 从云端还原：仅下载并合并（书籍/封面/进度/统计/设置），不上传本地数据。
  /// 适用于新设备初次配置、本地数据误删后找回。云端带覆盖标记时按快照替换。
  Future<void> restore(AppSettings settings) {
    return _guarded(() async {
    if (settings.webdavUrl.trim().isEmpty) {
      _lastError = '未配置 WebDAV 服务器';
      throw StateError(_lastError!);
    }
    _lastError = null;
    try {
      var url = settings.webdavUrl.trim();
      if (!url.endsWith('/')) url += '/';
      final client = webdav.newClient(
        url,
        user: settings.webdavUser,
        password: settings.webdavPassword,
        debug: false,
      );
      client.setHeaders({'accept-charset': 'utf-8'});
      final base = settings.webdavBaseDir.startsWith('/')
          ? settings.webdavBaseDir
          : '/${settings.webdavBaseDir}';

      final remoteEntries = await _listAll(client, base);
      final remoteFiles = <String, Uint8List>{};
      for (final f in remoteEntries) {
        final path = f.path ?? '';
        var rel = path;
        if (base.isNotEmpty && rel.startsWith(base)) {
          rel = rel.substring(base.length);
        }
        rel = rel.replaceAll(RegExp(r'^/+'), '').replaceAll('\\', '/');
        if (rel.isEmpty || rel.startsWith('apk/')) continue;
        if (rel.contains('/chapters/')) continue;
        final bytes = await _readRemote(client, path);
        if (bytes != null) remoteFiles[rel] = bytes;
      }

      final overwriteReceived = await _consumeOverwriteFlag(client, base);
      await _store.applySyncFiles(remoteFiles, replace: overwriteReceived);
      final remoteTombstones = remoteFiles['data/deleted_sessions.json'];
      if (remoteTombstones != null) {
        await _stats.applyRemoteTombstones(_parseTombstones(remoteTombstones));
      }
      final remoteSessions = remoteFiles['data/sessions.jsonl'];
      if (remoteSessions != null) {
        final list = _parseSessions(remoteSessions);
        if (overwriteReceived) {
          await _stats.replaceSessions(list);
        } else {
          await _stats.mergeSessions(list);
        }
      }
      final remoteSettings = remoteFiles['data/settings.json'];
      if (remoteSettings != null) {
        await _applyRemoteSettings(remoteSettings, replace: overwriteReceived);
      }
      _lastSyncAt = DateTime.now();
    } catch (e) {
      _lastError = e.toString();
      rethrow;
    }
    });
  }

  /// 轻量进度拉取：仅下载合并 data/progress.json 与 sessions.jsonl，
  /// 不拉书籍文件。打开章节前调用，多设备断点即时互通（按时间新者胜）。
  Future<void> pullProgress(AppSettings settings) {
    return _guarded(() async {
    if (settings.webdavUrl.trim().isEmpty) return;
    _loadHashCaches();
    try {
      var url = settings.webdavUrl.trim();
      if (!url.endsWith('/')) url += '/';
      final client = webdav.newClient(
        url,
        user: settings.webdavUser,
        password: settings.webdavPassword,
        debug: false,
      );
      client.setHeaders({'accept-charset': 'utf-8'});
      final base = settings.webdavBaseDir.startsWith('/')
          ? settings.webdavBaseDir
          : '/${settings.webdavBaseDir}';

      final overwriteReceived = await _consumeOverwriteFlag(client, base);
      // progress.json 只有几 KB 且是断点恢复的关键数据：
      // 必须每次直接下载，不走"签名未变跳过"（服务器不回传修改时间、
      // 且新旧内容字节数恰好相同时会误判未变化，导致断点不同步）
      final progressBytes =
          await _readRemote(client, '$base/data/progress.json');
      if (progressBytes != null) {
        await _store.applySyncFiles({'data/progress.json': progressBytes},
            replace: overwriteReceived);
      }
      // 删除墓碑：其他设备删除的练习记录即时在本地消失
      final tombBytes = await _readRemoteIfChanged(
          client, base, 'data/deleted_sessions.json');
      if (tombBytes != null) {
        await _stats.applyRemoteTombstones(_parseTombstones(tombBytes));
      }
      // sessions.jsonl（统计记录）与 progress.json 同等对待：每次必拉。
      // 它只有几十 KB 且是多设备统计一致的关键数据；服务器不回传修改
      // 时间、或新旧内容恰好等长时会误判"未变化"，导致统计漏同步。
      final sessionBytes =
          await _readRemote(client, '$base/data/sessions.jsonl');
      if (sessionBytes != null) {
        final list = _parseSessions(sessionBytes);
        if (overwriteReceived) {
          await _stats.replaceSessions(list);
        } else {
          await _stats.mergeSessions(list);
        }
      }
      final settingsBytes = await _readRemoteIfChanged(
          client, base, 'data/settings.json');
      if (settingsBytes != null) {
        await _applyRemoteSettings(settingsBytes, replace: overwriteReceived);
      }
      _lastSyncAt = DateTime.now();
      _saveHashCaches();
    } catch (_) {
      // 后台拉取静默失败：不影响本地打开章节
    }
    });
  }

  // ---------- 应用内更新（仅 Android）----------
  // 安装包命名：抄书打字-Android-v1.2.3.apk（arm64，真机）
  //            抄书打字-Android-v1.2.3-x64.apk（x86_64，模拟器）
  static final RegExp _apkVer =
      RegExp(r'抄书打字-Android-v(\d+)\.(\d+)\.(\d+)(-x64)?\.apk');

  String? _deviceAbiCache;
  Future<String?> _deviceAbi() async {
    if (_deviceAbiCache != null) return _deviceAbiCache;
    try {
      final r = await Process.run('getprop', ['ro.product.cpu.abi']);
      final v = r.stdout.toString().trim();
      _deviceAbiCache = v.contains('x86') ? 'x64' : 'arm64';
    } catch (_) {
      _deviceAbiCache = 'arm64';
    }
    return _deviceAbiCache;
  }

  static int _cmpVer(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }

  /// 列出云端 `<baseDir>/apk/` 目录，返回最新版本信息（安卓 apk）。
  /// 返回 {'version','fileName','size'}；无包或失败返回 null（见 lastError）。
  Future<Map<String, String>?> checkUpdate(AppSettings settings) async {
    if (settings.webdavUrl.trim().isEmpty) {
      _lastError = '未配置 WebDAV 服务器';
      return null;
    }
    try {
      var url = settings.webdavUrl.trim();
      if (!url.endsWith('/')) url += '/';
      final client = webdav.newClient(
        url,
        user: settings.webdavUser,
        password: settings.webdavPassword,
        debug: false,
      );
      client.setHeaders({'accept-charset': 'utf-8'});
      final base = settings.webdavBaseDir.startsWith('/')
          ? settings.webdavBaseDir
          : '/${settings.webdavBaseDir}';
      final list = await client.readDir('$base/apk');
      final abi = await _deviceAbi();
      // 同版本下按设备架构优先：x64 设备取 -x64 包，其余取 arm64 包
      Map<String, dynamic>? best;
      var bestVer = [0, 0, 0];
      Map<String, dynamic>? bestFallback;
      for (final f in list) {
        if (f.isDir == true) continue;
        final name = f.name ?? '';
        final m = _apkVer.firstMatch(name);
        if (m == null) continue;
        final ver = [
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
        ];
        final isX64 = m.group(4) != null;
        final matches = (abi == 'x64') == isX64;
        final cand = {
          'ver': ver,
          'name': name,
          'size': f.size ?? 0,
        };
        if (_cmpVer(ver, bestVer) > 0) {
          bestVer = ver;
          best = matches ? cand : null;
          bestFallback = cand;
        } else if (_cmpVer(ver, bestVer) == 0) {
          if (matches) best = cand;
          bestFallback ??= cand;
        }
      }
      final picked = best ?? bestFallback;
      if (picked == null || (picked['name'] as String).isEmpty) {
        _lastError = '云端 apk 目录中没有找到安装包';
        return null;
      }
      return {
        'version': bestVer.join('.'),
        'fileName': picked['name'] as String,
        'size': '${picked['size']}',
      };
    } catch (e) {
      _lastError = e.toString();
      return null;
    }
  }

  /// 流式下载安装包到临时目录（不占大块内存），返回本地文件。
  Future<File> downloadUpdateApk(
    AppSettings settings,
    String fileName, {
    void Function(int count, int total)? onProgress,
  }) async {
    var url = settings.webdavUrl.trim();
    if (!url.endsWith('/')) url += '/';
    final client = webdav.newClient(
      url,
      user: settings.webdavUser,
      password: settings.webdavPassword,
      debug: false,
    );
    client.setHeaders({'accept-charset': 'utf-8'});
    final base = settings.webdavBaseDir.startsWith('/')
        ? settings.webdavBaseDir
        : '/${settings.webdavBaseDir}';
    final tmp = await getTemporaryDirectory();
    // 清理历史遗留的安装包缓存：每次更新下载约 20MB，
    // 不清理会在应用缓存目录无限累积（占用数百 MB 的元凶）
    try {
      for (final f in tmp.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name.startsWith('抄书打字-Android-v') && name.endsWith('.apk')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    final savePath = p.join(tmp.path, fileName);
    await client.read2File('$base/apk/$fileName', savePath,
        onProgress: onProgress);
    return File(savePath);
  }

  /// 读取远端文件，但先做一次轻量目录查询（PROPFIND 响应仅几 KB）：
  /// 文件的修改时间+大小与上次一致时直接跳过下载。
  /// 返回 null 表示"文件不存在或未变化"（调用方按未变化处理）。
  Future<Uint8List?> _readRemoteIfChanged(
      webdav.Client client, String base, String rel) async {
    try {
      final slash = rel.lastIndexOf('/');
      final dir = slash < 0 ? '' : rel.substring(0, slash);
      final name = slash < 0 ? rel : rel.substring(slash + 1);
      final list = await client.readDir(dir.isEmpty ? base : '$base/$dir');
      webdav.File? f;
      for (final e in list) {
        if (e.isDir != true && (e.name ?? '') == name) {
          f = e;
          break;
        }
      }
      if (f == null) return null;
      final sig =
          '${f.mTime?.millisecondsSinceEpoch ?? 0}|${f.size ?? 0}';
      if (_appliedRemoteSigs[rel] == sig) return null; // 未变化：不下载
      final bytes = await _readRemote(client, '$base/$rel');
      if (bytes != null) _appliedRemoteSigs[rel] = sig;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  // ---------- 覆盖标记 / 会话解析 ----------
  /// 已应用的远端文件签名（修改时间|大小）：
  /// 同步时签名未变化的文件直接跳过下载，不产生流量。
  final Map<String, String> _appliedRemoteSigs = {};

  /// 本地设置的上传字节（剔除账号字段，云端不含任何账号信息）。
  Uint8List _localSettingsBytes() {
    final j = settingsProv!.s.toJson()
      ..removeWhere((k, _) =>
          k.startsWith('webdav') || k == 'ignoredUpdateVersion');
    return Uint8List.fromList(utf8.encode(jsonEncode(j)));
  }

  /// 应用远端设置。
  /// 普通模式：显示字段按 settingsUpdatedAt 新者胜；设备特有项保留本地。
  /// 覆盖模式（replace）：与来源设备完全一致（仅账号字段保留本地）。
  Future<void> _applyRemoteSettings(Uint8List bytes,
      {required bool replace}) async {
    if (settingsProv == null) return;
    try {
      final remote =
          AppSettings.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
      final local = settingsProv!.s;
      if (!replace && remote.settingsUpdatedAt <= local.settingsUpdatedAt) {
        return; // 本地设置更新，不回退
      }
      var merged = replace
          ? remote
          : remote.copyWith(
              // 设备特有项始终保留本地
              inputOnTop: local.inputOnTop,
              showSoftKeyboard: local.showSoftKeyboard,
              ignoredUpdateVersion: local.ignoredUpdateVersion,
              // 「同步时忽略布局」开启：练习页布局各设备各管各的，
              // 不跟随云端（layout/inputOnTop 本就含设备差异）
              layout: local.syncIgnoreLayout ? local.layout : null,
              layoutMode: local.syncIgnoreLayout ? local.layoutMode : null,
            );
      // 账号字段与设备特有开关始终保留本地（云端设置文件不含账号）
      merged = merged.copyWith(
        webdavUrl: local.webdavUrl,
        webdavUser: local.webdavUser,
        webdavPassword: local.webdavPassword,
        webdavBaseDir: local.webdavBaseDir,
        webdavAutoSync: local.webdavAutoSync,
        webdavSyncBooks: local.webdavSyncBooks,
        startupEnhanceSync: local.startupEnhanceSync,
        syncIgnoreLayout: local.syncIgnoreLayout,
      );
      await settingsProv!.applyRemote(merged);
    } catch (_) {}
  }

  List<PracticeSession> _parseSessions(Uint8List bytes) {
    final list = <PracticeSession>[];
    for (final line in utf8.decode(bytes).split('\n')) {
      final l = line.trim();
      if (l.isEmpty) continue;
      try {
        list.add(PracticeSession.fromJson(
            jsonDecode(l) as Map<String, dynamic>));
      } catch (_) {}
    }
    return list;
  }

  Map<String, int> _parseTombstones(Uint8List bytes) {
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final t = json['tombstones'] as Map<String, dynamic>? ?? const {};
      return t.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  File get _overwriteSeenFile =>
      File(p.join(_store.baseDir.path, 'data/overwrite_seen'));

  Future<void> _markOverwriteSeen(int ts) async {
    try {
      final f = _overwriteSeenFile;
      await f.parent.create(recursive: true);
      await f.writeAsString('$ts', flush: true);
    } catch (_) {}
  }

  /// 云端覆盖标记是否比本地已应用的更新（只检查，不消费）。
  Future<bool> _overwriteFlagPending(webdav.Client client, String base) async {
    try {
      final bytes = await _readRemote(client, '$base/data/overwrite.flag');
      if (bytes == null) return false;
      final ts = int.tryParse(utf8.decode(bytes).trim());
      if (ts == null) return false;
      var seen = 0;
      final f = _overwriteSeenFile;
      if (await f.exists()) {
        seen = int.tryParse((await f.readAsString()).trim()) ?? 0;
      }
      return ts > seen;
    } catch (_) {
      return false;
    }
  }

  /// 云端覆盖标记是否比本地已应用的更新；是则记下并返回 true（每台设备消费一次）。
  Future<bool> _consumeOverwriteFlag(
      webdav.Client client, String base) async {
    try {
      final bytes = await _readRemote(client, '$base/data/overwrite.flag');
      if (bytes == null) return false;
      final ts = int.tryParse(utf8.decode(bytes).trim());
      if (ts == null) return false;
      var seen = 0;
      final f = _overwriteSeenFile;
      if (await f.exists()) {
        seen = int.tryParse((await f.readAsString()).trim()) ?? 0;
      }
      if (ts <= seen) return false;
      await _markOverwriteSeen(ts);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 本次运行已确认存在的目录：避免每次上传前重复发 MKCOL/PROPFIND
  final Set<String> _ensuredDirs = {};

  Future<void> _ensureDir(webdav.Client client, String dir) async {
    if (_ensuredDirs.contains(dir)) return;
    final parts = dir.split('/').where((s) => s.isNotEmpty).toList();
    var cur = '';
    for (final part in parts) {
      cur += '/$part';
      try {
        await client.mkdir(cur);
      } catch (_) {
        // 已存在时会抛错，忽略
      }
    }
    _ensuredDirs.add(dir);
  }

  /// 递归列出远端目录下的所有文件。
  Future<List<webdav.File>> _listAll(
      webdav.Client client, String dir) async {
    final out = <webdav.File>[];
    try {
      final list = await client.readDir(dir);
      for (final f in list) {
        if (f.isDir ?? false) {
          out.addAll(await _listAll(client, f.path ?? ''));
        } else if ((f.path ?? '').isNotEmpty) {
          out.add(f);
        }
      }
    } catch (_) {
      // 目录不存在或列取失败：返回已收集的部分
    }
    return out;
  }

  Future<Uint8List?> _readRemote(
      webdav.Client client, String path) async {
    try {
      final data = await client.read(path);
      return Uint8List.fromList(data);
    } catch (_) {
      return null;
    }
  }
}
