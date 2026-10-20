import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/dates.dart';
import '../model/repo.dart';
import 'alarm.dart';
import 'common.dart';
import 'docs.dart';
import 'rewards.dart';
import 'task_detail.dart';
import 'tasks.dart';
import 'team.dart';
import 'views.dart';

/// Which screen is showing. [id] is a project / label id when relevant.
class Nav {
  final String kind;
  final String? id;
  const Nav(this.kind, [this.id]);

  @override
  bool operator ==(Object other) =>
      other is Nav && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

class HomePage extends StatefulWidget {
  final AppState app;
  const HomePage(this.app, {super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Nav nav = const Nav('today');
  final _scaffold = GlobalKey<ScaffoldState>();

  final _docPage = GlobalKey<DocPageState>();
  final _subs = <StreamSubscription>[];
  final _pending = <LedgerEntry>[];
  Timer? _announce;
  late final AppLifecycleListener _lifecycle;

  Repo get repo => widget.app.repo;

  @override
  void initState() {
    super.initState();
    final rs = widget.app.reminders;
    _subs.add(
      rs.alarms.listen((r) {
        if (mounted) showAlarm(context, widget.app, r);
      }),
    );
    _subs.add(
      rs.incentives.where((e) => e.kind != 'reward').listen((e) {
        // Gather what one evaluation produced and announce it once.
        _pending.add(e);
        _announce?.cancel();
        _announce = Timer(const Duration(milliseconds: 800), () {
          if (mounted) showIncentives(context, List.of(_pending));
          _pending.clear();
        });
      }),
    );
    _subs.add(
      rs.openTask.listen((id) {
        if (mounted && repo.task(id) != null) openTask(context, repo, id);
      }),
    );
    // Apply Done/Snooze taps made on notifications while we were away.
    _lifecycle = AppLifecycleListener(
      onResume: () => widget.app.reminders.resume(),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.app.reminders.resume(),
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _lifecycle.dispose();
    _announce?.cancel();
    super.dispose();
  }

  void _go(Nav n) {
    setState(() => nav = n);
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repo, widget.app]),
      builder: (context, _) {
        final wide = MediaQuery.of(context).size.width >= 800;
        // Fall back if the open project/label was deleted on another device.
        if ((nav.kind == 'project' && repo.project(nav.id) == null) ||
            (nav.kind == 'label' && repo.label(nav.id!) == null) ||
            (nav.kind == 'doc' && repo.doc(nav.id!) == null)) {
          nav = const Nav('inbox');
        }
        final sidebar = _Sidebar(app: widget.app, nav: nav, onGo: _go);
        final body = _body();
        return Scaffold(
          key: _scaffold,
          drawer: wide ? null : Drawer(child: sidebar),
          appBar: AppBar(title: Text(_title()), actions: _actions(context)),
          floatingActionButton:
              const {'team', 'rewards', 'docs', 'doc'}.contains(nav.kind)
              ? null
              : GestureDetector(
                  onLongPress: () => _quickAdd(context, voice: true),
                  child: FloatingActionButton(
                    tooltip: 'Quick add (hold to dictate)',
                    onPressed: () => _quickAdd(context),
                    child: const Icon(Icons.add),
                  ),
                ),
          body: wide
              ? Row(
                  children: [
                    SizedBox(width: 280, child: sidebar),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth:
                                (nav.kind == 'project' &&
                                        repo.project(nav.id)?.r['layout'] ==
                                            'board') ||
                                    nav.kind == 'doc'
                                ? double.infinity
                                : 860,
                          ),
                          child: body,
                        ),
                      ),
                    ),
                  ],
                )
              : body,
        );
      },
    );
  }

  void _quickAdd(BuildContext context, {bool voice = false}) => showQuickAdd(
    context,
    repo,
    projectId: nav.kind == 'project' ? nav.id : null,
    defaultDue: nav.kind == 'today' ? Due(repo.now()) : null,
    voice: voice,
  );

  String _title() => switch (nav.kind) {
    'inbox' => 'Inbox',
    'today' => 'Today',
    'upcoming' => 'Upcoming',
    'project' => repo.project(nav.id)?.name ?? '',
    'label' => '@${repo.label(nav.id!)?.name ?? ''}',
    'mine' => 'Assigned to me',
    'p1' => 'Priority 1',
    'search' => 'Search',
    'completed' => 'Completed',
    'team' => widget.app.team?.name ?? 'Team',
    'rewards' => 'Rewards & punishments',
    'docs' => 'Docs',
    'doc' => repo.doc(nav.id!)?.title ?? '',
    _ => '',
  };

  Widget _body() => switch (nav.kind) {
    'inbox' => ProjectView(repo, null, key: const ValueKey('inbox')),
    'today' => TodayView(repo),
    'upcoming' => UpcomingView(repo),
    'project' => ProjectView(repo, nav.id, key: ValueKey(nav.id)),
    'label' => FilteredView(
      repo,
      repo.withLabel(nav.id!),
      emptyText: 'No open tasks with this label',
      emptyIcon: Icons.label_outline,
    ),
    'mine' => FilteredView(
      repo,
      repo.meId == null ? [] : repo.assignedTo(repo.meId!),
      emptyText: 'Nothing assigned to you',
      emptyIcon: Icons.person_outline,
    ),
    'p1' => FilteredView(
      repo,
      repo.withPriority(1),
      emptyText: 'No urgent tasks',
    ),
    'search' => SearchView(repo),
    'completed' => CompletedView(repo),
    'team' => TeamView(widget.app),
    'rewards' => RewardsView(widget.app),
    'docs' => DocsIndex(widget.app, onOpen: (id) => _go(Nav('doc', id))),
    'doc' => DocPage(widget.app, nav.id!, key: _docPage),
    _ => const SizedBox(),
  };

  List<Widget> _actions(BuildContext context) {
    if (nav.kind == 'project') {
      final p = repo.project(nav.id)!;
      final board = p.r['layout'] == 'board';
      return [
        IconButton(
          tooltip: board ? 'List view' : 'Board view',
          icon: Icon(board ? Icons.view_list : Icons.view_kanban_outlined),
          onPressed: () =>
              repo.updateProject(p.id, {'layout': board ? 'list' : 'board'}),
        ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'rename':
                final n = await promptText(
                  context,
                  title: 'Rename project',
                  initial: p.name,
                );
                if (n != null && n.trim().isNotEmpty) {
                  repo.updateProject(p.id, {'name': n.trim()});
                }
              case 'color':
                if (!context.mounted) return;
                final c = await _pickColor(context, p.color);
                if (c != null) repo.updateProject(p.id, {'color': c});
              case 'favorite':
                repo.updateProject(p.id, {'favorite': !p.favorite});
              case 'archive':
                repo.updateProject(p.id, {'archived': true});
              case 'delete':
                if (context.mounted &&
                    await confirm(
                      context,
                      'Delete project?',
                      '“${p.name}” and all its tasks will be deleted for the whole team.',
                    )) {
                  repo.deleteProject(p.id);
                }
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'color', child: Text('Change color')),
            PopupMenuItem(
              value: 'favorite',
              child: Text(p.favorite ? 'Unfavorite' : 'Favorite'),
            ),
            const PopupMenuItem(value: 'archive', child: Text('Archive')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ];
    }
    if (nav.kind == 'label') {
      final l = repo.label(nav.id!)!;
      return [
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'rename') {
              final n = await promptText(
                context,
                title: 'Rename label',
                initial: l.name,
              );
              if (n != null && n.trim().isNotEmpty) {
                repo.updateLabel(l.id, {'name': n.trim()});
              }
            } else if (v == 'color') {
              final c = await _pickColor(context, l.color);
              if (c != null) repo.updateLabel(l.id, {'color': c});
            } else if (v == 'delete' &&
                await confirm(
                  context,
                  'Delete label?',
                  'Tasks keep existing; only the label is removed.',
                )) {
              repo.deleteLabel(l.id);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'color', child: Text('Change color')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ];
    }
    if (nav.kind == 'doc') {
      final d = repo.doc(nav.id!)!;
      final editing = _docPage.currentState?.editing ?? false;
      return [
        if (editing)
          FilledButton.icon(
            icon: const Icon(Icons.check),
            label: const Text('Save'),
            onPressed: () async {
              await _docPage.currentState?.save();
              setState(() {});
            },
          )
        else
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () {
              _docPage.currentState?.startEditing();
              setState(() {});
            },
          ),
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'rename':
                final n = await promptText(
                  context,
                  title: 'Rename document',
                  initial: d.title,
                );
                if (n != null && n.trim().isNotEmpty) {
                  repo.updateDoc(d.id, {'title': n.trim()});
                }
              case 'emoji':
                final e = await promptText(
                  context,
                  title: 'Icon (an emoji)',
                  initial: d.emoji,
                );
                if (e != null && e.trim().isNotEmpty) {
                  repo.updateDoc(d.id, {'emoji': e.trim()});
                }
              case 'pin':
                repo.updateDoc(d.id, {'pinned': !d.pinned});
              case 'delete':
                if (context.mounted &&
                    await confirm(
                      context,
                      'Delete document?',
                      '“${d.title}” will be deleted for the whole team.',
                    )) {
                  repo.deleteDoc(d.id);
                  _go(const Nav('docs'));
                }
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename')),
            const PopupMenuItem(value: 'emoji', child: Text('Change icon')),
            PopupMenuItem(
              value: 'pin',
              child: Text(d.pinned ? 'Unpin' : 'Pin to top'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ];
    }
    return [_SyncBadge(widget.app, onTap: () => _go(const Nav('team')))];
  }
}

Future<int?> _pickColor(BuildContext context, int current) => showDialog<int>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: const Text('Color'),
    content: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final c in palette)
          InkWell(
            onTap: () => Navigator.pop(ctx, c),
            customBorder: const CircleBorder(),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: Color(c),
              child: c == current
                  ? const Icon(Icons.check, color: Colors.white, size: 18)
                  : null,
            ),
          ),
      ],
    ),
  ),
);

class _SyncBadge extends StatelessWidget {
  final AppState app;
  final VoidCallback onTap;
  const _SyncBadge(this.app, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final online = app.sync?.peers.values.where((p) => p.online).length ?? 0;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(
          online > 0 ? Icons.hub : Icons.hub_outlined,
          size: 18,
          color: online > 0 ? const Color(0xFF058527) : null,
        ),
        label: Text(online == 0 ? 'Offline' : '$online online'),
        onPressed: onTap,
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final AppState app;
  final Nav nav;
  final void Function(Nav) onGo;
  const _Sidebar({required this.app, required this.nav, required this.onGo});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;

    Widget item(
      Nav n,
      IconData icon,
      String label, {
      Color? color,
      int? count,
    }) => ListTile(
      dense: true,
      selected: nav == n,
      selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      leading: Icon(icon, color: color, size: 20),
      title: Text(label, overflow: TextOverflow.ellipsis),
      trailing: count == null || count == 0
          ? null
          : Text(
              '$count',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
      onTap: () => onGo(n),
    );

    Widget heading(String text, {VoidCallback? onAdd}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: cs.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
          if (onAdd != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 18),
              onPressed: onAdd,
            ),
        ],
      ),
    );

    final open = repo.open;
    final projects = repo.projects;
    final favorites = projects.where((p) => p.favorite).toList();

    return SafeArea(
      child: ListView(
        key: const PageStorageKey('sidebar'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          ListTile(
            leading: repo.me == null ? null : MemberAvatar(repo.me!, size: 32),
            title: Text(
              app.team?.name ?? '',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(repo.me?.name ?? ''),
            onTap: () => onGo(const Nav('team')),
          ),
          item(const Nav('search'), Icons.search, 'Search'),
          item(
            const Nav('inbox'),
            Icons.inbox,
            'Inbox',
            color: const Color(0xFF246FE0),
            count: open
                .where((t) => t.projectId == null && t.parentId == null)
                .length,
          ),
          item(
            const Nav('today'),
            Icons.today,
            'Today',
            color: const Color(0xFF058527),
            count: repo.today().length,
          ),
          item(
            const Nav('upcoming'),
            Icons.calendar_month,
            'Upcoming',
            color: const Color(0xFF692EC2),
          ),
          item(
            const Nav('mine'),
            Icons.person_outline,
            'Assigned to me',
            color: const Color(0xFFEB8909),
            count: repo.meId == null ? 0 : repo.assignedTo(repo.meId!).length,
          ),
          item(
            const Nav('p1'),
            Icons.flag,
            'Priority 1',
            color: priorityColors[1],
            count: repo.withPriority(1).length,
          ),
          item(const Nav('completed'), Icons.check_circle_outline, 'Completed'),
          if (repo.meId != null)
            ListTile(
              dense: true,
              selected: nav == const Nav('rewards'),
              selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              leading: const Icon(
                Icons.emoji_events_outlined,
                color: Color(0xFFEB8909),
                size: 20,
              ),
              title: const Text('Rewards & punishments'),
              trailing: Text(
                '${repo.balance(repo.meId!)} pts',
                style: TextStyle(
                  color: repo.balance(repo.meId!) < 0
                      ? cs.error
                      : cs.onSurfaceVariant,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => onGo(const Nav('rewards')),
            ),
          if (favorites.isNotEmpty) ...[
            heading('Favorites'),
            for (final p in favorites)
              item(
                Nav('project', p.id),
                Icons.circle,
                p.name,
                color: Color(p.color),
                count: open
                    .where((t) => t.projectId == p.id && t.parentId == null)
                    .length,
              ),
          ],
          heading(
            'Projects',
            onAdd: () async {
              final n = await promptText(
                context,
                title: 'New project',
                action: 'Add',
              );
              if (n != null && n.trim().isNotEmpty) {
                onGo(Nav('project', repo.addProject(n)));
              }
            },
          ),
          for (final p in projects)
            item(
              Nav('project', p.id),
              Icons.tag,
              p.name,
              color: Color(p.color),
              count: open
                  .where((t) => t.projectId == p.id && t.parentId == null)
                  .length,
            ),
          if (repo.archivedProjects.isNotEmpty)
            ExpansionTile(
              dense: true,
              title: Text(
                'Archived',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
              children: [
                for (final p in repo.archivedProjects)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.archive_outlined,
                      color: Color(p.color),
                      size: 18,
                    ),
                    title: Text(p.name),
                    trailing: TextButton(
                      onPressed: () =>
                          repo.updateProject(p.id, {'archived': false}),
                      child: const Text('Restore'),
                    ),
                  ),
              ],
            ),
          heading(
            'Labels',
            onAdd: () async {
              final n = await promptText(
                context,
                title: 'New label',
                action: 'Add',
              );
              if (n != null && n.trim().isNotEmpty) {
                onGo(Nav('label', repo.ensureLabel(n.trim())));
              }
            },
          ),
          for (final l in repo.labels)
            item(
              Nav('label', l.id),
              Icons.label_outline,
              l.name,
              color: Color(l.color),
              count: repo.withLabel(l.id).length,
            ),
          heading(
            'Docs',
            onAdd: () async {
              final id = await newDoc(context, repo);
              if (id != null) onGo(Nav('doc', id));
            },
          ),
          item(
            const Nav('docs'),
            Icons.menu_book_outlined,
            'All documents',
            count: repo.docs.length,
          ),
          for (final d in repo.docs.where((d) => d.pinned))
            ListTile(
              dense: true,
              selected: nav == Nav('doc', d.id),
              selectedTileColor: cs.primaryContainer.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              leading: Text(d.emoji, style: const TextStyle(fontSize: 16)),
              title: Text(d.title, overflow: TextOverflow.ellipsis),
              onTap: () => onGo(Nav('doc', d.id)),
            ),
          const Divider(),
          item(const Nav('team'), Icons.hub_outlined, 'Team & devices'),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
