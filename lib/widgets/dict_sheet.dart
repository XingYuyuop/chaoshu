import 'package:flutter/material.dart';

import '../services/dict_service.dart';
import 'app_dialog.dart';

/// 内置字典查询弹层。
/// [initialQuery] 打开时预填并立即查询。
Future<void> showDictSheet(BuildContext context, {String? initialQuery}) {
  return showAppBottomSheet(
    context: context,
    builder: (ctx) => DictSheet(initialQuery: initialQuery),
  );
}

class DictSheet extends StatefulWidget {
  final String? initialQuery;

  const DictSheet({super.key, this.initialQuery});

  @override
  State<DictSheet> createState() => _DictSheetState();
}

class _DictSheetState extends State<DictSheet> {
  late final TextEditingController _controller;
  List<DictEntry> _results = [];
  bool _queried = false; // 是否执行过非空查询（区分提示语与“未收录”）
  int _seq = 0; // 防止旧查询结果晚到覆盖新结果

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialQuery ?? '');
    _search(widget.initialQuery ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final seq = ++_seq;
    final results = await DictService.lookup(query);
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = results;
      _queried = query.trim().isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        // 软键盘弹出时整体上移，保证输入框可见
        padding: EdgeInsets.fromLTRB(
            20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行：标题居左，关闭按钮居右
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('字典',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '关闭',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onChanged: _search,
              onSubmitted: _search,
              decoration: const InputDecoration(
                hintText: '输入字或词',
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: _resultsView(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultsView(ThemeData theme) {
    if (!_queried) {
      return Text('输入汉字后显示读音、部首与释义',
          style:
              theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline));
    }
    if (_results.isEmpty) {
      return Text('未收录该字',
          style:
              theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline));
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      itemCount: _results.length,
      itemBuilder: (context, i) => _entryBlock(theme, _results[i], i > 0),
    );
  }

  /// 单字结果块：大字 + 拼音/部首笔画 + 释义全文。
  Widget _entryBlock(ThemeData theme, DictEntry entry, bool withDivider) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (withDivider) ...[
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 12),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.char,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontSize: 34, height: 1.1)),
              const SizedBox(width: 14),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.pinyin.isEmpty ? '—' : entry.pinyin,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '部首 ${entry.radical.isEmpty ? '—' : entry.radical}　${entry.strokes} 画',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (entry.explanation.isNotEmpty)
            Text(entry.explanation, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
