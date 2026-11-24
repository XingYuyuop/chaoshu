import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/font_service.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';

/// 字体 / 版式 / 练习 / 配色 控制组（练习页排版弹层专用）。
/// 分组排版：每组带小标题与分隔线，滑块数值右对齐。
class TypographyControls extends StatelessWidget {
  final SettingsProvider settings;

  const TypographyControls({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    final s = settings.s;
    final theme = Theme.of(context);
    // 内置字体 + 自定义字体
    final fontItems = <MapEntry<String, String>>[
      ...fontFamilyOptions.entries,
      ...FontService.customFonts.entries
          .map((e) => MapEntry(e.key, e.value)),
    ];
    final currentFamily = fontItems.any((e) => e.key == s.fontFamily)
        ? s.fontFamily
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---------- 字体 ----------
        _sectionLabel(theme, '字体'),
        DropdownButton<String>(
          isExpanded: true,
          value: currentFamily,
          items: fontItems
              .map((e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value),
                  ))
              .toList(),
          onChanged: (v) =>
              settings.update((x) => x.copyWith(fontFamily: v ?? '')),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.only(left: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () => _importFont(context),
            icon: const Icon(Icons.text_increase_outlined, size: 18),
            label: const Text('导入字体文件（TTF / OTF）'),
          ),
        ),
        _sectionDivider(theme),

        // ---------- 版式 ----------
        _sectionLabel(theme, '版式'),
        _sliderTile(
          context,
          label: '字号',
          display: '${s.fontSize.round()}',
          value: s.fontSize,
          min: 12,
          max: 36,
          divisions: 24,
          onChanged: (v) => settings.update((x) => x.copyWith(fontSize: v)),
        ),
        _sliderTile(
          context,
          label: '行间距',
          display: s.lineHeight.toStringAsFixed(1),
          value: s.lineHeight,
          min: 1.2,
          max: 3.0,
          divisions: 18,
          onChanged: (v) => settings.update((x) => x.copyWith(lineHeight: v)),
        ),
        _sliderTile(
          context,
          label: '页边距',
          display: '${s.pageMargin.round()}',
          value: s.pageMargin,
          min: 8,
          max: 64,
          divisions: 14,
          onChanged: (v) => settings.update((x) => x.copyWith(pageMargin: v)),
        ),
        _sectionDivider(theme),

        // ---------- 练习 ----------
        _sectionLabel(theme, '练习字形（简繁转换）'),
        Text(
          switch (s.charVariant) {
            't' => '繁体：原文自动转为繁体抄录',
            's' => '简体：繁体原文自动转为简体',
            _ => '默认：保持原文，不做转换',
          },
          style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'default', label: Text('默认')),
            ButtonSegment(value: 's', label: Text('简')),
            ButtonSegment(value: 't', label: Text('繁')),
          ],
          selected: {
            ['default', 's', 't'].contains(s.charVariant)
                ? s.charVariant
                : 'default'
          },
          onSelectionChanged: (sel) =>
              settings.update((x) => x.copyWith(charVariant: sel.first)),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.only(left: 4),
          title: const Text('点击输入框时弹出软键盘'),
          subtitle: Text(s.showSoftKeyboard
              ? '开启：触屏点击弹出输入法打字'
              : '关闭：不弹软键盘，使用实体/外接键盘输入（墨水屏推荐）'),
          value: s.showSoftKeyboard,
          onChanged: (v) =>
              settings.update((x) => x.copyWith(showSoftKeyboard: v)),
        ),
        _sectionDivider(theme),

        // ---------- 配色 ----------
        _sectionLabel(theme, '页面配色'),
        DropdownButton<String>(
          isExpanded: true,
          value: paneBackgroundKeys.contains(s.paneBackground)
              ? s.paneBackground
              : 'paper',
          items: paneBackgroundKeys
              .map((k) => DropdownMenuItem(
                    value: k,
                    child: Text(paneBackgroundLabels[k] ?? k),
                  ))
              .toList(),
          onChanged: (v) =>
              settings.update((x) => x.copyWith(paneBackground: v)),
        ),
      ],
    );
  }

  Widget _sectionLabel(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _sectionDivider(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Divider(height: 1, color: theme.dividerColor),
    );
  }

  Future<void> _importFont(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['ttf', 'otf'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      final path = result.files.single.path;
      if (path == null) return;
      final family = await FontService.importFont(path);
      await settings.update((x) => x.copyWith(fontFamily: family));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  '已导入字体「${result.files.single.name}」并应用')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入字体失败：$e')),
        );
      }
    }
  }

  /// 滑块行：标签居左、当前值居右，滑块占整行。
  Widget _sliderTile(
    BuildContext context, {
    required String label,
    required String display,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text(
              display,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
