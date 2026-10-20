import 'repo.dart';

/// One scheduled reminder for this device's user.
class Reminder {
  /// Stable 31-bit id (Android alarms and notifications need ints).
  final int id;
  final String taskId;
  final DateTime at;
  final String title;
  final String body;
  final bool alarm;

  const Reminder(this.id, this.taskId, this.at, this.title, this.body, this.alarm);

  Map<String, Object?> toJson() => {
        'id': id,
        'taskId': taskId,
        'at': at.millisecondsSinceEpoch,
        'title': title,
        'body': body,
        'alarm': alarm,
      };

  static int stableId(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }
}

/// Reminders that should fire on this device within [horizon]: only for
/// tasks that are this user's responsibility, so a busy team doesn't buzz
/// everyone's phone.
///
/// Timed tasks remind at the due time unless they say otherwise. All-day
/// tasks only remind if they have explicit reminders, counted back from
/// [allDayAt] minutes past midnight (09:00 by default).
List<Reminder> upcomingReminders(Repo repo,
    {Duration horizon = const Duration(days: 7), int allDayAt = 9 * 60, int limit = 64}) {
  final me = repo.meId;
  final now = repo.now();
  final end = now.add(horizon);
  final out = <Reminder>[];
  for (final t in repo.open) {
    final due = t.due;
    if (due == null || !t.countsFor(me)) continue;
    final offsets = t.reminders ?? (due.hasTime ? const [0] : const <int>[]);
    final base = due.hasTime ? due.moment : due.date.add(Duration(minutes: allDayAt));
    final project = repo.project(t.projectId)?.name;
    for (final before in offsets.toSet()) {
      final at = base.subtract(Duration(minutes: before));
      if (!at.isAfter(now) || at.isAfter(end)) continue;
      final when = due.hasTime
          ? '${due.minutes! ~/ 60}:${(due.minutes! % 60).toString().padLeft(2, '0')}'
          : 'today';
      out.add(Reminder(
        Reminder.stableId('${t.id}|${at.millisecondsSinceEpoch}'),
        t.id,
        at,
        t.title,
        [
          before == 0 ? 'Due now' : 'Due ${_inWords(before)} ($when)',
          ?project,
          if (t.punishment.isNotEmpty) 'Miss it: ${t.punishment}',
        ].join(' · '),
        t.alarm,
      ));
    }
  }
  out.sort((a, b) => a.at.compareTo(b.at));
  return out.take(limit).toList();
}

String _inWords(int minutes) {
  if (minutes % 1440 == 0) return 'in ${minutes ~/ 1440} d';
  if (minutes % 60 == 0) return 'in ${minutes ~/ 60} h';
  return 'in $minutes min';
}

/// "!30m" → 30, "!2h" → 120, "!1d" → 1440, "!0" → 0 (at the due time).
int? parseReminderToken(String token) {
  final m = RegExp(r'^!(\d{1,4})\s*(m|min|h|d)?$', caseSensitive: false).firstMatch(token);
  if (m == null) return null;
  final n = int.parse(m[1]!);
  return switch (m[2]?.toLowerCase()) {
    'h' => n * 60,
    'd' => n * 1440,
    _ => n,
  };
}

/// Label for a reminder offset, e.g. "30 min before", "At due time".
String reminderLabel(int before) {
  if (before == 0) return 'At due time';
  if (before % 1440 == 0) return '${before ~/ 1440} day${before == 1440 ? '' : 's'} before';
  if (before % 60 == 0) return '${before ~/ 60} h before';
  return '$before min before';
}
