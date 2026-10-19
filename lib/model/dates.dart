/// A due date with an optional time of day. Serialized as `yyyy-MM-dd` or
/// `yyyy-MM-ddTHH:mm` (local time), which also sorts correctly as a string.
class Due implements Comparable<Due> {
  final DateTime date; // midnight, local
  final int? minutes; // minutes since midnight

  Due(DateTime d, [this.minutes]) : date = DateTime(d.year, d.month, d.day);

  bool get hasTime => minutes != null;

  DateTime get moment =>
      minutes == null ? date : date.add(Duration(minutes: minutes!));

  static Due? tryParse(Object? s) {
    if (s is! String || s.isEmpty) return null;
    final d = DateTime.tryParse(s.length == 10 ? s : s.substring(0, 10));
    if (d == null) return null;
    if (s.length >= 16) {
      final h = int.parse(s.substring(11, 13)), m = int.parse(s.substring(14, 16));
      return Due(d, h * 60 + m);
    }
    return Due(d);
  }

  @override
  String toString() {
    String two(int n) => n.toString().padLeft(2, '0');
    final ds = '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-${two(date.day)}';
    if (minutes == null) return ds;
    return '${ds}T${two(minutes! ~/ 60)}:${two(minutes! % 60)}';
  }

  Due withDate(DateTime d) => Due(d, minutes);

  @override
  int compareTo(Due other) => toString().compareTo(other.toString());

  @override
  bool operator ==(Object other) => other is Due && other.toString() == toString();

  @override
  int get hashCode => toString().hashCode;
}

DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

/// Adds months, clamping the day (Jan 31 + 1 month = Feb 28/29).
DateTime addMonths(DateTime d, int n) {
  final first = DateTime(d.year, d.month + n, 1);
  final lastDay = DateTime(first.year, first.month + 1, 0).day;
  return DateTime(first.year, first.month, d.day > lastDay ? lastDay : d.day);
}

const weekdayNames = {
  'monday': 1, 'mon': 1, 'lunes': 1, 'lun': 1,
  'tuesday': 2, 'tue': 2, 'tues': 2, 'martes': 2, 'mar': 2,
  'wednesday': 3, 'wed': 3, 'miercoles': 3, 'miércoles': 3, 'mie': 3, 'mié': 3,
  'thursday': 4, 'thu': 4, 'thur': 4, 'thurs': 4, 'jueves': 4, 'jue': 4,
  'friday': 5, 'fri': 5, 'viernes': 5, 'vie': 5,
  'saturday': 6, 'sat': 6, 'sabado': 6, 'sábado': 6, 'sab': 6, 'sáb': 6,
  'sunday': 7, 'sun': 7, 'domingo': 7, 'dom': 7,
};

const monthNames = {
  'january': 1, 'jan': 1, 'enero': 1, 'ene': 1,
  'february': 2, 'feb': 2, 'febrero': 2,
  'march': 3, 'marzo': 3,
  'april': 4, 'apr': 4, 'abril': 4, 'abr': 4,
  'may': 5, 'mayo': 5,
  'june': 6, 'jun': 6, 'junio': 6,
  'july': 7, 'jul': 7, 'julio': 7,
  'august': 8, 'aug': 8, 'agosto': 8, 'ago': 8,
  'september': 9, 'sep': 9, 'sept': 9, 'septiembre': 9,
  'october': 10, 'oct': 10, 'octubre': 10,
  'november': 11, 'nov': 11, 'noviembre': 11,
  'december': 12, 'dec': 12, 'diciembre': 12, 'dic': 12,
};

/// Next date strictly after [from] that falls on [weekday] (1 = Monday).
DateTime nextWeekday(DateTime from, int weekday) {
  var delta = (weekday - from.weekday) % 7;
  if (delta == 0) delta = 7;
  return addDays(from, delta);
}

enum RecurUnit { day, week, month, year }

/// Repeat rule. Text forms (English or Spanish):
/// `every day`, `every 3 days`, `every week`, `every 2 weeks`, `every month`,
/// `every year`, `every weekday`, `every mon, thu`, `daily`, `weekly`,
/// `monthly`, `yearly`, `cada día`, `cada 2 semanas`, `cada lunes`, …
class Recurrence {
  final RecurUnit unit;
  final int interval;
  final Set<int> weekdays; // only for week-based rules; empty = same weekday

  const Recurrence(this.unit, [this.interval = 1, this.weekdays = const {}]);

  static const _unitWords = {
    'day': RecurUnit.day, 'days': RecurUnit.day, 'dia': RecurUnit.day,
    'día': RecurUnit.day, 'dias': RecurUnit.day, 'días': RecurUnit.day,
    'week': RecurUnit.week, 'weeks': RecurUnit.week, 'semana': RecurUnit.week,
    'semanas': RecurUnit.week,
    'month': RecurUnit.month, 'months': RecurUnit.month, 'mes': RecurUnit.month,
    'meses': RecurUnit.month,
    'year': RecurUnit.year, 'years': RecurUnit.year, 'año': RecurUnit.year,
    'años': RecurUnit.year,
  };

  static const _shorthand = {
    'daily': Recurrence(RecurUnit.day),
    'diario': Recurrence(RecurUnit.day),
    'weekly': Recurrence(RecurUnit.week),
    'semanal': Recurrence(RecurUnit.week),
    'monthly': Recurrence(RecurUnit.month),
    'mensual': Recurrence(RecurUnit.month),
    'yearly': Recurrence(RecurUnit.year),
    'annually': Recurrence(RecurUnit.year),
    'anual': Recurrence(RecurUnit.year),
  };

  static bool isLead(String w) =>
      w == 'every' || w == 'cada' || _shorthand.containsKey(w);

  /// Parses as many of [words] (lowercase) as form a rule. Returns the rule
  /// and how many words were used, or null.
  static (Recurrence, int)? parseWords(List<String> words) {
    if (words.isEmpty) return null;
    final w0 = words[0];
    if (_shorthand.containsKey(w0)) return (_shorthand[w0]!, 1);
    if (w0 != 'every' && w0 != 'cada') return null;
    var i = 1;
    if (i >= words.length) return null;

    if (words[i] == 'weekday' || words[i] == 'workday' ||
        (words[i] == 'día' || words[i] == 'dia') &&
            i + 1 < words.length && words[i + 1] == 'hábil') {
      final used = words[i] == 'weekday' || words[i] == 'workday' ? 2 : 3;
      return (const Recurrence(RecurUnit.week, 1, {1, 2, 3, 4, 5}), used);
    }

    final days = <int>{};
    var j = i;
    while (j < words.length) {
      final w = words[j].replaceAll(',', '');
      if (weekdayNames.containsKey(w)) {
        days.add(weekdayNames[w]!);
        j++;
      } else if ((w == 'and' || w == 'y' || w.isEmpty) && days.isNotEmpty &&
          j + 1 < words.length &&
          weekdayNames.containsKey(words[j + 1].replaceAll(',', ''))) {
        j++;
      } else {
        break;
      }
    }
    if (days.isNotEmpty) return (Recurrence(RecurUnit.week, 1, days), j);

    var interval = 1;
    final n = int.tryParse(words[i]);
    if (n != null && n > 0) {
      interval = n;
      i++;
    } else if (words[i] == 'other') {
      interval = 2;
      i++;
    }
    if (i < words.length && _unitWords.containsKey(words[i])) {
      return (Recurrence(_unitWords[words[i]]!, interval), i + 1);
    }
    return null;
  }

  static Recurrence? tryParse(Object? s) {
    if (s is! String || s.trim().isEmpty) return null;
    final words = s.toLowerCase().trim().split(RegExp(r'[\s,]+'));
    final r = parseWords(words);
    return r != null && r.$2 == words.length ? r.$1 : null;
  }

  /// The next occurrence strictly after [from].
  DateTime next(DateTime from) {
    from = dayOf(from);
    switch (unit) {
      case RecurUnit.day:
        return addDays(from, interval);
      case RecurUnit.month:
        return addMonths(from, interval);
      case RecurUnit.year:
        return addMonths(from, 12 * interval);
      case RecurUnit.week:
        if (weekdays.isEmpty) return addDays(from, 7 * interval);
        for (var d = 1; d <= 7; d++) {
          final c = addDays(from, d);
          if (weekdays.contains(c.weekday)) return c;
        }
        return addDays(from, 7);
    }
  }

  /// First occurrence on or after [today] (used when a rule is set without
  /// an explicit date).
  DateTime first(DateTime today) {
    today = dayOf(today);
    if (unit == RecurUnit.week && weekdays.isNotEmpty &&
        !weekdays.contains(today.weekday)) {
      return next(today);
    }
    return today;
  }

  @override
  String toString() {
    const names = ['', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    if (unit == RecurUnit.week && weekdays.isNotEmpty) {
      if (weekdays.length == 5 && !weekdays.contains(6) && !weekdays.contains(7)) {
        return 'every weekday';
      }
      return 'every ${(weekdays.toList()..sort()).map((d) => names[d]).join(', ')}';
    }
    final u = unit.name;
    return interval == 1 ? 'every $u' : 'every $interval ${u}s';
  }
}
