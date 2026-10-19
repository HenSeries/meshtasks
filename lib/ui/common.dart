import 'package:flutter/material.dart';

import '../model/dates.dart';
import '../model/repo.dart';

const priorityColors = {
  1: Color(0xFFD1453B),
  2: Color(0xFFEB8909),
  3: Color(0xFF246FE0),
  4: Color(0xFF9E9E9E),
};

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

String fmtTime(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';

/// "Today", "Tomorrow", "Friday", "Oct 20", "Oct 20 2027".
String fmtDay(DateTime d, DateTime now) {
  final today = dayOf(now);
  final diff = dayOf(d).difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[d.weekday - 1];
  final base = '${_months[d.month - 1]} ${d.day}';
  return d.year == today.year ? base : '$base ${d.year}';
}

String fmtDue(Due due, DateTime now) {
  final day = fmtDay(due.date, now);
  return due.hasTime ? '$day ${fmtTime(due.minutes!)}' : day;
}

String fmtLongDay(DateTime d, DateTime now) {
  final label = fmtDay(d, now);
  final full = '${_weekdays[d.weekday - 1]} · ${_months[d.month - 1]} ${d.day}';
  return label == _weekdays[d.weekday - 1] ? full : '$label · $full';
}

Color dueColor(Due due, DateTime now, ColorScheme cs) {
  final today = dayOf(now);
  if (due.date.isBefore(today) ||
      (due.hasTime && due.date == today && due.moment.isBefore(now))) {
    return const Color(0xFFD1453B);
  }
  if (due.date == today) return const Color(0xFF058527);
  if (due.date == addDays(today, 1)) return const Color(0xFFAD6200);
  if (due.date.difference(today).inDays < 7) return const Color(0xFF692EC2);
  return cs.onSurfaceVariant;
}

class MemberAvatar extends StatelessWidget {
  final Member member;
  final double size;
  const MemberAvatar(this.member, {super.key, this.size = 22});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: member.name,
        child: CircleAvatar(
          radius: size / 2,
          backgroundColor: Color(member.color),
          child: Text(member.initials,
              style: TextStyle(
                  fontSize: size * 0.42, color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );
}

/// Pick a date (with optional time). Returns null on cancel; a `Due` with
/// a sentinel year 0 means "remove the date".
Future<Due?> pickDue(BuildContext context, Due? current) async {
  final now = DateTime.now();
  final today = dayOf(now);
  return showModalBottomSheet<Due>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget quick(IconData icon, String label, DateTime d, Color c) => ListTile(
            leading: Icon(icon, color: c),
            title: Text(label),
            trailing: Text('${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day}'),
            onTap: () => Navigator.pop(ctx, Due(d, current?.minutes)),
          );
      return SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          quick(Icons.today, 'Today', today, const Color(0xFF058527)),
          quick(Icons.wb_sunny_outlined, 'Tomorrow', addDays(today, 1), const Color(0xFFAD6200)),
          quick(Icons.weekend_outlined, 'This weekend', nextWeekday(addDays(today, -1), 6),
              const Color(0xFF246FE0)),
          quick(Icons.arrow_forward, 'Next week', nextWeekday(today, 1), const Color(0xFF692EC2)),
          ListTile(
            leading: const Icon(Icons.calendar_month),
            title: const Text('Pick a date…'),
            onTap: () async {
              final d = await showDatePicker(
                context: ctx,
                initialDate: current?.date ?? today,
                firstDate: DateTime(today.year - 5),
                lastDate: DateTime(today.year + 10),
              );
              if (d != null && ctx.mounted) Navigator.pop(ctx, Due(d, current?.minutes));
            },
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text(current?.hasTime == true ? 'Time: ${fmtTime(current!.minutes!)}' : 'Add time…'),
            onTap: () async {
              final t = await showTimePicker(
                context: ctx,
                initialTime: current?.hasTime == true
                    ? TimeOfDay(hour: current!.minutes! ~/ 60, minute: current.minutes! % 60)
                    : const TimeOfDay(hour: 9, minute: 0),
              );
              if (t != null && ctx.mounted) {
                Navigator.pop(ctx, Due(current?.date ?? today, t.hour * 60 + t.minute));
              }
            },
          ),
          if (current != null)
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('No date'),
              onTap: () => Navigator.pop(ctx, Due(DateTime(0))),
            ),
        ]),
      );
    },
  );
}

bool isClearDue(Due d) => d.date.year == 0;

Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String hint = '', String action = 'Save'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(action)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body,
        {String action = 'Delete', bool destructive = true}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error)
                  : null,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action)),
        ],
      ),
    ) ??
    false;
