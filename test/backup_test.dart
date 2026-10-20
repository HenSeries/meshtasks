import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshtasks/app_state.dart';
import 'package:meshtasks/core/store.dart';
import 'package:meshtasks/core/team.dart';
import 'package:meshtasks/model/repo.dart';

void main() {
  test('backup → restore keeps everything, private tasks too, with a new device id', () async {
    final dir = Directory.systemTemp.createTempSync('mt-backup');
    final app = await AppState.forTest(Store.open(':memory:'), Team.create('Acme'));
    final repo = app.repo;
    repo.setMe(repo.addMember('Jorge'));
    repo.ensureMyKey();
    repo.addTask(title: 'Team task');
    final secret = repo.addTask(title: 'My secret', private: true);
    repo.addDoc('Handbook', body: '# Hi');
    final bytes = await app.backup();
    await app.sync!.stop();

    // A reinstalled device: its own (empty) database, then the restore.
    final path = '${dir.path}/meshtasks.db';
    Store.open(path).close();
    final fresh = await AppState.forTest(Store.open(':memory:'), Team.create('x'))
      ..dbPath = path;
    expect(await fresh.stageRestore(bytes), 'Acme');
    await fresh.sync!.stop();
    expect(AppState.applyStagedRestore(path), isTrue);

    final restored = Store.open(path);
    final r = Repo(restored);
    expect(r.tasks.map((t) => t.title), containsAll(['Team task', 'My secret']));
    expect(r.task(secret)!.isPrivate, isTrue); // key came along
    expect(r.docs.single.title, 'Handbook');
    expect(restored.getMeta('team_name'), 'Acme');
    expect(restored.nodeId, isNot(app.store.nodeId)); // never clones a device
    restored.close();
    dir.deleteSync(recursive: true);
  });

  test('a file that is not a backup is refused', () async {
    final dir = Directory.systemTemp.createTempSync('mt-backup');
    final app = await AppState.forTest(Store.open(':memory:'), Team.create('Acme'))
      ..dbPath = '${dir.path}/meshtasks.db';
    await app.sync!.stop();
    await expectLater(app.stageRestore('hello, I am a photo'.codeUnits), throwsFormatException);
    expect(File('${dir.path}/meshtasks.db.restore').existsSync(), isFalse);
    dir.deleteSync(recursive: true);
  });
}
