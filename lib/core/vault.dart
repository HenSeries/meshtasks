import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:cryptography/cryptography.dart';

/// Personal encryption for private records.
///
/// A private record's fields replicate across the whole mesh like any other
/// (so a person's own devices stay in sync, even through a relay), but each
/// value is sealed with that person's key, which only their own devices hold.
/// Everyone else stores ciphertext they cannot read.
///
/// Each value is bound to its (table, id, field) as associated data, so a
/// sealed value can't be copied onto another field or record.
class Vault {
  static const prefix = 'enc1:';
  static final _aes = DartAesGcm.with256bits();

  final Map<String, SecretKeyData> _keys = {};
  final Map<String, Object?> _openCache = {};

  bool hasKey(String owner) => _keys.containsKey(owner);

  void addKey(String owner, List<int> key) {
    if (key.length != 32) throw ArgumentError('A personal key is 32 bytes');
    _keys[owner] = SecretKeyData(key);
  }

  static Uint8List newKey() {
    final rnd = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
  }

  /// Short public fingerprint, published on the member record so another
  /// device can check that a pasted key is the right one.
  static String fingerprint(List<int> key) {
    final h = const DartSha256().hashSync([...utf8.encode('meshtasks-key:'), ...key]);
    return h.bytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool isSealed(Object? v) => v is String && v.startsWith(prefix);

  List<int> _aad(String table, String id, String field) =>
      utf8.encode('$table\u0000$id\u0000$field');

  String seal(String owner, String table, String id, String field, Object? value) {
    final key = _keys[owner];
    if (key == null) throw StateError('No private key for $owner on this device');
    final box = _aes.encryptSync(utf8.encode(jsonEncode(value)),
        secretKeyData: key, aad: _aad(table, id, field));
    final sealed = '$prefix$owner:${base64Url.encode(box.concatenation())}';
    _openCache['$table\u0000$id\u0000$field\u0000$sealed'] = value;
    return sealed;
  }

  /// Owner of a sealed value (`enc1:<owner>:<data>`), or null if plain.
  static String? ownerOf(Object? stored) {
    if (!isSealed(stored)) return null;
    final s = stored as String;
    final end = s.indexOf(':', prefix.length);
    return end < 0 ? null : s.substring(prefix.length, end);
  }

  /// Returns the clear value (plain values pass through), or throws
  /// [VaultLocked] when this device doesn't hold the owner's key or the data
  /// was tampered with. The owner travels inside each value, so it stays
  /// readable even if the record's private flag changes concurrently.
  Object? open(String table, String id, String field, Object? stored) {
    if (!isSealed(stored)) return stored;
    final s = stored as String;
    // Cached per location, so a value copied elsewhere is still re-checked.
    final cacheKey = '$table\u0000$id\u0000$field\u0000$s';
    if (_openCache.containsKey(cacheKey)) return _openCache[cacheKey];
    final owner = ownerOf(s);
    final key = owner == null ? null : _keys[owner];
    if (key == null) throw const VaultLocked();
    try {
      final box = SecretBox.fromConcatenation(
          base64Url.decode(s.substring(prefix.length + owner!.length + 1)),
          nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength);
      final clear = jsonDecode(utf8.decode(
          _aes.decryptSync(box, secretKeyData: key, aad: _aad(table, id, field))));
      _openCache[cacheKey] = clear;
      return clear;
    } on SecretBoxAuthenticationError {
      throw const VaultLocked();
    }
  }

  // ---- moving a key between one person's devices ----

  static const _codePrefix = 'meshtasks-key1:';

  static String exportCode(String owner, List<int> key) =>
      '$_codePrefix$owner:${base64Url.encode(key).replaceAll('=', '')}';

  static (String owner, Uint8List key) parseCode(String code) {
    code = code.trim();
    if (!code.startsWith(_codePrefix)) {
      throw const FormatException('Not a MeshTasks personal key');
    }
    final parts = code.substring(_codePrefix.length).split(':');
    if (parts.length != 2) throw const FormatException('Damaged personal key');
    var b = parts[1];
    b = b.padRight((b.length + 3) ~/ 4 * 4, '=');
    final key = base64Url.decode(b);
    if (key.length != 32) throw const FormatException('Damaged personal key');
    return (parts[0], key);
  }
}

class VaultLocked implements Exception {
  const VaultLocked();
  @override
  String toString() => 'This device does not hold the key for this private item';
}
