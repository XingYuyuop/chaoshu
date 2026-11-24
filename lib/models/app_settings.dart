/// 应用设置模型。持久化到 settings.json 并参与 WebDAV 同步。
class AppSettings {
  // 外观
  final String themeMode; // light | dark | system
  final bool inkMode; // 墨水屏模式：禁用动画 + 高对比灰阶
  final String layout; // horizontal | vertical
  final String fontFamily; // '' = 系统默认
  final double fontSize;
  final double lineHeight;
  final double pageMargin;
  final String paneBackground; // 输入/原文区背景色 key
  /// 练习文本字形：default 原文不变 | s 繁→简 | t 简→繁
  final String charVariant;
  final bool autoAdvanceParagraph; // 段落完成后自动续段（否则按回车）
  final bool showSoftKeyboard; // 点击输入框时弹出软键盘（墨水屏/外接键盘可关）
  final bool inputOnTop; // 上下分栏时输入框在上（输入法候选条在屏幕上方的设备开启）
  final String ignoredUpdateVersion; // 用户点"忽略此版本"记录的版本号
  final bool autoResumePractice; // 启动时自动回到上次练习界面（默认关闭）
  final int settingsUpdatedAt; // 设置最后修改时间戳（同步冲突时新者胜）
  final int layoutMode; // 练习页布局：0 上抄书/下原文 1 上原文/下抄书 2 左抄书/右原文 3 左原文/右抄书
  final bool syncIgnoreLayout; // 同步时忽略布局：拉取云端设置保留本设备布局（layout/layoutMode），各设备各管各的

  // WebDAV
  final String webdavUrl;
  final String webdavUser;
  final String webdavPassword;
  final String webdavBaseDir;
  final bool webdavAutoSync;
  final bool webdavSyncBooks; // 是否同步书籍原文与封面
  final bool startupEnhanceSync; // 启动时增强同步：自动合并云端差异并提示结果

  const AppSettings({
    this.themeMode = 'system',
    this.inkMode = false,
    this.layout = 'horizontal',
    this.fontFamily = '',
    this.fontSize = 18,
    this.lineHeight = 1.8,
    this.pageMargin = 24,
    this.paneBackground = 'paper',
    this.charVariant = 'default',
    this.autoAdvanceParagraph = true,
    this.showSoftKeyboard = true,
    this.inputOnTop = false,
    this.ignoredUpdateVersion = '',
    this.autoResumePractice = false,
    this.settingsUpdatedAt = 0,
    this.layoutMode = 1,
    this.syncIgnoreLayout = false,
    this.webdavUrl = '',
    this.webdavUser = '',
    this.webdavPassword = '',
    this.webdavBaseDir = '/chaoshu',
    this.webdavAutoSync = true,
    this.webdavSyncBooks = true,
    this.startupEnhanceSync = true,
  });

  AppSettings copyWith({
    String? themeMode,
    bool? inkMode,
    String? layout,
    String? fontFamily,
    double? fontSize,
    double? lineHeight,
    double? pageMargin,
    String? paneBackground,
    String? charVariant,
    bool? autoAdvanceParagraph,
    bool? showSoftKeyboard,
    bool? inputOnTop,
    String? ignoredUpdateVersion,
    bool? autoResumePractice,
    int? settingsUpdatedAt,
    int? layoutMode,
    bool? syncIgnoreLayout,
    String? webdavUrl,
    String? webdavUser,
    String? webdavPassword,
    String? webdavBaseDir,
    bool? webdavAutoSync,
    bool? webdavSyncBooks,
    bool? startupEnhanceSync,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        inkMode: inkMode ?? this.inkMode,
        layout: layout ?? this.layout,
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        pageMargin: pageMargin ?? this.pageMargin,
        paneBackground: paneBackground ?? this.paneBackground,
        charVariant: charVariant ?? this.charVariant,
        autoAdvanceParagraph:
            autoAdvanceParagraph ?? this.autoAdvanceParagraph,
        showSoftKeyboard: showSoftKeyboard ?? this.showSoftKeyboard,
        inputOnTop: inputOnTop ?? this.inputOnTop,
        ignoredUpdateVersion:
            ignoredUpdateVersion ?? this.ignoredUpdateVersion,
        autoResumePractice:
            autoResumePractice ?? this.autoResumePractice,
        settingsUpdatedAt: settingsUpdatedAt ?? this.settingsUpdatedAt,
        layoutMode: layoutMode ?? this.layoutMode,
        syncIgnoreLayout: syncIgnoreLayout ?? this.syncIgnoreLayout,
        webdavUrl: webdavUrl ?? this.webdavUrl,
        webdavUser: webdavUser ?? this.webdavUser,
        webdavPassword: webdavPassword ?? this.webdavPassword,
        webdavBaseDir: webdavBaseDir ?? this.webdavBaseDir,
        webdavAutoSync: webdavAutoSync ?? this.webdavAutoSync,
        webdavSyncBooks: webdavSyncBooks ?? this.webdavSyncBooks,
        startupEnhanceSync: startupEnhanceSync ?? this.startupEnhanceSync,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode,
        'inkMode': inkMode,
        'layout': layout,
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'pageMargin': pageMargin,
        'paneBackground': paneBackground,
        'charVariant': charVariant,
        'autoAdvanceParagraph': autoAdvanceParagraph,
        'showSoftKeyboard': showSoftKeyboard,
        'inputOnTop': inputOnTop,
        'ignoredUpdateVersion': ignoredUpdateVersion,
        'autoResumePractice': autoResumePractice,
        'settingsUpdatedAt': settingsUpdatedAt,
        'layoutMode': layoutMode,
        'syncIgnoreLayout': syncIgnoreLayout,
        'webdavUrl': webdavUrl,
        'webdavUser': webdavUser,
        'webdavPassword': webdavPassword,
        'webdavBaseDir': webdavBaseDir,
        'webdavAutoSync': webdavAutoSync,
        'webdavSyncBooks': webdavSyncBooks,
        'startupEnhanceSync': startupEnhanceSync,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        themeMode: (json['themeMode'] ?? 'system') as String,
        inkMode: (json['inkMode'] ?? false) as bool,
        layout: (json['layout'] ?? 'horizontal') as String,
        fontFamily: (json['fontFamily'] ?? '') as String,
        fontSize: ((json['fontSize'] ?? 18) as num).toDouble(),
        lineHeight: ((json['lineHeight'] ?? 1.8) as num).toDouble(),
        pageMargin: ((json['pageMargin'] ?? 24) as num).toDouble(),
        paneBackground: (json['paneBackground'] ?? 'paper') as String,
        // 兼容旧版本：旧 's' 表示不转换 → 新 'default'；'t' 含义不变
        charVariant: switch (json['charVariant'] as String?) {
          's' => 'default',
          't' => 't',
          'default' => 'default',
          _ => 'default',
        },
        autoAdvanceParagraph:
            (json['autoAdvanceParagraph'] ?? true) as bool,
        showSoftKeyboard: (json['showSoftKeyboard'] ?? true) as bool,
        inputOnTop: (json['inputOnTop'] ?? false) as bool,
        ignoredUpdateVersion:
            (json['ignoredUpdateVersion'] ?? '') as String,
        autoResumePractice: (json['autoResumePractice'] ?? false) as bool,
        settingsUpdatedAt: (json['settingsUpdatedAt'] ?? 0) as int,
        layoutMode: (json['layoutMode'] ?? 1) as int,
        syncIgnoreLayout: (json['syncIgnoreLayout'] ?? false) as bool,
        webdavUrl: (json['webdavUrl'] ?? '') as String,
        webdavUser: (json['webdavUser'] ?? '') as String,
        webdavPassword: (json['webdavPassword'] ?? '') as String,
        webdavBaseDir: (json['webdavBaseDir'] ?? '/chaoshu') as String,
        webdavAutoSync: (json['webdavAutoSync'] ?? true) as bool,
        webdavSyncBooks: (json['webdavSyncBooks'] ?? true) as bool,
        startupEnhanceSync: (json['startupEnhanceSync'] ?? true) as bool,
      );

  /// 同步到 WebDAV 时剔除账号敏感字段（避免覆盖各设备自己的账号配置）。
  Map<String, dynamic> toSyncJson() {
    final m = toJson();
    m.remove('webdavUrl');
    m.remove('webdavUser');
    m.remove('webdavPassword');
    return m;
  }

  factory AppSettings.fromSyncJson(Map<String, dynamic> json) {
    final s = AppSettings.fromJson(json);
    return s; // 同步文件中不含账号字段，解析后账号保持本地值
  }
}
