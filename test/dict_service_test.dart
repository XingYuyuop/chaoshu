import 'package:chaoshu/services/dict_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('单字查询返回含拼音与释义的条目，并触发懒加载', () async {
    expect(DictService.ready, isFalse);
    final results = await DictService.lookup('你');
    expect(DictService.ready, isTrue);
    expect(results, hasLength(1));
    expect(results.first.char, '你');
    expect(results.first.pinyin, isNotEmpty);
    expect(results.first.explanation, isNotEmpty);
    expect(results.first.strokes, greaterThan(0));
    expect(results.first.radical, isNotEmpty);
  });

  test('多字查询依序返回每个字的条目', () async {
    final results = await DictService.lookup('测试');
    expect(results, hasLength(2));
    expect(results[0].char, '测');
    expect(results[1].char, '试');
  });

  test('未收录字符与空白查询返回空结果', () async {
    expect(await DictService.lookup('A'), isEmpty);
    expect(await DictService.lookup('  '), isEmpty);
    expect(await DictService.lookup(''), isEmpty);
  });
}
