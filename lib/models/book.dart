/// 书籍与章节数据模型。
class Book {
  final String id;
  final String title;
  final String author;
  final String description;
  final String? coverPath; // 相对于应用数据目录的路径，如 covers/xxx.png
  final String sourceFormat; // txt | epub
  final String sourceFileName;
  final List<String> chapterTitles;
  final int charCount;
  final DateTime importedAt;
  final int lastOpenedAtMs; // 最近一次开始练习的时间戳（书架排序用）

  Book({
    required this.id,
    required this.title,
    this.author = '',
    this.description = '',
    this.coverPath,
    required this.sourceFormat,
    required this.sourceFileName,
    required this.chapterTitles,
    this.charCount = 0,
    required this.importedAt,
    this.lastOpenedAtMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'description': description,
        'coverPath': coverPath,
        'sourceFormat': sourceFormat,
        'sourceFileName': sourceFileName,
        'chapterTitles': chapterTitles,
        'charCount': charCount,
        'importedAt': importedAt.toIso8601String(),
        'lastOpenedAtMs': lastOpenedAtMs,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: (json['title'] ?? '') as String,
        author: (json['author'] ?? '') as String,
        description: (json['description'] ?? '') as String,
        coverPath: json['coverPath'] as String?,
        sourceFormat: (json['sourceFormat'] ?? 'txt') as String,
        sourceFileName: (json['sourceFileName'] ?? '') as String,
        chapterTitles:
            (json['chapterTitles'] as List?)?.cast<String>() ?? const [],
        charCount: (json['charCount'] ?? 0) as int,
        importedAt:
            DateTime.tryParse((json['importedAt'] ?? '') as String) ??
                DateTime.now(),
        lastOpenedAtMs: (json['lastOpenedAtMs'] ?? 0) as int,
      );
}

/// 断点续练进度：一本书的所有章节练习状态。
class BookProgress {
  /// chapterIndex -> 段落进度
  final Map<int, ChapterProgress> chapters;
  final int lastChapterIndex;

  BookProgress({
    Map<int, ChapterProgress>? chapters,
    this.lastChapterIndex = 0,
  }) : chapters = chapters ?? {};

  bool isChapterCompleted(int chapterIndex) =>
      chapters[chapterIndex]?.completed ?? false;

  int get completedCount => chapters.values.where((c) => c.completed).length;

  Map<String, dynamic> toJson() => {
        'lastChapterIndex': lastChapterIndex,
        'chapters': chapters.map(
          (k, v) => MapEntry(k.toString(), v.toJson()),
        ),
      };

  factory BookProgress.fromJson(Map<String, dynamic> json) => BookProgress(
        lastChapterIndex: (json['lastChapterIndex'] ?? 0) as int,
        chapters: (json['chapters'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(int.parse(k), ChapterProgress.fromJson(v)),
            ) ??
            {},
      );

  BookProgress copyWith({
    Map<int, ChapterProgress>? chapters,
    int? lastChapterIndex,
  }) =>
      BookProgress(
        chapters: chapters ?? this.chapters,
        lastChapterIndex: lastChapterIndex ?? this.lastChapterIndex,
      );
}

/// 单章进度。
class ChapterProgress {
  final int paragraphIndex;
  final int charIndex; // 当前段落内已确认的字符数
  final bool completed;
  final int lastPracticedAtMs; // 冲突合并用

  const ChapterProgress({
    this.paragraphIndex = 0,
    this.charIndex = 0,
    this.completed = false,
    this.lastPracticedAtMs = 0,
  });

  Map<String, dynamic> toJson() => {
        'p': paragraphIndex,
        'c': charIndex,
        'done': completed,
        't': lastPracticedAtMs,
      };

  factory ChapterProgress.fromJson(Map<String, dynamic> json) =>
      ChapterProgress(
        paragraphIndex: (json['p'] ?? 0) as int,
        charIndex: (json['c'] ?? 0) as int,
        completed: (json['done'] ?? false) as bool,
        lastPracticedAtMs: (json['t'] ?? 0) as int,
      );

  ChapterProgress copyWith({
    int? paragraphIndex,
    int? charIndex,
    bool? completed,
    int? lastPracticedAtMs,
  }) =>
      ChapterProgress(
        paragraphIndex: paragraphIndex ?? this.paragraphIndex,
        charIndex: charIndex ?? this.charIndex,
        completed: completed ?? this.completed,
        lastPracticedAtMs: lastPracticedAtMs ?? this.lastPracticedAtMs,
      );
}
