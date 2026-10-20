import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../model/reminders.dart';

/// Something the user did on a notification while the app wasn't looking.
class NotifAction {
  final String type; // 'complete'
  final String taskId;
  final DateTime at;
  const NotifAction(this.type, this.taskId, this.at);
}

/// Delivers reminders and team-activity notifications on this platform.
abstract class Notifier {
  static Notifier forPlatform() {
    if (Platform.isAndroid) return AndroidNotifier();
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) return DesktopNotifier();
    return Notifier.none();
  }

  factory Notifier.none() = _NoNotifier;

  Future<void> init();

  /// Replaces the scheduled reminders with [reminders].
  Future<void> schedule(List<Reminder> reminders);

  /// Shows a notification now (assignments, comments, points…).
  Future<void> show(int id, String title, String body, {String? taskId});

  /// Done/snooze taps made outside the app, oldest first.
  Future<List<NotifAction>> takeActions();

  /// Task the app was opened for (tapped notification), once.
  Future<String?> takeLaunchTask();

  /// Alarm reminders the app itself must present (desktop).
  Stream<Reminder> get alarms;

  /// Tasks opened by clicking a notification while the app runs.
  Stream<String> get opened;

  /// Permission name → granted. Empty where nothing needs granting.
  Future<Map<String, bool>> permissions();
  Future<void> request(String permission);

  void snooze(Reminder r, {int minutes = 10});
}

class _NoNotifier implements Notifier {
  @override
  Future<void> init() async {}
  @override
  Future<void> schedule(List<Reminder> reminders) async {}
  @override
  Future<void> show(int id, String title, String body, {String? taskId}) async {}
  @override
  Future<List<NotifAction>> takeActions() async => const [];
  @override
  Future<String?> takeLaunchTask() async => null;
  @override
  Stream<Reminder> get alarms => const Stream.empty();
  @override
  Stream<String> get opened => const Stream.empty();
  @override
  Future<Map<String, bool>> permissions() async => const {};
  @override
  Future<void> request(String permission) async {}
  @override
  void snooze(Reminder r, {int minutes = 10}) {}
}

/// Android: everything is native (AlarmManager, notifications with
/// Done/Snooze, the full-screen alarm over other apps); see
/// android/app/src/main/kotlin/.../Reminders.kt.
class AndroidNotifier implements Notifier {
  static const _ch = MethodChannel('meshtasks/alarms');

  @override
  Future<void> init() async {}

  @override
  Future<void> schedule(List<Reminder> reminders) =>
      _ch.invokeMethod('schedule', jsonEncode([for (final r in reminders) r.toJson()]));

  @override
  Future<void> show(int id, String title, String body, {String? taskId}) =>
      _ch.invokeMethod('show', {'id': id, 'title': title, 'body': body, 'taskId': taskId});

  @override
  Future<List<NotifAction>> takeActions() async {
    final raw = await _ch.invokeMethod<String>('takeActions') ?? '[]';
    return [
      for (final a in jsonDecode(raw) as List)
        NotifAction(a['type'] as String, a['taskId'] as String,
            DateTime.fromMillisecondsSinceEpoch(a['at'] as int)),
    ];
  }

  @override
  Future<String?> takeLaunchTask() => _ch.invokeMethod<String>('takeLaunchTask');

  @override
  Stream<Reminder> get alarms => const Stream.empty();

  @override
  Stream<String> get opened => const Stream.empty();

  @override
  Future<Map<String, bool>> permissions() async =>
      (await _ch.invokeMapMethod<String, bool>('permissions')) ?? const {};

  @override
  Future<void> request(String permission) => _ch.invokeMethod('request', permission);

  @override
  void snooze(Reminder r, {int minutes = 10}) {}
}

/// Linux / Windows / macOS: reminders fire while the app is running (it
/// keeps running in the background like a chat app). Alarms bring the
/// window to the front and ring; see ui/alarm.dart.
class DesktopNotifier implements Notifier {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _alarms = StreamController<Reminder>.broadcast();
  final _opened = StreamController<String>.broadcast();
  List<Reminder> _queue = [];
  final List<Reminder> _snoozed = [];
  Timer? _timer;
  bool _ready = false;

  @override
  Future<void> init() async {
    try {
      _ready = await _plugin.initialize(
            settings: InitializationSettings(
              linux: const LinuxInitializationSettings(defaultActionName: 'Open'),
              macOS: const DarwinInitializationSettings(),
              windows: WindowsInitializationSettings(
                appName: 'MeshTasks',
                appUserModelId: 'dev.henseries.meshtasks',
                guid: '6e3b1c2a-4d7f-4b8e-9a51-3c2d8f0e7a11',
              ),
            ),
            onDidReceiveNotificationResponse: (r) {
              final task = r.payload;
              if (task != null && task.isNotEmpty) _opened.add(task);
            },
          ) ??
          false;
    } catch (_) {
      _ready = false; // no notification daemon: in-app alarms still work
    }
  }

  @override
  Future<void> schedule(List<Reminder> reminders) async {
    final now = DateTime.now();
    _snoozed.removeWhere((r) => !r.at.isAfter(now));
    _queue = [...reminders, ..._snoozed]..sort((a, b) => a.at.compareTo(b.at));
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    final now = DateTime.now();
    _queue.removeWhere((r) => !r.at.isAfter(now.subtract(const Duration(seconds: 30))));
    if (_queue.isEmpty) return;
    final next = _queue.first;
    // Re-check at least hourly so sleep/clock changes don't drift us.
    var wait = next.at.difference(now);
    if (wait > const Duration(hours: 1)) wait = const Duration(hours: 1);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _fire);
  }

  void _fire() {
    final now = DateTime.now();
    final due = _queue.where((r) => !r.at.isAfter(now)).toList();
    _queue.removeWhere(due.contains);
    _snoozed.removeWhere(due.contains);
    for (final r in due) {
      show(r.id, r.alarm ? '⏰ ${r.title}' : r.title, r.body, taskId: r.taskId);
      if (r.alarm) _alarms.add(r);
    }
    _arm();
  }

  @override
  Future<void> show(int id, String title, String body, {String? taskId}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        payload: taskId,
        notificationDetails: const NotificationDetails(
          linux: LinuxNotificationDetails(),
          macOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  @override
  void snooze(Reminder r, {int minutes = 10}) {
    final again = Reminder(r.id, r.taskId, DateTime.now().add(Duration(minutes: minutes)),
        r.title, r.body, r.alarm);
    _snoozed.add(again);
    _queue = [..._queue, again]..sort((a, b) => a.at.compareTo(b.at));
    _arm();
  }

  @override
  Future<List<NotifAction>> takeActions() async => const [];
  @override
  Future<String?> takeLaunchTask() async => null;
  @override
  Stream<Reminder> get alarms => _alarms.stream;
  @override
  Stream<String> get opened => _opened.stream;
  @override
  Future<Map<String, bool>> permissions() async => const {};
  @override
  Future<void> request(String permission) async {}
}
