import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'hlc.dart';

/// One field of one record. The unit of replication.
///
/// Conflict resolution is last-writer-wins per field, ordered by [hlc], so two
/// people editing different fields of the same task never lose each other's
/// changes. [modified] is this replica's local clock at the moment the cell
/// was stored; sync cursors are expressed in it.
class Cell {
  final String table;
  final String id;
  final String field;
  final Object? value;
  final String hlc;
  final String modified;

  const Cell(this.table, this.id, this.field, this.value, this.hlc,
      [this.modified = '']);

  Map<String, Object?> toJson() =>
      {'t': table, 'i': id, 'f': field, 'v': value, 'h': hlc};

  factory Cell.fromJson(Map<String, Object?> j) => Cell(
      j['t'] as String, j['i'] as String, j['f'] as String, j['v'],
      j['h'] as String);
}

class ChangesPage {
  final List<Cell> cells;
  final String cursor;
  final bool more;
  ChangesPage(this.cells, this.cursor, this.more);
}

/// Local-first replicated store: SQLite for durability, an in-memory
/// materialized view for fast reads.
class Store {
  final Database _db;
  final HlcClock clock;
  final Map<String, Map<String, Map<String, Cell>>> _data = {};
  final _changes = StreamController<Set<String>>.broadcast();
  final _remote = StreamController<List<Cell>>.broadcast();

  Store._(this._db, this.clock);

  String get nodeId => clock.node;

  /// Emits the set of tables touched by each write or merge.
  Stream<Set<String>> get changes => _changes.stream;

  /// Cells that arrived from other devices and changed local state.
  Stream<List<Cell>> get remoteChanges => _remote.stream;

  static Store open(String path, {String? nodeId, int Function()? now}) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('''
      CREATE TABLE IF NOT EXISTS cells(
        tbl TEXT NOT NULL, id TEXT NOT NULL, field TEXT NOT NULL,
        value TEXT, hlc TEXT NOT NULL, modified TEXT NOT NULL,
        PRIMARY KEY(tbl, id, field)) WITHOUT ROWID''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS cells_modified ON cells(modified)');
    db.execute('CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)');

    String? node = _getMeta(db, 'node');
    if (node == null) {
      node = nodeId ?? newId();
      _setMeta(db, 'node', node);
    }
    final maxRow = db.select(
        'SELECT max(max(hlc), max(modified)) AS m FROM cells').first;
    final last = maxRow['m'] as String?;
    final lastHlc = last == null ? null : Hlc.parse(last);
    final clock = HlcClock(node,
        last: lastHlc == null ? null : Hlc(lastHlc.millis, lastHlc.counter, node),
        now: now);

    final store = Store._(db, clock);
    for (final r in db.select('SELECT * FROM cells')) {
      store._cache(Cell(r['tbl'] as String, r['id'] as String,
          r['field'] as String, _decode(r['value'] as String?),
          r['hlc'] as String, r['modified'] as String));
    }
    return store;
  }

  void close() {
    _changes.close();
    _remote.close();
    _db.close();
  }

  // ---- local metadata (never replicated) ----

  String? getMeta(String k) => _getMeta(_db, k);

  /// All local metadata whose key starts with [prefix].
  Map<String, String> metaWithPrefix(String prefix) => {
        for (final r in _db.select(
            "SELECT k, v FROM meta WHERE substr(k, 1, ?) = ?", [prefix.length, prefix]))
          r['k'] as String: r['v'] as String,
      };
  void setMeta(String k, String? v) => _setMeta(_db, k, v);

  static String? _getMeta(Database db, String k) {
    final r = db.select('SELECT v FROM meta WHERE k=?', [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  static void _setMeta(Database db, String k, String? v) {
    if (v == null) {
      db.execute('DELETE FROM meta WHERE k=?', [k]);
    } else {
      db.execute('INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)', [k, v]);
    }
  }

  // ---- reads ----

  /// All records of [table] as `id -> {field: value}`, including the `id`.
  /// Records with `deleted == true` are skipped unless [includeDeleted].
  Map<String, Map<String, Object?>> rows(String table,
      {bool includeDeleted = false}) {
    final out = <String, Map<String, Object?>>{};
    final t = _data[table];
    if (t == null) return out;
    t.forEach((id, fields) {
      final row = <String, Object?>{'id': id};
      fields.forEach((f, c) => row[f] = c.value);
      if (!includeDeleted && row['deleted'] == true) return;
      out[id] = row;
    });
    return out;
  }

  Map<String, Object?>? row(String table, String id) {
    final fields = _data[table]?[id];
    if (fields == null) return null;
    return {'id': id, for (final c in fields.values) c.field: c.value};
  }

  /// The highest local `modified` stamp; a peer that has seen everything up
  /// to here has seen everything.
  String get cursor {
    final r = _db.select('SELECT max(modified) AS m FROM cells').first;
    return (r['m'] as String?) ?? '';
  }

  ChangesPage changesSince(String since, {int limit = 2000}) {
    final rs = _db.select(
        'SELECT * FROM cells WHERE modified > ? ORDER BY modified LIMIT ?',
        [since, limit + 1]);
    final more = rs.length > limit;
    final cells = [
      for (final r in rs.take(limit))
        Cell(r['tbl'] as String, r['id'] as String, r['field'] as String,
            _decode(r['value'] as String?), r['hlc'] as String,
            r['modified'] as String)
    ];
    return ChangesPage(
        cells, cells.isEmpty ? since : cells.last.modified, more);
  }

  // ---- writes ----

  /// Write fields of a record as a local edit.
  void put(String table, String id, Map<String, Object?> fields) {
    if (fields.isEmpty) return;
    final cells = <Cell>[];
    for (final e in fields.entries) {
      final ts = clock.send().toString();
      cells.add(Cell(table, id, e.key, e.value, ts, ts));
    }
    _commit(cells);
    _changes.add({table});
  }

  /// Merge remote cells. Returns how many changed local state.
  int merge(Iterable<Cell> cells) {
    // Winners keyed by (table,id,field) so duplicates within one batch
    // resolve the same way as across batches.
    final winners = <String, Cell>{};
    for (final c in cells) {
      clock.receive(Hlc.parse(c.hlc));
      final key = '${c.table}\u0000${c.id}\u0000${c.field}';
      final current = winners[key] ?? _data[c.table]?[c.id]?[c.field];
      if (current != null && current.hlc.compareTo(c.hlc) >= 0) continue;
      winners[key] = c;
    }
    final applied = [
      for (final c in winners.values)
        Cell(c.table, c.id, c.field, c.value, c.hlc, clock.send().toString())
    ];
    if (applied.isEmpty) return 0;
    _commit(applied);
    _changes.add({for (final c in applied) c.table});
    _remote.add(applied);
    return applied.length;
  }

  void _commit(List<Cell> cells) {
    _db.execute('BEGIN');
    try {
      final stmt = _db.prepare(
          'INSERT OR REPLACE INTO cells(tbl,id,field,value,hlc,modified) '
          'VALUES(?,?,?,?,?,?)');
      for (final c in cells) {
        stmt.execute(
            [c.table, c.id, c.field, jsonEncode(c.value), c.hlc, c.modified]);
      }
      stmt.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    cells.forEach(_cache);
  }

  void _cache(Cell c) {
    _data
        .putIfAbsent(c.table, () => {})
        .putIfAbsent(c.id, () => {})[c.field] = c;
  }

  static Object? _decode(String? s) => s == null ? null : jsonDecode(s);

  static final _rnd = Random.secure();

  /// 100 random bits in lowercase base32; collision-safe across devices.
  static String newId() {
    const alphabet = '0123456789abcdefghjkmnpqrstvwxyz';
    return List.generate(20, (_) => alphabet[_rnd.nextInt(32)]).join();
  }
}
