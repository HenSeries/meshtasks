/// Turns dictated Spanish or English into quick-add syntax, e.g.
///   "Llamar a Ana mañana a las tres de la tarde prioridad uno en el proyecto Ventas"
///   → "Llamar a Ana mañana a las 15:00 p1 #Ventas"
///   "Send the report next friday at 5 p.m. assign to Luis label finance"
///   → "Send the report next friday at 17:00 +Luis @finance"
/// Known [projects] and [members] let multi-word names match whole.
String spokenToQuickAdd(String spoken,
    {List<String> projects = const [], List<String> members = const []}) {
  var s = ' ${spoken.trim().replaceAll(RegExp(r'[,;]'), ' ').replaceAll(RegExp(r'[.!?¡¿]+$'), '')} ';
  s = s.replaceAll(RegExp(r'\s+'), ' ');

  RegExp re(String p) => RegExp(p, caseSensitive: false, unicode: true);
  String sub(String src, String pattern, String Function(Match m) f) =>
      src.replaceAllMapped(re(pattern), f);

  // Number words after words that take a number ("a las tres", "in two days").
  const numbers = {
    'una': 1, 'uno': 1, 'un': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5,
    'seis': 6, 'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, 'once': 11,
    'doce': 12, 'quince': 15, 'veinte': 20, 'treinta': 30,
    'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6,
    'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12,
    'fifteen': 15, 'twenty': 20, 'thirty': 30,
  };
  final numAlt = numbers.keys.join('|');
  s = sub(s, r'\b(a las|a la|at|prioridad|priority|en|in|dentro de|cada|every)\s+(' + numAlt + r')\b',
      (m) => '${m[1]} ${numbers[m[2]!.toLowerCase()]}');

  // Noon / midnight.
  s = sub(s, r'\b(al mediod[ií]a|a mediod[ií]a|at noon)\b', (_) => 'a las 12:00');
  s = sub(s, r'\b(a medianoche|at midnight)\b', (_) => 'a las 0:00');

  String hhmm(int h, int m) => '$h:${m.toString().padLeft(2, '0')}';
  int adjust(int h, String? when) {
    if (when == null) return h;
    final w = when.toLowerCase().replaceAll(RegExp(r'[\s.]'), '');
    final pm = w.startsWith('p') || w.contains('tarde') || w.contains('noche');
    final am = w.startsWith('a') || w.contains('mañana') || w.contains('manana') || w.contains('madrugada');
    if (pm && h < 12) return h + 12;
    if (am && h == 12) return 0;
    return h;
  }

  const ampm = r'(de la mañana|de la manana|de la madrugada|de la tarde|de la noche|[ap]\.?\s?m\.?|o.clock)';
  // "a las 3 y media de la tarde", "at 5:30 p.m."
  s = sub(s, r'\b(a las?|at)\s+(\d{1,2})(?::(\d{2}))?(\s+y\s+(media|cuarto)|\s+menos\s+cuarto)?(?:\s*' + ampm + r')?(?=\s|$)',
      (m) {
    var h = int.parse(m[2]!);
    var min = int.parse(m[3] ?? '0');
    final frac = m[4]?.toLowerCase() ?? '';
    if (frac.contains('media')) min = 30;
    if (frac.contains('y cuarto')) min = 15;
    if (frac.contains('menos')) {
      h -= 1;
      min = 45;
    }
    final w = m[6];
    h = w != null && w.toLowerCase().contains('clock') ? h : adjust(h, w);
    return m[1]!.toLowerCase().startsWith('a') ? 'a las ${hhmm(h, min)}' : 'at ${hhmm(h, min)}';
  });
  // Bare "3 p. m." / "10:30 am"
  s = sub(s, r'\b(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s?m\.?(?=\s|$)',
      (m) => hhmm(adjust(int.parse(m[1]!), '${m[3]}m'), int.parse(m[2] ?? '0')));

  // Priority.
  s = sub(s, r'\b(?:con |with )?(?:la |a )?(?:prioridad|priority)\s+(1|alta|urgente|m[aá]xima|high|urgent|top)\b', (_) => 'p1');
  s = sub(s, r'\b(?:con |with )?(?:la |a )?(?:prioridad|priority)\s+(2|media|medium)\b', (_) => 'p2');
  s = sub(s, r'\b(?:con |with )?(?:la |a )?(?:prioridad|priority)\s+(3|baja|low)\b', (_) => 'p3');
  s = sub(s, r'\b(?:con |with )?(?:la |a )?(?:prioridad|priority)\s+(4|ninguna|normal|none)\b', (_) => 'p4');

  // Private.
  s = sub(s, r'\b(?:como tarea privada|como privada|tarea privada|en privado|solo para m[ií]|es privada'
      r'|as a private task|as private|private task|make it private|only for me|just for me)\b', (_) => '!privada');
  s = sub(s, r'\s(privada|privado|private)\s*$', (_) => ' !privada');

  // Alarm and reminders: "con alarma", "recuérdame 30 minutos antes",
  // "remind me an hour before".
  s = sub(s, r'\b(?:con (?:una )?alarma|como alarma|que suene|with an alarm|with alarm|as an alarm)\b', (_) => '!alarma');
  s = sub(
      s,
      r'\b(?:y )?(?:recu[eé]rdame|av[ií]same|recordarme|notif[ií]came|remind me|notify me|alert me)\s+'
      r'(\d+|un|una|uno|one|an|a)\s+(minutos?|min|horas?|d[ií]as?|minutes?|hours?|days?)\s+(?:antes|before)\b', (m) {
    final n = int.tryParse(m[1]!) ?? 1;
    final unit = m[2]!.toLowerCase();
    final suffix = unit.startsWith('h') ? 'h' : unit.startsWith('d') ? 'd' : 'm';
    return '!$n$suffix';
  });

  // Names: match known ones whole (accent-insensitive), else one word.
  String fold(String x) => x
      .toLowerCase()
      .replaceAll(RegExp('[áà]'), 'a')
      .replaceAll(RegExp('[éè]'), 'e')
      .replaceAll(RegExp('[íì]'), 'i')
      .replaceAll(RegExp('[óò]'), 'o')
      .replaceAll(RegExp('[úùü]'), 'u')
      .replaceAll('ñ', 'n');

  String withName(String src, String lead, String sigil, List<String> known, {bool firstNames = false}) {
    final m = re(lead + r'\s+(\S+(?:\s+\S+){0,3})').firstMatch(src);
    if (m == null) return src;
    final rest = m[1]!;
    final restWords = rest.split(' ');
    final sorted = [...known]..sort((a, b) => b.length.compareTo(a.length));
    String? name;
    var used = 1;
    for (final k in sorted) {
      final kw = k.split(RegExp(r'\s+'));
      if (kw.length <= restWords.length &&
          fold(restWords.take(kw.length).join(' ')) == fold(k)) {
        name = k;
        used = kw.length;
        break;
      }
    }
    if (name == null && firstNames) {
      for (final k in sorted) {
        if (fold(k.split(' ').first) == fold(restWords.first)) {
          name = k;
          break;
        }
      }
    }
    name ??= restWords.first;
    final consumed = restWords.take(used).join(' ');
    final tag = sigil + name;
    return src.replaceFirst(m[0]!, ' $tag${rest.substring(consumed.length)}');
  }

  s = withName(s, r'\b(?:asign[aá]rselo|asignarl[ao]|asignarle|asignar|asignad[ao]|assigned|assign it|assign)\s+(?:a|to)', '+', members,
      firstNames: true);
  s = withName(s, r'\b(?:en el |en |al |para el |del |in the |in |to the |to |for the |for )?(?:proyecto|project)', '#', projects);
  s = withName(s, r'\b(?:en la |en |in the |in )?(?:secci[oó]n|section)', '/', const []);
  s = withName(s, r'\b(?:con |with )?(?:la |the )?(?:etiqueta|label|tag)', '@', const []);

  // Dates and repeats phrased the way people say them.
  s = sub(s, r'\bdentro de (\d+)', (m) => 'en ${m[1]}');
  s = sub(s, r'\b(la pr[oó]xima semana|la semana que viene|la otra semana)\b', (_) => 'próxima semana');
  s = sub(s, r'\b(el pr[oó]ximo mes|el mes que viene)\b', (_) => 'próximo mes');
  s = sub(s, r'\bthe day after tomorrow\b', (_) => 'in 2 days');
  s = sub(s, r'\b(este fin de semana)\b', (_) => 'sábado');
  s = sub(s, r'\b(this weekend)\b', (_) => 'saturday');
  s = sub(s, r'\b(?:todos los d[ií]as h[aá]biles|d[ií]as laborales|entre semana|de lunes a viernes|every weekday|on weekdays)\b',
      (_) => 'every weekday');
  s = sub(s, r'\b(todos los d[ií]as|diariamente|each day|every single day)\b', (_) => 'cada día');
  s = sub(s, r'\btodos los (lunes|martes|mi[eé]rcoles|jueves|viernes|s[aá]bados?|domingos?)\b',
      (m) => 'cada ${m[1]!.toLowerCase().replaceAll(RegExp(r'(?<=(?:bado|mingo))s$'), '')}');
  s = sub(s, r'\b(todas las semanas|semanalmente|each week)\b', (_) => 'cada semana');
  s = sub(s, r'\b(todos los meses|mensualmente|each month)\b', (_) => 'cada mes');
  s = sub(s, r'\b(todos los años|anualmente|each year)\b', (_) => 'cada año');
  // "el 20 de octubre" / "on october 20th": drop the article the parser would keep.
  s = sub(s, r'\bel (\d{1,2} de )', (m) => m[1]!);
  s = sub(s, r'\bon ((?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d)', (m) => m[1]!);

  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1);
}
