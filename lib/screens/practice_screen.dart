import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../state/practice_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dict_sheet.dart';
import '../widgets/input_pane.dart';
import '../widgets/original_pane.dart';
import '../widgets/typography_controls.dart';

/// 抄书练习主界面：左右分栏（可切上下），左原文右输入。
class PracticeScreen extends StatefulWidget {
  final Book book;
  final int chapterIndex;

  const PracticeScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
  });

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends State<PracticeScreen>
    with WidgetsBindingObserver {
  bool _dialogShown = false;
  bool _chapterStarted = false;
  PracticeProvider? _practice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 本次进入抄书页：跨章节累计的「本次 N 字」清零
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _practice?.beginVisit();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _practice?.endSession();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final practice = _practice;
    if (practice == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      practice.pause();
    } else if (state == AppLifecycleState.resumed) {
      practice.resume();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _practice ??= context.read<PracticeProvider>();
    if (!_chapterStarted) {
      _chapterStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _practice!.startChapter(widget.book, widget.chapterIndex);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final practice = context.watch<PracticeProvider>();
    final settings = context.watch<SettingsProvider>();
    final theme = Theme.of(context);
    // 章节完成弹窗
    if (practice.chapterCompleted && !_dialogShown) {
      _dialogShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCompleteDialog(context, practice);
      });
    }
    if (!practice.chapterCompleted) {
      _dialogShown = false;
    }

    final mode = settings.s.layoutMode.clamp(0, 3);
    final vertical = mode <= 1;
    final title = practice.hasBook
        ? practice.chapterTitle
        : widget.book.chapterTitles[widget.chapterIndex];

    return Scaffold(
        appBar: AppBar(
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // 标题跟随用户设置的字体
            style: theme.textTheme.titleMedium?.copyWith(
              fontFamily: settings.s.fontFamily.isEmpty
                  ? null
                  : settings.s.fontFamily,
              fontSize: (settings.s.fontSize - 1)
                  .clamp(14, 24)
                  .toDouble(),
            ),
          ),
          actions: [
            IconButton(
              tooltip: practice.isPaused ? '继续（暂停中不计时间）' : '暂停（不计时间）',
              icon: Icon(practice.isPaused
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded),
              onPressed: practice.togglePause,
            ),
            IconButton(
              tooltip: '排版设置（字体/字号/行距）',
              icon: const Icon(Icons.format_size),
              onPressed: () => _showTypographySheet(context, settings),
            ),
            IconButton(
              tooltip: '字典（查字/词释义）',
              icon: const Icon(Icons.translate),
              onPressed: () =>
                  showDictSheet(context, initialQuery: practice.stuckChar),
            ),
            IconButton(
              tooltip: '切换布局',
              icon: Icon(mode <= 1
                  ? Icons.view_agenda_outlined
                  : Icons.view_column_outlined),
              onPressed: () async {
                final v = await showAppMenu<String>(
                  context: context,
                  initialValue: '${settings.s.layoutMode}',
                  items: const [
                    AppMenuItem('0', '上抄书 · 下原文',
                        icon: Icons.vertical_align_top),
                    AppMenuItem('1', '上原文 · 下抄书',
                        icon: Icons.vertical_align_bottom),
                    AppMenuItem('2', '左抄书 · 右原文',
                        icon: Icons.flip_to_front),
                    AppMenuItem('3', '左原文 · 右抄书',
                        icon: Icons.flip_to_back),
                  ],
                );
                if (v == null) return;
                settings.update(
                    (s) => s.copyWith(layoutMode: int.tryParse(v) ?? 1));
              },
            ),
          ],
        ),
        body: SafeArea(
          child: !practice.hasBook
              ? const Center(child: CircularProgressIndicator())
              : Container(
                  color: _paneColor(context, settings),
                  child: Column(
                    children: [
                      _infoBar(context, practice, settings),
                      Divider(height: 1, color: theme.dividerColor),
                      Expanded(
                        child: vertical
                            ? _verticalSplit(context, practice, settings, mode)
                            : _horizontalSplit(
                                context, practice, settings, mode),
                      ),
                    ],
                  ),
                ),
        ),
    );
  }

  /// 统计信息条：横向可滚动，手机端不与标题/按钮挤在一起。
  /// 计时徽标用 ValueListenableBuilder 局部刷新，避免整页每秒重建。
  Widget _infoBar(BuildContext context, PracticeProvider practice,
      SettingsProvider settings) {
    return SizedBox(
      height: 44,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '上一段',
              icon: const Icon(Icons.skip_previous_outlined, size: 20),
              onPressed: practice.paragraphIndex > 0
                  ? () => practice
                      .jumpToParagraph(practice.paragraphIndex - 1)
                  : null,
            ),
            _StatChip(
              label: practice.totalParagraphs > 0
                  ? '段 ${practice.paragraphIndex + 1}/${practice.totalParagraphs}'
                  : '段 -',
              icon: Icons.segment,
            ),
            ValueListenableBuilder<int>(
              valueListenable: practice.ticker,
              builder: (context, activeMs, _) {
                return _StatChip(
                  label: practice.isPaused
                      ? '已暂停 ${_formatDuration(activeMs)}'
                      : _formatDuration(activeMs),
                  icon: practice.isPaused
                      ? Icons.pause_circle_outline
                      : Icons.timer_outlined,
                  highlight: practice.isPaused,
                );
              },
            ),
            _StatChip(
              label: '${practice.charsPerMinute.toStringAsFixed(0)} 字/分',
              icon: Icons.speed,
            ),
            _StatChip(
              label: '${(practice.accuracy * 100).toStringAsFixed(1)}%',
              icon: Icons.check_circle_outline,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '下一段',
              icon: const Icon(Icons.skip_next_outlined, size: 20),
              onPressed: practice.paragraphIndex <
                      practice.totalParagraphs - 1
                  ? () => practice
                      .jumpToParagraph(practice.paragraphIndex + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showTypographySheet(
      BuildContext context, SettingsProvider settings) async {
    _practice?.overlayOpen = true;
    try {
      await showAppBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题行：标题居左，关闭按钮居右
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('排版设置',
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold)),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '关闭',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                TypographyControls(settings: settings),
                const SizedBox(height: 8),
                Text(
                  '提示：连续两次空格可输入句号',
                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                      color: Theme.of(ctx).colorScheme.outline),
                ),
              ],
            ),
          ),
        ),
      ),
      );
    } finally {
      _practice?.overlayOpen = false;
    }
  }

  /// 上下分栏：mode 0 输入在上（抄书上），mode 1 原文在上。
  Widget _verticalSplit(BuildContext context, PracticeProvider practice,
      SettingsProvider settings, int mode) {
    final original = _original(context, practice, settings);
    final input = _input(context, practice, settings);
    final inputTop = mode == 0;
    return Column(
      children: [
        Expanded(child: inputTop ? input : original),
        const Divider(height: 1),
        Expanded(child: inputTop ? original : input),
      ],
    );
  }

  /// 左右分栏：mode 2 输入在左（抄书左），mode 3 原文在左。
  /// 手机端输入框宽度收敛（最长 480），方框不会拉得过长。
  Widget _horizontalSplit(BuildContext context, PracticeProvider practice,
      SettingsProvider settings, int mode) {
    final original = _original(context, practice, settings);
    Widget input = _input(context, practice, settings);
    final mq = MediaQuery.of(context);
    if (mq.size.width < 600) {
      input = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: input,
        ),
      );
    }
    final inputLeft = mode == 2;
    return Row(
      children: [
        Expanded(child: inputLeft ? input : original),
        const VerticalDivider(width: 1),
        Expanded(child: inputLeft ? original : input),
      ],
    );
  }

  Widget _original(BuildContext context, PracticeProvider practice,
      SettingsProvider settings) {
    return OriginalPane(
      paragraphs: practice.paragraphs,
      currentIndex: practice.paragraphIndex,
      engine: practice.engine,
      settings: settings,
    );
  }

  Widget _input(BuildContext context, PracticeProvider practice,
      SettingsProvider settings) {
    return InputPane(
      controller: practice.textController,
      engine: practice.engine,
      settings: settings,
      waitingAdvance: practice.waitingAdvance,
      chapterCompleted: practice.chapterCompleted,
      sessionChars: practice.sessionChars,
      stuckSeconds: practice.stuckSeconds,
      onAutoType: practice.typeStuckChar,
      onDictLookup: (ch) =>
          showDictSheet(context, initialQuery: ch),
      onChanged: (_) =>
          practice.onTextChanged(practice.textController.value),
      onAdvance: practice.advanceParagraph,
    );
  }

  Color _paneColor(BuildContext context, SettingsProvider settings) {
    final brightness = Theme.of(context).brightness;
    return paneBackgroundFor(settings.s.paneBackground, brightness);
  }

  String _formatDuration(int ms) {
    final totalSec = ms ~/ 1000;
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _showCompleteDialog(BuildContext context, PracticeProvider practice) {
    final practice2 = practice;
    practice2.overlayOpen = true;
    showAppDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('本章完成'),
          content: Text(
            '《${practice2.book?.title ?? ''}》\n'
            '${practice2.chapterTitle}\n\n'
            '用时 ${_formatDuration(practice2.elapsedActiveMs)}\n'
            '抄录 ${practice2.correctCharsTotal} 字\n'
            '正确率 ${(practice2.accuracy * 100).toStringAsFixed(1)}%\n'
            '速度 ${practice2.charsPerMinute.toStringAsFixed(0)} 字/分',
          ),
          actions: [
            TextButton(
              onPressed: () {
                practice2.overlayOpen = false;
                Navigator.of(ctx).pop();
                Navigator.of(context).pop(); // 返回章节列表
              },
              child: const Text('返回目录'),
            ),
            FilledButton(
              onPressed: () {
                practice2.overlayOpen = false;
                Navigator.of(ctx).pop();
                // 下一章
                final nextIdx = widget.chapterIndex + 1;
                if (nextIdx < widget.book.chapterTitles.length) {
                  practice2.startChapter(widget.book, nextIdx);
                  _dialogShown = false;
                } else {
                  Navigator.of(context).pop(); // 已是最后一章
                }
              },
              child: const Text('下一章'),
            ),
          ],
        );
      },
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool highlight;

  const _StatChip({
    required this.label,
    required this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
