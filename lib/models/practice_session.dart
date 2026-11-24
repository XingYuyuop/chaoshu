import 'dart:convert';
import 'dart:math';

/// 一次抄书练习会话记录。
class PracticeSession {
  final String id;
  final String bookId;
  final String bookTitle;
  final int chapterIndex;
  final String chapterTitle;
  final DateTime startAt;
  final DateTime endAt;
  final int activeMs; // 仅前台活动时间
  final int correctChars; // 首次确认正确的字符数
  final int errorCount; // 错字次数
  final int backspaceCount; // 退格次数

  const PracticeSession({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.chapterIndex,
    required this.chapterTitle,
    required this.startAt,
    required this.endAt,
    required this.activeMs,
    required this.correctChars,
    required this.errorCount,
    required this.backspaceCount,
  });

  /// 正确率 = 正确字符 / (正确字符 + 错误次数)
  double get accuracy {
    final total = correctChars + errorCount;
    if (total == 0) return 1.0;
    return correctChars / total;
  }

  /// 每分钟正确字数
  double get charsPerMinute {
    if (activeMs <= 0) return 0;
    return correctChars / max(activeMs / 60000.0, 1 / 60);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'startAt': startAt.millisecondsSinceEpoch,
        'endAt': endAt.millisecondsSinceEpoch,
        'activeMs': activeMs,
        'correctChars': correctChars,
        'errorCount': errorCount,
        'backspaceCount': backspaceCount,
      };

  factory PracticeSession.fromJson(Map<String, dynamic> json) =>
      PracticeSession(
        id: json['id'] as String,
        bookId: (json['bookId'] ?? '') as String,
        bookTitle: (json['bookTitle'] ?? '') as String,
        chapterIndex: (json['chapterIndex'] ?? 0) as int,
        chapterTitle: (json['chapterTitle'] ?? '') as String,
        startAt: DateTime.fromMillisecondsSinceEpoch(json['startAt'] ?? 0),
        endAt: DateTime.fromMillisecondsSinceEpoch(json['endAt'] ?? 0),
        activeMs: (json['activeMs'] ?? 0) as int,
        correctChars: (json['correctChars'] ?? 0) as int,
        errorCount: (json['errorCount'] ?? 0) as int,
        backspaceCount: (json['backspaceCount'] ?? 0) as int,
      );

  String toLine() => jsonEncode(toJson());
}
