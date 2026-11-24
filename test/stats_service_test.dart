import 'dart:convert';
import 'dart:io';

import 'package:chaoshu/models/practice_session.dart';
import 'package:chaoshu/services/library_store.dart';
import 'package:chaoshu/services/stats_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

PracticeSession session(String id, {int endAtMs = 1000}) => PracticeSession(
      id: id,
      bookId: 'b1',
      bookTitle: '书一',
      chapterIndex: 0,
      chapterTitle: '第一章',
      startAt: DateTime.fromMillisecondsSinceEpoch(endAtMs - 60000),
      endAt: DateTime.fromMillisecondsSinceEpoch(endAtMs),
      activeMs: 60000,
      correctChars: 100,
      errorCount: 2,
      backspaceCount: 3,
    );

void main() {
  late Directory temp;
  late LibraryStore store;
  late StatsService stats;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('chaoshu_stats_test');
    store = LibraryStore(baseDirOverride: temp);
    await store.init();
    stats = StatsService(store);
    await stats.load();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('删除单条记录写入墓碑，重启后不再出现', () async {
    await stats.addSession(session('s1'));
    await stats.addSession(session('s2', endAtMs: 2000));
    await stats.removeSession('s1');
    expect(stats.sessions.map((s) => s.id), ['s2']);
    expect(stats.tombstonesSnapshot.keys, contains('s1'));

    // 模拟应用重启
    final stats2 = StatsService(store);
    await stats2.load();
    expect(stats2.sessions.map((s) => s.id), ['s2']);
    expect(stats2.tombstonesSnapshot.keys, contains('s1'));
  });

  test('mergeSessions 跳过墓碑记录（删除不会被云端并集复活）', () async {
    await stats.addSession(session('s1'));
    await stats.removeSession('s1');
    // 云端仍有 s1（旧版本上传的 sessions.jsonl）
    await stats.mergeSessions([session('s1')]);
    expect(stats.sessions, isEmpty);
  });

  test('applyRemoteTombstones：其他设备删除的记录在本地即时消失', () async {
    await stats.addSession(session('s1'));
    await stats.addSession(session('s2', endAtMs: 2000));
    final now = DateTime.now().millisecondsSinceEpoch;
    await stats.applyRemoteTombstones({'s1': now});
    expect(stats.sessions.map((s) => s.id), ['s2']);
    expect(stats.tombstonesSnapshot['s1'], now);

    // 旧时间戳的墓碑不覆盖新时间戳
    await stats.applyRemoteTombstones({'s2': 1});
    expect(stats.sessions.map((s) => s.id), ['s2']);
  });

  test('restoreSession 撤销删除并撤销墓碑', () async {
    await stats.addSession(session('s1'));
    await stats.removeSession('s1');
    expect(stats.tombstonesSnapshot.keys, contains('s1'));
    final s1 = session('s1');
    await stats.restoreSession(s1);
    expect(stats.sessions.map((s) => s.id), contains('s1'));
    expect(stats.tombstonesSnapshot.keys, isNot(contains('s1')));

    // 重启后记录仍在
    final stats2 = StatsService(store);
    await stats2.load();
    expect(stats2.sessions.map((s) => s.id), contains('s1'));
  });

  test('clearSessions 为全部记录写墓碑', () async {
    await stats.addSession(session('s1'));
    await stats.addSession(session('s2', endAtMs: 2000));
    await stats.clearSessions();
    expect(stats.sessions, isEmpty);
    expect(stats.tombstonesSnapshot.keys, containsAll(['s1', 's2']));
    // 墓碑文件已落盘
    final f = File(p.join(temp.path, 'chaoshu_data', 'data',
        'deleted_sessions.json'));
    expect(f.existsSync(), isTrue);
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    expect((json['tombstones'] as Map).keys, containsAll(['s1', 's2']));
  });
}
