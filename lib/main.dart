import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'screens/library_screen.dart';
import 'screens/practice_screen.dart';
import 'screens/stats_screen.dart';
import 'screens/settings_screen.dart';
import 'services/font_service.dart';
import 'services/app_update.dart';
import 'services/library_store.dart';
import 'services/stats_service.dart';
import 'services/webdav_sync.dart';
import 'services/zh_conv.dart';
import 'state/library_provider.dart';
import 'state/practice_provider.dart';
import 'state/settings_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/sync_diff_dialog.dart';

/// 清理临时目录中历史更新遗留的安装包（每次约 20MB，避免无限累积）。
Future<void> _cleanupApkCache() async {
  try {
    final tmp = await getTemporaryDirectory();
    for (final f in tmp.listSync().whereType<File>()) {
      final name = f.path.split('/').last.split('\\').last;
      if (name.startsWith('抄书打字-Android-v') && name.endsWith('.apk')) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 全局崩溃日志（写入应用数据目录 crash.log，便于排查闪退）
  final support = await getApplicationSupportDirectory();
  final logFile =
      File('${support.path}/chaoshu_data/crash.log');
  void logCrash(String source, Object error, StackTrace? stack) {
    try {
      logFile.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $source\n$error\n$stack\n\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }
  FlutterError.onError = (details) {
    logCrash('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logCrash('PlatformDispatcher', error, stack);
    return true;
  };

  final store = LibraryStore();
  await store.init();
  await FontService.init(store.baseDir);
  unawaited(ZhConv.init()); // 词库后台加载，未就绪时恒等返回
  // 安卓：启动时清理上次更新遗留的安装包缓存。安装期间不能删
  // （系统安装器异步读文件，早删会报"软件包似乎无效"），
  // 统一放到启动时清理，既不残留大文件也不破坏安装。
  if (Platform.isAndroid) {
    unawaited(_cleanupApkCache());
  }
  final stats = StatsService(store);
  await stats.load();
  final settings = SettingsProvider();
  await settings.load();
  final webdav = WebDavSync(store, stats);
  webdav.settingsProv = settings; // 显示设置参与同步

  // 练习结束自动同步（配置完整且开启时）
  Future<void> autoSyncAfterPractice() async {
    final s = settings.s;
    if (!s.webdavAutoSync || s.webdavUrl.trim().isEmpty) return;
    await webdav.sync(s);
  }

  runApp(
    MultiProvider(
      providers: [
        Provider<LibraryStore>.value(value: store),
        ChangeNotifierProvider<StatsService>.value(value: stats),
        Provider<WebDavSync>.value(value: webdav),
        ChangeNotifierProvider<SettingsProvider>.value(value: settings),
        ChangeNotifierProvider(
          create: (_) => LibraryProvider(store),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final p = PracticeProvider(store, stats, settings);
            p.onSessionEnd = autoSyncAfterPractice;
            p.onPushProgress = () => webdav.pushProgress(settings.s);
            p.onPullProgress = () => webdav.pullProgress(settings.s);
            return p;
          },
        ),
      ],
      child: const ChaoshuApp(),
    ),
  );
}

class ChaoshuApp extends StatelessWidget {
  const ChaoshuApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final ink = settings.isInk;
    return MaterialApp(
      title: '抄书打字',
      debugShowCheckedModeBanner: false,
      // 强制中文界面（含系统文本选择工具条：剪切/拷贝/粘贴/全选）
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildLightTheme(ink: ink),
      darkTheme: buildDarkTheme(ink: ink),
      themeMode: ink ? ThemeMode.light : settings.themeMode,
      // 主题切换零动画：墨水屏切换模式不闪烁、无渐变残影
      themeAnimationDuration: Duration.zero,
      themeAnimationCurve: Curves.linear,
      // 全局禁用过滚动发光/回弹：墨水屏不留残影，普通屏更克制
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        overscroll: false,
      ),
      home: const HomeShell(),
    );
  }
}

const _tvFocusChannel = MethodChannel('chaoshu/tv_focus');

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _restored = false;
  bool _startupSyncDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tvFocusChannel.setMethodCallHandler(_onTvFocusCall);
    FocusManager.instance.addListener(_onGlobalFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreRecentPractice();
      unawaited(_autoCheckUpdate());
      // 启动增强同步：首页首帧可用后再执行（不在 splash/加载期弹窗）
      unawaited(_startupEnhanceSync());
      // 遥控器/键盘操作时，启动后要有一个初始焦点，否则方向键和
      // 确认键都无处落脚（表现为遥控器完全没反应）
      final scope = FocusScope.of(context);
      final primary = FocusManager.instance.primaryFocus;
      if (primary == null || identical(primary, scope)) {
        scope.nextFocus();
      }
    });
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onGlobalFocusChange);
    _tvFocusChannel.setMethodCallHandler(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 焦点是否在某个输入框内。在输入框里时方向键会被搜狗 TV 输入法
  /// 抢去移动光标，需要通知原生层接管方向键。
  bool _isEditingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.widget is EditableText;
  }

  void _onGlobalFocusChange() {
    _tvFocusChannel
        .invokeMethod('setCaptureDpad', _isEditingText())
        .catchError((_) => null);
  }

  /// Android TV / 电纸书端：原生层把方向键/确认键转发过来，移动 Flutter 焦点。
  Future<dynamic> _onTvFocusCall(MethodCall call) async {
    if (call.method != 'navigate') return null;
    final action = call.arguments as String?;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) {
      // 还没有任何焦点时，先聚焦第一个可聚焦控件
      FocusScope.of(context).nextFocus();
      return null;
    }
    if (action == 'confirm') {
      // 触发当前焦点控件的“点击”动作（InkWell / 按钮都注册了 ActivateIntent）
      final ctx = primary.context;
      if (ctx != null && Actions.maybeFind<ActivateIntent>(ctx) != null) {
        Actions.maybeInvoke(ctx, const ActivateIntent());
      } else {
        primary.nextFocus();
      }
      return null;
    }
    switch (action) {
      case 'up':
        if (!primary.focusInDirection(TraversalDirection.up)) {
          primary.previousFocus();
        }
      case 'down':
        if (!primary.focusInDirection(TraversalDirection.down)) {
          primary.nextFocus();
        }
      case 'left':
        primary.focusInDirection(TraversalDirection.left);
      case 'right':
        primary.focusInDirection(TraversalDirection.right);
    }
    return null;
  }

  /// 锁屏/切后台恢复时自动拉取远端进度并刷新界面：
  /// 进程在锁屏期间存活时界面停留在旧快照，其他设备的新进度
  /// 只有重新拉取才能看到（无需退出重进）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_pullOnResume());
    }
  }

  Future<void> _pullOnResume() async {
    if (!mounted) return;
    final settingsProv = context.read<SettingsProvider>();
    final s = settingsProv.s;
    if (!s.webdavAutoSync || s.webdavUrl.trim().isEmpty) return;
    try {
      await context
          .read<WebDavSync>()
          .pullProgress(s)
          .timeout(const Duration(seconds: 8), onTimeout: () {});
    } catch (_) {}
    if (!mounted) return;
    await context.read<LibraryProvider>().refresh();
  }

  /// 每次启动自动检查更新（安卓，已配置 WebDAV 时）。
  /// 有新版弹窗提示；点"忽略此版本"后该版本不再自动弹出（手动检测仍会显示）。
  Future<void> _autoCheckUpdate() async {
    try {
      if (!Platform.isAndroid || !mounted) return;
      final settingsProv = context.read<SettingsProvider>();
      final s = settingsProv.s;
      if (s.webdavUrl.trim().isEmpty) return;
      final webdav = context.read<WebDavSync>();
      final info = await webdav.checkUpdate(s);
      if (info == null || !mounted) return;
      final pkg = await PackageInfo.fromPlatform();
      if (!mounted) return;
      final cloud = info['version']!;
      if (cmpVersion(cloud, pkg.version) <= 0) return;
      if (cloud == settingsProv.s.ignoredUpdateVersion) return;
      final ink = settingsProv.isInk;
      final choice = await showUpdateConfirmDialog(
        context,
        cloudVersion: cloud,
        currentVersion: pkg.version,
        fileName: info['fileName']!,
        sizeMb: ((int.tryParse(info['size'] ?? '0') ?? 0) / 1048576)
            .toStringAsFixed(1),
        ink: ink,
      );
      if (!mounted) return;
      if (choice == 'ignore') {
        await settingsProv
            .update((x) => x.copyWith(ignoredUpdateVersion: cloud));
        return;
      }
      if (choice == 'install') {
        await downloadAndInstallApk(
          context,
          webdav: webdav,
          s: settingsProv.s,
          fileName: info['fileName']!,
          expectedSize: int.tryParse(info['size'] ?? '0') ?? 0,
          ink: ink,
        );
      }
    } catch (_) {
      // 启动检查失败静默忽略
    }
  }

  /// 启动增强同步（首页首帧后触发，本次启动最多执行一次）：
  /// 全量同步（拉取云端 → 合并 → 上传合并结果），完成后若存在书籍差异
  /// 且「启动时增强同步」开关开启，弹窗告知并提供「覆盖上传」入口。
  /// 同步失败静默：不打扰启动流程，用户可随时手动同步。
  Future<void> _startupEnhanceSync() async {
    if (_startupSyncDone) return;
    _startupSyncDone = true;
    if (!mounted) return;
    final settingsProv = context.read<SettingsProvider>();
    final s = settingsProv.s;
    if (!s.startupEnhanceSync) return;
    if (!s.webdavAutoSync || s.webdavUrl.trim().isEmpty) return;
    final webdav = context.read<WebDavSync>();
    try {
      // 大书库慢网络下可能耗时较长：超时后不再弹窗（同步在后台继续收尾）
      await webdav.sync(s).timeout(const Duration(seconds: 120),
          onTimeout: () {});
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final diff = webdav.lastStartupDiff;
    await context.read<LibraryProvider>().refresh();
    if (diff == null || !diff.hasDiff || !mounted) return;
    final action = await showSyncDiffDialog(context, diff: diff);
    if (!mounted || action != 'overwrite') return;
    if (!await confirmOverwriteSyncDialog(context)) return;
    if (!mounted) return;
    await _runOverwriteSync();
  }

  /// 覆盖上传：以本机数据为准重建云端，完成后刷新书架并提示结果。
  Future<void> _runOverwriteSync() async {
    final webdav = context.read<WebDavSync>();
    final s = context.read<SettingsProvider>().s;
    final lib = context.read<LibraryProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final progress = messenger.showSnackBar(const SnackBar(
      content: Text('正在覆盖同步…'),
      duration: Duration(minutes: 10),
    ));
    try {
      await webdav.sync(s, overwrite: true);
      await lib.refresh();
      progress.close();
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('覆盖同步完成')));
    } catch (_) {
      progress.close();
      if (!mounted) return;
      messenger.showSnackBar(
          const SnackBar(content: Text('覆盖同步失败，请检查网络后重试')));
    }
  }

  /// 应用进程被系统回收后重新打开（如墨水屏设备锁屏一段时间）：
  /// 开启"启动时自动回到上次练习"且 15 分钟内有未完成的练习进度时，
  /// 直接回到原练习页，而不是书架（默认关闭，用户在设置中开启）。
  void _restoreRecentPractice() {
    if (_restored) return;
    _restored = true;
    final settings = context.read<SettingsProvider>();
    if (!settings.s.autoResumePractice) return;
    final lib = context.read<LibraryProvider>();
    String? bestBookId;
    var bestChapter = 0;
    var bestTs = 0;
    for (final e in lib.store.progress.entries) {
      for (final c in e.value.chapters.entries) {
        if (c.value.completed) continue;
        if (c.value.lastPracticedAtMs > bestTs) {
          bestTs = c.value.lastPracticedAtMs;
          bestBookId = e.key;
          bestChapter = c.key;
        }
      }
    }
    if (bestBookId == null || bestTs == 0) return;
    if (DateTime.now().millisecondsSinceEpoch - bestTs >
        15 * 60 * 1000) {
      return;
    }
    final matches =
        lib.books.where((b) => b.id == bestBookId).toList();
    if (matches.isEmpty || !mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          PracticeScreen(book: matches.first, chapterIndex: bestChapter),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Scaffold(
        body: IndexedStack(
          index: _index,
          children: const [
            LibraryScreen(),
            StatsScreen(),
            SettingsScreen(),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.menu_book_outlined),
              activeIcon: Icon(Icons.menu_book),
              label: '书架',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.insights_outlined),
              activeIcon: Icon(Icons.insights),
              label: '统计',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings_outlined),
              activeIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
