import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Shared team identity. Every device that holds the secret can read and
/// write the team's data; there is no server and no account system.
class Team {
  final String id;
  final String name;
  final Uint8List secret;

  Team(this.id, this.name, this.secret);

  factory Team.create(String name) {
    final rnd = Random.secure();
    return Team(
      List.generate(12, (_) => rnd.nextInt(16).toRadixString(16)).join(),
      name,
      Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
    );
  }

  static const _prefix = 'meshtasks1:';

  /// Invite code to share with a new member. [peers] are `host:port`
  /// addresses the newcomer can try for the first sync.
  String invite(List<String> peers) =>
      _prefix +
      base64Url
          .encode(utf8.encode(jsonEncode({
            't': id,
            'n': name,
            'k': base64Url.encode(secret),
            'p': peers,
          })))
          .replaceAll('=', '');

  static (Team, List<String>) parseInvite(String code) {
    code = code.trim();
    if (!code.startsWith(_prefix)) {
      throw const FormatException('Not a MeshTasks invite code');
    }
    var b = code.substring(_prefix.length);
    b = b.padRight((b.length + 3) ~/ 4 * 4, '=');
    final j = jsonDecode(utf8.decode(base64Url.decode(b))) as Map;
    return (
      Team(j['t'] as String, j['n'] as String,
          base64Url.decode(j['k'] as String)),
      [for (final p in (j['p'] as List? ?? const [])) p as String],
    );
  }

  /// Public, non-secret tag used in LAN discovery beacons so devices only
  /// talk to members of their own team.
  late final String tag = _tag();

  String _tag() {
    var h = 0xcbf29ce484222325;
    for (final b in [...utf8.encode('tag:$id:'), ...secret.take(8)]) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16);
  }
}

/// Authenticated encryption of sync payloads with the team secret
/// (AES-256-GCM). A request that fails to decrypt is rejected, so the secret
/// doubles as access control.
class Envelope {
  final SecretKey _key;
  static final _aes = AesGcm.with256bits();

  Envelope(Uint8List secret) : _key = SecretKey(secret);

  Future<Uint8List> seal(Object? json) async {
    final box = await _aes.encrypt(utf8.encode(jsonEncode(json)),
        secretKey: _key);
    return box.concatenation();
  }

  Future<Object?> open(List<int> data) async {
    final box = SecretBox.fromConcatenation(data,
        nonceLength: _aes.nonceLength, macLength: _aes.macAlgorithm.macLength);
    final clear = await _aes.decrypt(box, secretKey: _key);
    return jsonDecode(utf8.decode(clear));
  }
}
