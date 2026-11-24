import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/app_settings.dart';
import '../theme/app_theme.dart';

/// 全局设置 Provider：持久化 settings.json，墨水屏模式联动动画时长表。
class SettingsProvider extends ChangeNotifier {
  AppSettings _settings = const AppSettings();
  String _deviceId = '';

  AppSettings get s => _settings;
  String get deviceId => _deviceId;

  bool get isInk => _settings.inkMode;
  ThemeMode get themeMode {
    switch (_settings.themeMode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  File? _settingsFile;

  Future<void> load() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'chaoshu_data'));
    await dir.create(recursive: true);
    _settingsFile = File(p.join(dir.path, 'settings.json'));
    if (await _settingsFile!.exists()) {
      try {
        _settings = AppSettings.fromJson(
          jsonDecode(await _settingsFile!.readAsString()) as Map<String, dynamic>,
        );
      } catch (_) {}
    }
    _deviceId = await _loadDeviceId(dir);
    AppDurations.inkMode = isInk;
  }

  Future<String> _loadDeviceId(Directory dir) async {
    final f = File(p.join(dir.path, 'device_id'));
    if (await f.exists()) {
      final id = (await f.readAsString()).trim();
      if (id.isNotEmpty) return id;
    }
    final id = DateTime.now().millisecondsSinceEpoch.toRadixString(36) +
        (DateTime.now().microsecondsSinceEpoch % 9999).toString();
    await f.writeAsString(id);
    return id;
  }

  Future<void> update(AppSettings Function(AppSettings) fn) async {
    // 本地修改：盖时间戳，同步冲突时新者胜
    _settings = fn(_settings).copyWith(
        settingsUpdatedAt: DateTime.now().millisecondsSinceEpoch);
    AppDurations.inkMode = isInk;
    notifyListeners();
    await _persist();
  }

  /// 应用远端同步来的设置（不盖本地时间戳，保持远端 ts 以便后续比较）。
  Future<void> applyRemote(AppSettings s) async {
    _settings = s;
    AppDurations.inkMode = isInk;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    if (_settingsFile == null) return;
    await _settingsFile!.writeAsString(
      jsonEncode(_settings.toJson()),
      flush: true,
    );
  }
}
