import 'package:flutter/material.dart';

import '../model/dates.dart';
import '../model/quick_add.dart';
import '../model/repo.dart';
import 'common.dart';
import 'task_detail.dart';
import 'voice.dart';

/// Todoist-style row: priority-coloured circle, title, and a meta line.
class TaskTile extends StatelessWidget {
  final Repo repo;
  final Task task;
  final bool showProject;
  final int? dragIndex;

  const TaskTile(this.repo, this.task,
      {super.key, this.showProject = true, this.dragIndex});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = repo.now();
    final project = repo.project(task.projectId);
    final section = task.sectionId == null
        ? null
        : repo.sections(task.projectId).where((s) => s.id == task.sectionId).firstOrNull;
    final assignee = repo.member(task.assignee);
    final subs = repo.subtasks(task.id);
    final comments = repo.commentCount(task.id);
    final due = task.due;
    final small = Theme.of(context).textTheme.bodySmall!;

    final meta = <Widget>[
      if (task.isPrivate) _Meta(Icons.lock_outline, 'Only me', cs.onSurfaceVariant),
      if (task.alarm && due != null) _Meta(Icons.alarm, 'Alarm', cs.error),
      if (task.reward.isNotEmpty) _Meta(Icons.emoji_events_outlined, task.reward, const Color(0xFF058527)),
      if (task.punishment.isNotEmpty) _Meta(Icons.gavel_outlined, task.punishment, cs.error),
      if (due != null)
        _Meta(task.recur != null ? Icons.repeat : Icons.event, fmtDue(due, now),
            dueColor(due, now, cs)),
      if (subs.isNotEmpty)
        _Meta(Icons.account_tree_outlined,
            '${subs.where((s) => s.done).length}/${subs.length}', cs.onSurfaceVariant),
      if (comments > 0) _Meta(Icons.chat_bubble_outline, '$comments', cs.onSurfaceVariant),
      for (final l in task.labels.map(repo.label).whereType<Label>())
        _Meta(Icons.label_outline, l.name, Color(l.color)),
      if (showProject)
        _Meta(
          project == null ? Icons.inbox_outlined : Icons.tag,
          project == null
              ? 'Inbox'
              : section == null
                  ? project.name
                  : '${project.name} / ${section.name}',
          project == null ? cs.onSurfaceVariant : Color(project.color),
        ),
    ];

    final tile = InkWell(
      onTap: () => openTask(context, repo, task.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Check(task: task, onTap: () => _toggle(context)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(task.title,
                  style: TextStyle(
                    decoration: task.done ? TextDecoration.lineThrough : null,
                    color: task.done ? cs.onSurfaceVariant : null,
                  )),
              if (task.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(task.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small.copyWith(color: cs.onSurfaceVariant)),
                ),
              if (meta.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 10, runSpacing: 2, children: meta),
                ),
            ]),
          ),
          if (assignee != null)
            Padding(
              padding: const EdgeInsets.only(left: 8, top: 2),
              child: MemberAvatar(assignee, size: 22),
            ),
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex!,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.drag_indicator, size: 18, color: cs.outlineVariant),
              ),
            ),
        ]),
      ),
    );

    return Dismissible(
      key: ValueKey('dismiss-${task.id}'),
      background: Container(
        color: const Color(0xFF058527),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.check, color: Colors.white),
      ),
      secondaryBackground: Container(
        color: const Color(0xFF692EC2),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.event, color: Colors.white),
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          _toggle(context);
        } else {
          final d = await pickDue(context, task.due);
          if (d != null) repo.updateTask(task.id, {'due': isClearDue(d) ? null : d.toString()});
        }
        return false;
      },
      child: tile,
    );
  }

  void _toggle(BuildContext context) {
    if (task.done) {
      repo.uncomplete(task.id);
      return;
    }
    final wasRecurring = task.recur != null;
    final before = Map<String, Object?>.of(task.r);
    final result = repo.complete(task.id);
    final messenger = ScaffoldMessenger.of(context);
    final points = result.points > 0 ? '  +${result.points} pts' : '';
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Text(wasRecurring
          ? 'Next: ${fmtDue(repo.task(task.id)!.due!, repo.now())}$points'
          : 'Completed “${task.title}”$points'),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => wasRecurring
            ? repo.undoRecurring(task.id, before['due'] as String?)
            : repo.uncomplete(task.id),
      ),
    ));
    if (result.reward != null) {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Text('🎉', style: TextStyle(fontSize: 44)),
          title: const Text('On time! You earned your reward'),
          content: Text(result.reward!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18)),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Enjoy'))],
        ),
      );
    }
  }
}

class _Check extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  const _Check({required this.task, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = priorityColors[task.priority]!;
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: c, width: task.priority < 4 ? 2 : 1.4),
            color: task.done ? c : c.withValues(alpha: task.priority < 4 ? 0.1 : 0),
          ),
          child: task.done ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Meta(this.icon, this.text, this.color);

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 3),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: color)),
        ),
      ]);
}

/// Text field that understands quick-add syntax and previews what it found.
class QuickAddField extends StatefulWidget {
  final Repo repo;
  final String? projectId;
  final String? sectionId;
  final String? parentId;
  final Due? defaultDue;
  final bool autofocus;
  final bool startWithVoice;

  const QuickAddField(this.repo,
      {super.key,
      this.projectId,
      this.sectionId,
      this.parentId,
      this.defaultDue,
      this.autofocus = true,
      this.startWithVoice = false});

  @override
  State<QuickAddField> createState() => _QuickAddFieldState();
}

class _QuickAddFieldState extends State<QuickAddField> {
  final _c = TextEditingController();
  final _focus = FocusNode();
  QuickAdd? _parsed;
  bool _private = false;

  /// Sub-tasks follow their parent's privacy; others can opt in.
  bool get _canChoosePrivacy => widget.parentId == null;

  @override
  void initState() {
    super.initState();
    if (widget.startWithVoice) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _dictate());
    }
    _c.addListener(() => setState(() {
          _parsed = _c.text.trim().isEmpty
              ? null
              : parseQuickAdd(_c.text,
                  now: widget.repo.now(),
                  projects: widget.repo.projects.map((p) => p.name).toList(),
                  members: widget.repo.members.map((m) => m.name).toList());
        }));
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _dictate() async {
    final text = await showVoiceSheet(context, widget.repo);
    if (text == null || !mounted) return;
    final current = _c.text.trim();
    _c.text = current.isEmpty ? text : '$current $text';
    _c.selection = TextSelection.collapsed(offset: _c.text.length);
    _focus.requestFocus();
  }

  void _submit() {
    var text = _c.text;
    if (_private && !(_parsed?.private ?? false)) text = '$text !private';
    final String? id;
    try {
      id = widget.repo.quickAdd(text,
        projectId: widget.projectId,
        sectionId: widget.sectionId,
        parentId: widget.parentId,
        defaultDue: widget.defaultDue);
    } on StateError catch (e) {
      // e.g. my private key lives on another device and wasn't imported yet.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      return;
    }
    if (id == null) return;
    _c.clear();
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final q = _parsed;
    final now = widget.repo.now();
    final chips = <Widget>[
      if (q?.due != null || (q != null && widget.defaultDue != null))
        _chip(Icons.event, fmtDue((q!.due ?? widget.defaultDue)!, now)),
      if (q?.recur != null) _chip(Icons.repeat, q!.recur.toString()),
      if (q?.priority != null && q!.priority! < 4)
        _chip(Icons.flag, 'P${q.priority}', priorityColors[q.priority]),
      if (q?.project != null) _chip(Icons.tag, q!.project!),
      if (q?.section != null) _chip(Icons.view_agenda_outlined, q!.section!),
      for (final l in q?.labels ?? const <String>[]) _chip(Icons.label_outline, l),
      if (q?.assignee != null) _chip(Icons.person_outline, q!.assignee!),
      if (_private || (q?.private ?? false)) _chip(Icons.lock_outline, 'Only me'),
    ];
    final cs = Theme.of(context).colorScheme;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _c,
        focusNode: _focus,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          hintText: widget.parentId != null
              ? 'Add sub-task'
              : 'e.g. Send report tomorrow 5pm p1 #Project @label +person',
          border: InputBorder.none,
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.mic_none),
              tooltip: 'Dictate (Spanish or English)',
              onPressed: _dictate,
            ),
            if (_canChoosePrivacy)
              IconButton(
                icon: Icon(_private ? Icons.lock : Icons.lock_open_outlined,
                    color: _private ? cs.primary : null),
                tooltip: _private ? 'Private: only you will see it' : 'Visible to the team',
                onPressed: () => setState(() => _private = !_private),
              ),
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Add task',
              onPressed: _c.text.trim().isEmpty ? null : _submit,
            ),
          ]),
        ),
      ),
      if (chips.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(spacing: 6, runSpacing: 4, children: chips),
        ),
    ]);
  }

  Widget _chip(IconData icon, String text, [Color? color]) => Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(icon, size: 14, color: color),
        label: Text(text, style: const TextStyle(fontSize: 12)),
        padding: EdgeInsets.zero,
      );
}

Future<void> showQuickAdd(BuildContext context, Repo repo,
    {String? projectId, String? sectionId, Due? defaultDue, bool voice = false}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 8, 12 + MediaQuery.of(ctx).viewInsets.bottom),
      child: QuickAddField(repo,
          projectId: projectId,
          sectionId: sectionId,
          defaultDue: defaultDue,
          autofocus: !voice,
          startWithVoice: voice),
    ),
  );
}

/// Inline "+ Add task" row that expands into a quick-add field.
class AddTaskRow extends StatefulWidget {
  final Repo repo;
  final String? projectId;
  final String? sectionId;
  final Due? defaultDue;
  const AddTaskRow(this.repo, {super.key, this.projectId, this.sectionId, this.defaultDue});

  @override
  State<AddTaskRow> createState() => _AddTaskRowState();
}

class _AddTaskRowState extends State<AddTaskRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!_open) {
      return InkWell(
        onTap: () => setState(() => _open = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            Icon(Icons.add, size: 20, color: cs.primary),
            const SizedBox(width: 12),
            Text('Add task', style: TextStyle(color: cs.onSurfaceVariant)),
          ]),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        QuickAddField(widget.repo,
            projectId: widget.projectId,
            sectionId: widget.sectionId,
            defaultDue: widget.defaultDue),
        TextButton(onPressed: () => setState(() => _open = false), child: const Text('Close')),
      ]),
    );
  }
}
