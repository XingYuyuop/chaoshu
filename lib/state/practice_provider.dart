import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/typing_engine.dart';
import '../models/book.dart';
import '../models/practice_session.dart';
import '../services/library_store.dart';
import '../services/stats_service.dart';
import '../services/text_utils.dart';
import '../services/zh_conv.dart';
import 'settings_provider.dart';

/// 单章练习编排：段落推进、引擎管理、会话计时、进度保存、统计上报。
class PracticeProvider extends ChangeNotifier {
  final LibraryStore store;
  final StatsService stats;
  final SettingsProvider settings;

  Book? book;
  int chapterIndex = 0;
  String chapterTitle = '';
  List<String> paragraphs = const [];

  int paragraphIndex = 0;
  TypingEngine? engine;
  final textController = TextEditingController();

  // 会话计时
  DateTime? _startAt;
  int _activeMs = 0;
  Timer? _tickTimer;
  DateTime _lastTick = DateTime.now();
  bool _paused = false;
  DateTime _lastInputAt = DateTime.now(); // 最近一次输入时间（60 秒无输入自动暂停）
  bool get isPaused => _paused;
  // 章节加载中（startChapter 的拉取/读章 await 窗口）：此期间
  // pause/endSession 不得用旧章节的 engine/断点写新 chapterIndex
  bool _loadingChapter = false;

  /// 手动暂停/继续：暂停期间不计入练习时长。
  void togglePause() {
    if (_paused) {
      resume();
    } else {
      pause();
    }
    ticker.value = _activeMs;
    notifyListeners();
  }

  /// 弹窗/底部面板打开时置 true：禁用全局空格跳字。
  bool overlayOpen = false;

  int correctCharsTotal = 0;
  // 本次进入抄书页实际敲入的字数（跨章节累计、进入抄书页清零）。
  // 只按打字时 confirmedLength 的正向增量计数——断点恢复的进度
  // 不计入，如实反映"这次打了多少字"
  int visitTypedChars = 0;
  int errorTotal = 0;
  int backspaceTotal = 0;

  /// 当前段是否等待回车继续（autoAdvance 关闭时）。
  bool waitingAdvance = false;

  /// 章节是否完成（触发完成弹窗）。
  bool chapterCompleted = false;

  /// 会话结束钩子（main 中接 WebDAV 自动同步）。
  Future<void> Function()? onSessionEnd;

  /// 轻量进度推送钩子（main 中接 WebDavSync.pushProgress）。
  Future<void> Function()? onPushProgress;

  /// 轻量进度拉取钩子（main 中接 WebDavSync.pullProgress）。
  Future<void> Function()? onPullProgress;

  // ---------- 打字期间自动推送进度 ----------
  // 打字期间每 30 秒推送一次进度；暂停立即停止推送（暂停前先传一次）；
  // 恢复打字重新启动周期；退出打字页时再全量上传一次。
  Timer? _pushTimer;

  // ---------- 双空格出句号 ----------
  // 输入法自带的「两下空格出句号」在本应用无法生效：目标段无空白、
  // 引擎忽略输入空白，且程序化回写会打断输入法的连击判定。
  // 在应用层复刻该习惯：组词外连续两次空格（400ms 内）注入「。」，
  // 交由引擎按原文判定（原文此处是句号则确认，否则按错字提示）。
  static const _doubleSpaceWindow = Duration(milliseconds: 400);
  DateTime? _lastSpaceAt;

  void _noteTypingActivity() {
    if (!settings.s.webdavAutoSync) return;
    if (settings.s.webdavUrl.trim().isEmpty) return;
    if (_paused) return;
    _pushTimer ??= Timer.periodic(
        const Duration(seconds: 30), (_) => _onPushTick());
  }

  void _onPushTick() {
    // 推送前落账当前断点（含段中已输字数），其他设备可恢复到字级
    _saveProgress(completed: chapterCompleted);
    onPushProgress?.call();
  }

  bool get hasBook => book != null;
  bool get isLastParagraph => paragraphIndex >= paragraphs.length - 1;
  int get totalParagraphs => paragraphs.length;

  PracticeProvider(this.store, this.stats, this.settings);

  /// 打开章节：优先从断点恢复。
  Future<void> startChapter(Book b, int chIndex) async {
    // 切章节：仅落账上一章会话，不触发全量同步（轻推送会带上统计）
    await endSession(notifySync: false);

    _loadingChapter = true;
    paragraphs = const [];
    paragraphIndex = 0;

    // 自动同步开启时，打开章节前轻量拉取远端最新断点（多设备免手动同步）
    try {
      if (settings.s.webdavAutoSync &&
          settings.s.webdavUrl.trim().isNotEmpty) {
        try {
          await onPullProgress
              ?.call()
              .timeout(const Duration(seconds: 6), onTimeout: () {});
        } catch (_) {}
      }

      book = b;
      chapterIndex = chIndex;
      chapterTitle = chIndex < b.chapterTitles.length
          ? b.chapterTitles[chIndex]
          : '第 ${chIndex + 1} 章';
      // 书架排序：最近练习的书排最前
      store.touchBook(b.id);
      paragraphs = await store.readChapter(b.id, chIndex);
      if (paragraphs.isEmpty) paragraphs = ['（本章无内容）'];

      // 简繁转换（练习字形设置）：default 不变 / s 繁→简 / t 简→繁
      if (settings.s.charVariant == 't') {
        paragraphs = paragraphs.map(ZhConv.toTraditional).toList();
        chapterTitle = ZhConv.toTraditional(chapterTitle);
      } else if (settings.s.charVariant == 's') {
        paragraphs = paragraphs.map(ZhConv.toSimplified).toList();
        chapterTitle = ZhConv.toSimplified(chapterTitle);
      }

      final cp = store.progressOf(b.id).chapters[chIndex];
      if (cp != null && cp.completed) {
        // 已完成章节从头开始（重抄）
        paragraphIndex = 0;
      } else if (cp != null) {
        paragraphIndex = cp.paragraphIndex.clamp(0, paragraphs.length - 1);
      } else {
        paragraphIndex = 0;
      }

      correctCharsTotal = 0;
      errorTotal = 0;
      backspaceTotal = 0;
      chapterCompleted = false;
      waitingAdvance = false;

      _startSession();
      _loadParagraph(restoreCharIndex: cp?.charIndex ?? 0, restore: cp != null && !cp.completed && cp.charIndex > 0);
    } finally {
      // 无论成功失败都要复位：否则中途异常会让进度写入永久失效
      _loadingChapter = false;
    }
    notifyListeners();
  }

  void _startSession() {
    _startAt = DateTime.now();
    _activeMs = 0;
    _lastTick = DateTime.now();
    _paused = false;
    _lastInputAt = DateTime.now();
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _flushTick();
      _checkIdlePause();
      _updateStuck();
      // 只更新计时 Notifier，不通知整页重建（墨水屏防频闪 / 省电）
      ticker.value = _activeMs;
    });
  }

  // ---------- 猜你想输入 ----------
  // 当前字长时间（≥20 秒）无进展时，在输入框上方提示可自动输入该字。
  // 用 ValueNotifier 局部刷新，避免每秒整页重建（墨水屏防频闪）。
  final ValueNotifier<int> stuckSeconds = ValueNotifier(0);
  DateTime _lastProgressAt = DateTime.now();
  // 打字进展后的提示隐藏冷却期：自动输入后即使 1 秒 tick 先到，
  // 冷却期内也强制隐藏，杜绝"下一个字"提示闪现
  DateTime _stuckHideUntil = DateTime.fromMillisecondsSinceEpoch(0);

  void _updateStuck() {
    final e = engine;
    int s = 0;
    if (e != null &&
        !_paused &&
        !waitingAdvance &&
        !chapterCompleted &&
        !e.isDone &&
        e.composing.isEmpty &&
        book != null) {
      s = DateTime.now().difference(_lastProgressAt).inSeconds;
    }
    if (DateTime.now().isBefore(_stuckHideUntil)) s = 0;
    if (stuckSeconds.value != s) stuckSeconds.value = s;
  }

  /// 统计本次实际敲入字数（confirmedLength 正向增量；断点恢复、
  /// 段落切换引起的回退/清零不计）并推进卡字计时基准。
  void _countTypedDelta(int prevConfirmed) {
    final e = engine!;
    if (e.confirmedLength != prevConfirmed) {
      _lastProgressAt = DateTime.now();
      // 立即隐藏「猜你想输入」提示并进入 2 秒冷却期
      _stuckHideUntil = DateTime.now().add(const Duration(seconds: 2));
      stuckSeconds.value = 0;
      if (e.confirmedLength > prevConfirmed) {
        visitTypedChars += e.confirmedLength - prevConfirmed;
      }
    }
  }

  /// 当前等待输入的字（用于「猜你想输入」提示与字典查询）。
  String? get stuckChar {
    final e = engine;
    if (e == null || e.isDone || chapterCompleted) return null;
    final rest = e.target.substring(e.confirmedLength);
    if (rest.isEmpty) return null;
    return String.fromCharCode(rest.runes.first);
  }

  /// 自动输入当前卡住的字（不记错误，属于辅助功能）。
  void typeStuckChar() {
    final e = engine;
    if (e == null || e.isDone || waitingAdvance || chapterCompleted) return;
    final ch = stuckChar;
    if (ch == null) return;
    final prevConfirmed = e.confirmedLength;
    // 无条件重置卡字计时并进入冷却期：即便输入法回声导致本次
    // confirmedLength 没变，也不会立刻再次弹出提示（闪现 bug）
    _lastProgressAt = DateTime.now();
    _stuckHideUntil = DateTime.now().add(const Duration(seconds: 2));
    stuckSeconds.value = 0;
    final v = TextEditingValue(
      text: '${e.confirmed}$ch',
      selection: TextSelection.collapsed(offset: e.confirmed.length + ch.length),
      composing: TextRange.empty,
    );
    textController.value = v;
    final override = e.process(v);
    if (override != null) textController.value = override;
    _countTypedDelta(prevConfirmed);
    if (e.isDone) _onParagraphDone();
    notifyListeners();
  }

  /// 60 秒未输入自动暂停（暂停期间不计时间；输入或回车即自动恢复）。
  void _checkIdlePause() {
    if (_paused || chapterCompleted || book == null || engine == null) return;
    if (DateTime.now().difference(_lastInputAt) >=
        const Duration(seconds: 60)) {
      pause();
    }
  }

  /// 每秒更新的活跃毫秒数；仅统计徽标监听，避免整页每秒重建。
  final ValueNotifier<int> ticker = ValueNotifier(0);

  void pause() {
    _flushTick();
    _paused = true;
    // 暂停前上传一次进度；暂停期间停止周期推送（不产生流量）
    if (settings.s.webdavAutoSync && settings.s.webdavUrl.trim().isNotEmpty) {
      _saveProgress(completed: chapterCompleted);
      onPushProgress?.call();
    }
    _pushTimer?.cancel();
    _pushTimer = null;
    notifyListeners();
  }

  void resume() {
    _lastTick = DateTime.now();
    // 重置空闲计时：暂停 ≥60 秒后手动继续时，若不重置，
    // 下一秒空闲检测会立即打回暂停（只能靠打字逃出）
    _lastInputAt = DateTime.now();
    _paused = false;
    // 恢复打字时重新启动 30 秒周期推送
    _noteTypingActivity();
    notifyListeners();
  }

  void _flushTick() {
    final now = DateTime.now();
    if (!_paused) {
      _activeMs += now.difference(_lastTick).inMilliseconds;
    }
    _lastTick = now;
  }

  int get elapsedActiveMs {
    return _activeMs;
  }

  double get charsPerMinute {
    final m = elapsedActiveMs / 60000.0;
    if (m <= 0.02) return 0;
    return correctCharsTotal / m;
  }

  /// 本次（本章会话）已抄录字数：已完成段落 + 当前段已确认部分。
  /// 当前段已完成等待推进时不再重复计入（_onParagraphDone 已落账）。
  int get sessionChars => visitTypedChars;

  /// 进入抄书页（全新一次访问）时清零本次统计。
  void beginVisit() {
    visitTypedChars = 0;
    notifyListeners();
  }

  double get accuracy {
    final total = correctCharsTotal + errorTotal;
    return total == 0 ? 1.0 : correctCharsTotal / total;
  }

  /// 载入当前段（新建引擎，支持断点恢复 charIndex）。
  void _loadParagraph({int restoreCharIndex = 0, bool restore = false}) {
    final target = paragraphs[paragraphIndex];
    engine = TypingEngine(target);
    final initial = restore ? target.substring(0, restoreCharIndex.clamp(0, target.length)) : '';
    textController.value = TextEditingValue(
      text: initial,
      selection: TextSelection.collapsed(offset: initial.length),
      composing: TextRange.empty,
    );
    // 引擎内部状态同步到已恢复前缀；若快照文本与目标不符
    // （如跨版本目标规范化差异），应用引擎的纠正结果
    if (initial.isNotEmpty) {
      final override = engine!.process(textController.value);
      if (override != null) textController.value = override;
    }
    waitingAdvance = false;
    _lastSpaceAt = null; // 换段重置双空格计时
    _lastProgressAt = DateTime.now(); // 换段重置卡字计时
    notifyListeners();
  }

  /// TextField 值变化入口：交给引擎判定，必要时回写控制器。
  void onTextChanged(TextEditingValue value) {
    if (engine == null || waitingAdvance || chapterCompleted) return;
    _lastInputAt = DateTime.now();
    final prevConfirmed = engine!.confirmedLength;
    // 暂停中开始打字 → 立即恢复计时（打字即开始）
    if (_paused) resume();
    _noteTypingActivity();

    if (engine!.isDone) {
      _lastProgressAt = DateTime.now();
      _onParagraphDone();
      notifyListeners();
      return;
    }

    // 双空格出句号检测（组词中不判定：此时空格是提交候选）
    final cr = value.composing;
    final hasComposing = cr.isValid &&
        !cr.isCollapsed &&
        cr.start >= 0 &&
        cr.end <= value.text.length;
    final stripped = TextUtils.stripWhitespace(value.text);
    final delta = (stripped == engine!.confirmed &&
            value.text.length > stripped.length)
        ? value.text.substring(stripped.length)
        : '';
    final pureSpaceDelta = !hasComposing &&
        delta.isNotEmpty &&
        !delta.contains(RegExp(r'[\n\r]')) &&
        delta.trim().isEmpty; // delta 必须全为空白（防止光标位置变化导致截取失真）
    if (!pureSpaceDelta) _lastSpaceAt = null;
    final isDoubleSpace = pureSpaceDelta &&
        _lastSpaceAt != null &&
        DateTime.now().difference(_lastSpaceAt!) <= _doubleSpaceWindow;
    if (isDoubleSpace) {
      _lastSpaceAt = null;
      final confirmed = engine!.confirmed;
      final injected = TextEditingValue(
        text: '$confirmed。',
        selection: TextSelection.collapsed(offset: confirmed.length + 1),
        composing: TextRange.empty,
      );
      textController.value = injected;
      final override = engine!.process(injected);
      if (override != null) textController.value = override;
      _countTypedDelta(prevConfirmed);
      if (engine!.isDone) _onParagraphDone();
      notifyListeners();
      return;
    }
    if (pureSpaceDelta) _lastSpaceAt = DateTime.now();

    final override = engine!.process(value);
    if (override != null) {
      // 程序化回写（引擎已确保无 composing）
      textController.value = override;
    }
    _countTypedDelta(prevConfirmed);
    if (engine!.isDone) {
      _onParagraphDone();
    }
    notifyListeners();
  }

  void _onParagraphDone() {
    correctCharsTotal += paragraphs[paragraphIndex].length;
    errorTotal += engine?.errorCount ?? 0;
    backspaceTotal += engine?.backspaceCount ?? 0;
    _saveProgress(completed: isLastParagraph);
    if (settings.s.autoAdvanceParagraph) {
      if (isLastParagraph) {
        _completeChapter();
      } else {
        paragraphIndex++;
        _loadParagraph();
      }
    } else {
      waitingAdvance = true;
      if (isLastParagraph) _completeChapter();
    }
    // 段落完成即刻推送断点（多设备秒级跟进）
    onPushProgress?.call();
    notifyListeners();
  }

  /// 回车/按钮：继续下一段。
  void advanceParagraph() {
    if (!waitingAdvance || chapterCompleted) return;
    _lastInputAt = DateTime.now();
    if (_paused) resume();
    if (paragraphIndex < paragraphs.length - 1) {
      paragraphIndex++;
      _loadParagraph();
      notifyListeners();
    }
  }

  /// 手动跳到指定段（会话继续，不拆分统计）。
  Future<void> jumpToParagraph(int index) async {
    if (index < 0 || index >= paragraphs.length) return;
    paragraphIndex = index;
    _loadParagraph();
    if (book != null) {
      _saveProgress(completed: chapterCompleted);
      // 跳段（上/下一段按钮）后立即推送断点：原本只落本地，要等
      // 30 秒周期推送，其他设备在此期间拉到的还是旧段落
      if (settings.s.webdavAutoSync && settings.s.webdavUrl.trim().isNotEmpty) {
        onPushProgress?.call();
      }
    }
    notifyListeners();
  }

  void _saveProgress({required bool completed}) {
    if (book == null || _loadingChapter) return;
    final bp = store.progressOf(book!.id);
    final alreadyCompleted = bp.isChapterCompleted(chapterIndex);
    // 断点归一化：当前段已打完但尚未推进时，保存为"下一段第 0 字"。
    // 这样其他设备恢复后直接处于待输入状态，与本机完全一致（无感同步），
    // 而不是停在"本段完成，按回车继续"。
    final done = engine?.isDone ?? false;
    final advanceToNext = done && !completed && !chapterCompleted;
    final idx = advanceToNext
        ? (paragraphIndex + 1).clamp(0, paragraphs.length - 1)
        : paragraphIndex;
    store.updateChapterProgress(
      book!.id,
      chapterIndex,
      ChapterProgress(
        paragraphIndex: idx,
        charIndex: advanceToNext ? 0 : (engine?.confirmedLength ?? 0),
        completed: completed || alreadyCompleted,
        lastPracticedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void _completeChapter() {
    chapterCompleted = true;
    _saveProgress(completed: true);
    notifyListeners();
  }

  /// 离开练习页：结束会话并写入统计。
  /// 结束会话。[notifySync] 为 false 时不触发全量同步钩子
  /// （切章节场景：统计落账后由 30 秒轻推送上云，避免每次切章
  /// 都全量重传书籍文件）。
  Future<void> endSession({bool notifySync = true}) async {
    if (book == null) return;
    _flushTick();
    _saveProgress(completed: chapterCompleted); // 退出前落账段中断点
    await _commitSessionStats(finished: chapterCompleted);
    _tickTimer?.cancel();
    _pushTimer?.cancel();
    _pushTimer = null;
    book = null;
    engine = null;
    paragraphs = const [];
    chapterCompleted = false;
    notifyListeners();
    final hook = onSessionEnd;
    if (hook != null && notifySync) {
      // 延迟到返回转场结束后再同步：全量同步的 md5/JSON 解析在主
      // isolate 执行，会挤掉 pop 动画的帧（返回目录/书架的卡顿来源）
      unawaited(Future.delayed(const Duration(milliseconds: 800), () async {
        try {
          await hook();
        } catch (_) {}
      }));
    }
  }

  Future<void> _commitSessionStats({bool finished = false}) async {
    // 章节加载窗口期：book/chapterIndex 可能已是新章节而 engine/统计
    // 还是旧会话，此时落账会把旧统计误归属到新章节
    if (book == null || _loadingChapter || _startAt == null) return;
    _flushTick();
    ticker.value = _activeMs;
    if (elapsedActiveMs < 1000 && correctCharsTotal == 0) return; // 空会话不记录
    if (elapsedActiveMs < 60000) return; // 少于 1 分钟的会话不入统计
    // 本会话已计入的段落统计之外，加上当前未完成段的正确字符
    // （当前段已完成已落账，isDone 时不再重复计入）
    final current = engine;
    final curCorrect = (current == null || current.isDone)
        ? 0
        : current.confirmedLength;
    await stats.addSession(PracticeSession(
      id: '${_startAt!.millisecondsSinceEpoch}-${book!.id}-$chapterIndex',
      bookId: book!.id,
      bookTitle: book!.title,
      chapterIndex: chapterIndex,
      chapterTitle: chapterTitle,
      startAt: _startAt!,
      endAt: DateTime.now(),
      activeMs: elapsedActiveMs,
      correctChars: correctCharsTotal + curCorrect,
      errorCount: errorTotal,
      backspaceCount: backspaceTotal,
    ));
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _pushTimer?.cancel();
    ticker.dispose();
    textController.dispose();
    super.dispose();
  }
}
