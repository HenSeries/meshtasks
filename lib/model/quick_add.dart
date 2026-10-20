import 'dates.dart';
import 'reminders.dart';

/// Result of parsing a Todoist-style quick-add line, e.g.
/// `Send invoice tomorrow 5pm p1 #Finance /Billing @email +Ana every month`.
/// `!private` (or `!privada`) makes the task visible only to its creator,
/// `!alarm` (`!alarma`) makes its reminders ring like an alarm, and
/// `!30m` / `!2h` / `!1d` adds a reminder that long before it is due.
class QuickAdd {
  String title = '';
  Due? due;
  Recurrence? recur;
  int? priority; // 1 (urgent) .. 4 (none)
  String? project;
  String? section;
  final List<String> labels = [];
  String? assignee;
  bool private = false;
  bool alarm = false;

  /// Minutes before the due time (from `!30m`, `!2h`, `!1d`, `!0`).
  final List<int> reminders = [];
}

/// Parses quick-add text. [projects] and [members] are known names, used so
/// that multi-word names (`#Mobile App`, `+Ana María`) match whole.
QuickAdd parseQuickAdd(String input,
    {required DateTime now,
    List<String> projects = const [],
    List<String> members = const []}) {
  final out = QuickAdd();
  final raw = input.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final lower = raw.map((w) => w.toLowerCase()).toList();
  final titleWords = <String>[];
  final today = dayOf(now);
  DateTime? date;
  int? minutes;

  // Matches a known multi-word name starting at raw[i] (after a sigil).
  int matchName(int i, String first, List<String> names, void Function(String) set) {
    final sorted = [...names]..sort((a, b) => b.length.compareTo(a.length));
    for (final n in sorted) {
      final parts = n.toLowerCase().split(RegExp(r'\s+'));
      if (i + parts.length > raw.length) continue;
      final cand = [first.toLowerCase(), ...lower.sublist(i + 1, i + parts.length)];
      if (cand.join(' ') == parts.join(' ')) {
        set(n);
        return parts.length;
      }
    }
    set(first.replaceAll('_', ' '));
    return 1;
  }

  (int, int)? parseTime(String w, {bool allowBare = false}) {
    final m = RegExp(r'^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?$').firstMatch(w);
    if (m == null) return null;
    var h = int.parse(m.group(1)!);
    final mm = int.parse(m.group(2) ?? '0');
    final ampm = m.group(3);
    // A bare number is only a time after "at" / "a las" (24h clock).
    if (ampm == null && m.group(2) == null && !allowBare) return null;
    if (ampm != null && ampm.startsWith('p') && h < 12) h += 12;
    if (ampm != null && ampm.startsWith('a') && h == 12) h = 0;
    if (h > 23 || mm > 59) return null;
    return (h * 60 + mm, 1);
  }

  /// Tries to read a date at position i. Returns (date, words used).
  (DateTime, int)? parseDate(int i) {
    final w = lower[i];
    final next = i + 1 < lower.length ? lower[i + 1] : null;
    final next2 = i + 2 < lower.length ? lower[i + 2] : null;
    switch (w) {
      case 'today' || 'tod' || 'hoy':
        return (today, 1);
      case 'tomorrow' || 'tmr' || 'tom' || 'mañana' || 'manana':
        return (addDays(today, 1), 1);
      case 'pasado' when next == 'mañana' || next == 'manana':
        return (addDays(today, 2), 2);
    }
    if ((w == 'next' || w == 'próxima' || w == 'proxima') &&
        (next == 'week' || next == 'semana')) {
      return (nextWeekday(today, 1), 2);
    }
    if ((w == 'next' || w == 'próximo' || w == 'proximo') &&
        (next == 'month' || next == 'mes')) {
      return (DateTime(today.year, today.month + 1, 1), 2);
    }
    // "in 3 days" / "en 2 semanas"
    if ((w == 'in' || w == 'en') && next != null && next2 != null) {
      final n = int.tryParse(next);
      if (n != null) {
        switch (next2) {
          case 'day' || 'days' || 'día' || 'días' || 'dia' || 'dias':
            return (addDays(today, n), 3);
          case 'week' || 'weeks' || 'semana' || 'semanas':
            return (addDays(today, 7 * n), 3);
          case 'month' || 'months' || 'mes' || 'meses':
            return (addMonths(today, n), 3);
        }
      }
    }
    // "monday", "next fri", "on tue", "el lunes", "este viernes"
    final lead = {'next', 'on', 'el', 'este', 'próximo', 'proximo', 'this'};
    if (lead.contains(w) && next != null && weekdayNames.containsKey(next)) {
      return (nextWeekday(today, weekdayNames[next]!), 2);
    }
    // Bare abbreviations ("sat", "wed", "mar") are ordinary words too, so
    // standalone only full names count; "on sat" works via the lead above.
    if (weekdayNames.containsKey(w) && (w.endsWith('day') || w.length >= 5)) {
      return (nextWeekday(today, weekdayNames[w]!), 1);
    }
    // ISO 2026-10-20
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(w);
    if (iso != null) {
      return (DateTime(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!)), 1);
    }
    // 20/10 or 20/10/2026 (day first)
    final dm = RegExp(r'^(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?$').firstMatch(w);
    if (dm != null) {
      final d = int.parse(dm[1]!), m = int.parse(dm[2]!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        var y = dm[3] == null ? today.year : int.parse(dm[3]!);
        if (y < 100) y += 2000;
        var dt = DateTime(y, m, d);
        if (dm[3] == null && dt.isBefore(today)) dt = DateTime(y + 1, m, d);
        return (dt, 1);
      }
    }
    // "oct 20" / "20 oct" / "20 de octubre"
    DateTime monthDay(int m, int d) {
      var dt = DateTime(today.year, m, d);
      if (dt.isBefore(today)) dt = DateTime(today.year + 1, m, d);
      return dt;
    }

    final dayNum = int.tryParse(w.replaceAll(RegExp(r'(st|nd|rd|th)$'), ''));
    if (monthNames.containsKey(w) && next != null) {
      final d = int.tryParse(next.replaceAll(RegExp(r'(st|nd|rd|th|,)$'), ''));
      if (d != null && d >= 1 && d <= 31) return (monthDay(monthNames[w]!, d), 2);
    }
    if (dayNum != null && dayNum >= 1 && dayNum <= 31 && next != null) {
      if (monthNames.containsKey(next)) return (monthDay(monthNames[next]!, dayNum), 2);
      if (next == 'de' && next2 != null && monthNames.containsKey(next2)) {
        return (monthDay(monthNames[next2]!, dayNum), 3);
      }
    }
    return null;
  }

  var i = 0;
  while (i < raw.length) {
    final w = raw[i], l = lower[i];

    if (l == '!private' || l == '!privada' || l == '!privado') {
      out.private = true;
      i++;
      continue;
    }
    if (l == '!alarm' || l == '!alarma') {
      out.alarm = true;
      i++;
      continue;
    }
    final before = parseReminderToken(l);
    if (before != null) {
      out.reminders.add(before);
      i++;
      continue;
    }

    // priority
    final p = RegExp(r'^p([1-4])$').firstMatch(l);
    if (p != null) {
      out.priority = int.parse(p[1]!);
      i++;
      continue;
    }
    if (w.length > 1 && w.startsWith('#')) {
      i += matchName(i, w.substring(1), projects, (n) => out.project = n);
      continue;
    }
    if (w.length > 1 && w.startsWith('/')) {
      out.section = w.substring(1).replaceAll('_', ' ');
      i++;
      continue;
    }
    if (w.length > 1 && w.startsWith('@')) {
      out.labels.add(w.substring(1));
      i++;
      continue;
    }
    if (w.length > 1 && w.startsWith('+')) {
      i += matchName(i, w.substring(1), members, (n) => out.assignee = n);
      continue;
    }

    // recurrence
    // Shorthands like "weekly" only count after the first word, so
    // "Weekly report" stays a title.
    if (Recurrence.isLead(l) && (i > 0 || l == 'every' || l == 'cada')) {
      final r = Recurrence.parseWords(lower.sublist(i));
      if (r != null) {
        out.recur = r.$1;
        i += r.$2;
        continue;
      }
    }

    // time: "5pm", "17:00", "at 5pm", "a las 5pm"
    var skip = 0;
    if ((l == 'at' || l == '@') && i + 1 < raw.length) skip = 1;
    if (l == 'a' && i + 2 < raw.length && lower[i + 1] == 'las') skip = 2;
    final t = i + skip < raw.length
        ? parseTime(lower[i + skip], allowBare: skip > 0)
        : null;
    if (t != null) {
      minutes = t.$1;
      i += skip + 1;
      continue;
    }

    final d = parseDate(i);
    if (d != null && date == null) {
      date = d.$1;
      i += d.$2;
      continue;
    }

    titleWords.add(w);
    i++;
  }

  out.title = titleWords.join(' ');
  if (date == null && out.recur != null) date = out.recur!.first(today);
  if (date == null && minutes != null) {
    // A bare time means today, or tomorrow if it already passed.
    final nowMin = now.hour * 60 + now.minute;
    date = minutes > nowMin ? today : addDays(today, 1);
  }
  if (date != null) out.due = Due(date, minutes);
  return out;
}
