import 'dart:async';

import '../core/hlc.dart';
import '../core/store.dart';
import '../model/repo.dart';
import '../model/reminders.dart';
import 'notifier.dart';

/// Keeps reminders scheduled, scores missed deadlines, applies actions taken
/// on notifications and announces team activity that arrives by sync.
class ReminderService {
  final Repo repo;
  final Notifier notifier;

  /// Rewards earned / punishments due, for the app to pop up.
  final _incentives = StreamController<LedgerEntry>.broadcast();
  Stream<LedgerEntry> get incentives => _incentives.stream;

  /// Tasks to open (from a notification).
  final _open = StreamController<String>.broadcast();
  Stream<String> get openTask => _open.stream;

  Stream<Reminder> get alarms => notifier.alarms;

  final _subs = <StreamSubscription>[];
  Timer? _tick, _debounce;

  ReminderService(this.repo, this.notifier);

  Future<void> start() async {
    await notifier.init();
    _subs.add(repo.store.changes.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 1), refresh);
    }));
    _subs.add(repo.store.remoteChanges.listen(_announce));
    _subs.add(notifier.opened.listen(_open.add));
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => refresh());
    await resume();
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _tick?.cancel();
    _debounce?.cancel();
  }

  /// Call when the app comes to the foreground.
  Future<void> resume() async {
    for (final a in await notifier.takeActions()) {
      if (a.type == 'complete' && repo.task(a.taskId) != null) {
        repo.complete(a.taskId, at: a.at);
      }
    }
    final launch = await notifier.takeLaunchTask();
    if (launch != null) _open.add(launch);
    await refresh();
  }

  Future<void> refresh() async {
    for (final e in repo.evaluate()) {
      _incentives.add(e);
      if (e.kind == 'punishment') {
        await notifier.show(Reminder.stableId('pun|${e.id}'), '⚖️ Punishment due', e.title,
            taskId: e.taskId);
      } else if (e.kind == 'penalty') {
        await notifier.show(Reminder.stableId('pen|${e.id}'), 'Missed: ${e.title}',
            '${e.points} points', taskId: e.taskId);
      }
    }
    await notifier.schedule(upcomingReminders(repo));
  }

  /// Notifications for things teammates did to *my* work. Only recent
  /// changes, so a device catching up on weeks of history stays quiet.
  void _announce(List<Cell> cells) {
    final me = repo.meId;
    if (me == null) return;
    final myNode = repo.store.nodeId;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 15)).millisecondsSinceEpoch;
    for (final c in cells) {
      final h = Hlc.parse(c.hlc);
      if (h.node == myNode || h.millis < cutoff) continue;
      if (c.table == 'tasks' && c.field == 'assignee' && c.value == me) {
        final t = repo.task(c.id);
        if (t == null || t.createdBy == me) continue;
        final by = repo.member(t.createdBy)?.name ?? 'Someone';
        notifier.show(Reminder.stableId('asg|${c.id}'), '$by assigned you a task', t.title,
            taskId: t.id);
      } else if (c.table == 'comments' && c.field == 'text') {
        final row = repo.store.row('comments', c.id);
        final taskId = row?['taskId'] as String?;
        final t = taskId == null ? null : repo.task(taskId);
        final author = row?['author'] as String?;
        if (t == null || author == me || !(t.countsFor(me) || t.createdBy == me)) continue;
        final text = repo.comments(t.id).where((x) => x.id == c.id).firstOrNull?.text ?? '';
        notifier.show(Reminder.stableId('cmt|${c.id}'),
            '${repo.member(author)?.name ?? 'Someone'} on “${t.title}”', text, taskId: t.id);
      } else if (c.table == 'docs' && c.field == 'createdBy') {
        // createdBy is written once, so this fires for new documents only.
        final d = repo.doc(c.id);
        if (d == null || c.value == me) continue;
        notifier.show(Reminder.stableId('doc|${c.id}'), '📄 ${d.title}',
            'New document from ${repo.member(d.updatedBy)?.name ?? 'a teammate'}');
      }
    }
  }
}
