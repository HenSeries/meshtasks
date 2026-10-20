import 'package:flutter_test/flutter_test.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/model/dates.dart';
import 'package:meshtasks/model/reminders.dart';
import 'package:meshtasks/model/repo.dart';

void sync(List<Repo> ds) {
  for (var i = 0; i < 2; i++) {
    for (final a in ds) {
      for (final b in ds) {
        if (a != b) b.store.merge(a.store.changesSince('').cells);
      }
    }
  }
}

void main() {
  var clock = DateTime(2026, 10, 19, 10); // Monday 10:00
  late Repo phone, laptop, ana;
  late String me;

  setUp(() {
    clock = DateTime(2026, 10, 19, 10);
    phone = Repo(Store.open(':memory:'), now: () => clock);
    me = phone.addMember('Jorge');
    phone.setMe(me);
    phone.ensureMyKey();
    laptop = Repo(Store.open(':memory:'), now: () => clock);
    ana = Repo(Store.open(':memory:'), now: () => clock);
    ana.setMe(ana.addMember('Ana'));
    ana.ensureMyKey();
    sync([phone, laptop, ana]);
    laptop.importKey(phone.exportMyKey());
  });

  group('Points', () {
    test('on-time completion earns base + bonus and the task reward', () {
      final id = phone.quickAdd('Ship release today 15:00 p1')!;
      phone.updateTask(id, {'reward': 'Pizza night'});
      final c = phone.complete(id);
      expect(c.points, 12);
      expect(c.reward, 'Pizza night');
      expect(phone.balance(me), 12);
      expect(phone.pendingIncentives(me).single.title, 'Pizza night');
    });

    test('missed task is penalized once, with its punishment', () {
      final id = phone.quickAdd('Send invoices today 9:00 p2')!;
      phone.updateTask(id, {'punishment': 'No coffee tomorrow'});
      clock = DateTime(2026, 10, 19, 9, 30); // within the grace hour
      expect(phone.evaluate(), isEmpty);
      clock = DateTime(2026, 10, 19, 11);
      final created = phone.evaluate();
      expect(created.map((e) => e.kind), unorderedEquals(['penalty', 'punishment']));
      expect(phone.evaluate(), isEmpty); // idempotent
      expect(phone.balance(me), -6);
      // Completing late still earns base points, no bonus.
      expect(phone.complete(id).points, 7);
      expect(phone.balance(me), 1);
    });

    test('two of my devices scoring the same event make one entry', () {
      final id = phone.quickAdd('Backup today 8:00')!;
      sync([phone, laptop, ana]);
      clock = DateTime(2026, 10, 19, 12);
      phone.evaluate();
      laptop.evaluate();
      sync([phone, laptop, ana]);
      expect(phone.balance(me), -2);
      expect(laptop.balance(me), -2);
      expect(phone.ledger(me), hasLength(1));
      expect(id, isNotEmpty);
    });

    test('an on-time completion cancels a penalty another device recorded', () {
      final id = phone.quickAdd('Report today 9:00')!;
      sync([phone, laptop, ana]);
      // Phone completes on time but is offline; laptop later thinks it's missed.
      clock = DateTime(2026, 10, 19, 8, 55);
      phone.complete(id);
      clock = DateTime(2026, 10, 19, 12);
      laptop.evaluate();
      sync([phone, laptop, ana]);
      expect(laptop.balance(me), 5); // 3 + on-time bonus, no penalty
      expect(laptop.ledger(me).map((e) => e.kind), ['earn']);
    });

    test('uncompleting takes the points back; recurring undo too', () {
      final id = phone.quickAdd('Water plants')!;
      phone.complete(id);
      expect(phone.balance(me), 3);
      phone.uncomplete(id);
      expect(phone.balance(me), 0);
      phone.complete(id);
      expect(phone.balance(me), 3);

      final r = phone.quickAdd('Standup every weekday 18:00')!;
      final before = phone.task(r)!.r['due'] as String?;
      phone.complete(r);
      expect(phone.balance(me), 8);
      phone.undoRecurring(r, before);
      expect(phone.balance(me), 3);
      expect(phone.task(r)!.r['due'], before);
    });

    test('rewards are bought with points; going negative triggers a punishment', () {
      final pizza = phone.addReward('Pizza', 10);
      phone.addPunishment('Clean the kitchen');
      expect(phone.redeem(pizza), isFalse);
      phone.adjustPoints(15, 'Helped a client on Sunday');
      expect(phone.redeem(pizza), isTrue);
      expect(phone.balance(me), 5);
      phone.adjustPoints(-8, 'Missed standup');
      final created = phone.evaluate();
      expect(created.single.title, 'Clean the kitchen');
      expect(phone.evaluate(), isEmpty); // one per day
      clock = clock.add(const Duration(days: 1));
      expect(phone.evaluate(), hasLength(1));
    });

    test('tasks that are not mine do not score for me', () {
      final ana2 = ana.meId!;
      final id = phone.addTask(title: 'Ana’s job', assignee: ana2);
      expect(phone.complete(id).points, 0);
      expect(phone.balance(me), 0);
    });
  });

  group('Visibility', () {
    test('private by default, shared on request', () {
      phone.addReward('Secret treat', 5);
      final shared = phone.addPunishment('Bring donuts for everyone', shared: true);
      phone.adjustPoints(4, 'bonus');
      sync([phone, laptop, ana]);
      expect(ana.rewards(me), isEmpty);
      expect(ana.punishments(me).single.title, 'Bring donuts for everyone');
      expect(ana.ledger(me), isEmpty); // score private
      expect(laptop.rewards(me).single.title, 'Secret treat'); // my other device

      phone.setScorePublic(true);
      phone.setIncentiveShared('punishments', shared, false);
      sync([phone, laptop, ana]);
      expect(ana.balance(me), 4);
      expect(ana.punishments(me), isEmpty);
    });
  });

  group('Reminders', () {
    test('only my tasks, at due time by default, with extras and alarms', () {
      phone.quickAdd('Call bank today 15:00 !alarma !30m');
      phone.quickAdd('All day thing today');
      phone.quickAdd('All day with reminder tomorrow !0');
      phone.addTask(title: 'Ana’s', assignee: ana.meId, due: Due(clock, 16 * 60));
      final rs = upcomingReminders(phone);
      expect(rs.map((r) => (r.title, r.at.hour, r.at.minute, r.alarm)), [
        ('Call bank', 14, 30, true),
        ('Call bank', 15, 0, true),
        ('All day with reminder', 9, 0, false),
      ]);
      expect(rs.first.id, isNot(rs[1].id));
      expect(Reminder.stableId('x'), Reminder.stableId('x'));
    });
  });

  group('Docs', () {
    test('create, attach, sync, delete', () {
      final id = phone.addDoc('Onboarding', body: '# Welcome\n\n- Read this');
      phone.attach(id, Attachment('a' * 64, 'handbook.pdf', 1200));
      phone.attach(id, Attachment('b' * 64, 'office.png', 300));
      sync([phone, laptop, ana]);
      final d = ana.doc(id)!;
      expect(d.title, 'Onboarding');
      expect(d.files.map((f) => f.name), ['handbook.pdf', 'office.png']);
      expect(d.files.last.markdown, '![office.png](blob:${'b' * 64})');
      expect(ana.wantedBlobs, {'a' * 64, 'b' * 64});
      ana.detach(id, 'a' * 64);
      ana.deleteDoc(id);
      sync([phone, laptop, ana]);
      expect(phone.docs, isEmpty);
    });
  });
}
