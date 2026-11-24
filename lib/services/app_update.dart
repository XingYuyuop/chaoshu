import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../models/app_settings.dart';
import '../widgets/app_dialog.dart';
import 'webdav_sync.dart';

/// 版本号比较：返回 >0 表示 a 更新。
int cmpVersion(String a, String b) {
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

/// 墨水屏弹窗胶囊按钮：裸 Container 描边 + GestureDetector，
/// 不依赖 Material 按钮机制（真机复现过文字不绘制的问题）。
Widget _inkPillButton(String label, VoidCallback onTap) {
  return GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Container(
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 1),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
            color: Colors.black,
            fontSize: 15,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none),
      ),
    ),
  );
}

/// 更新确认弹窗：返回 'install' / 'ignore' / null（直接关闭）。
/// 墨水屏适配：白底黑字、浅色遮罩、零动画；Windows 与安卓文案不同。
Future<String?> showUpdateConfirmDialog(
  BuildContext context, {
  required String cloudVersion,
  required String currentVersion,
  required String fileName,
  required String sizeMb,
  required bool ink,
}) {
  return showAppDialog<String>(
    context: context,
    barrierColor: ink ? Colors.black12 : null,
    builder: (ctx) => AlertDialog(
      backgroundColor: ink ? Colors.white : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ink ? 2 : 16),
        side: ink
            ? const BorderSide(color: Colors.black, width: 1)
            : BorderSide.none,
      ),
      titleTextStyle: ink
          ? const TextStyle(
              color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold)
          : null,
      contentTextStyle: ink
          ? const TextStyle(color: Colors.black, height: 1.45)
          : null,
      title: Text('发现新版本 v$cloudVersion'),
      content: SizedBox(
        width: 300,
        child: Text('当前版本 v$currentVersion\n'
            '安装包：$fileName（$sizeMb MB）'),
      ),
      actions: [
        // 按钮并排铺满整行，竖屏/横屏都不挤压；文字禁止换行。
        // 墨水屏按钮不使用 OutlinedButton/InkWell：真机上（MuMu/电纸书
        // 实测复现）Material 按钮机制内的 Text 会出现"样式正确但完全不
        // 绘制"的问题（按钮边框正常、内部纯白），改用裸 Container +
        // GestureDetector + 显式黑字，无水波纹也更贴合墨水屏零动画
        Row(
          children: [
            Expanded(
              child: ink
                  ? _inkPillButton('忽略', () => Navigator.pop(ctx, 'ignore'))
                  : OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, 'ignore'),
                      child: const Text('忽略',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ink
                  ? _inkPillButton('下载', () => Navigator.pop(ctx, 'install'))
                  : FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'install'),
                      child: const Text('下载',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 下载更新包（带进度弹窗，流式下载）：
/// 安卓调起系统安装；Windows 下载后在资源管理器中定位文件。
/// 返回 null 表示已发起；否则为错误信息文本。
Future<String?> downloadAndInstallApk(
  BuildContext context, {
  required WebDavSync webdav,
  required AppSettings s,
  required String fileName,
  int expectedSize = 0,
  required bool ink,
}) async {
  var progress = 0.0;
  StateSetter? dialogSetState;
  final progressDialog = showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: ink ? Colors.black12 : null,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        dialogSetState = setState;
        return AlertDialog(
          backgroundColor: ink ? Colors.white : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ink ? 2 : 16),
            side: ink
                ? const BorderSide(color: Colors.black, width: 1)
                : BorderSide.none,
          ),
          titleTextStyle: ink
              ? const TextStyle(
                  color: Colors.black,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)
              : null,
          contentTextStyle:
              ink ? const TextStyle(color: Colors.black) : null,
          title: const Text('正在下载更新'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                  value: progress <= 0 ? null : progress,
                  backgroundColor: ink ? Colors.white : null,
                  color: ink ? Colors.black : null),
              const SizedBox(height: 12),
              Text(progress <= 0
                  ? '准备中…'
                  : '${(progress * 100).toStringAsFixed(0)}%'),
            ],
          ),
        );
      },
    ),
  );
  try {
    final file = await webdav.downloadUpdateApk(
      s,
      fileName,
      onProgress: (c, t) {
        if (t > 0) {
          try {
            dialogSetState?.call(() => progress = c / t);
          } catch (_) {}
        }
      },
    );
    // 下载完整性校验：字节数与云端目录信息不符视为失败，
    // 避免半截包调起安装器后报"软件包似乎无效"误导用户
    if (expectedSize > 0 && file.lengthSync() != expectedSize) {
      try {
        await file.delete();
      } catch (_) {}
      return '下载不完整（${file.lengthSync()} / $expectedSize 字节），请重试';
    }
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // 关进度框
    }
    final res = await OpenFilex.open(file.path,
        type: 'application/vnd.android.package-archive');
    // 注意：安装期间绝不能删除安装包——系统安装器异步读取文件，
    // 过早删除会报"软件包似乎无效"。清理交给应用下次启动时统一进行。
    if (res.type != ResultType.done) {
      return '无法启动安装：${res.message}';
    }
    return null;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    return '下载失败：$e';
  } finally {
    await progressDialog;
  }
}
