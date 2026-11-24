import 'package:chaoshu/services/app_update.dart';
import 'package:chaoshu/state/settings_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('墨水屏更新弹窗按钮文字为黑色（白底可见）', (tester) async {
    final provider = SettingsProvider();
    await provider.update((s) => s.copyWith(inkMode: true));

    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: provider)],
        child: MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: Center(
                  child: FilledButton(
                    onPressed: () async {
                      await showUpdateConfirmDialog(
                        context,
                        cloudVersion: '9.9.9',
                        currentVersion: '1.0.0',
                        fileName: 'test.apk',
                        sizeMb: '1.0',
                        ink: true,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('忽略'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);

    final ignoreStyle =
        tester.renderObject<RenderParagraph>(find.text('忽略')).text.style!;
    final downloadStyle =
        tester.renderObject<RenderParagraph>(find.text('下载')).text.style!;
    debugPrint('忽略 color=${ignoreStyle.color}');
    debugPrint('下载 color=${downloadStyle.color}');
    expect(ignoreStyle.color, isNot(Colors.white));
    expect(downloadStyle.color, isNot(Colors.white));
  });
}
