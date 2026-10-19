// CLI tool: printing to stdout is its interface.
// ignore_for_file: avoid_print

// Fills a node's database with a demo workspace (members, projects,
// sections, labels, tasks). Usage: dart run tool/seed_demo.dart <db>
import 'package:meshtasks/core/store.dart';

void main(List<String> args) {
  final s = Store.open(args.first);
  final now = DateTime.now();
  String day(int offset, [String? time]) {
    final d = DateTime(now.year, now.month, now.day + offset);
    final ds = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return time == null ? ds : '${ds}T$time';
  }

  String put(String table, Map<String, Object?> f) {
    final id = Store.newId();
    s.put(table, id, f);
    return id;
  }

  final ana = put('members', {'name': 'Ana Gómez', 'color': 0xFFDB4035});
  final luis = put('members', {'name': 'Luis Pérez', 'color': 0xFF4073FF});
  final jorge = put('members', {'name': 'Jorge Restrepo', 'color': 0xFF299438});

  final web = put('projects', {'name': 'Website relaunch', 'color': 0xFF4073FF, 'order': 1, 'favorite': true});
  final ops = put('projects', {'name': 'Operations', 'color': 0xFFFF9933, 'order': 2});
  final sales = put('projects', {'name': 'Sales', 'color': 0xFF299438, 'order': 3});

  final design = put('sections', {'projectId': web, 'name': 'Design', 'order': 1});
  final build = put('sections', {'projectId': web, 'name': 'Build', 'order': 2});
  final launch = put('sections', {'projectId': web, 'name': 'Launch', 'order': 3});

  final urgent = put('labels', {'name': 'client', 'color': 0xFFE05194});
  final calls = put('labels', {'name': 'call', 'color': 0xFF14AAF5});

  var order = 0;
  String task(String title,
      {String? project, String? section, String? due, int p = 4, String? who,
      List<String> labels = const [], String? recur, String? parent, String desc = ''}) =>
      put('tasks', {
        'title': title,
        'description': desc,
        'projectId': project,
        'sectionId': section,
        'parentId': parent,
        'priority': p,
        'due': due,
        'recur': recur,
        'labels': labels,
        'assignee': who,
        'done': false,
        'order': ++order,
        'createdAt': now.millisecondsSinceEpoch,
        'createdBy': jorge,
      });

  task('Approve homepage mockups', project: web, section: design, due: day(0, '11:00'), p: 1, who: ana,
      labels: [urgent], desc: 'Two variants in Figma; pick one with the client.');
  task('Pick font pairing', project: web, section: design, due: day(2), p: 3, who: ana);
  final api = task('Set up contact form API', project: web, section: build, due: day(1), p: 2, who: jorge);
  task('Validation + spam filter', project: web, section: build, parent: api, who: jorge);
  task('Email notification', project: web, section: build, parent: api, who: luis);
  task('Migrate blog posts', project: web, section: build, due: day(4), who: luis);
  task('DNS cutover checklist', project: web, section: launch, due: day(9), p: 2, who: jorge);
  task('Weekly backup check', project: ops, due: day(0, '18:00'), recur: 'every fri', who: luis);
  task('Renew SSL certificates', project: ops, due: day(-1), p: 1, who: jorge);
  task('Standup notes', project: ops, due: day(1, '09:00'), recur: 'every weekday');
  task('Call Restaurante El Poblado', project: sales, due: day(0, '15:30'), p: 2, who: ana, labels: [calls, urgent]);
  task('Send proposal to Café Laureles', project: sales, due: day(3), p: 3, labels: [urgent]);
  task('Buy printer toner', due: day(0));
  task('Ideas for Q1 offsite');
  s.close();
  print('seeded');
}
