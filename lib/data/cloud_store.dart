import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/saved_item.dart';

/// Per-user cloud store. Same method surface as [AppDatabase] / [WebStore]
/// so the Riverpod providers can swap it in when signed in.
///
/// Layout:
///   users/{uid}/items/{itemId}        (+ `collectionIds` array + `updatedAt`)
///   users/{uid}/collections/{id}
///   users/{uid}/rules/{id}
///   users/{uid}/highlights/{id}
///
/// PRIVACY: only library content syncs (items, collections, rules,
/// highlights, notes). AI provider keys (Gemini / OpenRouter / Azure) live
/// in secure storage / SharedPreferences and are NEVER written here.
class FirestoreStore {
  final String uid;
  FirestoreStore({required this.uid});

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _items =>
      _db.collection('users').doc(uid).collection('items');
  CollectionReference<Map<String, dynamic>> get _collections =>
      _db.collection('users').doc(uid).collection('collections');
  CollectionReference<Map<String, dynamic>> get _rules =>
      _db.collection('users').doc(uid).collection('rules');
  CollectionReference<Map<String, dynamic>> get _highlights =>
      _db.collection('users').doc(uid).collection('highlights');

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> backfillFts() async {
    // Server-side search is out of scope; list() filters client-side.
  }

  Future<void> upsert(SavedItem item) async {
    await _items
        .doc(item.id)
        // Merge so the denormalized `collectionIds` array survives item edits.
        .set({...item.toMap(), 'updatedAt': _now()},
            SetOptions(merge: true));
  }

  Future<void> updateFields(String id, Map<String, Object?> fields) async {
    final norm = <String, Object?>{};
    fields.forEach((k, v) => norm[k] = v is bool ? (v ? 1 : 0) : v);
    norm['updatedAt'] = _now();
    await _items.doc(id).update(norm);
  }

  SavedItem _itemFromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = Map<String, dynamic>.from(d.data() ?? {});
    data.putIfAbsent('id', () => d.id);
    return SavedItem.fromMap(data);
  }

  List<String> _collIdsOf(DocumentSnapshot<Map<String, dynamic>> d) {
    final raw = d.data()?['collectionIds'];
    if (raw is List) return raw.map((e) => '$e').toList();
    return const [];
  }

  bool _match(
    SavedItem item,
    List<String> collIds, {
    ItemStatus? status,
    Category? category,
    ItemType? type,
    String? collectionId,
    bool aiOnly = false,
    bool remindedOnly = false,
    String? query,
  }) {
    if (status != null && item.status != status) return false;
    if (category != null && item.category != category) return false;
    if (type != null && item.type != type) return false;
    if (collectionId != null && !collIds.contains(collectionId)) return false;
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
    // Personal-scale library: one fetch, filter client-side. This avoids
    // composite-index setup for every filter combination.
    final snap = await _items.limit(2000).get();
    final out = <SavedItem>[];
    for (final d in snap.docs) {
      final item = _itemFromDoc(d);
      if (_match(item, _collIdsOf(d),
          status: status,
          category: category,
          type: type,
          collectionId: collectionId,
          aiOnly: aiOnly,
          remindedOnly: remindedOnly,
          query: query)) {
        out.add(item);
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> updateStatus(String id, ItemStatus status) async {
    await _items.doc(id).update({
      'status': status.name,
      'consumedAt': status == ItemStatus.done ? _now() : null,
      'updatedAt': _now(),
    });
  }

  Future<void> delete(String id) async {
    final batch = _db.batch();
    batch.delete(_items.doc(id));
    final hl = await _highlights.where('itemId', isEqualTo: id).get();
    for (final d in hl.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }

  Future<bool> existsByUrl(String url) async =>
      (await findIdByUrl(url)) != null;

  Future<String?> findIdByUrl(String url) async {
    final snap = await _items.where('url', isEqualTo: url).limit(1).get();
    if (snap.docs.isEmpty) return null;
    return snap.docs.first.id;
  }

  Future<SavedItem?> getById(String id) async {
    final d = await _items.doc(id).get();
    if (!d.exists) return null;
    return _itemFromDoc(d);
  }

  Future<int> count(
      {ItemStatus? status, Category? category, bool? aiProcessed}) async {
    final all = await list(status: status, category: category);
    if (aiProcessed == null) return all.length;
    return all.where((i) => i.aiProcessed == aiProcessed).length;
  }

  // ------------------------------------------------------------ collections
  Future<List<Collection>> collections() async {
    final snap = await _collections.limit(500).get();
    final out =
        snap.docs.map((d) => Collection.fromMap({...d.data(), 'id': d.id})).toList()
          ..sort((a, b) {
            final c = a.sortOrder.compareTo(b.sortOrder);
            return c != 0 ? c : a.createdAt.compareTo(b.createdAt);
          });
    return out;
  }

  Future<void> upsertCollection(Collection c) async {
    await _collections
        .doc(c.id)
        .set({...c.toMap(), 'updatedAt': _now()}, SetOptions(merge: true));
  }

  Future<void> deleteCollection(String id) async {
    final batch = _db.batch();
    batch.delete(_collections.doc(id));
    final linked =
        await _items.where('collectionIds', arrayContains: id).get();
    for (final d in linked.docs) {
      batch.update(d.reference, {
        'collectionIds': FieldValue.arrayRemove([id]),
        'updatedAt': _now(),
      });
    }
    await batch.commit();
  }

  Future<List<String>> itemCollectionIds(String itemId) async {
    final d = await _items.doc(itemId).get();
    final raw = d.data()?['collectionIds'];
    if (raw is List) return raw.map((e) => '$e').toList();
    return const [];
  }

  Future<void> setItemCollections(
      String itemId, List<String> collectionIds) async {
    await _items.doc(itemId).set(
        {'collectionIds': collectionIds, 'updatedAt': _now()},
        SetOptions(merge: true));
  }

  Future<int> collectionCount(String collectionId) async {
    final snap = await _items
        .where('collectionIds', arrayContains: collectionId)
        .limit(2000)
        .get();
    return snap.docs.length;
  }

  // ----------------------------------------------------------------- rules
  Future<List<TagRule>> tagRules() async {
    final snap = await _rules.limit(500).get();
    return snap.docs
        .map((d) => TagRule.fromMap({...d.data(), 'id': d.id}))
        .toList();
  }

  Future<void> upsertRule(TagRule r) async {
    await _rules
        .doc(r.id)
        .set({...r.toMap(), 'updatedAt': _now()}, SetOptions(merge: true));
  }

  Future<void> deleteRule(String id) async {
    await _rules.doc(id).delete();
  }

  // ------------------------------------------------------------ highlights
  Future<List<Highlight>> highlights(String itemId) async {
    final snap =
        await _highlights.where('itemId', isEqualTo: itemId).limit(500).get();
    final out = snap.docs
        .map((d) => Highlight.fromMap({...d.data(), 'id': d.id}))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  Future<void> addHighlight(Highlight h) async {
    await _highlights
        .doc(h.id)
        .set({...h.toMap(), 'updatedAt': _now()}, SetOptions(merge: true));
  }

  Future<void> deleteHighlight(String id) async {
    await _highlights.doc(id).delete();
  }
}
