import 'package:flutter/services.dart';

import 'package:lpinyin/lpinyin.dart' as pinyin;

import '../services/text_utils.dart';

/// 组词拼音匹配结果：matchLen = 已完整匹配的目标字数（相对 base），
/// errorPos = 失配位置（绝对目标索引），null 表示仍在匹配中。
class _PinyinMatch {
  final int matchLen;
  final int? errorPos;
  const _PinyinMatch(this.matchLen, this.errorPos);
}

/// 打字引擎状态。
enum TypingPhase {
  idle, // 尚未输入
  composing, // IME 组词中（拼音候选）
  typing, // 正常输入中
  error, // 当前字符错误（已阻断）
  done, // 本段完成
}

/// 标点 / 符号（提交触发符判定用）。
final _punctRe = RegExp(r'^[\p{P}\p{S}\p{Z}]+$', unicode: true);

/// 逐字精确匹配打字引擎（纯逻辑，可单测）。
///
/// TextField 的内容恒为「已确认前缀 + IME 组词文本」。引擎监听
/// TextEditingValue 变化：
/// - composing 非空 → 只刷新预览，不判定、不回滚；
/// - composing 为空 → 提交文本全量比对（支持一次提交多个字符）：
///   - 全部匹配 → confirmedIndex 前进（可能触发 done）；
///   - 有错 → 记错误一次，返回修正值（回滚到正确前缀），阻断继续输入。
///
/// 目标段已规范化（无空白/不可见字符），比对按「等价类」进行
/// （全角半角、引号/破折号/省略号变体视为相同）。
class TypingEngine {
  final String target;

  TypingEngine(this.target)
      : assert(!target.contains(RegExp(r'\s'))),
        _targetCanon = TextUtils.canonical(target);

  final String _targetCanon;

  String _confirmed = '';
  String _composing = '';
  String _lastClearedComposing = ''; // 已被自动清除过的错误候选（防反复清除）
  int _composingMatchLen = 0; // 组词候选中与原文实际匹配的字数（高亮用，防止进度超前）
  int? _errorIndex; // target 中当前错误字符的位置
  int _errorCount = 0;
  int _backspaceCount = 0;
  bool _done = false;
  TypingPhase _phase = TypingPhase.idle;
  void Function()? onStateChanged;

  String get confirmed => _confirmed;
  String get composing => _composing;

  /// 组词候选里与原文真正匹配的字数。
  /// 原文高亮只应推进到这里为止：候选与原文不符时不把不符部分涂成"进行中"，
  /// 否则左侧高亮进度会超前于实际打字内容（微软拼音等整句输入法尤其明显）。
  int get composingMatchLen => _composingMatchLen;
  int get confirmedLength => _confirmed.length;
  int? get errorIndex => _errorIndex;
  int get errorCount => _errorCount;
  int get backspaceCount => _backspaceCount;
  bool get isDone => _done;
  TypingPhase get phase => _phase;

  /// 组词预览 + 当前光标后剩余未输入文本。
  String get remaining =>
      target.substring(_confirmed.length + _composing.length);

  /// 处理 TextField 的值变化。返回 null 表示保持原值；
  /// 返回新值表示需要回写控制器（阻断错误字符）。
  TextEditingValue? process(TextEditingValue value) {
    if (_done) return _resetValue();

    final cr = value.composing;
    final hasComposing = cr.isValid &&
        !cr.isCollapsed &&
        cr.start >= 0 &&
        cr.end <= value.text.length;

    if (hasComposing) {
      // IME 组词中。桌面端（Windows 微软拼音等）组词文本是"拼音字母 +
      // 已选候选字"的混合，安卓输入法则多为已转换汉字。
      _composing = value.text.substring(cr.start, cr.end);
      final composed = _composedCJK(_composing);
      final composedCanon = TextUtils.canonical(composed);
      // 比对锚点 = 组词区域之前的实际已输入字数。常态下等于
      // _confirmed.length；桌面端 IME 在程序化回写后可能从其他位置
      // 重组词，按 cr.start 锚定可避免比对错位产生误报。
      final before = TextUtils.stripWhitespace(
          value.text.substring(0, cr.start));
      final base = before.length;
      // 组词区之前的纯文本是 IME 自动转换上屏的内容（桌面端输入法
      // 会把已转换的词逐步写入正文），必须同步进 _confirmed，
      // 否则左侧高亮（= 已确认 + 组词匹配）会滞后于实际输入。
      if (base > _confirmed.length) {
        final beforeCanon = TextUtils.canonical(before);
        var bad = -1;
        for (int i = _confirmed.length;
            i < beforeCanon.length && i < _targetCanon.length;
            i++) {
          if (beforeCanon[i] != _targetCanon[i]) {
            bad = i;
            break;
          }
        }
        if (bad != -1) {
          // IME 自动上屏的内容与原文不符：清除并回写正确前缀
          if (before != _lastClearedComposing) {
            _lastClearedComposing = before;
            _errorIndex = bad;
            _phase = TypingPhase.error;
            _composing = '';
            _composingMatchLen = 0;
            _notify();
            return _resetValue();
          }
          _errorIndex = bad;
          _phase = TypingPhase.error;
          _notify();
          return null;
        }
        _confirmed = before;
      } else if (base < _confirmed.length) {
        // 组词期间用户删掉了已确认内容：向下同步
        _confirmed = before;
      }
      // 1) 已转换候选字部分：与原文比对，不符立即清除
      //    （与安卓逐字上屏的"错字输不进来"体验一致）。
      //    同样的候选再次出现（IME 缓冲重上屏）时只提示不再清除，
      //    等用户修正拼音，避免闪烁循环。
      var cm = -1;
      for (int i = 0;
          i < composedCanon.length && base + i < _targetCanon.length;
          i++) {
        if (composedCanon[i] != _targetCanon[base + i]) {
          cm = i;
          break;
        }
      }
      if (cm != -1) {
        if (_composing != _lastClearedComposing) {
          _lastClearedComposing = _composing;
          _errorIndex = base + cm;
          _phase = TypingPhase.error;
          _composing = '';
          _composingMatchLen = 0;
          _notify();
          return _resetValue();
        }
        _errorIndex = base + cm;
        _phase = TypingPhase.error;
        _notify();
        return null;
      }
      _lastClearedComposing = '';
      // 2) 拼音部分：桌面端组词多为拼音字母（如打"许"时 composing="xu"），
      //    按目标字读音做前缀匹配，实现打拼音时左侧原文实时推进（跟字）；
      //    拼音偏离目标读音时红标提示（不打断输入，提交时阻断）。
      final m = _matchComposing(_composing, base);
      if (m.errorPos != null) {
        _errorIndex = m.errorPos;
        _phase = TypingPhase.error;
        _composingMatchLen = m.matchLen;
        _notify();
        return null;
      }
      _errorIndex = null;
      // 组词已完整匹配目标段尾（纯汉字/标点，无残留拼音字母）：
      // 桌面端整句输入法句末标点无需再按一次空格，直接完成本段
      if (base + m.matchLen >= _targetCanon.length &&
          m.matchLen > 0 &&
          !_hasAsciiLetter(_composing)) {
        _confirmed = target;
        _done = true;
        _phase = TypingPhase.done;
        _composing = '';
        _composingMatchLen = 0;
        _notify();
        return _resetValue();
      }
      _composingMatchLen =
          m.matchLen.clamp(0, _targetCanon.length - base);
      _phase = TypingPhase.composing;
      _notify();
      return null;
    }

    final typed = TextUtils.stripWhitespace(value.text);
    _composing = '';
    _composingMatchLen = 0;
    _lastClearedComposing = '';

    if (typed == _confirmed) {
      // 无新内容。若字段里残留了空白字符（如回车/空格），清理之。
      if (value.text != _confirmed) {
        return _resetValue();
      }
      return null;
    }

    // 全量前缀比对（按等价类）
    final typedCanon = TextUtils.canonical(typed);
    final n = typedCanon.length <= _targetCanon.length
        ? typedCanon.length
        : _targetCanon.length;
    var mismatch = -1;
    for (int i = 0; i < n; i++) {
      if (typedCanon[i] != _targetCanon[i]) {
        mismatch = i;
        break;
      }
    }

    if (mismatch == -1) {
      if (typedCanon.length <= _targetCanon.length) {
        // 全部正确
        if (typed.length < _confirmed.length) {
          _backspaceCount += _confirmed.length - typed.length;
        }
        _confirmed = typed;
        _errorIndex = null;
        if (typedCanon.length == _targetCanon.length) {
          _done = true;
          _phase = TypingPhase.done;
        } else {
          _phase = TypingPhase.typing;
        }
        _notify();
        return null;
      }
      // 输入超过目标长度：前缀已完整匹配，超出部分必然在段尾之后，
      // 不可能是原文 → 按前缀完成本段，多余的忽略不算错
      // （如段尾"你"、安卓整词上屏"你们"）
      mismatch = _targetCanon.length;
    }

    // 出错：截断到出错前（出错前的字符是正确的，予以确认）
    final oldConfirmedLen = _confirmed.length;
    _confirmed = typed.substring(0, mismatch.clamp(0, target.length));
    final tail = typedCanon.substring(mismatch);

    // Windows 微软拼音等整句输入法：组词以标点/回车提交时，提交文本末尾
    // 会带出一个触发标点（如「只不。」）。若已匹配前缀有推进且尾巴全是
    // 标点/符号 → 视为提交触发符，静默丢弃，不算错误、不回退组词。
    // 尾巴超出段尾（mismatch == 目标长度）同理：前缀已完整走完目标，
    // 超出部分不可能是原文，静默完成本段
    final tailIsPunct =
        _punctRe.hasMatch(tail) && _confirmed.length > oldConfirmedLen;
    final tailIsSurplus = mismatch == _targetCanon.length;
    if (tailIsPunct || tailIsSurplus) {
      _errorIndex = null;
      if (_confirmed.length == target.length) {
        _done = true;
        _phase = TypingPhase.done;
      } else {
        _phase = TypingPhase.typing;
      }
    } else {
      _errorIndex = mismatch;
      _errorCount++;
      _phase = TypingPhase.error;
    }
    _notify();
    return _resetValue();
  }

  /// 目标段每个字符的拼音读音表（无声母变体下全部小写、去声调）。
  /// CJK 字取全部多音字读音；非 CJK 无读音（等价类路径处理）。
  late final List<List<String>> _targetReadings = _buildTargetReadings();

  List<List<String>> _buildTargetReadings() {
    // 按UTF-16码元展开：DP 匹配用码元索引（与 _targetCanon 一致），
    // 非 BMP 字符（扩展B汉字/emoji）占两个码元，各放空读音占位，
    // 否则 rune/码元两套索引错位会越界或取错读音
    final out = <List<String>>[];
    for (final cu in target.codeUnits) {
      if (cu >= 0xD800 && cu <= 0xDFFF) {
        // 代理对（非 BMP）：占位，读音按 rune 级也查不到，留空
        out.add(const <String>[]);
        continue;
      }
      if (cu < 0x2E80) {
        out.add(const <String>[]);
        continue;
      }
      final c = String.fromCharCode(cu);
      final readings = <String>{};
      try {
        readings.addAll(pinyin.PinyinHelper.convertToPinyinArray(
                c, pinyin.PinyinFormat.WITHOUT_TONE)
            .map((p) => p.toLowerCase()));
        // 多音字补充读音
        final multi = pinyin.PinyinHelper.multiPinyinMap[c];
        if (multi != null) {
          readings.addAll(pinyin.PinyinHelper.formatPinyin(
                  multi, pinyin.PinyinFormat.WITHOUT_TONE)
              .map((p) => p.toLowerCase()));
        }
      } catch (_) {}
      out.add(readings.toList());
    }
    return out;
  }

  static bool _isAsciiLetter(int ch) =>
      (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A);

  /// 是否含 ASCII 字母（残留拼音字母 = 输入法还没完成转换）
  static bool _hasAsciiLetter(String s) {
    for (int i = 0; i < s.length; i++) {
      if (_isAsciiLetter(s.codeUnitAt(i))) return true;
    }
    return false;
  }

  /// 从 pos 起的连续 ASCII 字母长度。
  int _lettersRun(String s, int pos) {
    var end = pos;
    while (end < s.length && _isAsciiLetter(s.codeUnitAt(end))) {
      end++;
    }
    return end - pos;
  }

  /// 组词匹配结果。
  ///
  /// [matchLen] 相对 base 已完整匹配的目标字数（高亮推进）；
  /// [errorPos] 失配位置（绝对目标索引），null 表示仍在匹配中。

  /// 组词拼音匹配（广度优先 DP）：
  /// - 组词中的汉字 / 符号：等价类直接比对；
  /// - 字母串：与目标字读音整段匹配，或作为下一读音的前缀（正在打）。
  /// 成功时 matchLen 取最少匹配字数（保守高亮）；无任何路径可解释
  /// 组词内容时返回失配位置（最深推进处）。
  _PinyinMatch _matchComposing(String composing, int base) {
    final n = composing.length;
    if (n == 0) return _PinyinMatch(0, null);
    var bestTerminal = -1;
    var deepest = base;
    final seen = <int>{};
    var frontier = <List<int>>[
      [base, 0]
    ];
    seen.add(base * (n + 1));
    while (frontier.isNotEmpty) {
      final next = <List<int>>[];
      for (final st in frontier) {
        final ti = st[0];
        final pos = st[1];
        if (ti > deepest) deepest = ti;
        if (pos >= n) {
          if (bestTerminal == -1 || ti - base < bestTerminal) {
            bestTerminal = ti - base;
          }
          continue;
        }
        if (ti >= _targetCanon.length) {
          // 组词超出目标剩余：段尾之后的内容不可能是原文——
          // 前缀已完整走完目标即视为可接受（如段尾是"你"、组词是
          // "你们"，按前缀完成，多余的"们"忽略不算错）。
          // 历史特例"尾巴全是标点"只是其中一种情形，逻辑相同
          if (bestTerminal == -1 || ti - base < bestTerminal) {
            bestTerminal = ti - base;
          }
          continue;
        }
        final ch = composing.runes.elementAt(pos);
        if (ch < 0x2E80 && _isAsciiLetter(ch)) {
          // 拼音字母串：尝试目标字的每个读音
          final runLen = _lettersRun(composing, pos);
          final remain = composing.substring(pos, pos + runLen);
          for (final p in _targetReadings[ti]) {
            if (p.isEmpty) continue;
            if (remain.startsWith(p)) {
              final key = (ti + 1) * (n + 1) + (pos + p.length);
              if (seen.add(key)) next.add([ti + 1, pos + p.length]);
            } else if (p.startsWith(remain)) {
              // 部分音节：用户仍在打这个字
              if (bestTerminal == -1 || ti - base < bestTerminal) {
                bestTerminal = ti - base;
              }
            }
          }
        } else {
          // 汉字 / 标点等：等价类比对
          final c = String.fromCharCode(ch);
          if (TextUtils.canonical(c) == _targetCanon[ti]) {
            final key = (ti + 1) * (n + 1) + (pos + c.length);
            if (seen.add(key)) next.add([ti + 1, pos + c.length]);
          }
        }
      }
      frontier = next;
    }
    if (bestTerminal >= 0) return _PinyinMatch(bestTerminal, null);
    return _PinyinMatch(deepest - base, deepest);
  }

  /// 取组词文本中已转换的 CJK 候选字（拼音字母不算）。
  static String _composedCJK(String composing) {
    final buf = StringBuffer();
    for (final r in composing.runes) {
      if (r >= 0x2E80) buf.writeCharCode(r);
    }
    return buf.toString();
  }

  TextEditingValue _resetValue() {
    return TextEditingValue(
      text: _confirmed,
      selection: TextSelection.collapsed(offset: _confirmed.length),
      composing: TextRange.empty,
    );
  }

  /// 错误提示自动清除（UI 在短暂高亮后调用）。
  void clearError() {
    if (_phase == TypingPhase.error) {
      _errorIndex = null;
      _phase = TypingPhase.typing;
      _notify();
    }
  }

  /// 组词被外部强制清除（如 ESC 兜底重置输入连接）时同步内部状态：
  /// 程序化回写不触发 onChanged，引擎的组词/守卫状态若不清，
  /// 提示行与原文高亮会停留在旧组词态，直到下一次真实输入。
  void cancelComposing() {
    if (_composing.isEmpty &&
        _composingMatchLen == 0 &&
        _lastClearedComposing.isEmpty) {
      return;
    }
    _composing = '';
    _composingMatchLen = 0;
    _lastClearedComposing = '';
    _notify();
  }

  void _notify() {
    onStateChanged?.call();
  }

  /// 本段统计：首次确认的正确字符数。
  int get correctChars => _confirmed.length;
}
