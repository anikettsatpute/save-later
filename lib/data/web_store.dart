import 'dart:async';

import '../models/saved_item.dart';

/// In-memory store used on web. The sqlite wasm build is incompatible with
/// the sandboxed dev browser (COOP/COEP + wasm import errors), so the web
/// preview runs on this instead. Same API surface as [AppDatabase] for the
/// queries the app actually uses. Data lives for the session only — the
/// phone (sqflite) build is the source of truth.
class WebStore {
  final _items = <String, SavedItem>{};
  final _collections = <String, Collection>{};
  final _itemCollections = <String, Set<String>>{};
  final _rules = <String, TagRule>{};
  final _highlights = <String, List<Highlight>>{};

  Future<void> backfillFts() async {}

  Future<void> upsert(SavedItem item) async {
    _items[item.id] = item;
  }

  Future<void> updateFields(String id, Map<String, Object?> fields) async {
    final item = _items[id];
    if (item == null) return;
    _items[id] = SavedItem(
      id: item.id,
      url: item.url,
      title: fields['title'] as String? ?? item.title,
      type: item.type,
      thumbnailUrl: item.thumbnailUrl,
      author: item.author,
      summary: fields.containsKey('summary')
          ? fields['summary'] as String?
          : item.summary,
      category: item.category,
      tags: item.tags,
      status: item.status,
      createdAt: item.createdAt,
      consumedAt: item.consumedAt,
      aiProcessed: fields['aiProcessed'] as bool? ?? item.aiProcessed,
      siteName: item.siteName,
      excerpt: item.excerpt,
      readingMinutes: item.readingMinutes,
      subreddit: item.subreddit,
      redditScore: item.redditScore,
      redditComments: item.redditComments,
      isVideo: item.isVideo,
      bodyText: item.bodyText,
      userNote: fields.containsKey('userNote')
          ? fields['userNote'] as String?
          : item.userNote,
      remindAt: fields.containsKey('remindAt')
          ? (fields['remindAt'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  (fields['remindAt'] as int)))
          : item.remindAt,
    );
  }

  bool _match(SavedItem item,
      {ItemStatus? status,
      Category? category,
      ItemType? type,
      String? collectionId,
      bool aiOnly = false,
      bool remindedOnly = false,
      String? query}) {
    if (status != null && item.status != status) return false;
    if (category != null && item.category != category) return false;
    if (type != null && item.type != type) return false;
    if (collectionId != null &&
        !(_itemCollections[item.id]?.contains(collectionId) ?? false)) {
      return false;
    }
    if (aiOnly && !item.aiProcessed) return false;
    if (remindedOnly && item.remindAt == null) return false;
    if (query != null && query.trim().isNotEmpty) {
      final q = query.trim().toLowerCase();
      final hay =
          '${item.title} ${item.url} ${item.summary ?? ''} ${item.tags.join(' ')} ${item.userNote ?? ''} ${item.bodyText ?? ''}'
              .toLowerCase();
      if (!hay.contains(q)) return false;
    }
    return true;
  }

  Future<List<SavedItem>> list({
    ItemStatus? status,
    Category? category,
    ItemType? type,
    String? collectionId,
    bool aiOnly = false,
    bool remindedOnly = false,
    String? query,
    bool fullText = false,
  }) async {
    final out = _items.values
        .where((i) => _match(i,
            status: status,
            category: category,
            type: type,
            collectionId: collectionId,
            aiOnly: aiOnly,
            remindedOnly: remindedOnly,
            query: query))
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> updateStatus(String id, ItemStatus status) async {
    final item = _items[id];
    if (item == null) return;
    _items[id] = item.copyWith(
        status: status,
        consumedAt: status == ItemStatus.done ? DateTime.now() : null);
  }

  Future<void> delete(String id) async {
    _items.remove(id);
    _itemCollections.remove(id);
    _highlights.remove(id);
  }

  Future<bool> existsByUrl(String url) async =>
      _items.values.any((i) => i.url == url);

  Future<String?> findIdByUrl(String url) async =>
      _items.values.where((i) => i.url == url).map((i) => i.id).firstOrNull;

  Future<SavedItem?> getById(String id) async => _items[id];

  Future<int> count(
      {ItemStatus? status, Category? category, bool? aiProcessed}) async {
    return _items.values
        .where((i) =>
            (status == null || i.status == status) &&
            (category == null || i.category == category) &&
            (aiProcessed == null || i.aiProcessed == aiProcessed))
        .length;
  }

  Future<List<Collection>> collections() async {
    final out = _collections.values.toList()
      ..sort((a, b) {
        final c = a.sortOrder.compareTo(b.sortOrder);
        return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
      });
    return out;
  }

  Future<void> upsertCollection(Collection c) async {
    _collections[c.id] = c;
  }

  Future<void> deleteCollection(String id) async {
    _collections.remove(id);
    for (final set in _itemCollections.values) {
      set.remove(id);
    }
  }

  Future<List<String>> itemCollectionIds(String itemId) async =>
      _itemCollections[itemId]?.toList() ?? [];

  Future<void> setItemCollections(
      String itemId, List<String> collectionIds) async {
    _itemCollections[itemId] = collectionIds.toSet();
  }

  Future<int> collectionCount(String collectionId) async => _itemCollections
      .values
      .where((s) => s.contains(collectionId))
      .length;

  Future<List<TagRule>> tagRules() async => _rules.values.toList();

  Future<void> upsertRule(TagRule r) async {
    _rules[r.id] = r;
  }

  Future<void> deleteRule(String id) async {
    _rules.remove(id);
  }

  Future<List<Highlight>> highlights(String itemId) async =>
      _highlights[itemId]?.toList() ?? [];

  Future<void> addHighlight(Highlight h) async {
    _highlights.putIfAbsent(h.itemId, () => []).add(h);
  }

  Future<void> deleteHighlight(String id) async {
    for (final list in _highlights.values) {
      list.removeWhere((h) => h.id == id);
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
