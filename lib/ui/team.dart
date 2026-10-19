import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/sync.dart';
import 'common.dart';

class OnboardingPage extends StatefulWidget {
  final AppState app;
  const OnboardingPage(this.app, {super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _name = TextEditingController();
  final _team = TextEditingController();
  final _code = TextEditingController();
  bool _join = false;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Enter your name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_join) {
        await widget.app.joinTeam(_code.text, _name.text);
      } else {
        await widget.app.createTeam(_team.text, _name.text);
      }
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(Icons.hub_outlined, size: 64, color: cs.primary),
              const SizedBox(height: 12),
              Text('MeshTasks',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text('Team tasks that live on your devices.\nNo server, no cloud. Devices sync directly.',
                  textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Create a team'), icon: Icon(Icons.group_add)),
                  ButtonSegment(value: true, label: Text('Join a team'), icon: Icon(Icons.login)),
                ],
                selected: {_join},
                onSelectionChanged: (s) => setState(() => _join = s.first),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Your name', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              if (!_join)
                TextField(
                  controller: _team,
                  decoration: const InputDecoration(labelText: 'Team name', border: OutlineInputBorder()),
                )
              else
                TextField(
                  controller: _code,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Invite code',
                    hintText: 'meshtasks1:…  (ask a teammate: Team → Invite)',
                    border: OutlineInputBorder(),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: TextStyle(color: cs.error)),
                ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _go,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_join ? 'Join team' : 'Create team'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Team members, devices in the mesh and invite code.
class TeamView extends StatelessWidget {
  final AppState app;
  const TeamView(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final sync = app.sync!;
    final cs = Theme.of(context).colorScheme;
    final peers = sync.peers.values.toList()
      ..sort((a, b) => (b.lastSeen ?? DateTime(0)).compareTo(a.lastSeen ?? DateTime(0)));
    final now = DateTime.now();

    String ago(DateTime? t) {
      if (t == null) return 'never';
      final d = now.difference(t);
      if (d.inSeconds < 60) return 'just now';
      if (d.inMinutes < 60) return '${d.inMinutes} min ago';
      if (d.inHours < 24) return '${d.inHours} h ago';
      return fmtDay(t, now);
    }

    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Invite someone', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Send this code to a teammate (chat, email…). Anyone with it can read and edit '
              'the team’s tasks, so share it privately.',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy invite code'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: await app.inviteCode()));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Invite code copied')));
                  }
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.visibility_outlined),
                label: const Text('Show'),
                onPressed: () async {
                  final code = await app.inviteCode();
                  if (!context.mounted) return;
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Invite code'),
                      content: SelectableText(code, style: const TextStyle(fontFamily: 'monospace')),
                      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
                    ),
                  );
                },
              ),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Text('This device', style: Theme.of(context).textTheme.titleMedium),
      ListTile(
        leading: const Icon(Icons.smartphone),
        title: Text(app.deviceName),
        subtitle: FutureBuilder(
          future: sync.localAddresses(),
          builder: (_, s) => Text(s.hasData && s.data!.isNotEmpty
              ? s.data!.join('  ·  ')
              : 'port ${sync.port}'),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.edit),
          tooltip: 'Rename device',
          onPressed: () async {
            final n = await promptText(context, title: 'Device name', initial: app.deviceName);
            if (n != null && n.trim().isNotEmpty) app.deviceName = n;
          },
        ),
      ),
      ListTile(
        leading: repo.me == null ? const Icon(Icons.person) : MemberAvatar(repo.me!, size: 28),
        title: Text('Signed in as ${repo.me?.name ?? '—'}'),
      ),
      _PrivateKeyCard(app),
      const Divider(height: 32),
      Text('Devices in the mesh', style: Theme.of(context).textTheme.titleMedium),
      Wrap(spacing: 8, children: [
        TextButton.icon(
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
          onPressed: () => sync.syncAll(),
        ),
        TextButton.icon(
          icon: const Icon(Icons.add_link),
          label: const Text('Add address'),
          onPressed: () async {
            final a = await promptText(context,
                title: 'Connect to a device',
                hint: '192.168.1.20 or 100.64.0.3:47800 (Tailscale)',
                action: 'Connect');
            if (a != null && a.trim().isNotEmpty) await sync.addAddress(a);
          },
        ),
      ]),
      if (peers.isEmpty && sync.pendingAddresses.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'No other devices yet. Devices on the same Wi-Fi find each other automatically. '
            'For other networks (e.g. over Tailscale or a VPN), add an address.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      for (final p in peers)
        ListTile(
          leading: Icon(Icons.circle, size: 12, color: p.online ? const Color(0xFF058527) : cs.outline),
          title: Text(p.name),
          subtitle: Text([
            'synced ${ago(p.lastSync)}',
            if (p.addresses.isNotEmpty) p.addresses.join(', '),
            if (p.lastError != null && !p.online) p.lastError!,
          ].join('  ·  ')),
          trailing: IconButton(
            icon: const Icon(Icons.link_off),
            tooltip: 'Forget device',
            onPressed: () => sync.forgetPeer(p.node),
          ),
        ),
      for (final a in sync.pendingAddresses)
        ListTile(
          leading: const Icon(Icons.hourglass_empty, size: 18),
          title: Text(a),
          subtitle: const Text('Trying to reach…'),
        ),
      const Divider(height: 32),
      Text('Members', style: Theme.of(context).textTheme.titleMedium),
      for (final m in repo.members)
        ListTile(
          leading: MemberAvatar(m, size: 32),
          title: Text(m.id == repo.meId ? '${m.name} (me)' : m.name),
          subtitle: Text('${repo.assignedTo(m.id).length} open tasks assigned'),
          trailing: IconButton(
            icon: const Icon(Icons.edit, size: 18),
            tooltip: 'Rename',
            onPressed: () async {
              final n = await promptText(context, title: 'Rename member', initial: m.name);
              if (n != null && n.trim().isNotEmpty) repo.renameMember(m.id, n);
            },
          ),
        ),
      const SizedBox(height: 24),
      Text(
        'Team “${app.team!.name}” · sync port ${sync.port} · discovery UDP ${SyncNode.defaultDiscoveryPort}',
        style: Theme.of(context).textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
      ),
    ]);
  }
}

/// Personal key for private tasks: show where it lives, copy it to another
/// of my devices, or paste it from one.
class _PrivateKeyCard extends StatelessWidget {
  final AppState app;
  const _PrivateKeyCard(this.app);

  @override
  Widget build(BuildContext context) {
    final repo = app.repo;
    final cs = Theme.of(context).colorScheme;
    final locked = repo.myKeyIsElsewhere;

    Future<void> paste() async {
      final code = await promptText(context,
          title: 'Use my key from another device',
          hint: 'meshtasks-key1:…',
          action: 'Link');
      if (code == null || code.trim().isEmpty) return;
      try {
        final id = repo.importKey(code);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Linked as ${repo.member(id)?.name ?? 'you'}. Private tasks unlocked.')));
        }
      } on FormatException catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        }
      }
    }

    Future<void> copy() async {
      final ok = await confirm(
        context,
        'Copy your private key?',
        'Paste it only on your own devices (Team & devices → Private tasks → Use key from '
            'another device). Anyone who has it can read your private tasks.',
        action: 'Copy',
        destructive: false,
      );
      if (!ok) return;
      await Clipboard.setData(ClipboardData(text: repo.exportMyKey()));
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Private key copied')));
      }
    }

    return Card(
      color: locked ? cs.errorContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(locked ? Icons.lock_outline : Icons.key, size: 20),
            const SizedBox(width: 8),
            Text('Private tasks', style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 6),
          Text(
            locked
                ? 'Your private tasks are locked on this device. Copy your key on a device where '
                    'you already use MeshTasks and paste it here.'
                : 'Tasks you mark private are encrypted with a key that only your devices hold. '
                    'Teammates’ devices store them but can’t read them. To see them on another '
                    'of your devices, copy this key there. If you lose every device with the key, '
                    'those tasks can’t be recovered.',
            style: TextStyle(color: locked ? cs.onErrorContainer : cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!locked && repo.meId != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy key for my other device'),
                onPressed: copy,
              ),
            (locked ? FilledButton.icon : OutlinedButton.icon)(
              icon: const Icon(Icons.download),
              label: const Text('Use key from another device'),
              onPressed: paste,
            ),
          ]),
        ]),
      ),
    );
  }
}
