import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/saved_item.dart';

/// Local SQLite store. v5 adds: aiTopic/aiSubcategory/aiKeyPoints/
/// aiConfidence on items (AI subcategory taxonomy + topic + key points).
class AppDatabase {
  static const _name = 'save_later.db';
  static const _version = 5;
  Database? _db;
  bool _ftsAvailable = true;

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    // NOTE: mobile-only. Web preview uses WebStore (in-memory) — the sqlite
    // wasm build can't init in the sandboxed browser (COOP/COEP + wasm env
    // import errors), and merely importing the ffi_web package poisons the
    // web build. This file must stay free of web/sqlite-ffi imports.
    final dir = await getDatabasesPath();
    final opened = await openDatabase(
      p.join(dir, _name),
      version: _version,
      onCreate: (d, v) async => _createAll(d),
      onUpgrade: (d, oldV, newV) async => _upgrade(d, oldV),
    );
    _db = opened;
    return opened;
  }

  /// Shared v2/v3/v4/v5 migration steps (used by both mobile + web open paths).
  static Future<void> _upgrade(DatabaseExecutor d, int oldV) async {
    if (oldV < 2) {
      for (final col in [
        'siteName TEXT',
        'excerpt TEXT',
        'readingMinutes INTEGER',
        'subreddit TEXT',
        'redditScore INTEGER',
        'redditComments INTEGER',
        'isVideo INTEGER',
      ]) {
        await _addColumn(d, col);
      }
    }
    if (oldV < 3) {
      for (final col in ['bodyText TEXT', 'userNote TEXT', 'remindAt INTEGER']) {
        await _addColumn(d, col);
      }
      await _createV3Tables(d);
    }
    if (oldV < 4) {
      await _upgradeV4(d);
    }
    if (oldV < 5) {
      for (final col in [
        'aiTopic TEXT',
        'aiSubcategory TEXT',
        'aiKeyPoints TEXT',
        'aiConfidence REAL',
      ]) {
        await _addColumn(d, col);
      }
    }
  }

  /// match is a reserved word in SQLite FTS context and risky as a
  /// column name — rename to pattern, preserving existing rows.
  static Future<void> _upgradeV4(DatabaseExecutor d) async {
    final cols = await d.rawQuery('PRAGMA table_info(tag_rules)');
    final names = cols.map((c) => c['name'] as String).toSet();
    if (names.contains('match') && !names.contains('pattern')) {
      await d.execute('ALTER TABLE tag_rules RENAME COLUMN "match" TO pattern');
    } else if (!names.contains('pattern')) {
      await d.execute('ALTER TABLE tag_rules ADD COLUMN pattern TEXT NOT NULL DEFAULT \'\'');
    }
  }

  static Future<void> _addColumn(DatabaseExecutor d, String col) async {
    final name = col.split(' ').first;
    final existing = await d.rawQuery('PRAGMA table_info(items)');
    if (!existing.any((c) => c['name'] == name)) {
      await d.execute('ALTER TABLE items ADD COLUMN $col');
    }
  }

  static Future<void> _createAll(Database d) async {
    await d.execute('''
      CREATE TABLE items(
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        title TEXT NOT NULL,
        type TEXT NOT NULL,
        thumbnailUrl TEXT,
        author TEXT,
        summary TEXT,
        category TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        consumedAt INTEGER,
        aiProcessed INTEGER NOT NULL DEFAULT 0,
        siteName TEXT,
        excerpt TEXT,
        readingMinutes INTEGER,
        subreddit TEXT,
        redditScore INTEGER,
        redditComments INTEGER,
        isVideo INTEGER,
        bodyText TEXT,
        userNote TEXT,
        remindAt INTEGER,
        aiTopic TEXT,
        aiSubcategory TEXT,
        aiKeyPoints TEXT,
        aiConfidence REAL
      )
    ''');
    await d.execute('CREATE INDEX idx_items_status ON items(status)');
    await d.execute('CREATE INDEX idx_items_category ON items(category)');
    await d.execute('CREATE INDEX idx_items_created ON items(createdAt DESC)');
    await d.execute('CREATE INDEX idx_items_remind ON items(remindAt)');
    await _createV3Tables(d);
  }

  static Future<void> _createV3Tables(DatabaseExecutor d) async {
    await d.execute('''
      CREATE TABLE IF NOT EXISTS collections(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        icon TEXT,
        sortOrder INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS item_collections(
        itemId TEXT NOT NULL,
        collectionId TEXT NOT NULL,
        PRIMARY KEY (itemId, collectionId)
      )
    ''');
    await d.execute('CREATE INDEX IF NOT EXISTS idx_ic_item ON item_collections(itemId)');
    await d.execute('CREATE INDEX IF NOT EXISTS idx_ic_coll ON item_collections(collectionId)');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS tag_rules(
        id TEXT PRIMARY KEY,
        pattern TEXT NOT NULL,
        category TEXT,
        tags TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await d.execute('''
      CREATE TABLE IF NOT EXISTS highlights(
        id TEXT PRIMARY KEY,
        itemId TEXT NOT NULL,
        text TEXT NOT NULL,
        note TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');
    await d.execute('CREATE INDEX IF NOT EXISTS idx_hl_item ON highlights(itemId)');
    // FTS5 full-text index over title/summary/body/tags/userNote/topic.
    // Wrapped: some vendor SQLite builds ship without FTS5 — failure must
    // not break the whole open (list() falls back to LIKE when absent).
    try {
      await d.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
          id UNINDEXED, title, summary, bodyText, tags, userNote, aiTopic,
          content='', tokenize='porter'
        )
      ''');
      await d.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_items_fts_insert AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(id, title, summary, bodyText, tags, userNote, aiTopic)
          VALUES (new.id, new.title, new.summary, new.bodyText, new.tags, new.userNote, new.aiTopic);
        END
      ''');
      await d.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_items_fts_update AFTER UPDATE ON items BEGIN
          DELETE FROM items_fts WHERE id = old.id;
          INSERT INTO items_fts(id, title, summary, bodyText, tags, userNote, aiTopic)
          VALUES (new.id, new.title, new.summary, new.bodyText, new.tags, new.userNote, new.aiTopic);
        END
      ''');
      await d.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_items_fts_delete AFTER DELETE ON items BEGIN
          DELETE FROM items_fts WHERE id = old.id;
        END
      ''');
    } catch (_) {
      // FTS unavailable — search degrades to LIKE, app keeps working.
    }
  }

  /// Backfill FTS rows for pre-v3 installs (triggers only cover new writes).
  /// v5: rebuilds when the aiTopic column is missing so topic search works
  /// on existing installs. Never throws.
  Future<void> backfillFts() async {
    if (!_ftsAvailable) return;
    try {
      final d = await db;
      // v5 schema drift: old items_fts lacks aiTopic — rebuild it once.
      try {
        final cols = await d.rawQuery('SELECT * FROM items_fts LIMIT 0');
        if (cols.isNotEmpty && !cols.first.containsKey('aiTopic')) {
          await d.execute('DROP TRIGGER IF EXISTS trg_items_fts_insert');
          await d.execute('DROP TRIGGER IF EXISTS trg_items_fts_update');
          await d.execute('DROP TRIGGER IF EXISTS trg_items_fts_delete');
          await d.execute('DROP TABLE IF EXISTS items_fts');
          await _createV3Tables(d);
        }
      } catch (_) {
        // Fresh table path already handled by _createV3Tables.
      }
      final n = await d.rawQuery('SELECT COUNT(*) AS n FROM items_fts');
      final count = n.isEmpty ? 0 : (num.tryParse('${n.first['n']}') ?? 0);
      if (count > 0) return;
      await d.execute('''
        INSERT INTO items_fts(id, title, summary, bodyText, tags, userNote, aiTopic)
        SELECT id, title, summary, bodyText, tags, userNote, aiTopic FROM items
      ''');
    } catch (_) {
      _ftsAvailable = false;
    }
  }

  Future<void> upsert(SavedItem item) async {
    final d = await db;
    await d.insert('items', item.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateFields(String id, Map<String, Object?> fields) async {
    final d = await db;
    await d.update('items', fields, where: 'id = ?', whereArgs: [id]);
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
    final d = await db;
    // FTS path: match ids first, then load rows in createdAt order.
    // Skipped entirely when FTS proved unavailable (LIKE fallback below).
    List<String>? ftsIds;
    if (query != null && query.trim().isNotEmpty && fullText && _ftsAvailable) {
      final q = _ftsQuery(query);
      if (q == null) {
        // Query is only FTS syntax chars (e.g. "*") — skip FTS, use LIKE.
      } else {
        try {
          final rows = await d.rawQuery(
              'SELECT id FROM items_fts WHERE items_fts MATCH ? LIMIT 200', [q]);
          ftsIds = rows.map((r) => r['id'] as String).toList();
          if (ftsIds.isEmpty) return [];
        } catch (_) {
          _ftsAvailable = false;
          ftsIds = null; // fall back to LIKE below
        }
      }
    }
    final where = <String>[];
    final args = <Object?>[];
    if (ftsIds != null) {
      where.add('id IN (${List.filled(ftsIds.length, '?').join(',')})');
      args.addAll(ftsIds);
    }
    if (status != null) {
      where.add('status = ?');
      args.add(status.name);
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category.name);
    }
    if (type != null) {
      where.add('type = ?');
      args.add(type.name);
    }
    if (aiOnly) where.add('aiProcessed = 1');
    if (remindedOnly) where.add('remindAt IS NOT NULL');
    if (collectionId != null) {
      where.add('id IN (SELECT itemId FROM item_collections WHERE collectionId = ?)');
      args.add(collectionId);
    }
    if (query != null && query.trim().isNotEmpty && ftsIds == null) {
      where.add('(title LIKE ? OR url LIKE ? OR summary LIKE ? OR tags LIKE ? OR userNote LIKE ?)');
      final q = '%${query.trim()}%';
      args.addAll([q, q, q, q, q]);
    }
    final rows = await d.query(
      'items',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'createdAt DESC',
    );
    return rows.map(SavedItem.fromMap).toList();
  }

  /// Sanitizes free text into a safe FTS5 prefix query. Returns null when
  /// nothing searchable remains (caller falls back to LIKE).
  static String? _ftsQuery(String raw) {
    // Strip FTS operators / punctuation, keep letters+digits+spaces.
    final cleaned =
        raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim();
    final terms =
        cleaned.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).take(10).toList();
    if (terms.isEmpty) return null;
    // Prefix-match each term; quote defensively (no embedded quotes possible
    // after the strip above).
    return terms.map((t) => '"$t"*').join(' ');
  }

  Future<void> updateStatus(String id, ItemStatus status) async {
    final d = await db;
    await d.update(
      'items',
      {
        'status': status.name,
        'consumedAt':
            status == ItemStatus.done ? DateTime.now().millisecondsSinceEpoch : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final d = await db;
    await d.delete('items', where: 'id = ?', whereArgs: [id]);
    await d.delete('item_collections', where: 'itemId = ?', whereArgs: [id]);
    await d.delete('highlights', where: 'itemId = ?', whereArgs: [id]);
  }

  Future<bool> existsByUrl(String url) async => (await findIdByUrl(url)) != null;

  Future<String?> findIdByUrl(String url) async {
    final d = await db;
    final rows =
        await d.query('items', columns: ['id'], where: 'url = ?', whereArgs: [url], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['id'] as String?;
  }

  Future<SavedItem?> getById(String id) async {
    final d = await db;
    final rows = await d.query('items', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return SavedItem.fromMap(rows.first);
  }

  Future<int> count({ItemStatus? status, Category? category, bool? aiProcessed}) async {
    final d = await db;
    final where = <String>[];
    final args = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      args.add(status.name);
    }
    if (category != null) {
      where.add('category = ?');
      args.add(category.name);
    }
    if (aiProcessed != null) {
      where.add('aiProcessed = ?');
      args.add(aiProcessed ? 1 : 0);
    }
    final rows = await d.rawQuery(
      'SELECT COUNT(*) AS n FROM items${where.isEmpty ? '' : ' WHERE ${where.join(' AND ')}'}',
      args.isEmpty ? null : args,
    );
    if (rows.isEmpty) return 0;
    return (num.tryParse('${rows.first['n']}') ?? 0).toInt();
  }

  // ------------------------------------------------------------ collections
  Future<List<Collection>> collections() async {
    final d = await db;
    final rows = await d.query('collections', orderBy: 'sortOrder ASC, createdAt ASC');
    return rows.map(Collection.fromMap).toList();
  }

  Future<void> upsertCollection(Collection c) async {
    final d = await db;
    await d.insert('collections', c.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteCollection(String id) async {
    final d = await db;
    await d.delete('collections', where: 'id = ?', whereArgs: [id]);
    await d.delete('item_collections', where: 'collectionId = ?', whereArgs: [id]);
  }

  Future<List<String>> itemCollectionIds(String itemId) async {
    final d = await db;
    final rows = await d.query('item_collections',
        columns: ['collectionId'], where: 'itemId = ?', whereArgs: [itemId]);
    return rows.map((r) => r['collectionId'] as String).toList();
  }

  Future<void> setItemCollections(String itemId, List<String> collectionIds) async {
    final d = await db;
    await d.delete('item_collections', where: 'itemId = ?', whereArgs: [itemId]);
    for (final c in collectionIds) {
      await d.insert('item_collections', {'itemId': itemId, 'collectionId': c},
          conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<int> collectionCount(String collectionId) async {
    final d = await db;
    final rows = await d.rawQuery(
        'SELECT COUNT(*) AS n FROM item_collections WHERE collectionId = ?', [collectionId]);
    if (rows.isEmpty) return 0;
    return (num.tryParse('${rows.first['n']}') ?? 0).toInt();
  }

  // ----------------------------------------------------------------- rules
  Future<List<TagRule>> tagRules() async {
    final d = await db;
    final rows = await d.query('tag_rules');
    return rows.map(TagRule.fromMap).toList();
  }

  Future<void> upsertRule(TagRule r) async {
    final d = await db;
    await d.insert('tag_rules', r.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> deleteRule(String id) async {
    final d = await db;
    await d.delete('tag_rules', where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ highlights
  Future<List<Highlight>> highlights(String itemId) async {
    final d = await db;
    final rows = await d.query('highlights',
        where: 'itemId = ?', whereArgs: [itemId], orderBy: 'createdAt ASC');
    return rows.map(Highlight.fromMap).toList();
  }

  Future<void> addHighlight(Highlight h) async {
    final d = await db;
    await d.insert('highlights', h.toMap());
  }

  Future<void> deleteHighlight(String id) async {
    final d = await db;
    await d.delete('highlights', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
