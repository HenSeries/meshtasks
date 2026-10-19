/// Hybrid Logical Clock.
///
/// Timestamps serialize to a fixed-width string so that plain string
/// comparison gives the same order as comparing (millis, counter, node):
///   `000001760000000000-0000-<nodeId>`
class Hlc implements Comparable<Hlc> {
  final int millis;
  final int counter;
  final String node;

  const Hlc(this.millis, this.counter, this.node);

  static const zero = Hlc(0, 0, '');

  /// Max tolerated clock skew of a remote timestamp before we reject it.
  static const maxDrift = Duration(minutes: 5);

  factory Hlc.parse(String s) {
    final first = s.indexOf('-');
    final second = s.indexOf('-', first + 1);
    return Hlc(
      int.parse(s.substring(0, first)),
      int.parse(s.substring(first + 1, second), radix: 16),
      s.substring(second + 1),
    );
  }

  @override
  String toString() =>
      '${millis.toString().padLeft(15, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-$node';

  @override
  int compareTo(Hlc other) {
    if (millis != other.millis) return millis.compareTo(other.millis);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return node.compareTo(other.node);
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(millis, counter, node);
}

/// A mutable clock owned by one node.
class HlcClock {
  final String node;
  Hlc _last;
  final int Function() _now;

  HlcClock(this.node, {Hlc? last, int Function()? now})
      : _last = last ?? Hlc(0, 0, node),
        _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  Hlc get last => _last;

  /// Timestamp for a local event.
  Hlc send() {
    final wall = _now();
    if (wall > _last.millis) {
      _last = Hlc(wall, 0, node);
    } else {
      _last = Hlc(_last.millis, _last.counter + 1, node);
    }
    return _last;
  }

  /// Advance the clock after observing a remote timestamp.
  void receive(Hlc remote) {
    final wall = _now();
    if (remote.millis - wall > HlcClock.maxDriftMs) {
      throw StateError(
          'Remote clock is ${(remote.millis - wall) ~/ 1000}s ahead; '
          'check the date/time on node ${remote.node}');
    }
    final millis = [wall, _last.millis, remote.millis].reduce(
        (a, b) => a > b ? a : b);
    int counter;
    if (millis == _last.millis && millis == remote.millis) {
      counter = (_last.counter > remote.counter
              ? _last.counter
              : remote.counter) +
          1;
    } else if (millis == _last.millis) {
      counter = _last.counter + 1;
    } else if (millis == remote.millis) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    _last = Hlc(millis, counter, node);
  }

  static final maxDriftMs = Hlc.maxDrift.inMilliseconds;
}
