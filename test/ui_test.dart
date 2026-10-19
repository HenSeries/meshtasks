import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshtasks/app_state.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/core/team.dart';
import 'package:meshtasks/main.dart';
import 'package:meshtasks/model/dates.dart';

Future<AppState> seeded(WidgetTester tester) async {
  final app = (await tester.runAsync(
      () => AppState.forTest(Store.open(':memory:'), Team.create('Acme'))))!;
  final r = app.repo;
  final me = r.addMember('Jorge Restrepo');
  r.setMe(me);
  r.ensureMyKey();
  final ana = r.addMember('Ana Gómez');
  final web = r.addProject('Website relaunch');
  final sales = r.addProject('Sales');
  final design = r.addSection(web, 'Design');
  r.addSection(web, 'Build');
  final label = r.ensureLabel('client');
  final today = Due(DateTime.now());
  final parent = r.addTask(
      title: 'Approve homepage mockups with a fairly long title that should wrap nicely',
      projectId: web, sectionId: design, priority: 1, due: today, assignee: ana, labels: [label],
      description: 'Two variants in Figma');
  r.addTask(title: 'Sub one', projectId: web, sectionId: design, parentId: parent);
  r.addTask(title: 'Renew SSL', due: Due(DateTime.now().subtract(const Duration(days: 1))), assignee: me);
  r.addTask(title: 'Call client', projectId: sales, due: today, priority: 2, recur: Recurrence.tryParse('every fri'));
  r.addComment(parent, 'Looks good to me');
  return app;
}

Future<void> sizeTo(WidgetTester tester, Size s) async {
  tester.view.physicalSize = s;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> tapNav(WidgetTester tester, String label, {required bool phone}) async {
  if (phone) {
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.descendant(of: find.byType(ListTile), matching: find.text(label)).first);
  await tester.pumpAndSettle();
}

void main() {
  for (final (name, size, phone) in [
    ('phone', const Size(390, 844), true),
    ('desktop', const Size(1400, 900), false),
  ]) {
    testWidgets('every screen renders on $name', (tester) async {
      await sizeTo(tester, size);
      final app = await seeded(tester);
      await tester.pumpWidget(MeshTasksApp(app));
      await tester.pumpAndSettle();
      expect(find.text('Renew SSL'), findsOneWidget); // Today (overdue)

      for (final view in [
        'Inbox', 'Upcoming', 'Assigned to me', 'Priority 1', 'Completed',
        'Website relaunch', 'Sales', 'client', 'Search', 'Team & devices', 'Today',
      ]) {
        await tapNav(tester, view, phone: phone);
        final e = tester.takeException();
        expect(e, isNull, reason: '$view: ${e is FlutterError ? e.toStringDeep() : e}');
      }

      // Board view of a project.
      await tapNav(tester, 'Website relaunch', phone: phone);
      await tester.tap(find.byTooltip('Board view'));
      await tester.pumpAndSettle();
      expect(find.text('(No section)  0'), findsOneWidget);
      expect(find.textContaining('Design'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.runAsync(() => app.sync!.stop());
    });
  }

  testWidgets('quick add, complete with undo, and edit in detail', (tester) async {
    await sizeTo(tester, const Size(390, 844));
    final app = await seeded(tester);
    final repo = app.repo;
    await tester.pumpWidget(MeshTasksApp(app));
    await tester.pumpAndSettle();

    // Quick add from the FAB understands the syntax.
    await tester.tap(find.byTooltip('Quick add (hold to dictate)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Send proposal tomorrow 5pm p2 #Sales +Ana @client');
    await tester.pump();
    expect(find.text('Sales'), findsWidgets); // preview chip
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final added = repo.tasks.firstWhere((t) => t.title == 'Send proposal');
    expect(repo.project(added.projectId)!.name, 'Sales');
    expect(repo.member(added.assignee)!.name, 'Ana Gómez');
    expect(added.priority, 2);
    expect(added.due!.minutes, 17 * 60);
    // The lock makes the next task private (only my devices can read it).
    await tester.tap(find.byTooltip('Visible to the team'));
    await tester.pump();
    expect(find.text('Only me'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Dentist friday');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final secret = repo.tasks.firstWhere((t) => t.title == 'Dentist');
    expect(secret.isPrivate, isTrue);
    expect(secret.owner, repo.meId);
    await tester.tapAt(const Offset(200, 100)); // dismiss sheet
    await tester.pumpAndSettle();

    // Complete "Renew SSL" from Today, then undo.
    final ssl = repo.tasks.firstWhere((t) => t.title == 'Renew SSL');
    final row = find.ancestor(of: find.text('Renew SSL'), matching: find.byType(Row)).first;
    await tester.tap(find.descendant(of: row, matching: find.byType(InkResponse)).first);
    await tester.pumpAndSettle();
    expect(repo.task(ssl.id)!.done, isTrue);
    expect(find.text('Completed “Renew SSL”'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(repo.task(ssl.id)!.done, isFalse);

    // Open detail, change priority, add a comment.
    await tester.tap(find.text('Renew SSL'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ActionChip, 'P4'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Priority 1'));
    await tester.pumpAndSettle();
    expect(repo.task(ssl.id)!.priority, 1);
    await tester.enterText(find.widgetWithText(TextField, 'Comment'), 'On it');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(repo.comments(ssl.id).single.text, 'On it');
    expect(tester.takeException(), isNull);

    await tester.runAsync(() => app.sync!.stop());
  });

  testWidgets('onboarding creates a team', (tester) async {
    await sizeTo(tester, const Size(390, 844));
    final store = Store.open(':memory:');
    // Not joined yet: AppState with no team shows onboarding.
    final app = (await tester.runAsync(() => AppState.forTest(store, Team.create('x'))))!;
    await tester.runAsync(() => app.sync!.stop());
    app.team = null;
    await tester.pumpWidget(MeshTasksApp(app));
    await tester.pumpAndSettle();
    expect(find.text('Create team'), findsOneWidget);
    await tester.tap(find.text('Join a team'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'Ana');
    await tester.enterText(find.widgetWithText(TextField, 'Invite code'), 'garbage');
    await tester.tap(find.text('Join team'));
    await tester.pumpAndSettle();
    expect(find.text('Not a MeshTasks invite code'), findsOneWidget);
  });
}
