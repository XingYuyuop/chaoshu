import 'package:chaoshu/services/zh_conv.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await ZhConv.init();
  });

  test('简转繁：单字与常用词', () {
    expect(ZhConv.toTraditional('简体中文'), '簡體中文');
    expect(ZhConv.toTraditional('听马'), '聽馬');
    expect(ZhConv.toTraditional('鼠标'), '鼠標'); // 词组级
  });

  test('繁转简：单字', () {
    expect(ZhConv.toSimplified('簡體中文'), '简体中文');
    expect(ZhConv.toSimplified('聽馬'), '听马');
  });

  test('无对应字符保持原样', () {
    expect(ZhConv.toTraditional('Hello 123 你好'), 'Hello 123 你好');
  });
}
