import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../services/app_update.dart';
import '../services/webdav_sync.dart';
import '../state/library_provider.dart';
import '../state/settings_provider.dart';
import '../widgets/app_dialog.dart';
import 'book_screen.dart';

/// 书库首页：书籍网格 + 导入（按钮 / 拖拽）。
class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          if (lib.importing)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            _buildMenu(context),
        ],
      ),
      body: DropTarget(
        onDragDone: (details) => _importPaths(context, details.files
            .map((f) => f.path)
            .toList()),
        onDragEntered: (_) {},
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody(context, lib)),
            // 导入失败横幅覆盖在顶部：出现/消失不挤压书架布局；
            // 左右滑动可关闭
            if (lib.importError != null)
              Positioned(
                left: 12,
                right: 12,
                top: 8,
                child: Dismissible(
                  key: ValueKey(lib.importError),
                  direction: DismissDirection.horizontal,
                  onDismissed: (_) => lib.clearError(),
                  child: Material(
                    elevation: 4,
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(4),
                    child: ListTile(
                      dense: true,
                      leading: const Icon(Icons.error_outline),
                      title: Text('导入失败：${lib.importError}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => lib.clearError(),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: lib.importing ? null : () => _import(context),
        icon: const Icon(Icons.upload_file),
        label: const Text('导入书籍'),
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final lib = context.read<LibraryProvider>();
    final book = await lib.importFromPicker();
    if (book != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.title}》导入成功，点击书籍选择章节开始抄书')),
      );
    }
  }

  // ---------- 右上角菜单 ----------
  Widget _buildMenu(BuildContext context) {
    return IconButton(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert),
      onPressed: () async {
        final items = [
          const AppMenuItem('upload', '导入书籍', icon: Icons.upload_file),
          const AppMenuItem('backup', '备份数据',
              icon: Icons.cloud_upload_outlined),
          const AppMenuItem('restore', '还原数据',
              icon: Icons.cloud_download_outlined),
          const AppMenuItem('overwrite', '覆盖备份',
              icon: Icons.cloud_sync_outlined),
          if (Platform.isAndroid)
            const AppMenuItem('update', '检查更新',
                icon: Icons.system_update_alt),
        ];
        final v = await showAppMenu<String>(
            context: context, items: items);
        if (!context.mounted || v == null) return;
        switch (v) {
          case 'upload':
            _import(context);
          case 'backup':
            _doSync(context, overwrite: false);
          case 'restore':
            _doRestore(context);
          case 'overwrite':
            _doSync(context, overwrite: true);
          case 'update':
            _checkUpdate(context);
        }
      },
    );
  }

  void _toast(BuildContext context, String msg, {bool error = false}) {
    if (!context.mounted) return;
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        // 成功提示停留 3 秒，失败提示停留 5 秒
        duration: Duration(seconds: error ? 5 : 3),
        backgroundColor: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(2),
          side: BorderSide(
              color: error
                  ? theme.colorScheme.error
                  : theme.colorScheme.outline.withValues(alpha: 0.6)),
        ),
        content: Text(msg,
            style: TextStyle(
                color: error ? theme.colorScheme.error : theme.colorScheme.onSurface)),
      ));
  }

  /// 简短具体的同步错误提示（少字数、说人话）。
  String _syncErrMsg(Object e) {
    final s = e.toString();
    if (e is TimeoutException ||
        s.contains('TimeoutException') ||
        s.contains('timed out')) {
      return '连接超时，检查网络后重试';
    }
    if (s.contains('SocketException') ||
        s.contains('Connection refused') ||
        s.contains('Failed host lookup') ||
        s.contains('Network is unreachable')) {
      return '无法连接服务器，检查网络或服务器地址';
    }
    if (s.contains('401') || s.contains('Unauthorized')) {
      return '账号或密码错误';
    }
    if (s.contains('403') || s.contains('Forbidden')) {
      return '服务器拒绝访问（权限不足）';
    }
    if (s.contains('404')) {
      return '服务器路径不存在';
    }
    return '同步失败：${s.length > 60 ? '${s.substring(0, 60)}…' : s}';
  }

  Future<void> _doSync(BuildContext context, {required bool overwrite}) async {
    final settings = context.read<SettingsProvider>().s;
    if (settings.webdavUrl.trim().isEmpty) {
      _toast(context, '未配置 WebDAV，请到 设置-同步 填写服务器信息', error: true);
      return;
    }
    if (overwrite) {
      final ok = await showAppDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('覆盖同步'),
          content: const Text(
              '覆盖同步将覆盖云端所有的内容，包括云端的书籍也与本地相同，练习进度将合并'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('继续')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final webdav = context.read<WebDavSync>();
    try {
      _toast(context, overwrite ? '正在覆盖备份…' : '正在备份…');
      await webdav.sync(settings, overwrite: overwrite);
      _toast(context, overwrite ? '覆盖备份完成' : '备份完成');
    } catch (e) {
      _toast(context, _syncErrMsg(e), error: true);
    }
  }

  Future<void> _doRestore(BuildContext context) async {
    final settings = context.read<SettingsProvider>().s;
    if (settings.webdavUrl.trim().isEmpty) {
      _toast(context, '未配置 WebDAV，请到 设置-同步 填写服务器信息', error: true);
      return;
    }
    final webdav = context.read<WebDavSync>();
    try {
      _toast(context, '正在从云端还原…');
      await webdav.restore(settings);
      await context.read<LibraryProvider>().refresh();
      _toast(context, '还原完成：书籍、进度、统计已从云端恢复');
    } catch (e) {
      _toast(context, _syncErrMsg(e), error: true);
    }
  }

  Future<void> _checkUpdate(BuildContext context) async {
    final settingsProv = context.read<SettingsProvider>();
    final s = settingsProv.s;
    if (s.webdavUrl.trim().isEmpty) {
      _toast(context, '未配置 WebDAV，无法检测更新', error: true);
      return;
    }
    final webdav = context.read<WebDavSync>();
    try {
      final info = await webdav.checkUpdate(s);
      if (!context.mounted) return;
      if (info == null) {
        _toast(context, '云端 apk 目录未找到安装包', error: true);
        return;
      }
      final pkg = await PackageInfo.fromPlatform();
      if (!context.mounted) return;
      final cloud = info['version']!;
      if (cmpVersion(cloud, pkg.version) <= 0) {
        _toast(context, '已是最新版本 v${pkg.version}');
        return;
      }
      final choice = await showUpdateConfirmDialog(
        context,
        cloudVersion: cloud,
        currentVersion: pkg.version,
        fileName: info['fileName']!,
        sizeMb: ((int.tryParse(info['size'] ?? '0') ?? 0) / 1048576)
            .toStringAsFixed(1),
        ink: settingsProv.isInk,
      );
      if (!context.mounted || choice != 'install') return;
      final err = await downloadAndInstallApk(
        context,
        webdav: webdav,
        s: settingsProv.s,
        fileName: info['fileName']!,
        expectedSize: int.tryParse(info['size'] ?? '0') ?? 0,
        ink: settingsProv.isInk,
      );
      if (context.mounted && err != null) {
        _toast(context, err, error: true);
      }
    } catch (e) {
      if (context.mounted) _toast(context, '检测更新失败：$e', error: true);
    }
  }

  Future<void> _importPaths(BuildContext context, List<String> paths) async {
    if (paths.isEmpty) return;
    final lib = context.read<LibraryProvider>();
    final book = await lib.importFromPaths(paths);
    if (book != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.title}》导入成功，点击书籍选择章节开始抄书')),
      );
    }
  }

  Widget _buildBody(BuildContext context, LibraryProvider lib) {
    // 书架排序：最近练习的书排最前，其余按导入时间
    final books = lib.books.toList()
      ..sort((a, b) {
        final la = a.lastOpenedAtMs;
        final lb = b.lastOpenedAtMs;
        if (la != lb) return lb.compareTo(la);
        return b.importedAt.compareTo(a.importedAt);
      });
    if (books.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_library_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('还没有书籍',
                style: Theme.of(context).textTheme.titleMedium),
            // 手机端不显示引导文案；桌面端保留（支持拖入文件）
            if (!Platform.isAndroid && !Platform.isIOS)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48),
                child: Text(
                  '点击右下角按钮选择文件，\n或直接拖入 TXT / EPUB 电子书',
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      );
    }
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width > 900 ? 4 : (width > 560 ? 3 : 2);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.72,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (context, i) => _BookCard(book: books[i]),
    );
  }
}

class _BookCard extends StatelessWidget {
  final Book book;
  const _BookCard({required this.book});

  @override
  Widget build(BuildContext context) {
    final lib = context.watch<LibraryProvider>();
    final progress = lib.progressOf(book.id);
    final done = progress.completedCount;
    final total = book.chapterTitles.length;
    final theme = Theme.of(context);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(BookScreen.route(book)),
        onLongPress: () => _confirmDelete(context),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _cover(context),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                book.author.isEmpty
                    ? '${book.sourceFormat.toUpperCase()} · $total 章'
                    : '${book.author} · $total 章',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : done / total,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('$done/$total',
                      style: theme.textTheme.labelSmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover(BuildContext context) {
    final file = Provider.of<LibraryProvider>(context, listen: false)
        .store
        .coverFile(book);
    if (file != null) {
      // cacheWidth 按显示尺寸解码：封面原图可达 1.6MB（数千像素宽），
      // 全分辨率解码在主线程会造成书架/返回时的卡顿。
      // 系数取 420（卡片宽约 200-280 逻辑像素的 1.5 倍余量）：
      // 桌面端 DPR=1.0 时旧值 180px 偏模糊，现与手机端观感一致。
      return Image.file(
        file,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: (MediaQuery.devicePixelRatioOf(context) * 420).round(),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        book.sourceFormat == 'epub'
            ? Icons.auto_stories
            : Icons.description,
        size: 40,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final lib = context.read<LibraryProvider>();
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书籍'),
        content: Text('确定删除《${book.title}》吗？练习进度与统计将保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await lib.deleteBook(book.id);
    }
  }
}
