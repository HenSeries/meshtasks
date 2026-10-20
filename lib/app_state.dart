import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'core/blobs.dart';
import 'core/store.dart';
import 'core/sync.dart';
import 'core/team.dart';
import 'model/repo.dart';
import 'notify/notifier.dart';
import 'notify/service.dart';

/// Owns the local database, attachments, the team identity, the sync node
/// and reminders.
class AppState extends ChangeNotifier {
  final Store store;
  final Repo repo;
  final BlobStore blobs;
  late final ReminderService reminders;
  Team? team;
  SyncNode? sync;

  /// Database file ('' for in-memory test instances).
  String dbPath = '';

  AppState._(this.store, this.blobs, Notifier notifier) : repo = Repo(store) {
    reminders = ReminderService(repo, notifier);
  }

  static const _android = MethodChannel('meshtasks/net');

  /// For tests: an in-memory app already in [team], syncing on a random
  /// port without LAN discovery.
  @visibleForTesting
  static Future<AppState> forTest(Store store, Team team, {Directory? blobDir}) async {
    final s = AppState._(store,
        BlobStore(blobDir ?? Directory.systemTemp.createTempSync('meshtasks-blobs')), Notifier.none())
      .._saveTeam(team);
    await s._startSync(port: 0, discovery: false);
    return s;
  }

  static Future<AppState> load() async {
    // MESHTASKS_DB lets several instances run side by side on one machine.
    final override = Platform.environment['MESHTASKS_DB'];
    final String path;
    if (override != null && override.isNotEmpty) {
      path = override;
    } else {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      path = '${dir.path}/meshtasks.db';
    }
    applyStagedRestore(path);
    // Attachments live next to the database.
    final blobDir = Directory('${File(path).parent.path}/${File(path).uri.pathSegments.last}.files');
    final s = AppState._(Store.open(path), BlobStore(blobDir), Notifier.forPlatform())
      ..dbPath = path;
    final id = s.store.getMeta('team_id');
    if (id != null) {
      s.team = Team(id, s.store.getMeta('team_name') ?? 'Team',
          base64Url.decode(s.store.getMeta('team_secret')!));
      await s._startSync();
    }
    await s.reminders.start();
    return s;
  }

  bool get hasTeam => team != null;

  String get deviceName =>
      store.getMeta('device_name') ?? _defaultDeviceName();

  set deviceName(String v) {
    store.setMeta('device_name', v.trim());
    sync?.deviceName = v.trim();
    notifyListeners();
  }

  static String _defaultDeviceName() {
    try {
      final h = Platform.localHostname;
      if (h.isNotEmpty && h != 'localhost') return h;
    } catch (_) {}
    return Platform.operatingSystem;
  }

  Future<void> createTeam(String teamName, String myName) async {
    _saveTeam(Team.create(teamName.trim().isEmpty ? 'My team' : teamName.trim()));
    repo.setMe(repo.addMember(myName));
    repo.ensureMyKey();
    await _startSync();
    notifyListeners();
  }

  Future<void> joinTeam(String code, String myName) async {
    final (t, peers) = Team.parseInvite(code);
    _saveTeam(t);
    repo.setMe(repo.addMember(myName));
    repo.ensureMyKey();
    await _startSync();
    for (final p in peers) {
      await sync!.addAddress(p);
    }
    notifyListeners();
  }

  void _saveTeam(Team t) {
    team = t;
    store.setMeta('team_id', t.id);
    store.setMeta('team_name', t.name);
    store.setMeta('team_secret', base64Url.encode(t.secret));
  }

  Future<void> _startSync({int port = SyncNode.defaultPort, bool discovery = true}) async {
    if (Platform.isAndroid) {
      // Android drops broadcast packets unless a multicast lock is held.
      try {
        await _android.invokeMethod('acquireMulticastLock');
      } catch (_) {}
    }
    sync = SyncNode(store, team!,
        deviceName: deviceName,
        preferredPort: port,
        discovery: discovery,
        blobs: blobs,
        wantedBlobs: () => repo.wantedBlobs);
    await sync!.start();
    sync!.statusChanges.listen((_) => notifyListeners());
  }

  /// A restore staged last time replaces the database before it opens.
  static bool applyStagedRestore(String path) {
    final staged = File('$path.restore');
    if (!staged.existsSync()) return false;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$path$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    staged.renameSync(path);
    return true;
  }

  /// Everything on this device (tasks, docs, points, private keys, team
  /// key) as one file. Attachments aren't included: they sync back from
  /// teammates.
  Future<Uint8List> backup() async {
    final tmp = File('${Directory.systemTemp.path}/meshtasks-backup-${DateTime.now().microsecondsSinceEpoch}.db');
    try {
      store.backupTo(tmp.path);
      return await tmp.readAsBytes();
    } finally {
      if (tmp.existsSync()) tmp.deleteSync();
    }
  }

  /// Checks a backup and stages it to replace this device's data on the
  /// next start. Returns the backup's team name.
  Future<String> stageRestore(List<int> bytes) async {
    if (dbPath.isEmpty) throw StateError('No database file');
    final tmp = File('$dbPath.restore.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      final team = Store.prepareRestore(tmp.path);
      tmp.renameSync('$dbPath.restore');
      return team;
    } catch (_) {
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
  }

  Future<String> inviteCode() async =>
      team!.invite(await sync!.localAddresses());
}
