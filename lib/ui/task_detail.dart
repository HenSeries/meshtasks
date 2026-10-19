import 'package:flutter/material.dart';

import '../model/dates.dart';
import '../model/repo.dart';
import 'common.dart';
import 'tasks.dart';

void openTask(BuildContext context, Repo repo, String id) {
  final wide = MediaQuery.of(context).size.width >= 900;
  if (wide) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 760, height: 640, child: TaskDetail(repo, id)),
      ),
    );
  } else {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => TaskDetail(repo, id)));
  }
}

class TaskDetail extends StatelessWidget {
  final Repo repo;
  final String id;
  const TaskDetail(this.repo, this.id, {super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final t = repo.task(id);
          if (t == null) {
            return const Scaffold(body: Center(child: Text('This task was deleted.')));
          }
          return _Body(repo, t);
        },
      );
}

class _Body extends StatefulWidget {
  final Repo repo;
  final Task t;
  const _Body(this.repo, this.t);

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final _title = TextEditingController(text: widget.t.title);
  late final _desc = TextEditingController(text: widget.t.description);
  final _comment = TextEditingController();
  final _titleFocus = FocusNode();
  final _descFocus = FocusNode();

  Repo get repo => widget.repo;
  Task get t => widget.t;

  @override
  void initState() {
    super.initState();
    _titleFocus.addListener(() {
      if (!_titleFocus.hasFocus) _saveTitle();
    });
    _descFocus.addListener(() {
      if (!_descFocus.hasFocus) _saveDesc();
    });
  }

  @override
  void didUpdateWidget(_Body old) {
    super.didUpdateWidget(old);
    // Reflect edits arriving from other devices unless we're typing.
    if (!_titleFocus.hasFocus && _title.text != t.title) _title.text = t.title;
    if (!_descFocus.hasFocus && _desc.text != t.description) _desc.text = t.description;
  }

  @override
  void dispose() {
    _saveTitle();
    _saveDesc();
    for (final c in [_title, _desc, _comment]) {
      c.dispose();
    }
    _titleFocus.dispose();
    _descFocus.dispose();
    super.dispose();
  }

  void _saveTitle() {
    final current = repo.task(t.id);
    final v = _title.text.trim();
    if (current != null && v.isNotEmpty && v != current.title) {
      repo.updateTask(t.id, {'title': v});
    }
  }

  void _saveDesc() {
    final current = repo.task(t.id);
    if (current != null && _desc.text != current.description) {
      repo.updateTask(t.id, {'description': _desc.text});
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = repo.now();
    final project = repo.project(t.projectId);
    final section = repo.sections(t.projectId).where((s) => s.id == t.sectionId).firstOrNull;
    final parent = t.parentId == null ? null : repo.task(t.parentId!);
    final creator = repo.member(t.createdBy);

    final props = <Widget>[
      _Prop(
        icon: Icons.tag,
        label: 'Project',
        value: project == null ? 'Inbox' : section == null ? project.name : '${project.name} / ${section.name}',
        color: project == null ? null : Color(project.color),
        onTap: _pickProject,
      ),
      _Prop(
        icon: t.recur != null ? Icons.repeat : Icons.event,
        label: 'Date',
        value: t.due == null ? 'No date' : fmtDue(t.due!, now),
        color: t.due == null ? null : dueColor(t.due!, now, cs),
        onTap: () async {
          final d = await pickDue(context, t.due);
          if (d != null) repo.updateTask(t.id, {'due': isClearDue(d) ? null : d.toString()});
        },
      ),
      _Prop(
        icon: Icons.repeat,
        label: 'Repeat',
        value: t.recur?.toString() ?? 'Never',
        onTap: _pickRecur,
      ),
      _Prop(
        icon: Icons.flag,
        label: 'Priority',
        value: 'P${t.priority}',
        color: priorityColors[t.priority],
        onTap: _pickPriority,
      ),
      if (t.parentId == null && (t.isPrivate || t.createdBy == null || t.createdBy == repo.meId))
        _Prop(
          icon: t.isPrivate ? Icons.lock : Icons.groups_outlined,
          label: 'Who can see it',
          value: t.isPrivate ? 'Only me' : 'Team',
          color: t.isPrivate ? cs.primary : null,
          onTap: _togglePrivate,
        ),
      if (!t.isPrivate)
        _Prop(
          icon: Icons.person_outline,
          label: 'Assignee',
          value: repo.member(t.assignee)?.name ?? 'Unassigned',
          onTap: _pickAssignee,
        ),
      _Prop(
        icon: Icons.label_outline,
        label: 'Labels',
        value: t.labels.isEmpty
            ? 'None'
            : t.labels.map(repo.label).whereType<Label>().map((l) => l.name).join(', '),
        onTap: _pickLabels,
      ),
    ];

    final subs = repo.subtasks(t.id);
    final comments = repo.comments(t.id);

    return Scaffold(
      appBar: AppBar(
        title: Text(parent != null ? 'Sub-task of “${parent.title}”' : project?.name ?? 'Inbox',
            style: Theme.of(context).textTheme.titleMedium),
        actions: [
          IconButton(
            tooltip: 'Delete task',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (await confirm(context, 'Delete task?',
                  '“${t.title}” and its sub-tasks will be deleted for the whole team.')) {
                repo.deleteTask(t.id);
                if (context.mounted) Navigator.of(context).pop();
              }
            },
          ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Checkbox(
              shape: const CircleBorder(),
              side: BorderSide(color: priorityColors[t.priority]!, width: 2),
              activeColor: priorityColors[t.priority],
              value: t.done,
              onChanged: (_) => t.done ? repo.uncomplete(t.id) : repo.complete(t.id),
            ),
          ),
          Expanded(
            child: Column(children: [
              TextField(
                controller: _title,
                focusNode: _titleFocus,
                style: Theme.of(context).textTheme.titleLarge,
                decoration: const InputDecoration(border: InputBorder.none, hintText: 'Task name'),
                onSubmitted: (_) => _saveTitle(),
              ),
              TextField(
                controller: _desc,
                focusNode: _descFocus,
                maxLines: null,
                decoration: const InputDecoration(
                    border: InputBorder.none, hintText: 'Description', isDense: true),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: props),
        const SizedBox(height: 20),
        Text('Sub-tasks${subs.isEmpty ? '' : '  ${subs.where((s) => s.done).length}/${subs.length}'}',
            style: Theme.of(context).textTheme.titleSmall),
        for (final s in subs) TaskTile(repo, s, showProject: false),
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: QuickAddField(repo,
              projectId: t.projectId, sectionId: t.sectionId, parentId: t.id, autofocus: false),
        ),
        const Divider(height: 32),
        Text('Comments', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final c in comments)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: repo.member(c.author) == null
                ? const CircleAvatar(radius: 14, child: Icon(Icons.person, size: 16))
                : MemberAvatar(repo.member(c.author)!, size: 28),
            title: Text.rich(TextSpan(children: [
              TextSpan(
                  text: repo.member(c.author)?.name ?? 'Someone',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(
                  text: '  ${fmtDay(c.at, now)} ${fmtTime(c.at.hour * 60 + c.at.minute)}',
                  style: Theme.of(context).textTheme.bodySmall),
            ])),
            subtitle: SelectableText(c.text),
            trailing: c.author == repo.meId
                ? IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: 'Delete comment',
                    onPressed: () => repo.deleteComment(c.id))
                : null,
          ),
        TextField(
          controller: _comment,
          minLines: 1,
          maxLines: 5,
          decoration: InputDecoration(
            hintText: 'Comment',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.send),
              onPressed: () {
                repo.addComment(t.id, _comment.text);
                _comment.clear();
              },
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Created ${fmtDay(t.createdAt, now)}${creator == null ? '' : ' by ${creator.name}'}'
          '${t.done && t.doneAt != null ? ' · completed ${fmtDay(t.doneAt!, now)}${repo.member(t.r['doneBy'] as String?) == null ? '' : ' by ${repo.member(t.r['doneBy'] as String?)!.name}'}' : ''}',
          style: Theme.of(context).textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
        ),
      ]),
    );
  }

  Future<void> _togglePrivate() async {
    final makePrivate = !t.isPrivate;
    final ok = await confirm(
      context,
      makePrivate ? 'Make private?' : 'Share with the team?',
      makePrivate
          ? 'Only your devices will be able to read this task, its sub-tasks and comments. '
              'Teammates will stop seeing it.'
          : 'Everyone in the team will see this task, its sub-tasks and comments.',
      action: makePrivate ? 'Make private' : 'Share',
      destructive: false,
    );
    if (!ok) return;
    try {
      repo.setPrivate(t.id, makePrivate);
    } on StateError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _pickProject() async {
    final choice = await showModalBottomSheet<(String?, String?)>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.inbox),
            title: const Text('Inbox'),
            onTap: () => Navigator.pop(ctx, (null, null)),
          ),
          for (final s in repo.sections(null))
            ListTile(
              contentPadding: const EdgeInsets.only(left: 56),
              title: Text(s.name),
              onTap: () => Navigator.pop(ctx, (null, s.id)),
            ),
          for (final p in repo.projects) ...[
            ListTile(
              leading: Icon(Icons.circle, size: 14, color: Color(p.color)),
              title: Text(p.name),
              onTap: () => Navigator.pop(ctx, (p.id, null)),
            ),
            for (final s in repo.sections(p.id))
              ListTile(
                contentPadding: const EdgeInsets.only(left: 56),
                title: Text(s.name),
                onTap: () => Navigator.pop(ctx, (p.id, s.id)),
              ),
          ],
        ]),
      ),
    );
    if (choice == null) return;
    repo.updateTask(t.id, {'projectId': choice.$1, 'sectionId': choice.$2});
    for (final s in repo.subtasks(t.id)) {
      repo.updateTask(s.id, {'projectId': choice.$1, 'sectionId': choice.$2});
    }
  }

  Future<void> _pickRecur() async {
    const presets = [
      'every day', 'every weekday', 'every week', 'every 2 weeks', 'every month', 'every year'
    ];
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final p in presets)
            ListTile(title: Text(p), onTap: () => Navigator.pop(ctx, p)),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Custom… (e.g. every mon, thu)'),
            onTap: () async {
              final s = await promptText(ctx, title: 'Repeat', hint: 'every 3 days, every tue, cada lunes');
              if (ctx.mounted) Navigator.pop(ctx, s);
            },
          ),
          if (t.recur != null)
            ListTile(
              leading: const Icon(Icons.block),
              title: const Text('Don’t repeat'),
              onTap: () => Navigator.pop(ctx, ''),
            ),
        ]),
      ),
    );
    if (v == null) return;
    if (v.isEmpty) {
      repo.updateTask(t.id, {'recur': null});
      return;
    }
    final r = Recurrence.tryParse(v);
    if (r == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Didn’t understand “$v”')));
      }
      return;
    }
    repo.updateTask(t.id, {
      'recur': r.toString(),
      if (t.due == null) 'due': Due(r.first(repo.now())).toString(),
    });
  }

  Future<void> _pickPriority() async {
    final p = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final p in [1, 2, 3, 4])
            ListTile(
              leading: Icon(p == 4 ? Icons.outlined_flag : Icons.flag, color: priorityColors[p]),
              title: Text('Priority $p'),
              trailing: t.priority == p ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, p),
            ),
        ]),
      ),
    );
    if (p != null) repo.updateTask(t.id, {'priority': p});
  }

  Future<void> _pickAssignee() async {
    final m = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.person_off_outlined),
            title: const Text('Unassigned'),
            onTap: () => Navigator.pop(ctx, ''),
          ),
          for (final m in repo.members)
            ListTile(
              leading: MemberAvatar(m, size: 28),
              title: Text(m.id == repo.meId ? '${m.name} (me)' : m.name),
              trailing: t.assignee == m.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, m.id),
            ),
        ]),
      ),
    );
    if (m != null) repo.updateTask(t.id, {'assignee': m.isEmpty ? null : m});
  }

  Future<void> _pickLabels() async {
    final selected = t.labels.toSet();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            for (final l in repo.labels)
              CheckboxListTile(
                secondary: Icon(Icons.label, color: Color(l.color)),
                title: Text(l.name),
                value: selected.contains(l.id),
                onChanged: (v) => setSheet(() => v! ? selected.add(l.id) : selected.remove(l.id)),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('New label'),
              onTap: () async {
                final name = await promptText(ctx, title: 'New label', action: 'Create');
                if (name != null && name.trim().isNotEmpty) {
                  setSheet(() => selected.add(repo.ensureLabel(name.trim())));
                }
              },
            ),
          ]),
        ),
      ),
    );
    if (selected.length != t.labels.length || !selected.containsAll(t.labels)) {
      repo.updateTask(t.id, {'labels': selected.toList()});
    }
  }
}

class _Prop extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? color;
  final VoidCallback onTap;
  const _Prop({required this.icon, required this.label, required this.value, this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: ActionChip(
          avatar: Icon(icon, size: 16, color: color),
          label: Text(value),
          onPressed: onTap,
        ),
      );
}
