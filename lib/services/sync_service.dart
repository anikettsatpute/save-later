import '../data/cloud_store.dart';
import '../models/saved_item.dart';

/// Two-way merge between the on-device store (sqflite / in-memory — same
/// method surface, passed as `dynamic`) and the per-user [FirestoreStore].
///
/// Merge is by id (union). Ids present on both sides are left untouched —
/// correct under the single-user assumption because every write goes to the
/// active store. Returns a short summary for snackbars.
///
/// [ref] must be a Riverpod [Ref] (not WidgetRef) — call from a Provider, or
/// pass a ConsumerState's `ref` via [mergeFromWidget].
class SyncService {
  static Future<String> mergeLocalAndCloud({
    required dynamic local,
    required FirestoreStore cloud,
  }) async {
    var up = 0;
    var down = 0;

    // ---- items (+ their collection links) ----
    final List<SavedItem> localItems =
        List<SavedItem>.from(await local.list());
    final List<SavedItem> cloudItems = await cloud.list();
    final localIds = localItems.map((e) => e.id).toSet();
    final cloudIds = cloudItems.map((e) => e.id).toSet();

    for (final item in localItems) {
      if (cloudIds.contains(item.id)) continue;
      await cloud.upsert(item);
      final List<String> links =
          List<String>.from(await local.itemCollectionIds(item.id));
      if (links.isNotEmpty) {
        await cloud.setItemCollections(item.id, links);
      }
      up++;
    }
    for (final item in cloudItems) {
      if (localIds.contains(item.id)) continue;
      await local.upsert(item);
      final List<String> links =
          await cloud.itemCollectionIds(item.id);
      if (links.isNotEmpty) {
        await local.setItemCollections(item.id, links);
      }
      down++;
    }

    // ---- collections ----
    final List<Collection> localColls =
        List<Collection>.from(await local.collections());
    final List<Collection> cloudColls = await cloud.collections();
    final localCids = localColls.map((e) => e.id).toSet();
    final cloudCids = cloudColls.map((e) => e.id).toSet();
    for (final c in localColls) {
      if (cloudCids.contains(c.id)) continue;
      await cloud.upsertCollection(c);
      up++;
    }
    for (final c in cloudColls) {
      if (localCids.contains(c.id)) continue;
      await local.upsertCollection(c);
      down++;
    }

    // ---- auto-tag rules ----
    final List<TagRule> localRules =
        List<TagRule>.from(await local.tagRules());
    final List<TagRule> cloudRules = await cloud.tagRules();
    final localRids = localRules.map((e) => e.id).toSet();
    final cloudRids = cloudRules.map((e) => e.id).toSet();
    for (final r in localRules) {
      if (cloudRids.contains(r.id)) continue;
      await cloud.upsertRule(r);
      up++;
    }
    for (final r in cloudRules) {
      if (localRids.contains(r.id)) continue;
      await local.upsertRule(r);
      down++;
    }

    // ---- highlights (per item) ----
    final allItemIds = {...localIds, ...cloudIds};
    for (final itemId in allItemIds) {
      final List<Highlight> lh =
          List<Highlight>.from(await local.highlights(itemId));
      final List<Highlight> ch = await cloud.highlights(itemId);
      final lids = lh.map((e) => e.id).toSet();
      final cids = ch.map((e) => e.id).toSet();
      for (final h in lh) {
        if (cids.contains(h.id)) continue;
        await cloud.addHighlight(h);
        up++;
      }
      for (final h in ch) {
        if (lids.contains(h.id)) continue;
        await local.addHighlight(h);
        down++;
      }
    }

    return '↑ $up to cloud · ↓ $down to this device';
  }

  /// Widget-safe entry: reads the local store through a ConsumerState's
  /// [WidgetRef] without passing WidgetRef where a Ref is required.
  static Future<String> mergeFromWidget({
    required dynamic local,
    required FirestoreStore cloud,
  }) =>
      mergeLocalAndCloud(local: local, cloud: cloud);
}
