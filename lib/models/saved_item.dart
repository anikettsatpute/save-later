/// Core domain model for a saved item.
enum ItemType { youtube, reddit, article, movie, x, tiktok, instagram, generic, note }

enum ItemStatus { inbox, done, archived }

enum Category { watch, read, listen, moviesShows, learn, ideas, shopping, other }

extension CategoryLabel on Category {
  String get label => switch (this) {
        Category.watch => 'Watch',
        Category.read => 'Read',
        Category.listen => 'Listen',
        Category.moviesShows => 'Movies & Shows',
        Category.learn => 'Learn',
        Category.ideas => 'Ideas',
        Category.shopping => 'Shopping',
        Category.other => 'Other',
      };
}

class SavedItem {
  final String id;
  final String url;
  final String title;
  final ItemType type;
  final String? thumbnailUrl;
  final String? author;
  final String? summary;
  final Category category;
  final List<String> tags;
  final ItemStatus status;
  final DateTime createdAt;
  final DateTime? consumedAt;
  final bool aiProcessed;
  // v2 enrichment fields (nullable so old rows still load).
  final String? siteName;
  final String? excerpt;
  final int? readingMinutes;
  final String? subreddit;
  final int? redditScore;
  final int? redditComments;
  final bool? isVideo;

  const SavedItem({
    required this.id,
    required this.url,
    required this.title,
    required this.type,
    this.thumbnailUrl,
    this.author,
    this.summary,
    required this.category,
    this.tags = const [],
    this.status = ItemStatus.inbox,
    required this.createdAt,
    this.consumedAt,
    this.aiProcessed = false,
    this.siteName,
    this.excerpt,
    this.readingMinutes,
    this.subreddit,
    this.redditScore,
    this.redditComments,
    this.isVideo,
  });

  SavedItem copyWith({
    String? title,
    ItemType? type,
    String? thumbnailUrl,
    String? author,
    String? summary,
    Category? category,
    List<String>? tags,
    ItemStatus? status,
    DateTime? consumedAt,
    bool? aiProcessed,
    String? siteName,
    String? excerpt,
    int? readingMinutes,
    String? subreddit,
    int? redditScore,
    int? redditComments,
    bool? isVideo,
  }) {
    return SavedItem(
      id: id,
      url: url,
      title: title ?? this.title,
      type: type ?? this.type,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      author: author ?? this.author,
      summary: summary ?? this.summary,
      category: category ?? this.category,
      tags: tags ?? this.tags,
      status: status ?? this.status,
      createdAt: createdAt,
      consumedAt: consumedAt ?? this.consumedAt,
      aiProcessed: aiProcessed ?? this.aiProcessed,
      siteName: siteName ?? this.siteName,
      excerpt: excerpt ?? this.excerpt,
      readingMinutes: readingMinutes ?? this.readingMinutes,
      subreddit: subreddit ?? this.subreddit,
      redditScore: redditScore ?? this.redditScore,
      redditComments: redditComments ?? this.redditComments,
      isVideo: isVideo ?? this.isVideo,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'url': url,
        'title': title,
        'type': type.name,
        'thumbnailUrl': thumbnailUrl,
        'author': author,
        'summary': summary,
        'category': category.name,
        'tags': tags.join(','),
        'status': status.name,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'consumedAt': consumedAt?.millisecondsSinceEpoch,
        'aiProcessed': aiProcessed ? 1 : 0,
        'siteName': siteName,
        'excerpt': excerpt,
        'readingMinutes': readingMinutes,
        'subreddit': subreddit,
        'redditScore': redditScore,
        'redditComments': redditComments,
        'isVideo': isVideo == null ? null : (isVideo! ? 1 : 0),
      };

  factory SavedItem.fromMap(Map<String, dynamic> m) => SavedItem(
        id: m['id'] as String,
        url: m['url'] as String,
        title: m['title'] as String,
        type: ItemType.values.byName(m['type'] as String),
        thumbnailUrl: m['thumbnailUrl'] as String?,
        author: m['author'] as String?,
        summary: m['summary'] as String?,
        category: Category.values.byName(m['category'] as String),
        tags: ((m['tags'] as String?) ?? '').split(',').where((t) => t.isNotEmpty).toList(),
        status: ItemStatus.values.byName(m['status'] as String),
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
        consumedAt: (m['consumedAt'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch(m['consumedAt'] as int)
            : null,
        aiProcessed: (m['aiProcessed'] as int? ?? 0) == 1,
        siteName: m['siteName'] as String?,
        excerpt: m['excerpt'] as String?,
        readingMinutes: m['readingMinutes'] as int?,
        subreddit: m['subreddit'] as String?,
        redditScore: m['redditScore'] as int?,
        redditComments: m['redditComments'] as int?,
        isVideo: (m['isVideo'] as int?) == null ? null : (m['isVideo'] as int) == 1,
      );
}
