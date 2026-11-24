import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/practice_session.dart';
import 'library_store.dart';

/// 练习统计：sessions.jsonl 追加式存储，按 sessionId 去重合并。
/// ChangeNotifier：同步合并/删除/恢复后通知界面即时刷新。
class StatsService extends ChangeNotifier {
  final LibraryStore _store;
  final List<PracticeSession> _sessions = [];

  /// 删除墓碑：sessionId -> 删除时间戳。
  /// 删除记录只改本地会被云端 sessions.jsonl 的并集合并"复活"；
  /// 墓碑随同步传播，合并时跳过被标记的记录，删除才能跨设备生效。
  Map<String, int> _tombstones = {};

  StatsService(this._store);

  List<PracticeSession> get sessions => List.unmodifiable(_sessions);

  Map<String, int> get tombstonesSnapshot => Map.of(_tombstones);

  File get _sessionsFile =>
      File(p.join(_store.baseDir.path, 'data/sessions.jsonl'));

  File get _tombstonesFile =>
      File(p.join(_store.baseDir.path, 'data/deleted_sessions.json'));

  Future<void> load() async {
    await _loadTombstones();
    _sessions.clear();
    final f = _sessionsFile;
    if (await f.exists()) {
      try {
        for (final line in await f.readAsLines()) {
          final l = line.trim();
          if (l.isEmpty) continue;
          try {
            _sessions.add(PracticeSession.fromJson(
              jsonDecode(l) as Map<String, dynamic>,
            ));
          } catch (_) {}
        }
      } catch (_) {}
    }
    // 本地仍存在的墓碑记录先移除（自愈）
    _sessions.removeWhere((s) => _tombstones.containsKey(s.id));
  }

  Future<void> _loadTombstones() async {
    final f = _tombstonesFile;
    if (await f.exists()) {
      try {
        final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        final t = json['tombstones'] as Map<String, dynamic>? ?? const {};
        _tombstones = t.map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (_) {
        _tombstones = {};
      }
    }
    _pruneTombstones();
  }

  /// 墓碑保留一年，过期的直接丢弃（对应记录早已不在任何设备上）。
  void _pruneTombstones() {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch - 365 * 24 * 3600 * 1000;
    _tombstones.removeWhere((_, ts) => ts < cutoff);
  }

  Future<void> _saveTombstones() async {
    final f = _tombstonesFile;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode({'tombstones': _tombstones}),
        flush: true);
  }

  void _tombstoneAll(Iterable<String> ids) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      _tombstones[id] = now;
    }
  }

  Future<void> addSession(PracticeSession s) async {
    _sessions.add(s);
    final f = _sessionsFile;
    await f.parent.create(recursive: true);
    await f.writeAsString('${s.toLine()}\n',
        mode: FileMode.append, flush: true);
    notifyListeners();
  }

  /// 清空全部练习记录（不影响书籍与阅读进度）。
  Future<void> clearSessions() async {
    _tombstoneAll(_sessions.map((s) => s.id));
    await _saveTombstones();
    _sessions.clear();
    final f = _sessionsFile;
    if (await f.exists()) {
      await f.delete();
    }
    notifyListeners();
  }

  /// 删除单条记录（累计时长/字数等由记录推导，删除即扣减）。
  Future<void> removeSession(String id) async {
    _sessions.removeWhere((s) => s.id == id);
    _tombstoneAll([id]);
    await _saveTombstones();
    await _saveAll();
    notifyListeners();
  }

  /// 批量删除（按 id）：一次落盘，用于删除某本书的全部练习记录。
  Future<void> removeSessionsByIds(List<String> ids) async {
    final set = ids.toSet();
    _sessions.removeWhere((s) => set.contains(s.id));
    _tombstoneAll(set);
    await _saveTombstones();
    await _saveAll();
    notifyListeners();
  }

  /// 恢复一条被删除的记录（误删撤销）：同时撤销墓碑。
  Future<void> restoreSession(PracticeSession s) async {
    _tombstones.remove(s.id);
    await _saveTombstones();
    if (_sessions.any((x) => x.id == s.id)) return;
    _sessions.add(s);
    await _saveAll();
    notifyListeners();
  }

  /// 应用远端删除标记：本地被标记的记录移除；此后合并会跳过这些 id。
  Future<void> applyRemoteTombstones(Map<String, int> remote) async {
    var changed = false;
    remote.forEach((id, ts) {
      if (ts > (_tombstones[id] ?? 0)) {
        _tombstones[id] = ts;
        changed = true;
      }
    });
    _pruneTombstones();
    final before = _sessions.length;
    _sessions.removeWhere((s) => _tombstones.containsKey(s.id));
    if (_sessions.length != before) changed = true;
    if (!changed) return;
    await _saveTombstones();
    await _saveAll();
    notifyListeners();
  }

  /// 用给定记录整体替换本地统计（覆盖同步标记生效时使用，与来源设备完全一致）。
  Future<void> replaceSessions(List<PracticeSession> list) async {
    _sessions
      ..clear()
      ..addAll(list);
    await _saveAll();
    notifyListeners();
  }

  Future<void> _saveAll() async {
    _sessions.sort((a, b) => a.endAt.compareTo(b.endAt));
    final f = _sessionsFile;
    await f.parent.create(recursive: true);
    await f.writeAsString(
      '${_sessions.map((s) => s.toLine()).join('\n')}${_sessions.isEmpty ? '' : '\n'}',
      flush: true,
    );
  }

  /// 与远端会话合并：按 id 去重取并集（跳过墓碑记录），按 endAt 排序。
  Future<void> mergeSessions(List<PracticeSession> remote) async {
    // 本地墓碑记录先移除（其他设备删除的记录同步到本地后即时消失）
    _sessions.removeWhere((s) => _tombstones.containsKey(s.id));
    final byId = <String, PracticeSession>{};
    for (final s in _sessions) {
      byId[s.id] = s;
    }
    var changed = false;
    for (final s in remote) {
      if (_tombstones.containsKey(s.id)) continue;
      if (!byId.containsKey(s.id)) {
        byId[s.id] = s;
        changed = true;
      }
    }
    if (!changed) return;
    _sessions
      ..clear()
      ..addAll(byId.values.toList()
        ..sort((a, b) => a.endAt.compareTo(b.endAt)));
    final f = _sessionsFile;
    await f.writeAsString(
      '${_sessions.map((s) => s.toLine()).join('\n')}\n',
      flush: true,
    );
    notifyListeners();
  }

  List<PracticeSession> get sessionsSnapshot {
    final list = List<PracticeSession>.from(_sessions);
    list.sort((a, b) => b.endAt.compareTo(a.endAt));
    return list;
  }

  // ---------- 聚合 ----------
  int get totalCorrectChars =>
      _sessions.fold(0, (s, e) => s + e.correctChars);

  int get totalActiveMs => _sessions.fold(0, (s, e) => s + e.activeMs);

  double get overallAccuracy {
    final c = _sessions.fold(0, (s, e) => s + e.correctChars);
    final err = _sessions.fold(0, (s, e) => s + e.errorCount);
    final total = c + err;
    return total == 0 ? 1.0 : c / total;
  }

  /// 最近 n 天每日正确字数。
  Map<DateTime, int> dailyCorrectChars(int days) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final map = <DateTime, int>{};
    for (int i = days - 1; i >= 0; i--) {
      map[today.subtract(Duration(days: i))] = 0;
    }
    for (final s in _sessions) {
      final d = DateTime(s.endAt.year, s.endAt.month, s.endAt.day);
      if (map.containsKey(d)) {
        map[d] = map[d]! + s.correctChars;
      }
    }
    return map;
  }
}
