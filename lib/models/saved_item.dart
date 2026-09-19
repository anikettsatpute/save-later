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

/// View density for the inbox (Raindrop-style per-user layout choice).
enum ViewMode { list, grid, headlines }

/// User collection (Raindrop-style folder). Items link via item_collections.
class Collection {
  final String id;
  final String name;
  final String? icon;
  final int sortOrder;
  final DateTime createdAt;

  const Collection({
    required this.id,
    required this.name,
    this.icon,
    this.sortOrder = 0,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'icon': icon,
        'sortOrder': sortOrder,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Collection.fromMap(Map<String, dynamic> m) => Collection(
        id: m['id'] as String,
        name: m['name'] as String,
        icon: m['icon'] as String?,
        sortOrder: (m['sortOrder'] as int?) ?? 0,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
      );
}

/// Auto-tag rule: URL substring match -> forced category + extra tags.
/// Applied before AI; user-managed in Settings (Obsidian-style templates
/// for your capture pipeline).
class TagRule {
  final String id;
  final String match;
  final Category? category;
  final List<String> tags;
  final bool enabled;

  const TagRule({
    required this.id,
    required this.match,
    this.category,
    this.tags = const [],
    this.enabled = true,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'pattern': match,
        'category': category?.name,
        'tags': tags.join(','),
        'enabled': enabled ? 1 : 0,
      };

  factory TagRule.fromMap(Map<String, dynamic> m) => TagRule(
        id: m['id'] as String,
        // Column was renamed match -> pattern in DB v4 (match is reserved).
        // Accept both keys so rows written by the short-lived v3 build load.
        match: (m['pattern'] ?? m['match']) as String,
        category: (m['category'] as String?) != null
            ? Category.values.byName(m['category'] as String)
            : null,
        tags: ((m['tags'] as String?) ?? '')
            .split(',')
            .where((t) => t.isNotEmpty)
            .toList(),
        enabled: (m['enabled'] as int? ?? 1) == 1,
      );
}

/// A highlight / annotation on an item (Obsidian-style atomic note).
class Highlight {
  final String id;
  final String itemId;
  final String text;
  final String? note;
  final DateTime createdAt;

  const Highlight({
    required this.id,
    required this.itemId,
    required this.text,
    this.note,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'itemId': itemId,
        'text': text,
        'note': note,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory Highlight.fromMap(Map<String, dynamic> m) => Highlight(
        id: m['id'] as String,
        itemId: m['itemId'] as String,
        text: m['text'] as String,
        note: m['note'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAt'] as int),
      );
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
  // v3 fields: full-text body, Obsidian-style personal note, reminder.
  final String? bodyText;
  final String? userNote;
  final DateTime? remindAt;

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
    this.bodyText,
    this.userNote,
    this.remindAt,
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
    String? bodyText,
    String? userNote,
    DateTime? Function()? remindAt,
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
      bodyText: bodyText ?? this.bodyText,
      userNote: userNote ?? this.userNote,
      remindAt: remindAt != null ? remindAt() : this.remindAt,
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
        'bodyText': bodyText,
        'userNote': userNote,
        'remindAt': remindAt?.millisecondsSinceEpoch,
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
        bodyText: m['bodyText'] as String?,
        userNote: m['userNote'] as String?,
        remindAt: (m['remindAt'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch(m['remindAt'] as int)
            : null,
      );
}
