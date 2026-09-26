import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../data/cloud_store.dart';
import '../data/database.dart';
import '../data/web_store.dart';
import '../models/saved_item.dart';
import '../services/ai_service.dart';
import '../services/auth_service.dart';
import '../services/content_fetcher.dart';
import '../services/link_parser.dart';
import '../services/reminder_service.dart';
import '../services/share_parser.dart';

final _dbProvider = Provider((_) => AppDatabase());
final _webProvider = Provider((_) => WebStore());
final _aiProvider = Provider((_) => AiService());
const _uuid = Uuid();

/// Local on-device store: sqflite on mobile, in-memory on web.
/// (Web uses memory because the sqlite wasm build is blocked in the
/// sandboxed browser; mobile uses sqflite. Same method names.)
final localStoreProvider = Provider<Object>(
    (ref) => kIsWeb ? ref.watch(_webProvider) : ref.watch(_dbProvider));

/// Cloud store when signed in with Google (null otherwise). Firestore SDKs
/// only exist for Android / iOS / macOS / web — Linux + Windows desktop
/// builds always stay local.
final cloudStoreProvider = Provider<FirestoreStore?>((ref) {
  if (!supportsCloudSync) return null;
  if (!ref.watch(firebaseReadyProvider)) return null;
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return null;
  return FirestoreStore(uid: user.uid);
});

/// Active store: cloud when signed in, local otherwise. All existing call
/// sites (inbox, detail, settings, save flow) go through this, so sign-in
/// just flips the source with no UI changes.
///
/// PRIVACY: only library content syncs (items, notes, highlights,
/// collections, rules). AI provider keys stay in secure storage /
/// SharedPreferences on each device and are never written to Firestore.
final dbProviderForRetry = Provider<dynamic>((ref) =>
    (ref.watch(cloudStoreProvider) as Object?) ?? ref.watch(localStoreProvider));

/// Reads the right store inside providers (both are cheap singletons;
/// watching here re-runs queries on sign-in/out so the UI flips stores).
dynamic _store(Ref ref) =>
    (ref.watch(cloudStoreProvider) as Object?) ?? ref.watch(localStoreProvider);

dynamic _storeRead(Ref ref) =>
    (ref.read(cloudStoreProvider) as Object?) ?? ref.read(localStoreProvider);

/// Item id to navigate to (set by save sheet "View" action, consumed by inbox).
final navigateToItemProvider = StateProvider<String?>((_) => null);

enum SortMode { newest, oldest, az }

class InboxFilter {
  final ItemStatus? status;
  final Category? category;
  final ItemType? type;
  final String? collectionId;
  final bool aiOnly;
  final bool remindedOnly;
  final bool fullText;
  final SortMode sort;
  final String query;
  const InboxFilter({
    this.status = ItemStatus.inbox,
    this.category,
    this.type,
    this.collectionId,
    this.aiOnly = false,
    this.remindedOnly = false,
    this.fullText = true,
    this.sort = SortMode.newest,
    this.query = '',
  });

  InboxFilter copyWith({
    ItemStatus? Function()? status,
    Category? Function()? category,
    ItemType? Function()? type,
    String? Function()? collectionId,
    bool? aiOnly,
    bool? remindedOnly,
    bool? fullText,
    SortMode? sort,
    String? query,
  }) {
    return InboxFilter(
      status: status != null ? status() : this.status,
      category: category != null ? category() : this.category,
      type: type != null ? type() : this.type,
      collectionId: collectionId != null ? collectionId() : this.collectionId,
      aiOnly: aiOnly ?? this.aiOnly,
      remindedOnly: remindedOnly ?? this.remindedOnly,
      fullText: fullText ?? this.fullText,
      sort: sort ?? this.sort,
      query: query ?? this.query,
    );
  }
}

final filterProvider = StateProvider<InboxFilter>((_) => const InboxFilter());

/// Bumped on every data mutation. Counts/collections watch this — never
/// itemsProvider — so filter taps never trigger recounts (the old glitch).
final dataVersionProvider = StateProvider<int>((_) => 0);

void _bumpData(Ref ref) => ref.read(dataVersionProvider.notifier).state++;

/// Public alias so UI controllers (highlights/collections) can bump.
/// Accepts either Ref (controllers) or WidgetRef (widgets) — both expose
/// read() for the version counter.
void bumpData(dynamic ref) =>
    (ref as dynamic).read(dataVersionProvider.notifier).state++;

/// Persisted view density (list/grid/headlines), Raindrop-style.
final viewModeProvider = StateProvider<ViewMode>((_) => ViewMode.list);

final itemsProvider = FutureProvider<List<SavedItem>>((ref) async {
  final f = ref.watch(filterProvider);
  final db = _store(ref);
  await db.backfillFts();
  final list = await db.list(
    status: f.status,
    category: f.category,
    type: f.type,
    collectionId: f.collectionId,
    aiOnly: f.aiOnly,
    remindedOnly: f.remindedOnly,
    query: f.query.isEmpty ? null : f.query,
    fullText: f.fullText,
  );
  switch (f.sort) {
    case SortMode.newest:
      return list;
    case SortMode.oldest:
      return list.reversed.toList();
    case SortMode.az:
      return [...list]
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }
});

class ItemCounts {
  final int inbox;
  final int done;
  final int unreadAi;
  final Map<Category, int> perCategory;
  final Map<String, int> perTopic;
  final Map<String, int> perSubcategory;
  const ItemCounts(
      {required this.inbox,
      required this.done,
      required this.unreadAi,
      required this.perCategory,
      this.perTopic = const {},
      this.perSubcategory = const {}});
}

final countsProvider = FutureProvider<ItemCounts>((ref) async {
  ref.watch(dataVersionProvider);
  final db = _store(ref);
  final inbox = await db.count(status: ItemStatus.inbox);
  final done = await db.count(status: ItemStatus.done);
  final unreadAi = await db.count(status: ItemStatus.inbox, aiProcessed: false);
  final perCategory = <Category, int>{};
  for (final c in Category.values) {
    perCategory[c] = await db.count(status: ItemStatus.inbox, category: c);
  }
  // Topic/subcategory breakdown for the dashboard (inbox scope).
  final inboxItems = await db.list(status: ItemStatus.inbox);
  final perTopic = <String, int>{};
  final perSubcategory = <String, int>{};
  for (final it in inboxItems) {
    final t = (it.aiTopic ?? '').trim();
    if (t.isNotEmpty) perTopic[t] = (perTopic[t] ?? 0) + 1;
    final s = (it.aiSubcategory ?? '').trim();
    if (s.isNotEmpty) perSubcategory[s] = (perSubcategory[s] ?? 0) + 1;
  }
  return ItemCounts(
      inbox: inbox,
      done: done,
      unreadAi: unreadAi,
      perCategory: perCategory,
      perTopic: perTopic,
      perSubcategory: perSubcategory);
});

final collectionsProvider = FutureProvider<List<Collection>>((ref) async {
  ref.watch(dataVersionProvider);
  return _store(ref).collections();
});

final rulesProvider = FutureProvider<List<TagRule>>((ref) async {
  ref.watch(dataVersionProvider);
  return _store(ref).tagRules();
});

enum SavePhase { idle, fetching, ai, saving }

final savePhaseProvider = StateProvider<SavePhase>((_) => SavePhase.idle);

/// Post-save toast message owned by the inbox scaffold (auto-dismisses).
/// Set by AddSheet after pop; consumed once by InboxPage listener.
final pendingSaveMessageProvider = StateProvider<String?>((_) => null);

class SaveResult {
  final String? error;
  final String? aiError;
  final String? itemId;
  final bool usedAi;
  const SaveResult({this.error, this.aiError, this.itemId, this.usedAi = false});
  bool get ok => error == null;
}

/// Orchestrates: parse share -> rules -> fetch meta -> AI enrich -> persist.
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
      final db = _storeRead(_ref);
      final existingId = await db.findIdByUrl(url);
      if (existingId != null) {
        state = const AsyncValue.data(null);
        phase.state = SavePhase.idle;
        return SaveResult(error: 'Already saved', itemId: existingId);
      }
      phase.state = SavePhase.fetching;
      final meta = await LinkParser.fetchMeta(url);
      // Auto-tag rules run before AI (user pipeline wins).
      final rules = await db.tagRules();
      final ruleHit = _matchRule(rules, url, meta);
      // Prefetch platform body ONCE (YouTube oEmbed+watch page, Reddit
      // PullPush+Arctic, Instagram oEmbed+embed caption) so the AI prompt
      // and the stored bodyText share the same content — no double fetch.
      String? fetchedContent;
      try {
        fetchedContent = await ContentFetcher.fetchFor(url, meta.type.name);
      } catch (_) {}
      phase.state = SavePhase.ai;
      final ai = _ref.read(_aiProvider);
      final result = await ai.enrichWithFlag(
        url: url,
        meta: meta,
        userNote: (note?.trim().isNotEmpty ?? false) ? note!.trim() : null,
        titleHint:
            (parsed.titleHint?.trim().isNotEmpty ?? false) ? parsed.titleHint!.trim() : null,
        ruleSummary: ruleHit != null
            ? 'match=\"${ruleHit.match}\" category=${ruleHit.category?.name ?? 'none'} tags=[${ruleHit.tags.join(', ')}]'
            : null,
        fetchedContent: fetchedContent,
      );
      final enrichment = result.enrichment;
      phase.state = SavePhase.saving;
      final tags = <String>{
        ...enrichment.tags,
        if (ruleHit != null) ...ruleHit.tags,
      }.take(5).toList();
      final item = SavedItem(
        id: _uuid.v4(),
        url: url,
        title: note?.isNotEmpty == true
            ? note!
            : (parsed.titleHint?.isNotEmpty == true ? parsed.titleHint! : meta.title),
        type: meta.type,
        thumbnailUrl: meta.thumbnailUrl,
        author: meta.author,
        // Triple fallback chain: AI summary -> parser description/excerpt ->
        // synthesized sentence (never store empty/"Saved link").
        summary: enrichment.summary.isNotEmpty && enrichment.summary != 'Saved link'
            ? enrichment.summary
            : (meta.description?.isNotEmpty == true
                ? meta.description
                : (meta.excerpt?.isNotEmpty == true
                    ? meta.excerpt
                    : '${meta.siteName ?? 'Link'} — ${meta.title}')),
        category: ruleHit?.category ?? enrichment.category,
        tags: tags,
        createdAt: DateTime.now(),
        aiProcessed: result.usedAi,
        siteName: meta.siteName,
        excerpt: meta.excerpt,
        readingMinutes: meta.readingMinutes,
        subreddit: meta.subreddit,
        redditScore: meta.redditScore,
        redditComments: meta.redditComments,
        isVideo: meta.isVideo,
        // v5 AI taxonomy: topic + subcategory + key points + confidence.
        aiTopic: enrichment.topic.isNotEmpty ? enrichment.topic : null,
        aiSubcategory: enrichment.subcategory.isNotEmpty ? enrichment.subcategory : null,
        aiKeyPoints: enrichment.keyPoints,
        aiConfidence: result.usedAi ? enrichment.confidence : null,
        // Persist the full fetched platform body (not just articleText) so
        // askAboutItem + future re-classification see the same content the
        // classifier saw. Prefers fetched (YouTube/Reddit/Instagram) content.
        bodyText: (fetchedContent != null && fetchedContent.isNotEmpty)
            ? (fetchedContent.length > 6000
                ? '${fetchedContent.substring(0, 6000)}…'
                : fetchedContent)
            : meta.articleText,
      );
      await db.upsert(item);
      _ref.invalidate(itemsProvider);
      _bumpData(_ref);
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

  TagRule? _matchRule(List<TagRule> rules, String url, LinkMeta meta) {
    final hay = '${url.toLowerCase()} ${(meta.siteName ?? '').toLowerCase()}';
    for (final r in rules) {
      if (!r.enabled || r.match.trim().isEmpty) continue;
      if (hay.contains(r.match.trim().toLowerCase())) return r;
    }
    return null;
  }

  Future<void> setStatus(String id, ItemStatus status) async {
    await _storeRead(_ref).updateStatus(id, status);
    _ref.invalidate(itemsProvider);
    _bumpData(_ref);
  }

  Future<void> remove(String id) async {
    await ReminderService.cancel(ReminderService.notifId(id));
    await _storeRead(_ref).delete(id);
    _ref.invalidate(itemsProvider);
    _bumpData(_ref);
  }

  Future<void> setReminder(String id, DateTime? when) async {
    final db = _storeRead(_ref);
    await db.updateFields(id, {'remindAt': when?.millisecondsSinceEpoch});
    if (when == null) {
      await ReminderService.cancel(ReminderService.notifId(id));
    } else {
      final item = await db.getById(id);
      await ReminderService.schedule(
        id: ReminderService.notifId(id),
        title: item?.title ?? 'Saved item',
        when: when,
        body: item?.summary,
      );
    }
    _ref.invalidate(itemsProvider);
    _bumpData(_ref);
  }

  Future<void> saveNote(String id, String note) async {
    await _storeRead(_ref).updateFields(
        id, {'userNote': note.trim().isEmpty ? null : note.trim()});
    _ref.invalidate(itemsProvider);
    _bumpData(_ref);
  }

  Future<void> setCollections(String id, List<String> collectionIds) async {
    await _storeRead(_ref).setItemCollections(id, collectionIds);
    _ref.invalidate(itemsProvider);
    _bumpData(_ref);
  }
}

final saveControllerProvider =
    StateNotifierProvider<SaveController, AsyncValue<void>>((ref) => SaveController(ref));
