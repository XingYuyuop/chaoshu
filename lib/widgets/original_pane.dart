import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/rendering.dart' show RenderParagraph;

import 'dart:ui' show BoxHeightStyle;

import '../engine/typing_engine.dart';
import '../state/settings_provider.dart';

/// 原文面板：连续排版（当前段逐字高亮 + 后续段落顺流而下）。
/// 段落推进时自动滚动锚定当前段到顶部，视口内文字量稳定，
/// 无需手动翻页；可自由滚动回看/预读。
/// 所有段落均可长按/拖选划线，使用系统原生选择工具条复制。
class OriginalPane extends StatefulWidget {
  final List<String> paragraphs;
  final int currentIndex;
  final TypingEngine? engine;
  final SettingsProvider settings;

  const OriginalPane({
    super.key,
    required this.paragraphs,
    required this.currentIndex,
    required this.engine,
    required this.settings,
  });

  @override
  State<OriginalPane> createState() => _OriginalPaneState();
}

class _OriginalPaneState extends State<OriginalPane> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _currentKey = GlobalKey();
  final GlobalKey _paneKey = GlobalKey();
  final GlobalKey _typingTextKey = GlobalKey();
  double? _lastScrollTarget; // 上次滚动目标（防同一目标反复触发）
  bool _followAnimating = false; // 跟随滚动动画进行中

  static const int _aheadCount = 12; // 当前段之后渲染的段落数

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
  }

  @override
  void didUpdateWidget(covariant OriginalPane old) {
    super.didUpdateWidget(old);
    // 段落推进或整份内容更换（切换章节/重新开始）时都重新锚定
    if (old.currentIndex != widget.currentIndex ||
        !identical(old.paragraphs, widget.paragraphs)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrent());
    }
  }

  void _scrollToCurrent() {
    final ctx = _currentKey.currentContext;
    if (ctx == null || !mounted) return;
    final ink = widget.settings.isInk;
    // 锚定到靠近输入框的一侧：上下分栏（输入在下）时当前段贴原文栏底部
    // （紧邻输入框）；输入框在上或左右分栏时贴顶部（与输入框首行对齐）
    final alignment =
        (_isVerticalLayout(ctx) && !widget.settings.s.inputOnTop) ? 1.0 : 0.0;
    Scrollable.ensureVisible(
      ctx,
      alignment: alignment,
      duration: ink ? Duration.zero : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  /// 当前字位置回调：长段打字时视口"舒适区"自动跟随——当前行底越过
  /// 视口 62% 高度即上滚带回，始终给当前行下方留 2~3 行预读，
  /// 免去手动上滑找位置；用户翻离当前行时滚回。
  void _onTypingRect(Rect globalRect) {
    if (!mounted || !_scroll.hasClients || _followAnimating) return;
    final paneBox =
        _paneKey.currentContext?.findRenderObject() as RenderBox?;
    if (paneBox == null || !paneBox.attached) return;
    final viewportTop = paneBox.localToGlobal(Offset.zero).dy;
    final viewportH = _scroll.position.viewportDimension;
    final ink = widget.settings.isInk;
    // 顶部基准：当前段锚定侧（上下分栏输入在下时贴底部，其余贴顶部）
    final ctx = _currentKey.currentContext;
    final anchorBottom =
        ctx != null && _isVerticalLayout(ctx) && !widget.settings.s.inputOnTop;
    final lineH = widget.settings.s.fontSize * widget.settings.s.lineHeight;
    double? delta;
    // 舒适区下沿：视口 62% 高度处（当前行底超过即触发跟随）
    final comfortBottom = viewportTop + viewportH * 0.62;
    if (globalRect.bottom > comfortBottom) {
      // 当前行侵入舒适区下方 → 上滚把行底带回舒适区下沿
      delta = globalRect.bottom - comfortBottom;
    } else if (globalRect.top < viewportTop) {
      // 当前行在视口上方（用户往下翻看）→ 回滚到当前行
      delta = globalRect.top -
          viewportTop -
          (anchorBottom ? lineH : lineH * 2);
    }
    if (delta == null || delta.abs() < 1) return;
    final target = (_scroll.offset + delta)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    // 同一目标不重复触发：滚动途中全局坐标持续变化，若按全局矩形
    // 去重会反复重新触发追逐滚动，造成视图/横线漂移
    if (_lastScrollTarget != null &&
        (target - _lastScrollTarget!).abs() < 0.5) {
      return;
    }
    _lastScrollTarget = target;
    if (ink) {
      _scroll.jumpTo(target);
      _lastScrollTarget = null;
    } else {
      _followAnimating = true;
      _scroll
          .animateTo(target,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic)
          .whenComplete(() {
        _followAnimating = false;
        _lastScrollTarget = null;
      });
    }
  }

  /// 与 practice_screen 的分栏判定保持一致（auto：窄竖屏用上下分栏）。
  bool _isVerticalLayout(BuildContext ctx) {
    switch (widget.settings.s.layout) {
      case 'vertical':
        return true;
      case 'horizontal':
        return false;
    }
    final size = MediaQuery.of(ctx).size;
    return size.width < size.height && size.width < 600;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final idx = widget.currentIndex.clamp(0, widget.paragraphs.length - 1);
    final baseStyle = TextStyle(
      fontSize: widget.settings.s.fontSize,
      height: widget.settings.s.lineHeight,
      fontFamily: widget.settings.s.fontFamily.isEmpty
          ? null
          : widget.settings.s.fontFamily,
    );

    final contextStyle = baseStyle.copyWith(
      color: theme.colorScheme.outline,
    );

    return SingleChildScrollView(
      key: _paneKey,
      controller: _scroll,
      padding: EdgeInsets.all(widget.settings.s.pageMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上一段（回看上下文）
          if (idx > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(
                widget.paragraphs[idx - 1],
                style: contextStyle,
              ),
            ),
          // 当前段（逐字高亮，可划线选择）
          Padding(
            key: _currentKey,
            padding: EdgeInsets.zero,
            child: _CurrentParagraph(
              text: widget.paragraphs[idx],
              engine: widget.engine,
              style: baseStyle,
              theme: theme,
              settings: widget.settings,
              typingKey: _typingTextKey,
              onTypingRect: _onTypingRect,
            ),
          ),
          // 后续段落顺流而下
          for (int i = idx + 1;
              i <= (idx + _aheadCount).clamp(0, widget.paragraphs.length - 1);
              i++)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(widget.paragraphs[i], style: contextStyle),
            ),
          if (idx < widget.paragraphs.length - 1)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                '… 本章还剩 ${widget.paragraphs.length - idx - 1} 段',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
        ],
      ),
    );
  }
}

/// 当前字下划线厚度与间隙（字形框下方绘制）。
const double _markThickness = 2.5;
const double _markGap = 3.0;

/// 当前段逐字高亮渲染（SelectableText.rich：支持原生划线选择/复制）：
/// - 已确认字符：正常色
/// - 当前待输入字符：反色高亮（墨水屏：黑底白字）
/// - 错误字符：红色下划线/高亮（墨水屏：加粗实线）
/// - 未输入字符：正常色（稍淡）
class _CurrentParagraph extends StatefulWidget {
  final String text;
  final TypingEngine? engine;
  final TextStyle style;
  final ThemeData theme;
  final SettingsProvider settings;
  final GlobalKey typingKey;
  final ValueChanged<Rect> onTypingRect;

  const _CurrentParagraph({
    required this.text,
    required this.engine,
    required this.style,
    required this.theme,
    required this.settings,
    required this.typingKey,
    required this.onTypingRect,
  });

  @override
  State<_CurrentParagraph> createState() => _CurrentParagraphState();
}

class _CurrentParagraphState extends State<_CurrentParagraph> {
  /// 当前字下划线框（Stack 局部坐标）。
  ///
  /// 位置在 postFrame 后从**真实渲染的 RenderParagraph** 读取字形框，
  /// 而非独立 TextPainter 预测——部分阅读器上两者存在分歧（字体回退、
  /// 换行环境、系统缩放差异），预测框会偏移导致横线标错位置。
  /// 真实框所见即所得，任何设备上都精确对齐当前字。
  final ValueNotifier<Rect?> _barRect = ValueNotifier(null);

  @override
  void dispose() {
    _barRect.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ink = widget.settings.isInk;
    final e = widget.engine;
    final text = widget.text;
    final confirmedLen = e?.confirmedLength ?? 0;
    final errorIndex = e?.errorIndex;

    // 组词高亮长度 = 候选中与原文真正匹配的字数（引擎实时比对）。
    // 候选与原文不符的部分不涂色，保证左侧高亮进度与实际打字一致。
    final composingLen =
        (e == null || e.composing.isEmpty) ? 0 : e.composingMatchLen;

    final normal = widget.style;
    final dim = normal.copyWith(
      color: widget.theme.colorScheme.onSurface.withValues(
          alpha: ink ? 0.55 : 0.45),
    );
    // 组词匹配中的字符：墨水屏模式不加底色（避免色块残影），仅加粗；
    // 彩色模式保留浅色底以示区分
    final composingBg = ink
        ? normal.copyWith(fontWeight: FontWeight.bold)
        : normal.copyWith(
            backgroundColor:
                widget.theme.colorScheme.primary.withValues(alpha: 0.18),
          );
    // 当前待输入字符：加粗。下划线不用 TextDecoration（位置由字体度量
    // 决定无法下移），也不用 WidgetSpan（占排版空间会把字符挤开）——
    // 用 Stack + CustomPaint 按真实字形框绘制在文字下方
    final markColor = ink ? Colors.black : widget.theme.colorScheme.onSurface;
    final currentMarkText = normal.copyWith(fontWeight: FontWeight.bold);
    final markIndex = confirmedLen + composingLen;
    // 错误字符：红色下划线（墨水屏：加粗实线，与彩色模式一致）
    final errorStyle = ink
        ? normal.copyWith(
            color: widget.theme.colorScheme.error,
            fontWeight: FontWeight.bold,
            decoration: TextDecoration.underline,
            decorationThickness: 2.5,
          )
        : normal.copyWith(
            backgroundColor: widget.theme.colorScheme.errorContainer,
            color: widget.theme.colorScheme.onError,
            decoration: TextDecoration.underline,
            decorationColor: widget.theme.colorScheme.error,
          );

    final spans = <InlineSpan>[];
    for (int i = 0; i < text.length; i++) {
      if (errorIndex != null && i == errorIndex) {
        spans.add(TextSpan(text: text[i], style: errorStyle));
      } else if (i < confirmedLen) {
        spans.add(TextSpan(text: text[i], style: normal));
      } else if (i < markIndex) {
        spans.add(TextSpan(text: text[i], style: composingBg));
      } else if (i == markIndex) {
        spans.add(TextSpan(text: text[i], style: currentMarkText));
      } else {
        spans.add(TextSpan(text: text[i], style: dim));
      }
    }

    if (markIndex >= 0 && markIndex < text.length) {
      // 等本帧真实布局完成后从渲染对象取字形框（横线晚一帧出现）
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _measureBar(markIndex));
    } else {
      _barRect.value = null;
    }

    return Stack(
      children: [
        Text.rich(
          TextSpan(children: spans),
          style: widget.style,
          key: widget.typingKey,
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _MarkBarPainter(_barRect, markColor),
          ),
        ),
      ],
    );
  }

  /// postFrame：从真实渲染对象取当前字字形框，画横线并上报视口位置
  /// （供自动跟随滚动使用，同样保证与显示一致）。
  void _measureBar(int index) {
    final ro = widget.typingKey.currentContext?.findRenderObject();
    if (ro is! RenderParagraph || !ro.attached || !mounted) {
      _barRect.value = null;
      return;
    }
    final boxes = ro.getBoxesForSelection(
      TextSelection(baseOffset: index, extentOffset: index + 1),
      boxHeightStyle: BoxHeightStyle.tight,
    );
    if (boxes.isEmpty) {
      _barRect.value = null;
      return;
    }
    final b = boxes.first;
    _barRect.value = Rect.fromLTWH(b.left, b.bottom + _markGap,
        b.right - b.left, _markThickness);
    widget.onTypingRect(ro.localToGlobal(Offset(b.left, b.top)) &
        Size(b.right - b.left, b.bottom - b.top));
  }
}

/// 当前待输入字符的基线下方短横线。位置来自 _barRect（真实渲染字形框），
/// notifier 变化即重绘。
class _MarkBarPainter extends CustomPainter {
  final ValueListenable<Rect?> rect;
  final Color color;
  _MarkBarPainter(this.rect, this.color) : super(repaint: rect);

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect.value;
    if (r == null) return;
    canvas.drawRect(r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MarkBarPainter oldDelegate) =>
      color != oldDelegate.color;
}
