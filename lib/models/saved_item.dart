/// Core domain model for a saved item.
enum ItemType { youtube, reddit, article, movie, x, tiktok, instagram, generic, note }

enum ItemStatus { inbox, done, archived }

enum Category { watch, read, listen, moviesShows, learn, ideas, shopping, other }

/// AI subcategory taxonomy (v5). Kept as free-form String on the model so
/// new values don't break old rows; [AiSubcategories.forCategory] is the
/// closed list the classifier must pick from.
class AiSubcategories {
  static const Map<Category, List<String>> forCategory = {
    Category.watch: ['tutorial', 'vlog', 'documentary', 'review', 'music-video', 'livestream', 'shorts', 'other-video'],
    Category.read: ['news', 'blog', 'essay', 'thread', 'documentation', 'other-read'],
    Category.listen: ['podcast', 'song', 'audiobook', 'other-audio'],
    Category.moviesShows: ['movie', 'series', 'trailer', 'other-screen'],
    Category.learn: ['course', 'howto', 'reference', 'paper', 'other-learn'],
    Category.ideas: ['startup', 'opinion', 'discussion', 'inspiration', 'other-idea'],
    Category.shopping: ['product', 'deal', 'recipe', 'other-buy'],
    Category.other: ['other'],
  };

  static String normalize(Category category, String? raw) {
    final allowed = forCategory[category] ?? const ['other'];
    final t = (raw ?? '').trim().toLowerCase().replaceAll(RegExp(r'[^a-z-]'), '');
    if (allowed.contains(t)) return t;
    // Fuzzy: accept close variants ("tutorials" -> "tutorial").
    for (final a in allowed) {
      if (t.startsWith(a) || a.startsWith(t) && t.isNotEmpty) return a;
    }
    return allowed.last;
  }
}

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
        id: '${m['id']}',
        name: '${m['name']}',
        icon: m['icon'] == null ? null : '${m['icon']}',
        sortOrder: (num.tryParse('${m['sortOrder'] ?? 0}') ?? 0).toInt(),
        createdAt: DateTime.fromMillisecondsSinceEpoch((num.tryParse('${m['createdAt']}') ?? 0).toInt()),
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
        id: '${m['id']}',
        // Column was renamed match -> pattern in DB v4 (match is reserved).
        // Accept both keys so rows written by the short-lived v3 build load.
        match: '${m['pattern'] ?? m['match']}',
        category: m['category'] == null
            ? null
            : Category.values.byName('${m['category']}'),
        tags: ('${m['tags'] ?? ''}')
            .split(',')
            .where((t) => t.isNotEmpty)
            .toList(),
        enabled: (num.tryParse('${m['enabled'] ?? 1}') ?? 1) == 1,
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
        id: '${m['id']}',
        itemId: '${m['itemId']}',
        text: '${m['text']}',
        note: m['note'] == null ? null : '${m['note']}',
        createdAt: DateTime.fromMillisecondsSinceEpoch((num.tryParse('${m['createdAt']}') ?? 0).toInt()),
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
  // v5 fields: AI topic + subcategory + key points (nullable, old rows load).
  final String? aiTopic;
  final String? aiSubcategory;
  final List<String> aiKeyPoints;
  final double? aiConfidence;

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
    this.aiTopic,
    this.aiSubcategory,
    this.aiKeyPoints = const [],
    this.aiConfidence,
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
    String? aiTopic,
    String? aiSubcategory,
    List<String>? aiKeyPoints,
    double? aiConfidence,
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
      aiTopic: aiTopic ?? this.aiTopic,
      aiSubcategory: aiSubcategory ?? this.aiSubcategory,
      aiKeyPoints: aiKeyPoints ?? this.aiKeyPoints,
      aiConfidence: aiConfidence ?? this.aiConfidence,
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
        'aiTopic': aiTopic,
        'aiSubcategory': aiSubcategory,
        'aiKeyPoints': aiKeyPoints.join('\n'),
        'aiConfidence': aiConfidence,
      };

  factory SavedItem.fromMap(Map<String, dynamic> m) => SavedItem(
        id: '${m['id']}',
        url: '${m['url']}',
        title: '${m['title']}',
        type: ItemType.values.byName('${m['type']}'),
        thumbnailUrl: m['thumbnailUrl'] == null ? null : '${m['thumbnailUrl']}',
        author: m['author'] == null ? null : '${m['author']}',
        summary: m['summary'] == null ? null : '${m['summary']}',
        category: Category.values.byName('${m['category']}'),
        tags: ('${m['tags'] ?? ''}').split(',').where((t) => t.isNotEmpty).toList(),
        status: ItemStatus.values.byName('${m['status']}'),
        createdAt: DateTime.fromMillisecondsSinceEpoch((num.tryParse('${m['createdAt']}') ?? 0).toInt()),
        consumedAt: m['consumedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((num.tryParse('${m['consumedAt']}') ?? 0).toInt()),
        aiProcessed: (num.tryParse('${m['aiProcessed'] ?? 0}') ?? 0) == 1,
        siteName: m['siteName'] == null ? null : '${m['siteName']}',
        excerpt: m['excerpt'] == null ? null : '${m['excerpt']}',
        readingMinutes: m['readingMinutes'] == null ? null : (num.tryParse('${m['readingMinutes']}') ?? 0).toInt(),
        subreddit: m['subreddit'] == null ? null : '${m['subreddit']}',
        redditScore: m['redditScore'] == null ? null : (num.tryParse('${m['redditScore']}') ?? 0).toInt(),
        redditComments: m['redditComments'] == null ? null : (num.tryParse('${m['redditComments']}') ?? 0).toInt(),
        isVideo: m['isVideo'] == null ? null : (num.tryParse('${m['isVideo']}') ?? 0) == 1,
        bodyText: m['bodyText'] == null ? null : '${m['bodyText']}',
        userNote: m['userNote'] == null ? null : '${m['userNote']}',
        remindAt: m['remindAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((num.tryParse('${m['remindAt']}') ?? 0).toInt()),
        aiTopic: m['aiTopic'] == null ? null : '${m['aiTopic']}',
        aiSubcategory: m['aiSubcategory'] == null ? null : '${m['aiSubcategory']}',
        aiKeyPoints: switch (m['aiKeyPoints']) {
          null => const [],
          final List l => l.map((e) => '$e').where((e) => e.isNotEmpty).toList(),
          _ => '${m['aiKeyPoints']}'
              .split('\n')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(),
        },
        aiConfidence: m['aiConfidence'] == null
            ? null
            : (num.tryParse('${m['aiConfidence']}') ?? 0).toDouble(),
      );
}
