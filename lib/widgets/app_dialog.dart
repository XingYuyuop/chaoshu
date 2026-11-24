import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/settings_provider.dart';

/// 墨水屏零动画弹层助手：
/// - 墨水屏模式：弹窗/菜单/底栏全部零过渡（RawDialogRoute 瞬时呈现），
///   无淡入淡出、无缩放、无上滑，避免刷新残影与闪烁。
/// - 普通模式：走系统默认动画，观感不变。

/// 弹窗（替代 showDialog）。
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
}) {
  final ink = context.read<SettingsProvider>().isInk;
  if (!ink) {
    return showDialog<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
      barrierColor: barrierColor,
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 墨水屏：遮罩全透明——只显示弹窗本身，周围背景不做任何变化
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, a1, a2) => Center(
      // 不嵌套 Dialog：透明 Material 仅承载，AlertDialog 自带白底黑框
      // （墨水屏主题），居中且按内容收缩，避免出现整屏大白框。
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 280),
          child: Material(
            type: MaterialType.transparency,
            child: builder(ctx),
          ),
        ),
      ),
    ),
  );
}

/// 墨水屏弹窗胶囊按钮：裸 Container 描边 + GestureDetector，
/// 不依赖 Material 按钮机制（真机复现过 Material 按钮内 Text
/// "样式正确但完全不绘制"的问题，见 app_update.dart 同款私有实现）。
/// 供各弹窗在墨水屏模式下复用。
Widget inkPillButton(String label, VoidCallback onTap) {
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

/// 底部弹层（替代 showModalBottomSheet）。
Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final ink = context.read<SettingsProvider>().isInk;
  if (!ink) {
    return showModalBottomSheet<T>(
      context: context,
      builder: builder,
      shape: RoundedRectangleBorder(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(16)),
        side: BorderSide(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4)),
      ),
    );
  }
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, a1, a2) => Align(
      alignment: Alignment.bottomCenter,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(2)),
          side: BorderSide(color: Colors.black, width: 1),
        ),
        child: SafeArea(child: builder(ctx)),
      ),
    ),
  );
}

/// 菜单项模型。
class AppMenuItem {
  final String value;
  final String label;
  final IconData? icon;
  const AppMenuItem(this.value, this.label, {this.icon});
}

/// 右上角菜单（替代 PopupMenuButton）。
/// 返回选中项 value；未选返回 null。
Future<String?> showAppMenu<T extends Object>({
  required BuildContext context,
  required List<AppMenuItem> items,
  String? initialValue,
}) {
  final ink = context.read<SettingsProvider>().isInk;
  if (!ink) {
    return showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        MediaQuery.of(context).size.width - 8,
        kTextTabBarHeight + MediaQuery.of(context).padding.top,
        8,
        0,
      ),
      items: items
          .map((e) => PopupMenuItem<String>(
                value: e.value,
                child: Row(
                  children: [
                    if (e.icon != null) Icon(e.icon, size: 20),
                    if (e.icon != null) const SizedBox(width: 10),
                    Text(e.label),
                  ],
                ),
              ))
          .toList(),
    );
  }
  // 墨水屏：零动画的静态卡片菜单，右上角对齐，遮罩全透明（避免整屏闪烁）
  final theme = Theme.of(context);
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (ctx, a1, a2) => Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: EdgeInsets.only(
          top: kToolbarHeight + MediaQuery.of(ctx).padding.top + 4,
          right: 8,
        ),
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(2),
            side: const BorderSide(color: Colors.black, width: 1),
          ),
          elevation: 0,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final e in items)
                  InkWell(
                    onTap: () => Navigator.pop(ctx, e.value),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (e.icon != null)
                            Icon(e.icon,
                                size: 18, color: theme.colorScheme.onSurface),
                          if (e.icon != null) const SizedBox(width: 10),
                          Text(e.label,
                              style: TextStyle(
                                  color: theme.colorScheme.onSurface)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
