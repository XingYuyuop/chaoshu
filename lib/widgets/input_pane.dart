import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/typing_engine.dart';
import '../state/settings_provider.dart';

/// 输入面板：提示条 + 进度条 + 打字输入框。
class InputPane extends StatefulWidget {
  final TextEditingController controller;
  final TypingEngine? engine;
  final SettingsProvider settings;
  final bool waitingAdvance;
  final bool chapterCompleted;
  final int sessionChars; // 本次会话已抄录字数
  final ValueNotifier<int> stuckSeconds; // 当前字无进展秒数（猜你想输入）
  final VoidCallback onAutoType; // 自动输入当前卡住的字
  final void Function(String char) onDictLookup; // 查字典释义
  final ValueChanged<String> onChanged;
  final VoidCallback onAdvance;

  const InputPane({
    super.key,
    required this.controller,
    required this.engine,
    required this.settings,
    required this.waitingAdvance,
    required this.chapterCompleted,
    required this.sessionChars,
    required this.stuckSeconds,
    required this.onAutoType,
    required this.onDictLookup,
    required this.onChanged,
    required this.onAdvance,
  });

  @override
  State<InputPane> createState() => _InputPaneState();
}

class _InputPaneState extends State<InputPane> {
  final _focus = FocusNode();

  /// 当前等待输入的字（猜你想输入提示用）。
  String? _stuckChar() {
    final e = widget.engine;
    if (e == null || e.isDone || e.target.isEmpty) return null;
    final rest = e.target.substring(e.confirmedLength);
    if (rest.isEmpty) return null;
    return String.fromCharCode(rest.runes.first);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  /// 关闭软键盘模式：焦点到手立即隐藏软键盘。
  /// 不用 TextInputType.none——部分设备会断开输入通道导致后续无法输入；
  /// 此方式输入通道完整，实体键盘照常工作，软键盘短暂闪现后收起。
  void _onFocusChanged() {
    if (!_focus.hasFocus) return;
    if (!widget.settings.s.showSoftKeyboard) {
      Future.delayed(const Duration(milliseconds: 60), () {
        SystemChannels.textInput.invokeMethod('TextInput.hide');
      });
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.settings;
    final e = widget.engine;
    final ink = settings.isInk;
    final isError = e?.phase == TypingPhase.error;
    final isDone = e?.isDone ?? false;

    String hint;
    Color hintColor;
    if (widget.chapterCompleted) {
      hint = '本章已完成';
      hintColor = theme.colorScheme.primary;
    } else if (isDone && widget.waitingAdvance) {
      hint = settings.s.autoAdvanceParagraph ? '本段完成' : '本段完成，按回车继续';
      hintColor = theme.colorScheme.primary;
    } else if (isError) {
      // errorIndex 可能等于 target.length（超出目标长度时），需防护
      final wrongChar =
          (e!.errorIndex != null && e.errorIndex! < e.target.length)
              ? e.target[e.errorIndex!]
              : '';
      hint = e.composing.isNotEmpty
          ? '组词与原文不符：应为「$wrongChar」'
          : '应为「$wrongChar」，输入错误已退回，请重输';
      hintColor = theme.colorScheme.error;
    } else if (e != null && e.composing.isNotEmpty) {
      hint = '正在输入：${e.composing}';
      hintColor = theme.colorScheme.outline;
    } else if (e != null && e.confirmedLength > 0) {
      hint = '已输入 ${e.confirmedLength} / ${e.target.length} 字';
      hintColor = theme.colorScheme.outline;
    } else {
      hint = '对照原文逐字输入 · 空格免输';
      hintColor = theme.colorScheme.outline;
    }

    // 输入进度条（当前段完成度）
    final progress = e == null || e.target.isEmpty
        ? 0.0
        : (e.confirmedLength / e.target.length).clamp(0.0, 1.0);

    return Padding(
      padding: EdgeInsets.all(settings.s.pageMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 提示行：状态提示居左，本次抄录字数居右
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: hintColor,
                      fontWeight: isError ? FontWeight.bold : null,
                    )),
              ),
              const SizedBox(width: 12),
              Text('本次 ${widget.sessionChars} 字',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                    fontWeight: FontWeight.bold,
                  )),
            ],
          ),
          const SizedBox(height: 6),
          // 猜你想输入：当前字 ≥20 秒无进展时提示可自动输入/查释义。
          // Wrap 自适应：左右布局窄面板放不下时换行，不会截断成单字
          ValueListenableBuilder<int>(
            valueListenable: widget.stuckSeconds,
            builder: (context, seconds, _) {
              final ch = _stuckChar();
              if (seconds < 20 || ch == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 0,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: widget.onAutoType,
                      child: Text('输入"$ch"',
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          )),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => widget.onDictLookup(ch),
                      child: Text('查释义',
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          )),
                    ),
                  ],
                ),
              );
            },
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(settings.isInk ? 0 : 4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: theme.colorScheme.outline
                  .withValues(alpha: settings.isInk ? 0.4 : 0.25),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _onEnter,
                const SingleActivator(LogicalKeyboardKey.numpadEnter):
                    _onEnter,
                const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
                const SingleActivator(LogicalKeyboardKey.keyV, control: true):
                    () {}, // 禁用粘贴
                const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                    () {},
              },
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                autofocus: true,
                maxLines: null,
                minLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                autocorrect: false,
                // 必须开启 suggestions：关闭后输入法会把输入框当作
                // 密码/无预测类输入，默认切到英文键盘；开启后中文输入法
                // 才会以中文模式打开。autocorrect 保持关闭以免误改错字。
                enableSuggestions: true,
                smartDashesType: SmartDashesType.disabled,
                smartQuotesType: SmartQuotesType.disabled,
                contextMenuBuilder: (context, editableTextState) =>
                    const SizedBox.shrink(), // 禁用长按菜单（防粘贴）
                style: TextStyle(
                  fontSize: settings.s.fontSize,
                  height: settings.s.lineHeight,
                  fontFamily: settings.s.fontFamily.isEmpty
                      ? null
                      : settings.s.fontFamily,
                ),
                cursorColor: ink ? Colors.black : theme.colorScheme.primary,
                decoration: InputDecoration(
                  hintText: '在此输入…',
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ink ? 2 : 10),
                  ),
                ),
                onChanged: widget.onChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onEnter() {
    if (widget.waitingAdvance || widget.chapterCompleted) widget.onAdvance();
  }

  /// ESC 兼容处理：部分设备/输入法按 ESC 取消组词后，输入连接会卡死
  /// （之后打字无响应，需按 Shift 切换输入法模式才能恢复）。
  /// 这里捕获 ESC：清除引擎错误态，并强制回写控制器重置组词状态，
  /// 重新同步框架与输入法的连接。
  void _onEscape() {
    widget.engine?.clearError();
    widget.engine?.cancelComposing();
    final v = widget.controller.value;
    widget.controller.value = TextEditingValue(
      text: v.text,
      selection: v.selection,
      composing: TextRange.empty,
    );
  }
}
