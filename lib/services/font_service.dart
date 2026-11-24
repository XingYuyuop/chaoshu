import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// 自定义字体管理：从字体目录加载 / 导入 TTF、OTF。
/// 字体族名约定为 `custom_<文件名去扩展名>`。
class FontService {
  static final Map<String, String> customFonts = {}; // family -> 显示名
  static Directory? _fontsDir;

  static String familyNameOf(String fileName) =>
      'custom_${p.basenameWithoutExtension(fileName)}';

  static Future<void> init(Directory baseDir) async {
    _fontsDir = Directory(p.join(baseDir.path, 'fonts'));
    await _fontsDir!.create(recursive: true);
    for (final f in _fontsDir!.listSync().whereType<File>()) {
      final ext = p.extension(f.path).toLowerCase();
      if (ext != '.ttf' && ext != '.otf') continue;
      final family = familyNameOf(f.path);
      try {
        await _load(family, await f.readAsBytes());
        customFonts[family] = p.basenameWithoutExtension(f.path);
      } catch (_) {
        // 字体损坏则跳过
      }
    }
  }

  /// 导入字体文件，返回字体族名。
  static Future<String> importFont(String path) async {
    final ext = p.extension(path).toLowerCase();
    if (ext != '.ttf' && ext != '.otf') {
      throw Exception('仅支持 TTF / OTF 字体文件');
    }
    final family = familyNameOf(path);
    final data = await File(path).readAsBytes();
    await _load(family, data); // 先验证可用
    await _fontsDir!.create(recursive: true);
    await File(p.join(_fontsDir!.path, p.basename(path)))
        .writeAsBytes(data, flush: true);
    customFonts[family] = p.basenameWithoutExtension(path);
    return family;
  }

  static Future<void> _load(String family, Uint8List bytes) async {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  }
}
