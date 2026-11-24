import 'package:chaoshu/engine/typing_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue v(String text, {TextRange? composing}) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing ?? TextRange.empty,
    );

void main() {
  const target = '听了他的话我禁不住反问';
  late TypingEngine engine;

  setUp(() {
    engine = TypingEngine(target);
  });

  group('TypingEngine 逐字匹配', () {
    test('初始为 idle，无错误', () {
      expect(engine.phase, TypingPhase.idle);
      expect(engine.confirmedLength, 0);
      expect(engine.isDone, false);
    });

    test('逐字正确输入', () {
      for (int i = 0; i < target.length; i++) {
        final r = engine.process(v(target.substring(0, i + 1)));
        expect(r, isNull);
        expect(engine.errorIndex, isNull);
      }
      expect(engine.confirmedLength, target.length);
      expect(engine.isDone, true);
      expect(engine.phase, TypingPhase.done);
      expect(engine.errorCount, 0);
    });

    test('错字阻断：错误字符被回滚并计数', () {
      final r = engine.process(v('听')); // 正确
      expect(r, isNull);
      final r2 = engine.process(v('听了们')); // 第 3 字错误
      expect(r2, isNotNull);
      expect(r2!.text, '听了');
      expect(engine.errorIndex, 2);
      expect(engine.errorCount, 1);
      expect(engine.confirmedLength, 2);
      // 修正后可继续
      final r3 = engine.process(v('听了他的话'));
      expect(r3, isNull);
      expect(engine.confirmedLength, 5);
      expect(engine.errorIndex, isNull);
    });

    test('IME composing：候选与原文不符立即清除（与安卓一致）', () {
      engine.process(v('听'));
      // 组词候选 "们me"：候选字 "们" 与原文 "了" 不符 → 立即回写清除错误候选
      final r = engine.process(
          v('听们me', composing: const TextRange(start: 1, end: 3)));
      expect(r, isNotNull);
      expect(r!.text, '听');
      expect(engine.phase, TypingPhase.error);
      expect(engine.errorIndex, 1);
      expect(engine.composing, isEmpty);
      expect(engine.confirmedLength, 1); // 已确认部分保留

      // 同样的错误候选再次上屏（IME 缓冲）：只提示，不再清除
      final r2 = engine.process(
          v('听们me', composing: const TextRange(start: 1, end: 3)));
      expect(r2, isNull);
      expect(engine.phase, TypingPhase.error);

      // 候选"了"正确 + 拼音 "t"（"他"的部分音节）→ 组词预览推进
      final r3 = engine.process(
          v('听了t', composing: const TextRange(start: 1, end: 3)));
      expect(r3, isNull);
      expect(engine.phase, TypingPhase.composing);
      expect(engine.errorIndex, isNull);
      // 提交后判定
      engine.process(v('听了'));
      expect(engine.confirmedLength, 2);
      expect(engine.composing, isEmpty);
    });

    test('组词完整匹配目标段尾时自动完成（桌面端句号免空格）', () {
      // 组词=完整目标段+句末标点（输入法已全部转换为汉字）
      final r = engine.process(v('听了他的话我禁不住反问。',
          composing: const TextRange(start: 0, end: 12)));
      expect(engine.phase, TypingPhase.done);
      expect(engine.confirmedLength, 11);
      expect(engine.errorIndex, isNull);
      expect(r, isNotNull); // 回写已确认文本
    });

    test('组词带残留拼音字母时不自动完成', () {
      // 拼音还没转换成汉字：不能提前完成段落
      engine.process(v('听了他的话hao',
          composing: const TextRange(start: 0, end: 8)));
      expect(engine.phase, isNot(TypingPhase.done));
    });

    test('IME 自动上屏前缀同步确认（桌面端跟字修复）', () {
      // 已确认"听"；IME 自动转换上屏"了他的"，组词区只剩"话"
      engine.process(v('听了他的话',
          composing: const TextRange(start: 4, end: 5)));
      // "了他的"被同步确认，组词"话"与原文匹配推进
      expect(engine.confirmedLength, 4);
      expect(engine.phase, TypingPhase.composing);
      expect(engine.composingMatchLen, 1);
      expect(engine.errorIndex, isNull);
      // 提交后全句确认
      engine.process(v('听了他的话'));
      expect(engine.confirmedLength, 5);
    });

    test('IME 自动上屏内容与原文不符时清除回写', () {
      engine.process(v('听'));
      // IME 上屏了错字"门"后组词"话"
      final r = engine.process(v('听门的话',
          composing: const TextRange(start: 3, end: 4)));
      expect(r, isNotNull);
      expect(r!.text, '听');
      expect(engine.phase, TypingPhase.error);
      expect(engine.errorIndex, 1);
      expect(engine.confirmedLength, 1);
    });

    test('IME 拼音组词：按目标读音匹配（桌面端跟字）', () {
      // 打 "t"（"听"的部分音节）→ 匹配中，无错误
      engine.process(v('t', composing: const TextRange(start: 0, end: 1)));
      expect(engine.phase, TypingPhase.composing);
      expect(engine.errorIndex, isNull);
      // 打完整音节 "ting" → 第 1 字"听"匹配推进（跟字）
      engine.process(v('ting', composing: const TextRange(start: 0, end: 4)));
      expect(engine.phase, TypingPhase.composing);
      expect(engine.composingMatchLen, 1);
      // 打错读音 "le"（"听"读 ting）→ 失配红标
      engine.process(v('le', composing: const TextRange(start: 0, end: 2)));
      expect(engine.phase, TypingPhase.error);
      expect(engine.errorIndex, 0);
      // 全句拼音 "tingletad" → "听了他" 完整 3 字 + "的"正在打 → 推进 3
      engine.process(
          v('tingletad', composing: const TextRange(start: 0, end: 9)));
      expect(engine.phase, TypingPhase.composing);
      expect(engine.composingMatchLen, 3);
    });

    test('整句提交：正确前缀被接受，错误处截断', () {
      final r = engine.process(v('听了他的话我禁不住反问')); // 全对整句
      expect(r, isNull);
      expect(engine.isDone, true);
    });

    test('整句提交含错字', () {
      final r = engine.process(v('听了他的话我禁不住问')); // 少“反”
      expect(r, isNotNull);
      expect(r!.text, '听了他的话我禁不住'); // 错误位置 9
      expect(engine.errorIndex, 9);
      expect(engine.confirmedLength, 9);
      expect(engine.errorCount, 1);
    });

    test('退格自由收缩并计数', () {
      for (int i = 0; i < 5; i++) {
        engine.process(v(target.substring(0, i + 1)));
      }
      expect(engine.confirmedLength, 5);
      final r = engine.process(v('听了')); // 退格 3 字
      expect(r, isNull);
      expect(engine.confirmedLength, 2);
      expect(engine.backspaceCount, 3);
      // 退格后重新输入
      engine.process(v('听了他的话'));
      expect(engine.confirmedLength, 5);
      expect(engine.errorCount, 0);
    });

    test('空格自动忽略（中英文混排）', () {
      final eng = TypingEngine('helloworld');
      eng.process(v('hello world'));
      expect(eng.isDone, true);
      expect(eng.confirmed, 'helloworld');
    });

    test('输入超过目标长度：前缀完整匹配 → 完成本段，多余忽略不算错', () {
      final short = TypingEngine('你好');
      final r = short.process(v('你好吗'));
      expect(r, isNotNull);
      expect(short.errorIndex, isNull);
      expect(short.confirmedLength, 2);
      expect(short.errorCount, 0);
      expect(short.isDone, isTrue);
    });

    test('段尾组词超出：组词"你们"匹配段尾"你"按前缀完成', () {
      final tail = TypingEngine('天亮你');
      // 先确认"天亮"，剩余目标只有"你"
      tail.process(v('天亮'));
      expect(tail.confirmedLength, 2);
      // 组词区为已转换候选"你们"（无拼音字母）：超出段尾的"们"忽略
      const cr = TextRange(start: 2, end: 4);
      final val = TextEditingValue(
          text: '天亮你们',
          selection: const TextSelection.collapsed(offset: 2),
          composing: cr);
      final r = tail.process(val);
      expect(r, isNotNull);
      expect(tail.errorIndex, isNull);
      expect(tail.isDone, isTrue);
      expect(tail.errorCount, 0);
    });

    test('clearError 清除错误高亮', () {
      engine.process(v('们'));
      expect(engine.errorIndex, 0);
      engine.clearError();
      expect(engine.errorIndex, isNull);
      expect(engine.phase, TypingPhase.typing);
    });

    test('done 状态后继续输入被拒绝', () {
      engine.process(v(target));
      expect(engine.isDone, true);
      final r = engine.process(v('${target}x'));
      expect(r, isNotNull);
      expect(r!.text, target);
    });

    test('等价类：全角/半角标点互通', () {
      final eng = TypingEngine('说:你好!');
      eng.process(v('说，你好！')); // 用户打了全角逗号/叹号，目标为半角冒号/叹号
      // 全角'，'→',' 但目标第 1 字是':'，仍应报错于位置 1
      expect(eng.errorIndex, 1);
      // 修正后：半角冒号 + 全角叹号（与目标等价）
      final r = eng.process(v('说:你好！'));
      expect(r, isNull);
      expect(eng.isDone, true);
    });

    test('整句组词以标点提交：接受已匹配部分，标点尾巴静默丢弃', () {
      // Windows 微软拼音整句模式：组词「听了他的话我禁不」后输入「。」提交
      final r = engine.process(v('听了他的话我禁不。'));
      expect(engine.errorCount, 0);
      expect(engine.confirmedLength, 8); // 「听了他的话我禁不」
      expect(engine.errorIndex, isNull);
      expect(r, isNotNull);
    });

    test('组词全对 + 标点触发提交 → 段落完成', () {
      final eng = TypingEngine('只不过');
      eng.process(v('只不过。'));
      expect(eng.errorCount, 0);
      expect(eng.isDone, true);
    });

    test('组词中真错字：保留正确前缀并报错', () {
      final eng = TypingEngine('只不过');
      eng.process(v('只大。')); // 「大」是错字，「。」是提交符
      expect(eng.errorCount, 1);
      expect(eng.errorIndex, 1);
      expect(eng.confirmedLength, 1);
    });

    test('无匹配进展的标点输入仍算错误', () {
      final eng = TypingEngine('只不过');
      eng.process(v('。')); // 开头就打个标点
      expect(eng.errorCount, 1);
      expect(eng.errorIndex, 0);
    });

    test('组词阶段实时报错：候选与原文不符不计数', () {
      final eng = TypingEngine('只不过');
      eng.process(v('只', composing: const TextRange(start: 0, end: 1)));
      expect(eng.errorIndex, isNull);
      eng.process(v('只大', composing: const TextRange(start: 0, end: 2)));
      // 「大」与目标「不」不符 → 实时提示错误，但不落账
      expect(eng.errorIndex, 1);
      expect(eng.errorCount, 0);
    });

    test('拼音字母（未转换）不参与组词比对', () {
      final eng = TypingEngine('只不过');
      eng.process(v('zh', composing: const TextRange(start: 0, end: 2)));
      expect(eng.errorIndex, isNull);
      expect(eng.phase, TypingPhase.composing);
    });
  });
}
