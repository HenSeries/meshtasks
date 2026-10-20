import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../app_state.dart';
import '../model/reminders.dart';
import '../model/repo.dart';

/// Desktop alarm: raises the window above everything, rings, and waits for
/// Done / Snooze. (Android has its own native full-screen alarm.)
Future<void> showAlarm(BuildContext context, AppState app, Reminder r) async {
  final ringer = _Ringer();
  final desktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  if (desktop) {
    try {
      await windowManager.show();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
    } catch (_) {}
  }
  unawaited(ringer.start());
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        icon: const Text('⏰', style: TextStyle(fontSize: 48)),
        title: Text(r.title, textAlign: TextAlign.center),
        content: Text(r.body, textAlign: TextAlign.center),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () {
              app.reminders.notifier.snooze(r);
              Navigator.pop(ctx);
            },
            child: const Text('Snooze 10 min'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF058527),
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.check),
            label: const Text('Done'),
            onPressed: () {
              app.repo.complete(r.taskId);
              Navigator.pop(ctx);
            },
          ),
        ],
      );
    },
  );
  ringer.stop();
  if (desktop) {
    try {
      await windowManager.setAlwaysOnTop(false);
    } catch (_) {}
  }
}

/// Plays the alarm sound with whatever the OS offers, a few times.
class _Ringer {
  Process? _p;
  bool _stopped = false;

  Future<void> start() async {
    try {
      final data = await rootBundle.load('assets/sounds/alarm.wav');
      final f = File('${Directory.systemTemp.path}/meshtasks-alarm.wav');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      final List<String> cmd;
      if (Platform.isLinux) {
        cmd = [await _first(['pw-play', 'paplay', 'aplay']) ?? 'aplay', f.path];
      } else if (Platform.isMacOS) {
        cmd = ['afplay', f.path];
      } else if (Platform.isWindows) {
        cmd = ['powershell', '-NoProfile', '-Command', "(New-Object Media.SoundPlayer '${f.path}').PlaySync()"];
      } else {
        return;
      }
      for (var i = 0; i < 8 && !_stopped; i++) {
        _p = await Process.start(cmd.first, cmd.sublist(1));
        await _p!.exitCode;
        if (!_stopped) await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  void stop() {
    _stopped = true;
    _p?.kill();
  }

  static Future<String?> _first(List<String> names) async {
    for (final n in names) {
      final r = await Process.run('sh', ['-c', 'command -v $n']);
      if (r.exitCode == 0) return n;
    }
    return null;
  }
}

/// Tells the user about penalties and punishments recorded in one go:
/// missed deadlines as a single banner, punishments in one dialog.
void showIncentives(BuildContext context, List<LedgerEntry> entries) {
  final penalties = entries.where((e) => e.kind == 'penalty').toList();
  final punishments = entries.where((e) => e.kind == 'punishment').toList();
  if (penalties.isNotEmpty) {
    final pts = penalties.fold<int>(0, (s, e) => s + e.points);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(penalties.length == 1
          ? 'Missed “${penalties.single.title}”: $pts pts'
          : 'Missed ${penalties.length} deadlines: $pts pts'),
    ));
  }
  if (punishments.isEmpty) return;
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Text('⚖️', style: TextStyle(fontSize: 44)),
      title: Text(punishments.length == 1 ? 'Punishment due' : '${punishments.length} punishments due'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final p in punishments)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(p.title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 17)),
          ),
        const SizedBox(height: 8),
        const Text('Mark them done in Rewards & punishments.', textAlign: TextAlign.center),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}
