import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/webdav_sync.dart';
import '../state/library_provider.dart';
import '../state/settings_provider.dart';
import 'practice_screen.dart';

/// 章节列表页：完成状态、断点续练入口。
class BookScreen extends StatefulWidget {
  final Book book;

  const BookScreen({super.key, required this.book});

  static Route route(Book book) {
    return MaterialPageRoute(builder: (_) => BookScreen(book: book));
  }

  @override
  State<BookScreen> createState() => _BookScreenState();
}

class _BookScreenState extends State<BookScreen> {
  @override
  void initState() {
    super.initState();
    // 进入书籍页时轻量拉取远端断点，让"继续练习"与章节列表拿到最新进度。
    // 必须只执行一次：此前写在 build 的 postFrame 里，
    // pull → refresh → 重建 → 再 pull 会形成每秒多轮请求的死循环
    //（实测：空闲时 CPU 50%+、持续几十 KB/s 网络流量、云端零写入）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final webdav = context.read<WebDavSync>();
      final s = context.read<SettingsProvider>().s;
      if (s.webdavAutoSync && s.webdavUrl.trim().isNotEmpty) {
        webdav.pullProgress(s).then((_) {
          if (mounted) context.read<LibraryProvider>().refresh();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final book = widget.book;
    // 书可能被删除或经同步更新，取最新实例
    final current = lib.books.firstWhere(
      (b) => b.id == book.id,
      orElse: () => book,
    );
    final progress = lib.progressOf(current.id);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          current.title,
          // 跟随用户设置的字体
          style: theme.textTheme.titleMedium?.copyWith(
            fontFamily: context
                    .read<SettingsProvider>()
                    .s
                    .fontFamily
                    .isEmpty
                ? null
                : context.read<SettingsProvider>().s.fontFamily,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (current.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                current.description,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text(
                  '共 ${current.chapterTitles.length} 章 · 已完成 ${progress.completedCount} 章',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _continue(context, current, progress),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: const Text('继续练习'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: current.chapterTitles.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final cp = progress.chapters[i];
                final done = cp?.completed ?? false;
                final isLast = progress.lastChapterIndex == i;
                return ListTile(
                  leading: done
                      ? Icon(Icons.check_circle,
                          color: theme.colorScheme.primary, size: 20)
                      : (isLast && cp != null
                          ? Icon(Icons.edit_note,
                              color: theme.colorScheme.outline, size: 20)
                          : const SizedBox(
                              width: 20,
                              height: 20,
                            )),
                  title: Text(
                    current.chapterTitles[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      decoration:
                          done ? TextDecoration.lineThrough : null,
                      color: done ? theme.colorScheme.outline : null,
                    ),
                  ),
                  subtitle: (cp != null && !done && cp.paragraphIndex > 0)
                      ? Text(
                          '练到第 ${cp.paragraphIndex + 1} 段',
                          style: theme.textTheme.bodySmall,
                        )
                      : null,
                  trailing: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  onTap: () => _openPractice(context, current, i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _continue(BuildContext context, Book book, BookProgress progress) {
    _openPractice(context, book, progress.lastChapterIndex);
  }

  void _openPractice(BuildContext context, Book book, int chapterIndex) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PracticeScreen(book: book, chapterIndex: chapterIndex),
      ),
    );
  }
}
