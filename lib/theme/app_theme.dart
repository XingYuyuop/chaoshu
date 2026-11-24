import 'package:flutter/material.dart';

/// 中央动画时长表：墨水屏模式下所有动画时长归零。
class AppDurations {
  static bool inkMode = false;

  static Duration get normal =>
      inkMode ? Duration.zero : const Duration(milliseconds: 200);
  static Duration get slow =>
      inkMode ? Duration.zero : const Duration(milliseconds: 350);
}

const _seedLight = Color(0xFF4E6E8E);
const _paper = Color(0xFFFAF6EF);

ThemeData buildLightTheme({required bool ink}) {
  final scheme = ink
      ? const ColorScheme.light(
          primary: Colors.black,
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: Colors.black,
          secondary: Colors.black54,
          error: Colors.black,
          outline: Colors.black,
        )
      : ColorScheme.fromSeed(seedColor: _seedLight).copyWith(
          surface: _paper,
        );

  return _baseTheme(scheme, ink, Brightness.light);
}

ThemeData buildDarkTheme({required bool ink}) {
  final scheme = ink
      ? const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Colors.black,
          onSurface: Colors.white,
          secondary: Colors.white60,
          error: Colors.white,
          outline: Colors.white,
        )
      : ColorScheme.fromSeed(
          seedColor: _seedLight,
          brightness: Brightness.dark,
        );

  return _baseTheme(scheme, ink, Brightness.dark);
}

/// 无转场页面切换（墨水屏模式用）。
class _NoTransitionPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return child;
  }
}

ThemeData _baseTheme(ColorScheme scheme, bool ink, Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    splashFactory: ink ? NoSplash.splashFactory : InkSparkle.splashFactory,
    highlightColor: ink ? Colors.transparent : null,
    hoverColor: ink ? Colors.transparent : null,
    splashColor: ink ? Colors.transparent : null,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        for (final platform in TargetPlatform.values)
          platform: ink
              ? const _NoTransitionPageTransitionsBuilder()
              : const FadeUpwardsPageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: ink ? true : false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    dialogTheme: DialogThemeData(
      // 墨水屏：弹窗白底黑字（默认主题色底在墨水屏上偏深、易残影）
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
      contentTextStyle:
          ink ? const TextStyle(color: Colors.black, height: 1.45) : null,
    ),
    navigationBarTheme: NavigationBarThemeData(      elevation: 0,
      backgroundColor: scheme.surface,
      // 墨水屏：指示条不用实心黑（黑色图标叠黑底会"消失"），改为白底描边
      indicatorColor:
          scheme.primary.withValues(alpha: ink ? 0 : 0.12),
      indicatorShape: ink
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(2),
              side: const BorderSide(color: Colors.black, width: 1),
            )
          : const RoundedRectangleBorder(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ink ? 2 : 12),
        side: ink
            ? const BorderSide(color: Colors.black, width: 1)
            : BorderSide(color: scheme.outline.withValues(alpha: 0.15)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      // 墨水屏：细边框（粗黑框长时间停留易产生残影）
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ink ? 2 : 10),
        borderSide: BorderSide(width: 1, color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ink ? 2 : 10),
        borderSide: BorderSide(width: 1, color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ink ? 2 : 10),
        borderSide: BorderSide(
            width: ink ? 1 : 2, color: scheme.onSurface),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outline.withValues(alpha: ink ? 1 : 0.2),
      thickness: ink ? 1 : 0.5,
    ),
    visualDensity: ink ? VisualDensity.comfortable : VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// 面板背景色选项（key -> 各主题下的颜色）。
const paneBackgrounds = <String, (Color, Color)>{
  // key: (浅色模式背景, 深色模式背景)
  'paper': (Color(0xFFFAF6EF), Color(0xFF1E2126)),
  'white': (Color(0xFFFFFFFF), Color(0xFF15181C)),
  'sepia': (Color(0xFFF3E5CB), Color(0xFF242019)),
  'mint': (Color(0xFFEAF3EC), Color(0xFF18201B)),
  'gray': (Color(0xFFF0F0F0), Color(0xFF202225)),
};

Color paneBackgroundFor(String key, Brightness brightness) {
  final pair = paneBackgrounds[key] ?? paneBackgrounds['paper']!;
  return brightness == Brightness.light ? pair.$1 : pair.$2;
}

const String paneBackgroundPaperKey = 'paper';
const List<String> paneBackgroundKeys = [
  'paper',
  'white',
  'sepia',
  'mint',
  'gray',
];

const Map<String, String> paneBackgroundLabels = {
  'paper': '纸白',
  'white': '纯白',
  'sepia': '米黄',
  'mint': '浅绿',
  'gray': '浅灰',
};

/// 常见中文字体选项（Windows 上按字体族名生效，Android 回退到系统字体）。
const Map<String, String> fontFamilyOptions = {
  '': '系统默认',
  'Microsoft YaHei': '微软雅黑',
  'SimSun': '宋体',
  'KaiTi': '楷体',
  'SimHei': '黑体',
  'DengXian': '等线',
};
