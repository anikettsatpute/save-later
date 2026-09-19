import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import '../models/saved_item.dart';
import '../services/ai_service.dart';
import '../services/link_parser.dart';
import '../services/share_parser.dart';

final _dbProvider = Provider((_) => AppDatabase());
final _aiProvider = Provider((_) => AiService());
const _uuid = Uuid();

/// Exposed for Settings retry path (re-upsert enriched items).
// ignore: unused_element
final dbProviderForRetry = _dbProvider;

/// Item id to navigate to (set by save sheet "View" action, consumed by inbox).
final navigateToItemProvider = StateProvider<String?>((_) => null);

enum SortMode { newest, oldest, az }

class InboxFilter {
  final ItemStatus? status;
  final Category? category;
  final ItemType? type;
  final bool aiOnly;
  final SortMode sort;
  final String query;
  const InboxFilter({
    this.status = ItemStatus.inbox,
    this.category,
    this.type,
    this.aiOnly = false,
    this.sort = SortMode.newest,
    this.query = '',
  });

  InboxFilter copyWith({
    ItemStatus? Function()? status,
    Category? Function()? category,
    ItemType? Function()? type,
    bool? aiOnly,
    SortMode? sort,
    String? query,
  }) {
    return InboxFilter(
      status: status != null ? status() : this.status,
      category: category != null ? category() : this.category,
      type: type != null ? type() : this.type,
      aiOnly: aiOnly ?? this.aiOnly,
      sort: sort ?? this.sort,
      query: query ?? this.query,
    );
  }
}

final filterProvider = StateProvider<InboxFilter>((_) => const InboxFilter());

final itemsProvider = FutureProvider<List<SavedItem>>((ref) async {
  final f = ref.watch(filterProvider);
  final db = ref.watch(_dbProvider);
  final list = await db.list(
    status: f.status,
    category: f.category,
    type: f.type,
    aiOnly: f.aiOnly,
    query: f.query.isEmpty ? null : f.query,
  );
  switch (f.sort) {
    case SortMode.newest:
      return list; // DB returns createdAt DESC
    case SortMode.oldest:
      return list.reversed.toList();
    case SortMode.az:
      return [...list]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }
});

/// Aggregate counts for the stats header + category rail.
class ItemCounts {
  final int inbox;
  final int done;
  final int unreadAi;
  final Map<Category, int> perCategory;
  const ItemCounts(
      {required this.inbox, required this.done, required this.unreadAi, required this.perCategory});
}

final countsProvider = FutureProvider<ItemCounts>((ref) async {
  // Recompute whenever the list changes.
  ref.watch(itemsProvider);
  final db = ref.watch(_dbProvider);
  final inbox = await db.count(status: ItemStatus.inbox);
  final done = await db.count(status: ItemStatus.done);
  final unreadAi = await db.count(status: ItemStatus.inbox, aiProcessed: false);
  final perCategory = <Category, int>{};
  for (final c in Category.values) {
    perCategory[c] = await db.count(status: ItemStatus.inbox, category: c);
  }
  return ItemCounts(inbox: inbox, done: done, unreadAi: unreadAi, perCategory: perCategory);
});

enum SavePhase { idle, fetching, ai, saving }

final savePhaseProvider = StateProvider<SavePhase>((_) => SavePhase.idle);

class SaveResult {
  final String? error; // fatal: nothing saved
  final String? aiError; // non-fatal: saved with rules, AI failed
  final String? itemId;
  final bool usedAi;
  const SaveResult({this.error, this.aiError, this.itemId, this.usedAi = false});
  bool get ok => error == null;
}

/// Orchestrates: parse share -> fetch meta -> AI enrich -> persist.
class SaveController extends StateNotifier<AsyncValue<void>> {
  final Ref _ref;
  SaveController(this._ref) : super(const AsyncValue.data(null));

  Future<SaveResult> saveUrl(String rawInput, {String? note}) async {
    final parsed = ShareParser.parse(rawInput);
    final url = (parsed.url ?? '').trim();
    if (url.isEmpty) {
      _ref.read(savePhaseProvider.notifier).state = SavePhase.idle;
      return const SaveResult(error: 'No link found in shared text');
    }
    final phase = _ref.read(savePhaseProvider.notifier);
    state = const AsyncValue.loading();
    try {
      final db = _ref.read(_dbProvider);
      final existingId = await db.findIdByUrl(url);
      if (existingId != null) {
        state = const AsyncValue.data(null);
        phase.state = SavePhase.idle;
        return SaveResult(error: 'Already saved', itemId: existingId);
      }
      phase.state = SavePhase.fetching;
      final meta = await LinkParser.fetchMeta(url);
      phase.state = SavePhase.ai;
      final ai = _ref.read(_aiProvider);
      final result = await ai.enrichWithFlag(url: url, meta: meta);
      final enrichment = result.enrichment;
      phase.state = SavePhase.saving;
      final item = SavedItem(
        id: _uuid.v4(),
        url: url,
        // Shared title hint (e.g. YouTube app sends title) wins over note field,
        // explicit note wins over everything.
        title: note?.isNotEmpty == true
            ? note!
            : (parsed.titleHint?.isNotEmpty == true ? parsed.titleHint! : meta.title),
        type: meta.type,
        thumbnailUrl: meta.thumbnailUrl,
        author: meta.author,
        summary: enrichment.summary.isNotEmpty ? enrichment.summary : meta.description,
        category: enrichment.category,
        tags: enrichment.tags,
        createdAt: DateTime.now(),
        aiProcessed: result.usedAi,
        siteName: meta.siteName,
        excerpt: meta.excerpt,
        readingMinutes: meta.readingMinutes,
        subreddit: meta.subreddit,
        redditScore: meta.redditScore,
        redditComments: meta.redditComments,
        isVideo: meta.isVideo,
      );
      await db.upsert(item);
      _ref.invalidate(itemsProvider);
      state = const AsyncValue.data(null);
      phase.state = SavePhase.idle;
      final hasKey = (await ai.getApiKey())?.isNotEmpty == true;
      if (hasKey && !result.usedAi && enrichment.error != null) {
        return SaveResult(aiError: enrichment.error, itemId: item.id);
      }
      return SaveResult(itemId: item.id, usedAi: result.usedAi);
    } catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
      phase.state = SavePhase.idle;
      return SaveResult(error: 'Failed to save: $e');
    }
  }

  Future<void> setStatus(String id, ItemStatus status) async {
    await _ref.read(_dbProvider).updateStatus(id, status);
    _ref.invalidate(itemsProvider);
  }

  Future<void> remove(String id) async {
    await _ref.read(_dbProvider).delete(id);
    _ref.invalidate(itemsProvider);
  }
}

final saveControllerProvider =
    StateNotifierProvider<SaveController, AsyncValue<void>>((ref) => SaveController(ref));
