import 'package:flutter_test/flutter_test.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/model/dates.dart';
import 'package:meshtasks/model/quick_add.dart';
import 'package:meshtasks/model/repo.dart';

// Saturday 2026-10-17, 10:00
final now = DateTime(2026, 10, 17, 10);

QuickAdd qa(String s, {List<String> projects = const [], List<String> members = const []}) =>
    parseQuickAdd(s, now: now, projects: projects, members: members);

void main() {
  group('Recurrence', () {
    test('parses common forms', () {
      expect(Recurrence.tryParse('every day').toString(), 'every day');
      expect(Recurrence.tryParse('every 2 weeks').toString(), 'every 2 weeks');
      expect(Recurrence.tryParse('every weekday').toString(), 'every weekday');
      expect(Recurrence.tryParse('every mon, thu').toString(), 'every mon, thu');
      expect(Recurrence.tryParse('cada 3 días').toString(), 'every 3 days');
      expect(Recurrence.tryParse('cada lunes').toString(), 'every mon');
      expect(Recurrence.tryParse('monthly').toString(), 'every month');
      expect(Recurrence.tryParse('every banana'), isNull);
    });

    test('next occurrences', () {
      final fri = DateTime(2026, 10, 16);
      expect(Recurrence.tryParse('every weekday')!.next(fri), DateTime(2026, 10, 19));
      expect(Recurrence.tryParse('every mon, thu')!.next(DateTime(2026, 10, 19)),
          DateTime(2026, 10, 22));
      expect(Recurrence.tryParse('every month')!.next(DateTime(2026, 1, 31)),
          DateTime(2026, 2, 28));
      expect(Recurrence.tryParse('every 2 weeks')!.next(fri), DateTime(2026, 10, 30));
    });
  });

  group('Quick add', () {
    test('full Todoist-style line', () {
      final q = qa('Send invoice tomorrow 5pm p1 #Finance /Billing @email +Ana',
          projects: ['Finance'], members: ['Ana Gómez']);
      expect(q.title, 'Send invoice');
      expect(q.due.toString(), '2026-10-18T17:00');
      expect(q.priority, 1);
      expect(q.project, 'Finance');
      expect(q.section, 'Billing');
      expect(q.labels, ['email']);
      expect(q.assignee, 'Ana');
    });

    test('multi-word project and member names', () {
      final q = qa('Fix login #Mobile App +Ana Gómez',
          projects: ['Mobile App', 'Mobile'], members: ['Ana Gómez']);
      expect(q.title, 'Fix login');
      expect(q.project, 'Mobile App');
      expect(q.assignee, 'Ana Gómez');
    });

    test('dates', () {
      expect(qa('a today').due.toString(), '2026-10-17');
      expect(qa('a next week').due.toString(), '2026-10-19');
      expect(qa('a monday').due.toString(), '2026-10-19');
      expect(qa('a on fri').due.toString(), '2026-10-23');
      expect(qa('a in 3 days').due.toString(), '2026-10-20');
      expect(qa('a oct 20').due.toString(), '2026-10-20');
      expect(qa('a 5/1').due.toString(), '2027-01-05');
      expect(qa('a 2026-12-24').due.toString(), '2026-12-24');
      expect(qa('a 20 de noviembre').due.toString(), '2026-11-20');
      expect(qa('a mañana a las 9').due.toString(), '2026-10-18T09:00');
    });

    test('bare time today or tomorrow', () {
      expect(qa('standup 9:30am').due.toString(), '2026-10-18T09:30');
      expect(qa('review 3pm').due.toString(), '2026-10-17T15:00');
    });

    test('recurrence sets first date', () {
      final q = qa('Weekly report every friday at 4pm');
      expect(q.title, 'Weekly report');
      expect(q.recur.toString(), 'every fri');
      expect(q.due.toString(), '2026-10-23T16:00');
      expect(qa('water plants every day').due.toString(), '2026-10-17');
      expect(qa('report weekly').recur.toString(), 'every week');
    });

    test('ordinary words are left alone', () {
      expect(qa('Buy a sun hat for wed party').title, 'Buy a sun hat for wed party');
      expect(qa('Fix 3 bugs').title, 'Fix 3 bugs');
      expect(qa('Fix 3 bugs').due, isNull);
    });
  });

  group('Repo', () {
    late Repo repo;
    setUp(() => repo = Repo(Store.open(':memory:'), now: () => now));

    test('quick add resolves project, labels, assignee', () {
      final p = repo.addProject('Sales');
      final ana = repo.addMember('Ana');
      final id = repo.quickAdd('Call lead today p2 #Sales @phone +ana')!;
      final t = repo.task(id)!;
      expect(t.projectId, p);
      expect(t.assignee, ana);
      expect(t.priority, 2);
      expect(repo.label(t.labels.single)!.name, 'phone');
      expect(repo.today().map((t) => t.id), [id]);
    });

    test('unknown project stays in the title', () {
      final id = repo.quickAdd('Thing #Nope')!;
      expect(repo.task(id)!.title, 'Thing #Nope');
      expect(repo.task(id)!.projectId, isNull);
    });

    test('completing a recurring task rolls it forward', () {
      final id = repo.quickAdd('Backup every weekday 18:00')!;
      final sub = repo.addTask(title: 'check logs', parentId: id);
      repo.complete(sub);
      repo.complete(id);
      final t = repo.task(id)!;
      expect(t.done, isFalse);
      // First due Mon 19th (created on a Saturday), so next is Tue 20th.
      expect(t.due.toString(), '2026-10-20T18:00');
      expect(repo.task(sub)!.done, isFalse);
    });

    test('completing a parent completes subtasks', () {
      final id = repo.addTask(title: 'parent');
      final sub = repo.addTask(title: 'child', parentId: id);
      repo.complete(id);
      expect(repo.task(sub)!.done, isTrue);
      expect(repo.completed().length, 2);
    });

    test('deleting a project removes its tasks from views', () {
      final p = repo.addProject('Temp');
      repo.addTask(title: 'x', projectId: p, due: Due(now));
      expect(repo.today(), hasLength(1));
      repo.deleteProject(p);
      expect(repo.today(), isEmpty);
      expect(repo.projects, isEmpty);
    });

    test('reorder writes a fractional order between neighbours', () {
      final ids = [for (final n in ['a', 'b', 'c']) repo.addTask(title: n)];
      repo.reorder(repo.inbox(), 2, 0, 'tasks');
      expect(repo.inbox().map((t) => t.title), ['c', 'a', 'b']);
      repo.reorder(repo.inbox(), 0, 1, 'tasks');
      expect(repo.inbox().map((t) => t.title), ['a', 'c', 'b']);
      expect(ids, hasLength(3));
    });
  });
}
