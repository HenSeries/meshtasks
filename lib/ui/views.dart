import 'package:flutter/material.dart';

import '../model/dates.dart';
import '../model/repo.dart';
import 'common.dart';
import 'tasks.dart';

Widget _header(BuildContext context, String text, {Widget? trailing, Color? color}) => Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 4, 6),
      child: Row(children: [
        Expanded(
          child: Text(text,
              style: Theme.of(context).textTheme.titleSmall!.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  )),
        ),
        ?trailing,
      ]),
    );

Widget _empty(BuildContext context, IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(children: [
        Icon(icon, size: 56, color: Theme.of(context).colorScheme.outlineVariant),
        const SizedBox(height: 12),
        Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      ]),
    );

/// Reorderable list of tasks as a sliver.
class _TaskSliver extends StatelessWidget {
  final Repo repo;
  final List<Task> tasks;
  final bool showProject;
  final bool reorderable;
  const _TaskSliver(this.repo, this.tasks, {this.showProject = false, this.reorderable = true});

  @override
  Widget build(BuildContext context) {
    if (!reorderable) {
      return SliverList.list(children: [
        for (final t in tasks) TaskTile(repo, t, key: ValueKey(t.id), showProject: showProject),
      ]);
    }
    return SliverReorderableList(
      itemCount: tasks.length,
      onReorderItem: (o, n) => repo.reorder(tasks, o, n, 'tasks'),
      itemBuilder: (context, i) => Material(
        key: ValueKey(tasks[i].id),
        type: MaterialType.transparency,
        child: TaskTile(repo, tasks[i], showProject: showProject, dragIndex: i),
      ),
    );
  }
}

// ---------------------------------------------------------------- Today

class TodayView extends StatelessWidget {
  final Repo repo;
  const TodayView(this.repo, {super.key});

  @override
  Widget build(BuildContext context) {
    final now = repo.now();
    final today = dayOf(now);
    final overdue = repo.overdue();
    final todays = repo.dueOn(today);
    return CustomScrollView(slivers: [
      if (overdue.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: _header(context, 'Overdue',
              color: const Color(0xFFD1453B),
              trailing: TextButton(
                onPressed: () {
                  for (final t in overdue) {
                    repo.updateTask(t.id, {'due': t.due!.withDate(today).toString()});
                  }
                },
                child: const Text('Reschedule to today'),
              )),
        ),
        _TaskSliver(repo, overdue, showProject: true, reorderable: false),
      ],
      SliverToBoxAdapter(child: _header(context, fmtLongDay(today, now))),
      _TaskSliver(repo, todays, showProject: true, reorderable: false),
      SliverToBoxAdapter(child: AddTaskRow(repo, defaultDue: Due(today))),
      if (overdue.isEmpty && todays.isEmpty)
        SliverToBoxAdapter(
            child: _empty(context, Icons.wb_sunny_outlined, 'Nothing due today. Enjoy!')),
    ]);
  }
}

// ------------------------------------------------------------- Upcoming

class UpcomingView extends StatelessWidget {
  final Repo repo;
  const UpcomingView(this.repo, {super.key});

  @override
  Widget build(BuildContext context) {
    final now = repo.now();
    final today = dayOf(now);
    final overdue = repo.overdue();
    final later = repo.open.where((t) => t.due != null && !t.due!.date.isBefore(addDays(today, 21))).toList()
      ..sort(Repo.byDueThenPriority);
    return CustomScrollView(slivers: [
      if (overdue.isNotEmpty) ...[
        SliverToBoxAdapter(child: _header(context, 'Overdue', color: const Color(0xFFD1453B))),
        _TaskSliver(repo, overdue, showProject: true, reorderable: false),
      ],
      for (var i = 0; i < 21; i++) ...[
        SliverToBoxAdapter(child: _header(context, fmtLongDay(addDays(today, i), now))),
        _TaskSliver(repo, repo.dueOn(addDays(today, i)), showProject: true, reorderable: false),
        SliverToBoxAdapter(child: AddTaskRow(repo, defaultDue: Due(addDays(today, i)))),
      ],
      if (later.isNotEmpty) ...[
        SliverToBoxAdapter(child: _header(context, 'Later')),
        _TaskSliver(repo, later, showProject: true, reorderable: false),
      ],
    ]);
  }
}

// -------------------------------------------------------------- Project

/// A project (or the Inbox when [projectId] is null) with sections.
class ProjectView extends StatefulWidget {
  final Repo repo;
  final String? projectId;
  const ProjectView(this.repo, this.projectId, {super.key});

  @override
  State<ProjectView> createState() => ProjectViewState();
}

class ProjectViewState extends State<ProjectView> {
  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    final pid = widget.projectId;
    final sections = repo.sections(pid);
    final unsectioned = pid == null ? repo.inbox().where((t) => t.sectionId == null).toList()
        : repo.inProject(pid, sectionId: null);

    if (pid != null && repo.project(pid)?.r['layout'] == 'board') return _Board(repo, pid);

    return CustomScrollView(slivers: [
      _TaskSliver(repo, unsectioned),
      SliverToBoxAdapter(child: AddTaskRow(repo, projectId: pid)),
      if (unsectioned.isEmpty && sections.isEmpty)
        SliverToBoxAdapter(
            child: _empty(context, Icons.task_alt,
                pid == null ? 'Inbox zero. Capture anything here.' : 'No tasks yet.')),
      for (final s in sections) ...[
        SliverToBoxAdapter(
          child: _header(context, s.name, trailing: _SectionMenu(repo, s)),
        ),
        SliverToBoxAdapter(child: Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant)),
        _TaskSliver(repo, _sectionTasks(repo, pid, s.id)),
        SliverToBoxAdapter(child: AddTaskRow(repo, projectId: pid, sectionId: s.id)),
      ],
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.view_agenda_outlined),
              label: const Text('Add section'),
              onPressed: () async {
                final n = await promptText(context, title: 'New section', action: 'Add');
                if (n != null && n.trim().isNotEmpty) repo.addSection(pid, n);
              },
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 80)),
    ]);
  }
}

List<Task> _sectionTasks(Repo repo, String? pid, String sectionId) => pid == null
    ? (repo.open.where((t) => t.projectId == null && t.parentId == null && t.sectionId == sectionId).toList()
      ..sort((a, b) => a.order.compareTo(b.order)))
    : repo.inProject(pid, sectionId: sectionId);

class _SectionMenu extends StatelessWidget {
  final Repo repo;
  final Section s;
  const _SectionMenu(this.repo, this.s);

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 18),
        onSelected: (v) async {
          if (v == 'rename') {
            final n = await promptText(context, title: 'Rename section', initial: s.name);
            if (n != null && n.trim().isNotEmpty) repo.renameSection(s.id, n);
          } else if (v == 'delete' &&
              await confirm(context, 'Delete section?',
                  '“${s.name}” and all its tasks will be deleted for the whole team.')) {
            repo.deleteSection(s.id);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );
}

/// Kanban board: one column per section; drag cards between columns.
class _Board extends StatelessWidget {
  final Repo repo;
  final String pid;
  const _Board(this.repo, this.pid);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final columns = <(Section?, List<Task>)>[
      (null, repo.inProject(pid, sectionId: null)),
      for (final s in repo.sections(pid)) (s, repo.inProject(pid, sectionId: s.id)),
    ];
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      children: [
        for (final (section, tasks) in columns)
          DragTarget<String>(
            onWillAcceptWithDetails: (d) => repo.task(d.data)?.sectionId != section?.id,
            onAcceptWithDetails: (d) => repo.updateTask(d.data, {
              'sectionId': section?.id,
              'order': (tasks.isEmpty ? 0 : tasks.last.order) + 1,
            }),
            builder: (context, candidate, _) => Container(
              width: 300,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                color: candidate.isNotEmpty ? cs.primaryContainer.withValues(alpha: 0.4) : cs.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _header(context, '${section?.name ?? '(No section)'}  ${tasks.length}',
                    trailing: section == null ? null : _SectionMenu(repo, section)),
                Expanded(
                  child: ListView(children: [
                    for (final t in tasks)
                      LongPressDraggable<String>(
                        data: t.id,
                        feedback: Material(
                          elevation: 6,
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(width: 280, child: TaskTile(repo, t, showProject: false)),
                        ),
                        childWhenDragging: Opacity(
                            opacity: 0.3, child: _card(TaskTile(repo, t, showProject: false))),
                        child: _card(TaskTile(repo, t, showProject: false)),
                      ),
                    AddTaskRow(repo, projectId: pid, sectionId: section?.id),
                  ]),
                ),
              ]),
            ),
          ),
        SizedBox(
          width: 220,
          child: Align(
            alignment: Alignment.topLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: const Text('Add section'),
              onPressed: () async {
                final n = await promptText(context, title: 'New section', action: 'Add');
                if (n != null && n.trim().isNotEmpty) repo.addSection(pid, n);
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(Widget child) => Card(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

// ------------------------------------------------------- Simple filters

class FilteredView extends StatelessWidget {
  final Repo repo;
  final List<Task> tasks;
  final String emptyText;
  final IconData emptyIcon;
  const FilteredView(this.repo, this.tasks,
      {super.key, required this.emptyText, this.emptyIcon = Icons.filter_alt_outlined});

  @override
  Widget build(BuildContext context) => CustomScrollView(slivers: [
        _TaskSliver(repo, tasks, showProject: true, reorderable: false),
        if (tasks.isEmpty) SliverToBoxAdapter(child: _empty(context, emptyIcon, emptyText)),
      ]);
}

class CompletedView extends StatelessWidget {
  final Repo repo;
  const CompletedView(this.repo, {super.key});

  @override
  Widget build(BuildContext context) {
    final now = repo.now();
    final done = repo.completed();
    final groups = <DateTime, List<Task>>{};
    for (final t in done) {
      groups.putIfAbsent(dayOf(t.doneAt ?? DateTime(0)), () => []).add(t);
    }
    return CustomScrollView(slivers: [
      for (final e in groups.entries) ...[
        SliverToBoxAdapter(child: _header(context, fmtLongDay(e.key, now))),
        _TaskSliver(repo, e.value, showProject: true, reorderable: false),
      ],
      if (done.isEmpty)
        SliverToBoxAdapter(child: _empty(context, Icons.check_circle_outline, 'No completed tasks yet.')),
    ]);
  }
}

class SearchView extends StatefulWidget {
  final Repo repo;
  const SearchView(this.repo, {super.key});

  @override
  State<SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<SearchView> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final results = widget.repo.search(q);
    return CustomScrollView(slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search tasks',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => q = v),
          ),
        ),
      ),
      _TaskSliver(widget.repo, results, showProject: true, reorderable: false),
      if (q.isNotEmpty && results.isEmpty)
        SliverToBoxAdapter(child: _empty(context, Icons.search_off, 'No matches')),
    ]);
  }
}
