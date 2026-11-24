import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/webdav_sync.dart';
import '../state/settings_provider.dart';
import 'app_dialog.dart';

/// 启动增强同步相关弹窗（走 showAppDialog，墨水屏零动画适配）。
/// 墨水屏下按钮必须用 inkPillButton：Material 按钮在真机上存在
/// Text 不绘制的问题（见 app_dialog.dart 说明）。

/// 「数据同步」书籍差异提示弹窗。
/// 返回 'overwrite'（用户选择覆盖上传）或 null（知道了/点外部关闭）。
Future<String?> showSyncDiffDialog(
  BuildContext context, {
  required SyncDiffInfo diff,
}) {
  final ink = context.read<SettingsProvider>().isInk;
  return showAppDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('数据同步'),
      content: SizedBox(
        width: 300,
        child: Text('检测到书籍差异：本机独有 ${diff.localOnlyBooks} 本，'
            '云端独有 ${diff.cloudOnlyBooks} 本。\n'
            '已自动合并并上传到云端。'),
      ),
      actions: [
        // 按钮并排铺满整行，竖屏/横屏都不挤压；文字禁止换行
        Row(
          children: [
            Expanded(
              child: ink
                  ? inkPillButton('知道了', () => Navigator.pop(ctx))
                  : OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('知道了',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ink
                  ? inkPillButton(
                      '覆盖上传', () => Navigator.pop(ctx, 'overwrite'))
                  : FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'overwrite'),
                      child: const Text('覆盖上传',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ),
      ],
    ),
  );
}

/// 覆盖同步二次确认（文案与设置页/书架页的覆盖同步弹窗一致）。
Future<bool> confirmOverwriteSyncDialog(BuildContext context) async {
  final ink = context.read<SettingsProvider>().isInk;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('覆盖同步'),
      content: const Text(
          '将以本机数据为准覆盖云端：\n\n'
          '· 本地删除的书籍会同时从云端删除\n'
          '· 云端有而本地没有的书籍不会下载\n'
          '· 练习进度与统计仍按时间自动合并\n\n'
          '确定继续吗？'),
      actions: [
        Row(
          children: [
            Expanded(
              child: ink
                  ? inkPillButton('取消', () => Navigator.pop(ctx, false))
                  : TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ink
                  ? inkPillButton('覆盖同步', () => Navigator.pop(ctx, true))
                  : FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('覆盖同步',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ),
      ],
    ),
  );
  return ok == true;
}
