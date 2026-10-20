import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'blobs.dart';
import 'hlc.dart';
import 'store.dart';
import 'team.dart';

class Peer {
  final String node;
  String name;
  final Set<String> addresses;
  DateTime? lastSeen;
  DateTime? lastSync;
  String? lastError;

  Peer(this.node, this.name, [Set<String>? addresses])
      : addresses = addresses ?? {};

  bool get online =>
      lastSeen != null &&
      DateTime.now().difference(lastSeen!) < const Duration(minutes: 1);

  Map<String, Object?> toJson() =>
      {'node': node, 'name': name, 'addresses': addresses.toList()};

  factory Peer.fromJson(Map j) => Peer(j['node'] as String,
      j['name'] as String, {...(j['addresses'] as List).cast<String>()});
}

/// Peer-to-peer replication. Every device is both a server and a client:
///
/// * an HTTP endpoint (`POST /sync`) that accepts and returns encrypted
///   batches of [Cell]s,
/// * a UDP broadcast beacon so devices on the same LAN find each other,
/// * peer exchange, so learning one address is enough to reach the mesh
///   (needed across networks such as Tailscale, where broadcast doesn't go).
class SyncNode {
  final Store store;
  final Team team;
  final Envelope _env;
  String deviceName;
  final int preferredPort;
  final int discoveryPort;
  final bool discovery;

  /// Attachment files, and which ones this device wants (referenced by
  /// records but not yet downloaded).
  final BlobStore? blobs;
  final Set<String> Function()? wantedBlobs;

  HttpServer? _server;
  RawDatagramSocket? _udp;
  final _timers = <Timer>[];
  StreamSubscription? _localChanges;
  Timer? _pushDebounce;

  /// Peers keyed by node id.
  final Map<String, Peer> peers = {};

  /// Addresses added by hand whose node id we don't know yet.
  final Set<String> pendingAddresses = {};
  final _syncing = <String>{};

  /// Attachments being downloaded right now (one download per file).
  final _fetching = <String>{};
  final _status = StreamController<void>.broadcast();

  static const defaultPort = 47800;
  static const defaultDiscoveryPort = 47801;
  static const _pageSize = 2000;

  SyncNode(this.store, this.team,
      {required this.deviceName,
      this.preferredPort = defaultPort,
      this.discoveryPort = defaultDiscoveryPort,
      this.discovery = true,
      this.blobs,
      this.wantedBlobs})
      : _env = Envelope(team.secret) {
    _loadPeers();
  }

  int? get port => _server?.port;
  Stream<void> get statusChanges => _status.stream;

  Future<void> start() async {
    _server = await _bind();
    _server!.listen(_handle);
    if (discovery) await _startDiscovery();
    _localChanges = store.changes.listen((_) {
      _pushDebounce?.cancel();
      _pushDebounce =
          Timer(const Duration(milliseconds: 400), () => syncAll());
    });
    _timers.add(
        Timer.periodic(const Duration(seconds: 20), (_) => syncAll()));
    unawaited(syncAll());
  }

  Future<void> stop() async {
    for (final t in _timers) {
      t.cancel();
    }
    _pushDebounce?.cancel();
    await _localChanges?.cancel();
    _udp?.close();
    await _server?.close(force: true);
    _server = null;
  }

  Future<HttpServer> _bind() async {
    for (var p = preferredPort; p < preferredPort + 20; p++) {
      try {
        return await HttpServer.bind(InternetAddress.anyIPv4, p);
      } on SocketException {
        continue;
      }
    }
    return HttpServer.bind(InternetAddress.anyIPv4, 0);
  }

  // ---------------------------------------------------------------- peers

  void _loadPeers() {
    final raw = store.getMeta('peers');
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        final p = Peer.fromJson(j as Map);
        peers[p.node] = p;
      }
    }
    final pending = store.getMeta('pending_addresses');
    if (pending != null) {
      pendingAddresses.addAll((jsonDecode(pending) as List).cast<String>());
    }
  }

  void _savePeers() {
    store.setMeta('peers', jsonEncode([for (final p in peers.values) p]));
    store.setMeta('pending_addresses', jsonEncode(pendingAddresses.toList()));
    _status.add(null);
  }

  /// Add a `host:port` by hand (e.g. a Tailscale IP) and try it right away.
  Future<void> addAddress(String address) async {
    address = address.trim();
    if (!address.contains(':')) address = '$address:$defaultPort';
    pendingAddresses.add(address);
    _savePeers();
    await syncAddress(address);
  }

  void forgetPeer(String node) {
    peers.remove(node);
    store.setMeta('recv:$node', null);
    store.setMeta('sent:$node', null);
    _savePeers();
  }

  Peer _notePeer(String node, String name, String? address) {
    final p = peers.putIfAbsent(node, () => Peer(node, name));
    p.name = name;
    p.lastSeen = DateTime.now();
    if (address != null && p.addresses.add(address)) {
      pendingAddresses.remove(address);
      _savePeers();
    }
    _status.add(null);
    return p;
  }

  /// Our own reachable addresses, for invites and peer exchange.
  Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false)) {
      for (final a in i.addresses) {
        out.add('${a.address}:$port');
      }
    }
    return out;
  }

  // ----------------------------------------------------------------- client

  /// Sync with every known peer and pending address.
  Future<void> syncAll() async {
    final targets = <String>{
      for (final p in peers.values)
        if (p.addresses.isNotEmpty) p.node,
    };
    await Future.wait([
      for (final node in targets) syncPeer(node),
      for (final a in pendingAddresses.toList()) syncAddress(a),
    ]);
  }

  /// Try each known address of a peer until one works.
  Future<bool> syncPeer(String node) async {
    final p = peers[node];
    if (p == null) return false;
    // Most recently working address first would be nicer; order is stable.
    for (final a in p.addresses.toList()) {
      if (await syncAddress(a, expectNode: node)) return true;
    }
    return false;
  }

  Future<bool> syncAddress(String address, {String? expectNode}) async {
    if (!_syncing.add(address)) return false;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4);
    try {
      final hello =
          await _post(client, address, '/hello', _helloBody()) as Map;
      final node = hello['node'] as String;
      if (node == store.nodeId) {
        // Our own address (e.g. listed in an invite); never sync with self.
        pendingAddresses.remove(address);
        _savePeers();
        return false;
      }
      final peer = _notePeer(node, hello['name'] as String, address);
      _absorbAddresses(hello['peers']);

      var recv = store.getMeta('recv:$node') ?? '';
      var sent = store.getMeta('sent:$node') ?? '';
      bool more;
      do {
        final page = store.changesSince(sent, limit: _pageSize);
        final res = await _post(client, address, '/sync', {
          ..._helloBody(),
          'since': recv,
          'cells': [
            // The peer authored these; it already has them.
            for (final c in page.cells)
              if (Hlc.parse(c.hlc).node != node) c.toJson()
          ],
        }) as Map;
        store.merge([
          for (final c in res['cells'] as List)
            Cell.fromJson((c as Map).cast())
        ]);
        recv = res['cursor'] as String;
        sent = page.cursor;
        store.setMeta('recv:$node', recv);
        store.setMeta('sent:$node', sent);
        more = page.more || res['more'] == true;
      } while (more);
      await _fetchBlobs(client, address);

      peer
        ..lastSync = DateTime.now()
        ..lastError = null;
      _status.add(null);
      return true;
    } catch (e) {
      final p = expectNode == null ? null : peers[expectNode];
      if (p != null) {
        p.lastError = _describe(e);
        _status.add(null);
      }
      return false;
    } finally {
      client.close(force: true);
      _syncing.remove(address);
    }
  }

  /// Downloads referenced attachments this peer has and we don't, in
  /// chunks; an interrupted download resumes next time.
  Future<void> _fetchBlobs(HttpClient client, String address) async {
    final store = blobs, wanted = wantedBlobs;
    if (store == null || wanted == null) return;
    var got = false;
    for (final h in wanted()) {
      if (store.has(h) || !BlobStore.isHash(h) || !_fetching.add(h)) continue;
      try {
        while (true) {
          final offset = store.received(h);
          final res = await _post(client, address, '/blob',
              {..._helloBody(), 'hash': h, 'offset': offset}) as Map;
          final data = res['data'];
          if (data is! String) break; // this peer doesn't have it
          // Only append the bytes that belong exactly where we are.
          if (store.received(h) != offset) continue;
          if (data.isNotEmpty) await store.appendChunk(h, base64Decode(data));
          if (store.received(h) >= (res['size'] as int)) {
            got = await store.finishReceive(h) || got;
            break;
          }
          if (data.isEmpty) break;
        }
      } finally {
        _fetching.remove(h);
      }
    }
    if (got) _status.add(null);
  }

  Map<String, Object?> _helloBody() => {
        'node': store.nodeId,
        'name': deviceName,
        'port': port,
        'team': team.id,
      };

  Future<Object?> _post(HttpClient client, String address, String path,
      Object body) async {
    final req = await client
        .postUrl(Uri.parse('http://$address$path'))
        .timeout(const Duration(seconds: 5));
    req.headers.contentType = ContentType.binary;
    req.add(await _env.seal(body));
    final res = await req.close().timeout(const Duration(seconds: 30));
    final bytes = await res
        .fold<List<int>>([], (a, b) => a..addAll(b))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} from $address');
    }
    return _env.open(bytes);
  }

  void _absorbAddresses(Object? list) {
    if (list is! List) return;
    for (final e in list) {
      final m = e as Map;
      final node = m['node'] as String;
      if (node == store.nodeId) continue;
      final p = peers.putIfAbsent(node, () => Peer(node, m['name'] as String));
      p.addresses.addAll((m['addresses'] as List).cast<String>());
    }
    _savePeers();
  }

  static String _describe(Object e) => switch (e) {
        SocketException(:final message, :final osError) =>
          osError?.message ?? message,
        TimeoutException() => 'timed out',
        HttpException(:final message) when message.startsWith('HTTP 403') =>
          'rejected: device has a different team key',
        _ => e.toString(),
      };

  // ----------------------------------------------------------------- server

  Future<void> _handle(HttpRequest req) async {
    try {
      if (req.method != 'POST') {
        req.response
          ..statusCode = 200
          ..write('MeshTasks node\n');
        return;
      }
      final bytes = await req.fold<List<int>>([], (a, b) => a..addAll(b));
      final Map body;
      try {
        body = await _env.open(bytes) as Map;
      } catch (_) {
        req.response.statusCode = 403;
        return;
      }
      final from = body['node'] as String;
      final remotePort = body['port'] as int?;
      final remoteIp = req.connectionInfo?.remoteAddress.address;
      _notePeer(from, body['name'] as String,
          remotePort == null || remoteIp == null || remoteIp == '127.0.0.1'
              ? null
              : '$remoteIp:$remotePort');

      Object reply;
      switch (req.uri.path) {
        case '/hello':
          reply = {
            ..._helloBody(),
            'peers': [
              for (final p in peers.values)
                if (p.node != from) p.toJson()
            ],
          };
        case '/sync':
          store.merge([
            for (final c in body['cells'] as List)
              Cell.fromJson((c as Map).cast())
          ]);
          final page =
              store.changesSince(body['since'] as String, limit: _pageSize);
          reply = {
            'cells': [
              for (final c in page.cells)
                if (Hlc.parse(c.hlc).node != from) c.toJson()
            ],
            'cursor': page.cursor,
            'more': page.more,
          };
          peers[from]?.lastSync = DateTime.now();
        case '/blob':
          final h = body['hash'] as String;
          final size = blobs?.size(h);
          final offset = (body['offset'] as int?) ?? 0;
          final chunk = size == null
              ? null
              : await blobs!.readRange(h, offset, BlobStore.chunkBytes);
          reply = chunk == null
              ? {'missing': true}
              : {'size': size, 'data': base64Encode(chunk)};
        default:
          req.response.statusCode = 404;
          return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.binary
        ..add(await _env.seal(reply));
    } catch (e) {
      req.response.statusCode = 500;
    } finally {
      await req.response.close();
    }
  }

  // -------------------------------------------------------------- discovery

  Future<void> _startDiscovery() async {
    try {
      _udp = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, discoveryPort,
          reuseAddress: true, reusePort: Platform.isLinux || Platform.isMacOS);
    } on SocketException {
      return; // Another instance owns the port; manual peers still work.
    }
    _udp!.broadcastEnabled = true;
    _udp!.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final d = _udp!.receive();
      if (d == null) return;
      try {
        final m = jsonDecode(utf8.decode(d.data)) as Map;
        if (m['app'] != 'meshtasks' || m['tag'] != team.tag) return;
        final node = m['node'] as String;
        if (node == store.nodeId) return;
        final address = '${d.address.address}:${m['port']}';
        final known = peers[node];
        final isNew = known == null || !known.addresses.contains(address);
        final p = _notePeer(node, m['name'] as String, address);
        final stale = p.lastSync == null ||
            DateTime.now().difference(p.lastSync!) >
                const Duration(seconds: 30);
        if (isNew || stale) unawaited(syncAddress(address, expectNode: node));
      } catch (_) {/* not ours */}
    });
    void beacon() {
      final msg = utf8.encode(jsonEncode({
        'app': 'meshtasks',
        'tag': team.tag,
        'node': store.nodeId,
        'name': deviceName,
        'port': port,
      }));
      try {
        _udp?.send(msg, InternetAddress('255.255.255.255'), discoveryPort);
      } catch (_) {}
    }

    beacon();
    _timers.add(Timer.periodic(const Duration(seconds: 5), (_) => beacon()));
  }
}
