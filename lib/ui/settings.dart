import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import 'common.dart';
import 'team.dart';

/// Backup & restore, and the permissions reminders and alarms need.
class SettingsView extends StatelessWidget {
  final AppState app;
  const SettingsView(this.app, {super.key});

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        BackupCard(app),
        AlertsCard(app),
      ]);
}

class BackupCard extends StatelessWidget {
  final AppState app;
  const BackupCard(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.backup_outlined, size: 20),
            const SizedBox(width: 8),
            Text('Backup & restore', style: Theme.of(context).textTheme.titleMedium),
          ]),
          const SizedBox(height: 6),
          Text(
            'One file with everything on this device: tasks, docs, points, your private key and '
            'the team key. Keep it somewhere safe (it unlocks your private tasks). Use it after '
            'reinstalling or on a new phone. Attached files aren’t inside: they come back from '
            'teammates’ devices.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              icon: const Icon(Icons.save_alt),
              label: const Text('Save backup'),
              onPressed: () => saveBackup(context, app),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('Restore backup'),
              onPressed: () => restoreBackup(context, app),
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<void> saveBackup(BuildContext context, AppState app) async {
  final now = DateTime.now();
  final name = 'meshtasks-backup-${now.year}-${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}.mtbackup';
  try {
    final uri = await FilePicker.saveFile(
      fileName: name,
      bytes: await app.backup(),
      dialogTitle: 'Save MeshTasks backup',
    );
    if (uri != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Backup saved: $name')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t save backup: $e')));
    }
  }
}

/// Picks a backup, confirms, stages it and closes the app; it opens with the
/// restored data next time.
Future<void> restoreBackup(BuildContext context, AppState app) async {
  final f = await FilePicker.pickFile(dialogTitle: 'Choose a MeshTasks backup');
  if (f == null || !context.mounted) return;
  if (app.hasTeam &&
      !await confirm(context, 'Replace this device’s data?',
          'Everything on this device is replaced by the backup. Changes made here that '
          'never synced to another device are lost.',
          action: 'Restore')) {
    return;
  }
  final String team;
  try {
    team = await app.stageRestore(await f.readAsBytes());
  } on FormatException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.restore, size: 40),
      title: const Text('Backup ready'),
      content: Text('MeshTasks will close now. Open it again to continue with team “$team”.'),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close MeshTasks'))],
    ),
  );
  await app.sync?.stop();
  exit(0);
}
