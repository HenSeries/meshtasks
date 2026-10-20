import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

/// Content-addressed file storage for attachments. Records refer to files by
/// their SHA-256, so identical files are stored once and a file can be
/// fetched from any peer that has it and checked on arrival.
class BlobStore {
  final Directory dir;
  BlobStore(this.dir) {
    dir.createSync(recursive: true);
  }

  /// Largest attachment accepted (it travels in one encrypted message).
  static const maxBytes = 25 * 1024 * 1024;

  static String hashOf(List<int> bytes) => const DartSha256()
      .hashSync(bytes)
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static bool isHash(String s) => RegExp(r'^[0-9a-f]{64}$').hasMatch(s);

  File file(String hash) {
    if (!isHash(hash)) throw ArgumentError('bad blob hash');
    return File('${dir.path}/$hash');
  }

  bool has(String hash) => isHash(hash) && file(hash).existsSync();

  Uint8List? read(String hash) => has(hash) ? file(hash).readAsBytesSync() : null;

  /// Stores [bytes] and returns their hash. Rejects data that doesn't match
  /// [expect] (a tampered or corrupted transfer).
  String put(List<int> bytes, {String? expect}) {
    if (bytes.length > maxBytes) {
      throw ArgumentError('File is larger than ${maxBytes ~/ (1024 * 1024)} MB');
    }
    final hash = hashOf(bytes);
    if (expect != null && expect != hash) throw StateError('blob hash mismatch');
    final f = file(hash);
    if (!f.existsSync()) {
      final tmp = File('${f.path}.part');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(f.path);
    }
    return hash;
  }
}
