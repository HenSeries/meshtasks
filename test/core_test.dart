import 'dart:io';

import 'package:meshtasks/core/blobs.dart';
import 'package:meshtasks/core/hlc.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/core/sync.dart';
import 'package:meshtasks/core/team.dart';
import 'package:test/test.dart';

Store mem(String node) => Store.open(':memory:', nodeId: node);

void main() {
  group('Hlc', () {
    test('string order matches logical order', () {
      final a = const Hlc(1000, 0, 'b');
      final b = const Hlc(1000, 1, 'a');
      final c = const Hlc(1001, 0, 'a');
      expect(a.compareTo(b) < 0, isTrue);
      expect(a.toString().compareTo(b.toString()) < 0, isTrue);
      expect(b.toString().compareTo(c.toString()) < 0, isTrue);
      expect(Hlc.parse(b.toString()), b);
    });

    test('monotonic even if wall clock goes backwards', () {
      var t = 5000;
      final clock = HlcClock('n', now: () => t);
      final x = clock.send();
      t = 1000;
      expect(clock.send().compareTo(x) > 0, isTrue);
    });

    test('rejects remote clocks far in the future', () {
      final clock = HlcClock('n', now: () => 0);
      expect(() => clock.receive(const Hlc(10 * 60 * 1000, 0, 'x')),
          throwsStateError);
    });
  });

  group('Store', () {
    test('field-level last writer wins, both orders converge', () {
      final a = mem('a'), b = mem('b');
      a.put('tasks', 't1', {'title': 'Draft', 'priority': 4});
      b.merge(a.changesSince('').cells);
      // Concurrent edits to different fields both survive.
      a.put('tasks', 't1', {'title': 'Final'});
      b.put('tasks', 't1', {'priority': 1});
      // Concurrent edits to the same field: later HLC wins everywhere.
      a.put('tasks', 't1', {'notes': 'from a'});
      b.put('tasks', 't1', {'notes': 'from b'});

      final fromA = a.changesSince('').cells;
      final fromB = b.changesSince('').cells;
      a.merge(fromB);
      b.merge(fromA);
      expect(a.row('tasks', 't1'), b.row('tasks', 't1'));
      expect(a.row('tasks', 't1')!['title'], 'Final');
      expect(a.row('tasks', 't1')!['priority'], 1);
    });

    test('merge is idempotent and ignores stale writes', () {
      final a = mem('a'), b = mem('b');
      a.put('tasks', 't', {'title': 'old'});
      final old = a.changesSince('').cells;
      a.put('tasks', 't', {'title': 'new'});
      b.merge(a.changesSince('').cells);
      expect(b.merge(old), 0);
      expect(b.merge(a.changesSince('').cells), 0);
      expect(b.row('tasks', 't')!['title'], 'new');
    });

    test('deleted rows hidden by default', () {
      final a = mem('a');
      a.put('tasks', 't', {'title': 'x'});
      a.put('tasks', 't', {'deleted': true});
      expect(a.rows('tasks'), isEmpty);
      expect(a.rows('tasks', includeDeleted: true), hasLength(1));
    });

    test('survives reopen with clock ahead of stored data', () {
      final dir = Directory.systemTemp.createTempSync('mt');
      final path = '${dir.path}/db.sqlite';
      var s = Store.open(path);
      final node = s.nodeId;
      s.put('tasks', 't', {'title': 'persisted'});
      final last = s.clock.last;
      s.close();
      s = Store.open(path);
      expect(s.nodeId, node);
      expect(s.row('tasks', 't')!['title'], 'persisted');
      expect(s.clock.send().compareTo(last) > 0, isTrue);
      s.close();
      dir.deleteSync(recursive: true);
    });

    test('paging walks every change exactly once', () {
      final a = mem('a');
      for (var i = 0; i < 25; i++) {
        a.put('tasks', 't$i', {'title': '$i'});
      }
      var cursor = '';
      final seen = <String>[];
      ChangesPage p;
      do {
        p = a.changesSince(cursor, limit: 7);
        seen.addAll(p.cells.map((c) => c.id));
        cursor = p.cursor;
      } while (p.more);
      expect(seen, hasLength(25));
      expect(seen.toSet(), hasLength(25));
    });
  });

  group('Team', () {
    test('invite round trip', () {
      final t = Team.create('Ops');
      final (back, peers) = Team.parseInvite(t.invite(['10.0.0.2:47800']));
      expect(back.id, t.id);
      expect(back.name, 'Ops');
      expect(back.secret, t.secret);
      expect(back.tag, t.tag);
      expect(peers, ['10.0.0.2:47800']);
    });

    test('envelope rejects a different key', () async {
      final a = Envelope(Team.create('a').secret);
      final b = Envelope(Team.create('b').secret);
      final sealed = await a.seal({'x': 1});
      expect(await a.open(sealed), {'x': 1});
      expect(() => b.open(sealed), throwsA(anything));
    });
  });

  group('Sync over HTTP', () {
    late Team team;
    final nodes = <SyncNode>[];

    Future<SyncNode> node(String id, {Team? t}) async {
      final n = SyncNode(mem(id), t ?? team,
          deviceName: id, preferredPort: 0, discovery: false);
      await n.start();
      nodes.add(n);
      return n;
    }

    setUp(() => team = Team.create('test'));
    tearDown(() async {
      for (final n in nodes) {
        await n.stop();
      }
      nodes.clear();
    });

    test('two devices exchange edits both ways', () async {
      final a = await node('a'), b = await node('b');
      a.store.put('tasks', 't1', {'title': 'from a'});
      b.store.put('tasks', 't2', {'title': 'from b'});
      expect(await a.syncAddress('127.0.0.1:${b.port}'), isTrue);
      expect(b.store.row('tasks', 't1')!['title'], 'from a');
      expect(a.store.row('tasks', 't2')!['title'], 'from b');
      expect(a.peers.keys, contains('b'));
    });

    test('offline edits on both sides converge after reconnect', () async {
      final a = await node('a'), b = await node('b');
      final addr = '127.0.0.1:${b.port}';
      a.store.put('tasks', 't', {'title': 'shared', 'done': false});
      await a.syncAddress(addr);
      // "Offline": both edit without syncing.
      a.store.put('tasks', 't', {'done': true});
      b.store.put('tasks', 't', {'title': 'renamed'});
      await a.syncAddress(addr);
      expect(a.store.row('tasks', 't'), b.store.row('tasks', 't'));
      expect(a.store.row('tasks', 't')!['done'], true);
      expect(a.store.row('tasks', 't')!['title'], 'renamed');
    });

    test('changes relay through a middle node (a <-> b <-> c)', () async {
      final a = await node('a'), b = await node('b'), c = await node('c');
      a.store.put('tasks', 'x', {'title': 'hop'});
      await a.syncAddress('127.0.0.1:${b.port}');
      await c.syncAddress('127.0.0.1:${b.port}');
      expect(c.store.row('tasks', 'x')!['title'], 'hop');
    });

    test('large history syncs across several pages', () async {
      final a = await node('a'), b = await node('b');
      for (var i = 0; i < 2500; i++) {
        a.store.put('tasks', 't$i', {'title': '$i', 'order': i});
      }
      await b.syncAddress('127.0.0.1:${a.port}');
      expect(b.store.rows('tasks'), hasLength(2500));
    });

    test('a device with another team key is refused', () async {
      final a = await node('a');
      final intruder = await node('evil', t: Team.create('other'));
      a.store.put('tasks', 's', {'title': 'secret'});
      expect(await intruder.syncAddress('127.0.0.1:${a.port}'), isFalse);
      expect(intruder.store.rows('tasks'), isEmpty);
    });
  });

  group('Attachments', () {
    final nodes = <SyncNode>[];
    tearDown(() async {
      for (final n in nodes) {
        await n.stop();
      }
      nodes.clear();
    });

    test('files referenced by records travel through the mesh', () async {
      final team = Team.create('t');
      final tmp = Directory.systemTemp.createTempSync('blobs');
      Future<SyncNode> node(String id) async {
        final store = mem(id);
        final blobs = BlobStore(Directory('${tmp.path}/$id'));
        final n = SyncNode(store, team,
            deviceName: id, preferredPort: 0, discovery: false, blobs: blobs,
            wantedBlobs: () => {
                  for (final d in store.rows('docs').values)
                    for (final a in (d['files'] as List? ?? [])) (a as Map)['hash'] as String
                });
        await n.start();
        nodes.add(n);
        return n;
      }

      final a = await node('a'), b = await node('b'), c = await node('c');
      final bytes = List<int>.generate(300000, (i) => i * 7 % 251);
      final h = a.blobs!.put(bytes);
      a.store.put('docs', 'd1', {
        'title': 'Manual',
        'files': [{'hash': h, 'name': 'manual.pdf'}]
      });
      await b.syncAddress('127.0.0.1:${a.port}');
      expect(b.blobs!.read(h), bytes);
      await c.syncAddress('127.0.0.1:${b.port}'); // c never talks to a
      expect(c.blobs!.read(h), bytes);
      expect(() => c.blobs!.put([1, 2, 3], expect: h), throwsStateError);
      tmp.deleteSync(recursive: true);
    });
  });
}
