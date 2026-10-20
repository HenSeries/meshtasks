import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/model/repo.dart';

/// Full mesh exchange between in-memory devices.
void syncAll(List<Repo> devices) {
  for (var round = 0; round < 2; round++) {
    for (final a in devices) {
      for (final b in devices) {
        if (a != b) b.store.merge(a.store.changesSince('').cells);
      }
    }
  }
}

void main() {
  late Repo jorgePhone, jorgeLaptop, ana;
  late String jorge;

  setUp(() {
    jorgePhone = Repo(Store.open(':memory:'));
    jorge = jorgePhone.addMember('Jorge');
    jorgePhone.setMe(jorge);
    jorgePhone.ensureMyKey();

    ana = Repo(Store.open(':memory:'));
    ana.setMe(ana.addMember('Ana'));
    ana.ensureMyKey();

    jorgeLaptop = Repo(Store.open(':memory:'));
    jorgeLaptop.setMe(jorgeLaptop.addMember('Jorge (laptop)'));
    syncAll([jorgePhone, jorgeLaptop, ana]);
  });

  test('private task is invisible and unreadable to teammates', () {
    final id = jorgePhone.quickAdd('Buy anniversary gift tomorrow !private')!;
    jorgePhone.addComment(id, 'Ring size 6');
    jorgePhone.addTask(title: 'Shared task');
    syncAll([jorgePhone, jorgeLaptop, ana]);

    expect(ana.tasks.map((t) => t.title), ['Shared task']);
    expect(ana.task(id), isNull);
    expect(ana.comments(id), isEmpty);
    // The ciphertext did replicate, but no plaintext did.
    final raw = jsonEncode(ana.store.changesSince('').cells.map((c) => c.toJson()).toList());
    expect(raw.contains('anniversary'), isFalse);
    expect(raw.contains('Ring size'), isFalse);
    expect(ana.store.row('tasks', id), isNotNull);

    final mine = jorgePhone.task(id)!;
    expect(mine.isPrivate, isTrue);
    expect(mine.assignee, jorge);
    expect(jorgePhone.comments(id).single.text, 'Ring size 6');
  });

  test('my other device reads private tasks after importing my key', () {
    final id = jorgePhone.quickAdd('Doctor appointment !privada')!;
    syncAll([jorgePhone, jorgeLaptop, ana]);
    expect(jorgeLaptop.task(id), isNull);

    final code = jorgePhone.exportMyKey();
    final laptopThrowaway = jorgeLaptop.meId!;
    jorgeLaptop.importKey(code);
    expect(jorgeLaptop.meId, jorge);
    expect(jorgeLaptop.task(id)!.title, 'Doctor appointment');
    // The member the laptop created on joining is cleaned up.
    syncAll([jorgePhone, jorgeLaptop, ana]);
    expect(ana.members.map((m) => m.id), isNot(contains(laptopThrowaway)));

    // Concurrent edits to different fields on both of my devices merge.
    jorgeLaptop.updateTask(id, {'priority': 1});
    jorgePhone.updateTask(id, {'title': 'Doctor appointment (bring results)'});
    syncAll([jorgePhone, jorgeLaptop, ana]);
    for (final d in [jorgePhone, jorgeLaptop]) {
      expect(d.task(id)!.title, 'Doctor appointment (bring results)');
      expect(d.task(id)!.priority, 1);
    }
    expect(ana.task(id), isNull);
  });

  test('a wrong key is rejected', () {
    jorgePhone.quickAdd('x !private');
    syncAll([jorgePhone, jorgeLaptop, ana]);
    final anasKey = ana.exportMyKey();
    final forged = anasKey.replaceFirst(ana.meId!, jorge);
    expect(() => jorgeLaptop.importKey(forged), throwsFormatException);
  });

  test('sharing a private task with the team again', () {
    final id = jorgePhone.addTask(title: 'Draft budget', private: true);
    final sub = jorgePhone.addTask(title: 'Collect quotes', parentId: id);
    expect(jorgePhone.task(sub)!.isPrivate, isTrue); // inherits from parent
    syncAll([jorgePhone, jorgeLaptop, ana]);
    expect(ana.task(id), isNull);

    jorgePhone.setPrivate(id, false);
    syncAll([jorgePhone, jorgeLaptop, ana]);
    expect(ana.task(id)!.title, 'Draft budget');
    expect(ana.task(sub)!.title, 'Collect quotes');

    jorgePhone.setPrivate(id, true);
    syncAll([jorgePhone, jorgeLaptop, ana]);
    expect(ana.task(id), isNull);
    expect(ana.task(sub), isNull);
  });

  test('device that lacks my existing key must import it, not mint a new one', () {
    jorgeLaptop.setMe(jorge);
    expect(jorgeLaptop.myKeyIsElsewhere, isTrue);
    expect(() => jorgeLaptop.addTask(title: 'x', private: true), throwsStateError);
  });

  test('real join flow: each device made its own key, then I link them', () {
    // Like AppState.joinTeam: the PC joins, gets its own member and key.
    final pc = Repo(Store.open(':memory:'));
    final pcMember = pc.addMember('Jorge PC');
    pc.setMe(pcMember);
    pc.ensureMyKey();
    syncAll([jorgePhone, pc, ana]);
    // Private tasks written on both before linking.
    final fromPhone = jorgePhone.addTask(title: 'Phone secret', private: true);
    final fromPc = pc.addTask(title: 'PC secret', private: true);
    syncAll([jorgePhone, pc, ana]);

    pc.importKey(jorgePhone.exportMyKey());
    syncAll([jorgePhone, pc, ana]);

    expect(pc.task(fromPhone)?.title, 'Phone secret', reason: 'PC reads phone private');
    expect(jorgePhone.task(fromPc)?.title, 'PC secret', reason: 'phone reads PC private');
    expect(ana.task(fromPc), isNull);
    expect(pc.members.map((m) => m.name), isNot(contains('Jorge PC')),
        reason: 'throwaway member removed');
  });
}
