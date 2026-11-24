import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/practice_session.dart';
import '../services/library_store.dart';
import '../services/stats_service.dart';
import '../services/webdav_sync.dart';
import '../state/settings_provider.dart';
import '../widgets/app_dialog.dart';

/// 统计报表：总览、近 14 天柱状图、书籍练习（按书名+作者聚合）。
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  PracticeSession? _lastDeleted;

  /// 删除后底部浮动提示 3 秒（与书架备份/还原提示同一位置），
  /// 新的删除会 clear + 重新显示，计时自动重置。
  void _deleteSession(PracticeSession s) {
    context.read<StatsService>().removeSession(s.id);
    _pushAfterMutation();
    _lastDeleted = s;
    _showToast(Text('已删除「${s.bookTitle} · ${s.chapterTitle}」'),
        action: SnackBarAction(label: '撤销', onPressed: _undoDelete));
  }

  void _undoDelete() {
    final s = _lastDeleted;
    if (s == null) return;
    _lastDeleted = null;
    context.read<StatsService>().restoreSession(s);
    _pushAfterMutation();
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
  }

  /// 删除/恢复统计后立即推送云端（墓碑与 sessions.jsonl 随之上传，
  /// 删除结果不会被其他设备的并集合并"复活"）。
  void _pushAfterMutation() {
    final s = context.read<SettingsProvider>().s;
    if (!s.webdavAutoSync || s.webdavUrl.trim().isEmpty) return;
    unawaited(context.read<WebDavSync>().pushProgress(s));
  }

  void _showToast(Widget content, {SnackBarAction? action}) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        backgroundColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.6)),
        ),
        action: action,
        content: DefaultTextStyle(
          style: theme.textTheme.bodyMedium!
              .copyWith(color: theme.colorScheme.onSurface),
          child: content,
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final stats = context.watch<StatsService>();
    final theme = Theme.of(context);
    final daily = stats.dailyCorrectChars(14);
    // 按书名+作者聚合全部练习记录（同名同作者的书合并为一本）
    final store = context.read<LibraryStore>();
    final groups = _buildGroups(stats.sessionsSnapshot, store);

    return Scaffold(
      appBar: AppBar(
        title: const Text('练习统计'),
        actions: [
          IconButton(
            tooltip: '清除全部练习记录',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _StatCard(
                    label: '累计抄录',
                    value: '${stats.totalCorrectChars}',
                    unit: '字',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    label: '累计时长',
                    value: _formatHours(stats.totalActiveMs),
                    unit: '',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _StatCard(
                    label: '总体正确率',
                    value:
                        '${(stats.overallAccuracy * 100).toStringAsFixed(1)}',
                    unit: '%',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    label: '练习次数',
                    value: stats.sessions.length.toString(),
                    unit: '次',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text('近 14 天抄录字数', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          _DailyBars(daily: daily),
          const SizedBox(height: 24),
          Text('书籍练习', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('暂无练习记录',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ),
            )
          else
            ...groups.map((g) => _BookGroupTile(
                  group: g,
                  onTap: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => _BookStatsPage(
                        group: g,
                        onDelete: (s) => _deleteSession(s),
                        onDeleteAll: () => _confirmDeleteGroup(g),
                      ),
                    ));
                  },
                  onLongPress: () => _confirmDeleteGroup(g),
                )),
        ],
      ),
    );
  }

  /// 长按书籍条目 / 书内页删除按钮：删除该书的全部练习记录
  /// （墨水屏弹窗无背景变化）。
  Future<void> _confirmDeleteGroup(_BookGroup g) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除练习记录'),
        content: Text(
            '「${g.title}」共 ${g.sessions.length} 条练习记录，\n'
            '累计时长与字数会同步扣减，确定删除吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      _deleteGroupSessions(g);
      setState(() {});
    }
  }

  /// 删除整本书的练习记录并推送云端，底部提示 3 秒。
  void _deleteGroupSessions(_BookGroup g) {
    context
        .read<StatsService>()
        .removeSessionsByIds(g.sessions.map((s) => s.id).toList());
    _pushAfterMutation();
    _showToast(Text('已删除「${g.title}」的 ${g.sessions.length} 条练习记录'));
  }

  /// 全部会话按（书名+作者）聚合；最近练过的书排最前。
  /// 同名同作者的多本书（重复导入/已删除）合并为一条：
  /// 已删书的记录按书名匹配到书架上同名著作的作者，归入同一组。
  List<_BookGroup> _buildGroups(
      Iterable<PracticeSession> sessions, LibraryStore store) {
    final bookById = {for (final b in store.books) b.id: b};
    // 书名 -> 作者（供已删书记录归组）
    final authorByTitle = <String, String>{};
    for (final b in store.books) {
      authorByTitle[b.title] = b.author;
    }
    final map = <String, _BookGroup>{};
    for (final s in sessions) {
      final b = bookById[s.bookId];
      final title = b?.title ?? s.bookTitle;
      final author = b?.author ?? authorByTitle[s.bookTitle] ?? '';
      final g = map.putIfAbsent(
          '$title\u0000$author', () => _BookGroup(title: title, author: author));
      g.sessions.add(s);
      if (b != null && g.book == null) g.book = b;
    }
    final list = map.values.toList()
      ..sort((a, b) => b.lastEndAt.compareTo(a.lastEndAt));
    return list;
  }

  String _formatHours(int ms) => _fmtHours(ms);

  Future<void> _confirmClear(BuildContext context) async {
    final stats = context.read<StatsService>();
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除练习记录'),
        content: const Text(
            '将删除全部练习统计（时长、字数、正确率、历史记录）。\n书籍与阅读进度不受影响。\n此操作不可恢复，确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await stats.clearSessions();
      if (mounted) setState(() {});
    }
  }
}

String _fmtHours(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return '$h 小时 $m 分';
}

/// 按（书名+作者）聚合的一本书的练习数据。
class _BookGroup {
  final String title;
  final String author;
  final List<PracticeSession> sessions = [];
  Book? book; // 仍在书架中的任一同名书（取封面用），删除后为 null

  _BookGroup({required this.title, required this.author});

  int get totalMs => sessions.fold(0, (m, s) => m + s.activeMs);
  int get totalChars =>
      sessions.fold(0, (m, s) => m + s.correctChars);
  DateTime get lastEndAt => sessions
      .map((s) => s.endAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);
}

/// 书籍练习条目：缩小版封面 + 书名 + 次数与总时长。
class _BookGroupTile extends StatelessWidget {
  final _BookGroup group;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _BookGroupTile({
    required this.group,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = Provider.of<LibraryStore>(context, listen: false);
    final coverFile = group.book == null ? null : store.coverFile(group.book!);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            width: 44,
            height: 62,
            child: coverFile != null
                ? Image.file(
                    coverFile,
                    fit: BoxFit.cover,
                    // 缩略图按小尺寸解码，避免大封面拖慢列表
                    cacheWidth: 132,
                    gaplessPlayback: true,
                  )
                : Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(Icons.auto_stories,
                        size: 22, color: theme.colorScheme.outline),
                  ),
          ),
        ),
        title: Text(group.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${group.author.isEmpty ? '佚名' : group.author} · '
          '${group.sessions.length} 次练习 · 抄录 ${group.totalChars} 字',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          _fmtHours(group.totalMs),
          style: theme.textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// 单本书的练习历史：每一次会话一条，可左滑/长按删除；
/// 右上角按钮删除本书全部记录。
class _BookStatsPage extends StatefulWidget {
  final _BookGroup group;
  final void Function(PracticeSession) onDelete;
  final VoidCallback onDeleteAll;

  const _BookStatsPage({
    required this.group,
    required this.onDelete,
    required this.onDeleteAll,
  });

  @override
  State<_BookStatsPage> createState() => _BookStatsPageState();
}

class _BookStatsPageState extends State<_BookStatsPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final df = DateFormat('yyyy年M月d日');
    // 实时取自统计服务：单条/整书删除后列表立即刷新
    final ids = widget.group.sessions.map((s) => s.id).toSet();
    final sessions = context
        .watch<StatsService>()
        .sessionsSnapshot
        .where((s) => ids.contains(s.id))
        .toList();
    final totalMs = sessions.fold(0, (m, s) => m + s.activeMs);
    final totalChars = sessions.fold(0, (m, s) => m + s.correctChars);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.group.title, maxLines: 1),
        actions: [
          IconButton(
            tooltip: '删除本书全部练习记录',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: widget.onDeleteAll,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${widget.group.author.isEmpty ? '佚名' : widget.group.author}\n'
            '共 ${sessions.length} 次练习 · '
            '累计 ${_fmtHours(totalMs)} · '
            '抄录 $totalChars 字',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline, height: 1.5),
          ),
          const SizedBox(height: 12),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('该书的练习记录已清空',
                    style: TextStyle(color: theme.colorScheme.outline)),
              ),
            )
          else ...[
            ...sessions.map((s) => _SwipeSessionTile(
                  // key 隔离各条目状态：删除后打开状态不会串到下一条
                  key: ValueKey(s.id),
                  session: s,
                  onDelete: () => widget.onDelete(s),
                )),
            const SizedBox(height: 8),
            Center(
              child: Text(
                '记录自 ${df.format(sessions.last.startAt)} 起',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 左滑删除：轻滑停留显示删除按钮（点击删除），滑到底/快速滑动直接删除。
class _SwipeSessionTile extends StatefulWidget {
  final PracticeSession session;
  final VoidCallback onDelete;

  const _SwipeSessionTile({
    super.key,
    required this.session,
    required this.onDelete,
  });

  @override
  State<_SwipeSessionTile> createState() => _SwipeSessionTileState();
}

class _SwipeSessionTileState extends State<_SwipeSessionTile> {
  static const _buttonWidth = 72.0;
  double _dx = 0;

  void _confirmDelete(BuildContext context) {
    showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该条记录'),
        content: Text(
            '「${widget.session.bookTitle} · ${widget.session.chapterTitle}」\n'
            '删除后累计时长与字数会同步扣减，可在 3 秒内撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok == true) widget.onDelete();
    });
  }

  /// 单击条目：显示这条练习的起止时间与数据。
  void _showDetail(BuildContext context) {
    final s = widget.session;
    final df = DateFormat('yyyy年M月d日 HH:mm');
    showAppDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s.bookTitle} · ${s.chapterTitle}',
            maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Text(
            '从 ${df.format(s.startAt)}\n'
            '练习到 ${df.format(s.endAt)}\n\n'
            '持续 ${_fmtHours(s.activeMs)} · 抄录 ${s.correctChars} 字\n'
            '正确率 ${(s.accuracy * 100).toStringAsFixed(1)}% · '
            '${s.charsPerMinute.toStringAsFixed(0)} 字/分'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.session;
    return Stack(children: [
      // 左滑时露出的红色删除背景
      Positioned.fill(
        child: ColoredBox(
          color: theme.colorScheme.error,
          child: const Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: EdgeInsets.only(right: 24),
              child: Icon(Icons.delete_outline, color: Colors.white),
            ),
          ),
        ),
      ),
      GestureDetector(
        onLongPress: () => _confirmDelete(context),
        onTap: () => _showDetail(context),
        onHorizontalDragUpdate: (d) {
          setState(() {
            _dx = (_dx + d.delta.dx).clamp(-_buttonWidth - 40, 0.0);
          });
        },
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (_dx < -_buttonWidth * 0.6 || v < -450) {
            widget.onDelete(); // 左滑删除：滑过 60% 或快速滑动
          } else {
            setState(() => _dx = 0); // 未达阈值：弹回
          }
        },
        child: Transform.translate(
          offset: Offset(_dx, 0),
          child: ColoredBox(
            color: theme.colorScheme.surface,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_edu),
              title: Text('${s.bookTitle} · ${s.chapterTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${DateFormat('MM-dd HH:mm').format(s.endAt)} · '
                '${s.correctChars} 字 · '
                '${(s.accuracy * 100).toStringAsFixed(1)}% · '
                '${s.charsPerMinute.toStringAsFixed(0)} 字/分',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: SizedBox(
                width: 76,
                child: Text(
                  _fmtHours(s.activeMs),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 6),
            // 数值自动缩放，长文本（如"9 小时 2 分"）不换行
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: RichText(
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: value,
                      style: theme.textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    TextSpan(
                      text: ' $unit',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 简单柱状图（CustomPaint，墨水屏友好：纯色块无动画）。
class _DailyBars extends StatelessWidget {
  final Map<DateTime, int> daily;

  const _DailyBars({required this.daily});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxVal =
        daily.values.fold<int>(1, (m, v) => v > m ? v : m);
    final df = DateFormat('MM/dd');
    return SizedBox(
      height: 140,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: daily.entries.map((e) {
          final h = e.value / maxVal;
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    e.value == 0 ? '' : '${e.value}',
                    style: theme.textTheme.labelSmall,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 2),
                  Container(
                    height: (h * 90).clamp(2, 90).toDouble(),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary
                          .withValues(alpha: e.value == 0 ? 0.15 : 0.8),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(df.format(e.key),
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 9,
                        color: theme.colorScheme.outline,
                      )),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
