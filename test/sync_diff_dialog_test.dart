import 'package:chaoshu/services/webdav_sync.dart';
import 'package:chaoshu/state/settings_provider.dart';
import 'package:chaoshu/widgets/sync_diff_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// 启动增强同步弹窗：墨水屏按钮黑字可见 + 返回值正确。
void main() {
  final diff = SyncDiffInfo(localOnlyBooks: 2, cloudOnlyBooks: 1);

  Future<void> pumpHost(
    WidgetTester tester, {
    required bool ink,
    required Future<void> Function(BuildContext context) open,
  }) async {
    final provider = SettingsProvider();
    await provider.update((s) => s.copyWith(inkMode: ink));
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: provider)],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (context) {
                  return OutlinedButton(
                    onPressed: () => open(context),
                    child: const Text('open'),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  TextStyle? styleOf(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text)).text.style;

  testWidgets('墨水屏差异弹窗：按钮文字黑色且选择覆盖上传返回 overwrite',
      (tester) async {
    String? result;
    await pumpHost(tester, ink: true, open: (context) async {
      result = await showSyncDiffDialog(context, diff: diff);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('数据同步'), findsOneWidget);
    expect(find.textContaining('本机独有 2 本'), findsOneWidget);
    expect(find.textContaining('云端独有 1 本'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    expect(find.text('覆盖上传'), findsOneWidget);
    expect(styleOf(tester, '知道了')!.color, isNot(Colors.white));
    expect(styleOf(tester, '覆盖上传')!.color, isNot(Colors.white));

    await tester.tap(find.text('覆盖上传'));
    await tester.pumpAndSettle();
    expect(result, 'overwrite');
  });

  testWidgets('墨水屏差异弹窗：知道了返回 null', (tester) async {
    String? result;
    await pumpHost(tester, ink: true, open: (context) async {
      result = await showSyncDiffDialog(context, diff: diff);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('墨水屏覆盖同步二次确认：确认返回 true', (tester) async {
    bool? confirmed;
    await pumpHost(tester, ink: true, open: (context) async {
      confirmed = await confirmOverwriteSyncDialog(context);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('覆盖同步'), findsNWidgets(2)); // 标题 + 确认按钮
    expect(find.textContaining('覆盖云端'), findsOneWidget);
    expect(styleOf(tester, '取消')!.color, isNot(Colors.white));
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('覆盖同步').last)
          .text
          .style!
          .color,
      isNot(Colors.white),
    );

    await tester.tap(find.text('覆盖同步').last);
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });

  testWidgets('彩色模式：覆盖上传走 FilledButton 且返回 overwrite', (tester) async {
    String? result;
    await pumpHost(tester, ink: false, open: (context) async {
      result = await showSyncDiffDialog(context, diff: diff);
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.text('覆盖上传'));
    await tester.pumpAndSettle();
    expect(result, 'overwrite');
  });
}
