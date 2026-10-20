import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

/// Content-addressed file storage for attachments. Records refer to files by
/// their SHA-256, so identical files are stored once and a file can be
/// fetched from any peer that has it and checked on arrival.
///
/// Files are streamed (never held whole in memory), so videos work, and a
/// transfer interrupted halfway resumes where it stopped.
class BlobStore {
  final Directory dir;
  BlobStore(this.dir) {
    dir.createSync(recursive: true);
  }

  /// Largest attachment accepted.
  static const maxBytes = 1024 * 1024 * 1024; // 1 GB

  /// Bytes per network request when copying a file between devices.
  static const chunkBytes = 4 * 1024 * 1024;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String hashOf(List<int> bytes) => _hex(const DartSha256().hashSync(bytes).bytes);

  static bool isHash(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  File file(String hash) {
    if (!isHash(hash)) throw ArgumentError('bad blob hash');
    return File('${dir.path}/$hash');
  }

  File _part(String hash) => File('${file(hash).path}.part');

  bool has(String hash) => isHash(hash) && file(hash).existsSync();

  int? size(String hash) => has(hash) ? file(hash).lengthSync() : null;

  Uint8List? read(String hash) => has(hash) ? file(hash).readAsBytesSync() : null;

  /// Up to [length] bytes of a stored file starting at [offset].
  Future<Uint8List?> readRange(String hash, int offset, int length) async {
    if (!has(hash)) return null;
    final raf = await file(hash).open();
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  /// Stores [bytes] and returns their hash. Rejects data that doesn't match
  /// [expect] (a tampered or corrupted transfer).
  String put(List<int> bytes, {String? expect}) {
    _checkSize(bytes.length);
    final hash = hashOf(bytes);
    if (expect != null && expect != hash) throw StateError('blob hash mismatch');
    final f = file(hash);
    if (!f.existsSync()) {
      final tmp = File('${f.path}.tmp');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(f.path);
    }
    return hash;
  }

  /// Streams a file in (e.g. a video picked from the phone), hashing as it
  /// goes. Returns the hash and size.
  Future<(String, int)> putStream(Stream<List<int>> data) async {
    final tmp = File('${dir.path}/incoming-${DateTime.now().microsecondsSinceEpoch}.tmp');
    final out = tmp.openWrite();
    final sink = const DartSha256().newHashSink();
    var n = 0;
    try {
      await for (final chunk in data) {
        n += chunk.length;
        _checkSize(n);
        sink.add(chunk);
        out.add(chunk);
      }
      await out.close();
    } catch (_) {
      await out.close();
      if (tmp.existsSync()) tmp.deleteSync();
      rethrow;
    }
    sink.close();
    final hash = _hex(sink.hashBytes);
    if (has(hash)) {
      tmp.deleteSync();
    } else {
      tmp.renameSync(file(hash).path);
    }
    return (hash, n);
  }

  // ---- receiving from a peer, chunk by chunk ----

  /// Bytes of [hash] already received (resume point).
  int received(String hash) => _part(hash).existsSync() ? _part(hash).lengthSync() : 0;

  Future<void> appendChunk(String hash, List<int> chunk) async {
    _checkSize(received(hash) + chunk.length);
    await _part(hash).writeAsBytes(chunk, mode: FileMode.append, flush: true);
  }

  /// Verifies a fully received file and makes it available. A corrupted or
  /// tampered transfer is thrown away.
  Future<bool> finishReceive(String hash) async {
    final part = _part(hash);
    if (!part.existsSync()) return false;
    final sink = const DartSha256().newHashSink();
    await for (final chunk in part.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    if (_hex(sink.hashBytes) != hash) {
      if (part.existsSync()) part.deleteSync();
      throw StateError('blob hash mismatch');
    }
    part.renameSync(file(hash).path);
    return true;
  }

  static void _checkSize(int n) {
    if (n > maxBytes) {
      throw ArgumentError('File is larger than ${maxBytes ~/ (1024 * 1024)} MB');
    }
  }
}
