import 'package:flutter/material.dart';

import '../app_state.dart';
import '../model/repo.dart';
import 'common.dart';

/// Points balance, rewards to buy, punishments, history, and the team board.
class RewardsView extends StatelessWidget {
  final AppState app;
  const RewardsView(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final me = repo.meId;
    final cs = Theme.of(context).colorScheme;
    if (me == null) return const Center(child: Text('Pick who you are in Team & devices first.'));
    final balance = repo.balance(me);
    final pending = repo.pendingIncentives(me);
    final history = repo.ledger(me).where((e) => e.points != 0).take(40).toList();
    final others = repo.members.where((m) => m.id != me).toList();

    Widget section(String title, {Widget? action}) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 6),
          child: Row(children: [
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ?action,
          ]),
        );

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        color: balance < 0 ? cs.errorContainer : cs.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            Text('$balance',
                style: Theme.of(context).textTheme.displayMedium!.copyWith(fontWeight: FontWeight.w700)),
            Text(balance < 0 ? 'points: below zero, punishments apply' : 'points',
                style: TextStyle(color: balance < 0 ? cs.onErrorContainer : cs.onPrimaryContainer)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.exposure),
                label: const Text('Adjust points'),
                onPressed: () => _adjust(context),
              ),
              FilterChip(
                avatar: Icon(repo.scorePublic(me) ? Icons.groups : Icons.lock_outline, size: 18),
                label: Text(repo.scorePublic(me) ? 'Team can see my score' : 'Score is private'),
                selected: repo.scorePublic(me),
                onSelected: (v) => _guard(context, () => repo.setScorePublic(v)),
              ),
            ]),
          ]),
        ),
      ),
      if (pending.isNotEmpty) ...[
        section('To do'),
        for (final e in pending)
          Card(
            child: ListTile(
              leading: Text(e.kind == 'punishment' ? '⚖️' : '🎁', style: const TextStyle(fontSize: 26)),
              title: Text(e.title),
              subtitle: Text(e.kind == 'punishment'
                  ? 'Punishment to carry out'
                  : e.kind == 'redeem'
                      ? 'Reward you bought'
                      : 'Reward you earned'),
              trailing: FilledButton.tonal(
                onPressed: () => repo.resolveIncentive(e.id),
                child: Text(e.kind == 'punishment' ? 'Done' : 'Enjoyed'),
              ),
            ),
          ),
      ],
      section('My rewards',
          action: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add'),
            onPressed: () => _addIncentive(context, reward: true),
          )),
      if (repo.rewards(me).isEmpty)
        _hint(context, 'Rewards you buy with points. E.g. “1 hour of gaming: 40 pts”.'),
      for (final r in repo.rewards(me))
        ListTile(
          leading: const Text('🎁', style: TextStyle(fontSize: 24)),
          title: Text(r.title),
          subtitle: Text('${r.cost} pts · ${r.isPrivate ? 'private' : 'shared'}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            FilledButton(
              onPressed: balance >= r.cost
                  ? () {
                      if (repo.redeem(r.id)) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Enjoy: ${r.title} (−${r.cost} pts)')));
                      }
                    }
                  : null,
              child: const Text('Redeem'),
            ),
            _menu(context, 'rewards', r),
          ]),
        ),
      section('My punishments',
          action: TextButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Add'),
            onPressed: () => _addIncentive(context, reward: false),
          )),
      if (repo.punishments(me).isEmpty)
        _hint(context,
            'While your balance is below zero, one of these applies each day. E.g. “No coffee tomorrow”.'),
      for (final p in repo.punishments(me))
        ListTile(
          leading: const Text('⚖️', style: TextStyle(fontSize: 24)),
          title: Text(p.title),
          subtitle: Text(p.isPrivate ? 'private' : 'shared'),
          trailing: _menu(context, 'punishments', p),
        ),
      if (others.isNotEmpty) ...[
        section('Team'),
        for (final m in others) _TeamRow(repo, m),
      ],
      if (history.isNotEmpty) ...[
        section('History'),
        for (final e in history)
          ListTile(
            dense: true,
            leading: Icon(_kindIcon(e.kind), color: e.points >= 0 ? const Color(0xFF058527) : cs.error),
            title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${_kindLabel(e.kind)} · ${fmtDay(e.at, repo.now())}'),
            trailing: Text('${e.points > 0 ? '+' : ''}${e.points}',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: e.points >= 0 ? const Color(0xFF058527) : cs.error)),
          ),
      ],
      const SizedBox(height: 16),
      Text(
        'How points work: finishing your task earns P1 10 · P2 7 · P3 5 · P4 3, plus 2 if on time. '
        'Missing a deadline (1 h grace) costs P1 8 · P2 6 · P3 4 · P4 2. '
        'Tasks count for you when they’re assigned to you, or unassigned and created by you.',
        style: Theme.of(context).textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
      ),
    ]);
  }

  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  static IconData _kindIcon(String k) => switch (k) {
        'earn' => Icons.check_circle_outline,
        'penalty' => Icons.timer_off_outlined,
        'redeem' => Icons.redeem,
        _ => Icons.tune,
      };

  static String _kindLabel(String k) => switch (k) {
        'earn' => 'Completed',
        'penalty' => 'Missed',
        'redeem' => 'Redeemed',
        _ => 'Adjusted',
      };

  void _guard(BuildContext context, void Function() f) {
    try {
      f();
    } on StateError catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _menu(BuildContext context, String table, Incentive i) => PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'share') _guard(context, () => app.repo.setIncentiveShared(table, i.id, i.isPrivate));
          if (v == 'delete') app.repo.deleteIncentive(table, i.id);
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'share', child: Text(i.isPrivate ? 'Share with the team' : 'Make private')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );

  Future<void> _adjust(BuildContext context) async {
    final pts = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Adjust points'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: pts,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            decoration: const InputDecoration(labelText: 'Points (use − to subtract)', hintText: '15 or -5'),
          ),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Why')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    final n = int.tryParse(pts.text.trim().replaceAll('−', '-'));
    if (ok == true && n != null && n != 0 && context.mounted) {
      _guard(context, () => app.repo.adjustPoints(n, note.text.trim().isEmpty ? 'Manual' : note.text.trim()));
    }
  }

  Future<void> _addIncentive(BuildContext context, {required bool reward}) async {
    final title = TextEditingController();
    final cost = TextEditingController(text: '30');
    var shared = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(reward ? 'New reward' : 'New punishment'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: title,
              autofocus: true,
              decoration: InputDecoration(
                  labelText: reward ? 'Reward' : 'Punishment',
                  hintText: reward ? 'Movie night' : 'No dessert today'),
            ),
            if (reward)
              TextField(
                controller: cost,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Cost in points'),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Share with the team'),
              subtitle: const Text('Teammates see it and can keep you accountable'),
              value: shared,
              onChanged: (v) => set(() => shared = v),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !context.mounted) return;
    _guard(context, () {
      if (reward) {
        app.repo.addReward(title.text, int.tryParse(cost.text.trim()) ?? 0, shared: shared);
      } else {
        app.repo.addPunishment(title.text, shared: shared);
      }
    });
  }
}

/// A teammate's shared score and shared rewards/punishments.
class _TeamRow extends StatelessWidget {
  final Repo repo;
  final Member m;
  const _TeamRow(this.repo, this.m);

  @override
  Widget build(BuildContext context) {
    final public = repo.scorePublic(m.id);
    final shared = [
      ...repo.rewards(m.id).map((r) => '🎁 ${r.title} (${r.cost})'),
      ...repo.punishments(m.id).map((p) => '⚖️ ${p.title}'),
      ...repo.pendingIncentives(m.id).where((e) => e.kind == 'punishment').map((e) => '⏳ owes: ${e.title}'),
    ];
    return ListTile(
      leading: MemberAvatar(m, size: 32),
      title: Text(m.name),
      subtitle: shared.isEmpty ? null : Text(shared.join('\n')),
      trailing: Text(public ? '${repo.balance(m.id)} pts' : '🔒',
          style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
