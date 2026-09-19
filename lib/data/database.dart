import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/saved_item.dart';

/// Local SQLite store. Single table, no migrations needed for v1.
class AppDatabase {
  static const _name = 'save_later.db';
  static const _version = 2;
  Database? _db;

  Future<Database> get db async {
    final existing = _db;
    if (existing != null) return existing;
    final dir = await getDatabasesPath();
    final opened = await openDatabase(
      p.join(dir, _name),
      version: _version,
      onCreate: (d, v) async {
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
            isVideo INTEGER
          )
        ''');
        await d.execute('CREATE INDEX idx_items_status ON items(status)');
        await d.execute('CREATE INDEX idx_items_category ON items(category)');
        await d.execute('CREATE INDEX idx_items_created ON items(createdAt DESC)');
      },
      onUpgrade: (d, oldV, newV) async {
        // v1 -> v2: add enrichment columns. ALTER TABLE is idempotent-safe
        // because old installs are all at v1.
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
            final name = col.split(' ').first;
            final existing = await d.rawQuery('PRAGMA table_info(items)');
            if (!existing.any((c) => c['name'] == name)) {
              await d.execute('ALTER TABLE items ADD COLUMN $col');
            }
          }
        }
      },
    );
    _db = opened;
    return opened;
  }

  Future<void> upsert(SavedItem item) async {
    final d = await db;
    await d.insert('items', item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<SavedItem>> list(
      {ItemStatus? status,
      Category? category,
      ItemType? type,
      bool aiOnly = false,
      String? query}) async {
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
    if (type != null) {
      where.add('type = ?');
      args.add(type.name);
    }
    if (aiOnly) {
      where.add('aiProcessed = 1');
    }
    if (query != null && query.trim().isNotEmpty) {
      where.add('(title LIKE ? OR url LIKE ? OR summary LIKE ? OR tags LIKE ?)');
      final q = '%${query.trim()}%';
      args.addAll([q, q, q, q]);
    }
    final rows = await d.query(
      'items',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'createdAt DESC',
    );
    return rows.map(SavedItem.fromMap).toList();
  }

  Future<void> updateStatus(String id, ItemStatus status) async {
    final d = await db;
    await d.update(
      'items',
      {
        'status': status.name,
        'consumedAt': status == ItemStatus.done
            ? DateTime.now().millisecondsSinceEpoch
            : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> delete(String id) async {
    final d = await db;
    await d.delete('items', where: 'id = ?', whereArgs: [id]);
  }

  Future<bool> existsByUrl(String url) async => (await findIdByUrl(url)) != null;

  Future<String?> findIdByUrl(String url) async {
    final d = await db;
    final rows = await d.query('items',
        columns: ['id'], where: 'url = ?', whereArgs: [url], limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['id'] as String?;
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
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
