import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../services/library_store.dart';

/// 书库 Provider：书籍列表 + 导入/删除。
class LibraryProvider extends ChangeNotifier {
  final LibraryStore store;
  bool importing = false;
  String? importError;

  LibraryProvider(this.store);

  List<Book> get books => store.books;

  BookProgress progressOf(String bookId) => store.progressOf(bookId);

  Future<Book?> importFromPicker() async {
    importing = true;
    importError = null;
    notifyListeners();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return null;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        importError = '读取文件失败';
        return null;
      }
      final book = await store.importBook(file.name, bytes);
      notifyListeners();
      return book;
    } catch (e) {
      importError = e.toString();
      return null;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  /// 从本地路径导入（拖拽）；返回第一本成功导入的书。
  Future<Book?> importFromPaths(List<String> paths) async {
    importing = true;
    importError = null;
    notifyListeners();
    Book? first;
    try {
      for (final path in paths) {
        final name = path.replaceAll('\\', '/').split('/').last;
        if (!name.toLowerCase().endsWith('.txt') &&
            !name.toLowerCase().endsWith('.epub')) {
          continue;
        }
        try {
          final bytes = await File(path).readAsBytes();
          final book = await store.importBook(name, bytes);
          first ??= book;
        } catch (e) {
          importError = '$name：$e';
        }
      }
      if (paths.isNotEmpty && first == null && importError == null) {
        importError = '仅支持 TXT / EPUB 文件';
      }
      return first;
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  Future<void> deleteBook(String bookId) async {
    await store.deleteBook(bookId);
    notifyListeners();
  }

  Future<void> refresh() async {
    notifyListeners();
  }

  void clearError() {
    importError = null;
    notifyListeners();
  }
}
