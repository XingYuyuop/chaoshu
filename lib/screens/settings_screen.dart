import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/app_settings.dart';
import '../services/webdav_sync.dart';
import '../widgets/app_dialog.dart';
import '../state/library_provider.dart';
import '../state/settings_provider.dart';

/// 设置页：外观与排版、练习、WebDAV 同步。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  final _urlFocus = FocusNode();
  final _userFocus = FocusNode();
  final _pwdFocus = FocusNode();
  final _dirFocus = FocusNode();
  bool _obscurePwd = true;
  bool _syncing = false;
  String? _syncResult;
  int _tab = 0; // 当前板块：0 外观 / 1 练习 / 2 同步
  String _versionText = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<SettingsProvider>().s;
      _urlCtrl.text = s.webdavUrl;
      _userCtrl.text = s.webdavUser;
      _pwdCtrl.text = s.webdavPassword;
      _dirCtrl.text = s.webdavBaseDir;
      setState(() {});
    });
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _versionText = '抄书打字 v${info.version}');
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _pwdCtrl.dispose();
    _dirCtrl.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _pwdFocus.dispose();
    _dirFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final s = settings.s;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Column(
        children: [
          _tabBar(theme, settings),
          const Divider(height: 1),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                _appearanceTab(theme, s),
                _practiceTab(theme, s),
                _syncTab(theme, s),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const _tabs = ['外观', '练习', '同步'];

  /// 顶部分板块标签条：横向滚动，以后可扩展更多板块。
  Widget _tabBar(ThemeData theme, SettingsProvider settings) {
    final ink = settings.isInk;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _tabs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final selected = i == _tab;
          return InkWell(
            borderRadius: BorderRadius.circular(ink ? 2 : 18),
            onTap: () => setState(() => _tab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? (ink ? Colors.black : theme.colorScheme.primary)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(ink ? 2 : 18),
                border: Border.all(
                  width: 1,
                  color: selected
                      ? Colors.transparent
                      : (ink ? Colors.black : theme.colorScheme.outline),
                ),
              ),
              child: Text(
                _tabs[i],
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected
                      ? (ink ? Colors.white : theme.colorScheme.onPrimary)
                      : theme.colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.bold : null,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _appearanceTab(ThemeData theme, AppSettings s) {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 外观 ----------
          _sectionTitle(theme, '外观'),
          Card(
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('浅色模式'),
                  groupValue: s.themeMode,
                  value: 'light',
                  onChanged: (v) =>
                      _update((x) => x.copyWith(themeMode: v)),
                ),
                RadioListTile<String>(
                  title: const Text('深色模式'),
                  groupValue: s.themeMode,
                  value: 'dark',
                  onChanged: (v) =>
                      _update((x) => x.copyWith(themeMode: v)),
                ),
                RadioListTile<String>(
                  title: const Text('跟随系统'),
                  groupValue: s.themeMode,
                  value: 'system',
                  onChanged: (v) =>
                      _update((x) => x.copyWith(themeMode: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('墨水屏模式'),
                  subtitle:
                      const Text('禁用全部动画，使用高对比黑白配色（适配电子墨水屏设备）'),
                  value: s.inkMode,
                  onChanged: (v) => _update((x) => x.copyWith(inkMode: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('同步时忽略布局'),
                  subtitle:
                      const Text('多设备同步时，练习页布局（上原文下抄书等）保留本设备设置，不跟随云端'),
                  value: s.syncIgnoreLayout,
                  onChanged: (v) =>
                      _update((x) => x.copyWith(syncIgnoreLayout: v)),
                ),
              ],
            ),
          ),
          Center(
            child: Text(
              _versionText.isEmpty ? '' : _versionText,
              style: TextStyle(color: theme.colorScheme.outline),
            ),
          ),
          const SizedBox(height: 24),
        ],
      );
  }

  Widget _practiceTab(ThemeData theme, AppSettings s) {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- 练习 ----------
          _sectionTitle(theme, '练习'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('段落完成后自动续段'),
                  subtitle: const Text('关闭后需按回车或点击按钮继续下一段'),
                  value: s.autoAdvanceParagraph,
                  onChanged: (v) =>
                      _update((x) => x.copyWith(autoAdvanceParagraph: v)),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('启动时自动回到上次练习'),
                  subtitle: const Text(
                      '打开软件时直接进入上次练习的界面（15 分钟内的练习有效，默认关闭）'),
                  value: s.autoResumePractice,
                  onChanged: (v) =>
                      _update((x) => x.copyWith(autoResumePractice: v)),
                ),
              ],
            ),
          ),
        ],
      );
  }

  Widget _syncTab(ThemeData theme, AppSettings s) {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- WebDAV ----------
          _sectionTitle(theme, 'WebDAV 同步'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _urlCtrl,
                      focusNode: _urlFocus,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        SystemChannels.textInput
                            .invokeMethod('TextInput.hide');
                        FocusScope.of(context).requestFocus(_userFocus);
                      },
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: 'https://dav.jianguoyun.com/dav/',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _userCtrl,
                      focusNode: _userFocus,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        SystemChannels.textInput
                            .invokeMethod('TextInput.hide');
                        FocusScope.of(context).requestFocus(_pwdFocus);
                      },
                      decoration: const InputDecoration(
                        labelText: '账号',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pwdCtrl,
                      focusNode: _pwdFocus,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) {
                        SystemChannels.textInput
                            .invokeMethod('TextInput.hide');
                        FocusScope.of(context).requestFocus(_dirFocus);
                      },
                      obscureText: _obscurePwd,
                      decoration: InputDecoration(
                        labelText: '密码 / 应用密码',
                        isDense: true,
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePwd
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _obscurePwd = !_obscurePwd),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _dirCtrl,
                      focusNode: _dirFocus,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        SystemChannels.textInput
                            .invokeMethod('TextInput.hide');
                        _dirFocus.unfocus();
                      },
                      decoration: const InputDecoration(
                        labelText: '远端目录',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('进度同步'),
                      subtitle: const Text('同步抄写进度与抄写统计数据'),
                      value: s.webdavAutoSync,
                      onChanged: (v) =>
                          _update((x) => x.copyWith(webdavAutoSync: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('书籍同步'),
                      value: s.webdavSyncBooks,
                      onChanged: (v) =>
                          _update((x) => x.copyWith(webdavSyncBooks: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('增强同步'),
                      subtitle: const Text('启动时同步合并云端差异'),
                      value: s.startupEnhanceSync,
                      onChanged: (v) =>
                          _update((x) => x.copyWith(startupEnhanceSync: v)),
                    ),
                    const SizedBox(height: 8),
                    // 备份/还原/覆盖：与书架右上角菜单一致
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _syncing ? null : _doSync,
                          icon: _syncing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.cloud_upload_outlined),
                          label: const Text('备份数据'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _syncing ? null : _doRestore,
                          icon: const Icon(Icons.cloud_download_outlined),
                          label: const Text('还原数据'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _syncing ? null : _confirmOverwriteSync,
                          icon: const Icon(Icons.cloud_sync_outlined),
                          label: const Text('覆盖数据'),
                        ),
                      ],
                    ),
                    if (_syncResult != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _syncResult!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: _syncOk
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
  }

  bool get _syncOk =>
      _syncResult != null && _syncResult!.startsWith('同步成功');

  void _update(AppSettings Function(AppSettings) fn) {
    context.read<SettingsProvider>().update(fn);
  }

  Widget _sectionTitle(ThemeData theme, String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(text,
          style: theme.textTheme.titleSmall
              ?.copyWith(color: theme.colorScheme.primary)),
    );
  }

  /// 还原数据：从云端恢复书籍、进度、统计（与书架菜单一致）。
  Future<void> _doRestore() async {
    final settingsProv = context.read<SettingsProvider>();
    await settingsProv.update((x) => x.copyWith(
          webdavUrl: _normalizeUrl(_urlCtrl.text),
          webdavUser: _userCtrl.text.trim(),
          webdavPassword: _pwdCtrl.text,
          webdavBaseDir: _dirCtrl.text.trim().isEmpty
              ? '/chaoshu'
              : _dirCtrl.text.trim(),
        ));
    _urlCtrl.text = settingsProv.s.webdavUrl;
    if (!mounted) return;
    final webdav = context.read<WebDavSync>();
    setState(() {
      _syncing = true;
      _syncResult = null;
    });
    try {
      await webdav.restore(settingsProv.s);
      if (!mounted) return;
      await context.read<LibraryProvider>().refresh();
      if (!mounted) return;
      setState(() {
        _syncResult =
            '还原完成 ${DateTime.now().toString().substring(11, 19)}';
      });
    } catch (e) {
      setState(() {
        _syncResult = '还原失败：${_friendlyError(webdav.lastError ?? e)}';
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _confirmOverwriteSync() async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('覆盖数据'),
        content: const Text(
            '将以本机数据为准覆盖云端：\n\n'
            '· 本地删除的书籍会同时从云端删除\n'
            '· 云端有而本地没有的书籍不会下载\n'
            '· 练习进度与统计仍按时间自动合并\n\n'
            '确定继续吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('覆盖数据'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _doSync(overwrite: true);
    }
  }

  Future<void> _doSync({bool overwrite = false}) async {
    final settingsProv = context.read<SettingsProvider>();
    // 先保存当前表单（URL 规范化：补协议、去首尾空白与多余斜杠/冒号）
    await settingsProv.update((x) => x.copyWith(
          webdavUrl: _normalizeUrl(_urlCtrl.text),
          webdavUser: _userCtrl.text.trim(),
          webdavPassword: _pwdCtrl.text,
          webdavBaseDir: _dirCtrl.text.trim().isEmpty
              ? '/chaoshu'
              : _dirCtrl.text.trim(),
        ));
    _urlCtrl.text = settingsProv.s.webdavUrl; // 回显规范化后的地址
    final webdav = context.read<WebDavSync>();
    final lib = context.read<LibraryProvider>();
    if (!mounted) return;
    setState(() {
      _syncing = true;
      _syncResult = null;
    });
    try {
      await webdav.sync(settingsProv.s, overwrite: overwrite);
      lib.refresh();
      setState(() {
        _syncResult = '同步成功 ${DateTime.now().toString().substring(11, 19)}';
      });
    } catch (e) {
      setState(() {
        _syncResult = '同步失败：${_friendlyError(webdav.lastError ?? e)}';
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 规范化 WebDAV 地址：补 https://、去空白/结尾斜杠与冒号。
  static String _normalizeUrl(String raw) {
    var url = raw.trim();
    if (url.isEmpty) return url;
    if (!url.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      url = 'https://$url';
    }
    while (url.endsWith('/') || url.endsWith(':')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 把底层网络异常翻译成用户能看懂的提示。
  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('Failed host lookup') || s.contains('SocketException')) {
      return '无法连接服务器（域名解析失败）。请检查网址是否正确、手机网络是否可用，'
          '并确认该域名已正确解析（可用浏览器先访问试试）。';
    }
    if (s.contains('401') || s.contains('Unauthorized')) {
      return '账号或密码错误（401）。';
    }
    if (s.contains('Handshake') || s.contains('certificate') ||
        s.contains('CERT')) {
      return 'HTTPS 证书校验失败。请确认地址正确，或改用 http://（仅限可信内网）。';
    }
    if (s.contains('timed out') || s.contains('timeout')) {
      return '连接超时，请检查网络或稍后重试。';
    }
    return s;
  }
}
