// CLI tool: printing to stdout is its interface.
// ignore_for_file: avoid_print

// Headless MeshTasks peer: an always-on relay for the mesh (PC, Raspberry Pi,
// spare phone in Termux…) plus a few commands for scripting.
//
//   dart run bin/node.dart --db relay.db create "Team" "Relay"
//   dart run bin/node.dart --db relay.db join <invite-code>
//   dart run bin/node.dart --db relay.db invite
//   dart run bin/node.dart --db relay.db serve [--peer host:port]...
//   dart run bin/node.dart --db relay.db add "Task title" [--due 2026-10-20]
//   dart run bin/node.dart --db relay.db list
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/core/sync.dart';
import 'package:meshtasks/core/team.dart';

Future<void> main(List<String> argv) async {
  final args = [...argv];
  String opt(String name, String fallback) {
    final i = args.indexOf(name);
    if (i < 0 || i + 1 >= args.length) return fallback;
    final v = args[i + 1];
    args.removeRange(i, i + 2);
    return v;
  }

  List<String> opts(String name) {
    final out = <String>[];
    while (args.contains(name)) {
      out.add(opt(name, ''));
    }
    return out;
  }

  final db = opt('--db', 'meshtasks-node.db');
  final port = int.parse(opt('--port', '${SyncNode.defaultPort}'));
  final due = opt('--due', '');
  final peers = opts('--peer');
  if (args.isEmpty) {
    stderr.writeln('usage: node.dart [--db file] create|join|invite|serve|add|list ...');
    exit(64);
  }

  final store = Store.open(db);
  Team? team() {
    final id = store.getMeta('team_id');
    if (id == null) return null;
    return Team(id, store.getMeta('team_name')!, base64Url.decode(store.getMeta('team_secret')!));
  }

  void saveTeam(Team t, String me) {
    store.setMeta('team_id', t.id);
    store.setMeta('team_name', t.name);
    store.setMeta('team_secret', base64Url.encode(t.secret));
    store.setMeta('device_name', me);
  }

  switch (args.first) {
    case 'create':
      saveTeam(Team.create(args[1]), args.length > 2 ? args[2] : 'relay');
      print('Created team ${args[1]}. Run "invite" to get a code.');
    case 'join':
      final (t, addrs) = Team.parseInvite(args[1]);
      saveTeam(t, args.length > 2 ? args[2] : 'relay');
      store.setMeta('pending_addresses', jsonEncode(addrs));
      print('Joined ${t.name}. Run "serve" to sync.');
    case 'invite':
      final node = SyncNode(store, team()!, deviceName: 'relay', preferredPort: port, discovery: false);
      await node.start();
      print(team()!.invite(await node.localAddresses()));
      await node.stop();
    case 'add':
      final id = Store.newId();
      store.put('tasks', id, {
        'title': args[1],
        'priority': 4,
        'done': false,
        'labels': <String>[],
        'order': DateTime.now().millisecondsSinceEpoch / 1000,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        if (due.isNotEmpty) 'due': due,
      });
      print(id);
    case 'list':
      for (final t in store.rows('tasks').values) {
        print('${t['done'] == true ? '[x]' : '[ ]'} ${t['title']}  ${t['due'] ?? ''}');
      }
    case 'serve':
      final t = team();
      if (t == null) {
        stderr.writeln('No team yet: run create or join first.');
        exit(1);
      }
      final node = SyncNode(store, t,
          deviceName: store.getMeta('device_name') ?? 'relay', preferredPort: port);
      await node.start();
      for (final p in peers) {
        await node.addAddress(p);
      }
      print('Serving team "${t.name}" on ${(await node.localAddresses()).join(', ')}');
      var last = '';
      node.statusChanges.listen((_) {
        final s = node.peers.values
            .map((p) => '${p.name}${p.online ? '*' : ''}')
            .join(' ');
        if (s != last) print('[${DateTime.now().toIso8601String().substring(11, 19)}] peers: $s');
        last = s;
      });
      store.changes.listen((tables) => print(
          '[${DateTime.now().toIso8601String().substring(11, 19)}] changed: ${tables.join(', ')} '
          '(${store.rows('tasks').length} tasks)'));
      await ProcessSignal.sigint.watch().first;
      await node.stop();
      store.close();
    default:
      stderr.writeln('unknown command ${args.first}');
      exit(64);
  }
}
