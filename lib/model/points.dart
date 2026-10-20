part of 'repo.dart';

/// What finishing a task earned: points and, if it was on time, the task's
/// self-set reward.
class Completion {
  final int points;
  final String? reward;
  const Completion(this.points, this.reward);
}

/// One line in a member's points ledger.
class LedgerEntry extends Entity {
  LedgerEntry(super.r);
  String? get member => (r['member'] ?? r['owner']) as String?;

  /// earn | penalty | redeem | manual | reward | punishment
  String get kind => (r['kind'] as String?) ?? 'manual';
  int get points => (r['points'] as int?) ?? 0;
  String get title => (r['title'] as String?) ?? '';
  String? get taskId => r['taskId'] as String?;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch((r['at'] as int?) ?? 0);

  /// For rewards and punishments: still to enjoy / to carry out.
  bool get pending => r['status'] == 'pending';
  bool get isPrivate => r['owner'] != null;
}

/// A reward you can buy with points, or a punishment that applies when
/// your balance drops below zero. Belongs to one member; private (sealed)
/// or shared with the team.
class Incentive extends Entity {
  Incentive(super.r);
  String? get member => (r['member'] ?? r['owner']) as String?;
  String get title => (r['title'] as String?) ?? '';
  int get cost => (r['cost'] as int?) ?? 0;
  bool get isPrivate => r['owner'] != null;
}

/// Scoring rules. Kept simple so people can predict them.
class PointRules {
  static const base = {1: 10, 2: 7, 3: 5, 4: 3};
  static const onTimeBonus = 2;
  static const penalty = {1: -8, 2: -6, 3: -4, 4: -2};

  /// How long after the due moment a task counts as missed. The slack also
  /// lets a completion made on another device sync in before we penalize.
  static const grace = Duration(hours: 1);
}

extension Points on Repo {
  // ---------------------------------------------------------- visibility

  /// Whether a member shares their score and history with the team.
  bool scorePublic(String memberId) => store.row('members', memberId)?['scorePublic'] == true;

  /// Owner to seal my records with, or null when they're shared.
  String? _sealFor(String me, {required bool shared}) => shared ? null : ensureMyKey();

  /// Writes a ledger/catalog record for [me], sealed unless [shared].
  void _putMine(String table, String id, String me, Map<String, Object?> fields,
      {required bool shared}) {
    final owner = _sealFor(me, shared: shared);
    _putAs(table, id, {...fields, 'owner': owner, 'member': shared ? me : null}, owner);
  }

  /// Re-seals (or un-seals) every field of an existing record.
  void _reseal(String table, String id, String me, {required bool shared}) {
    final r = store.row(table, id);
    if (r == null) return;
    final open = _open(table, r);
    if (open == null) return;
    final fields = Map<String, Object?>.of(open)
      ..remove('id')
      ..remove('owner')
      ..remove('member');
    _putMine(table, id, me, fields, shared: shared);
  }

  void setScorePublic(bool shared) {
    final me = meId;
    if (me == null) return;
    store.put('members', me, {'scorePublic': shared});
    for (final e in ledger(me, includeDeleted: true)) {
      _reseal('ledger', e.id, me, shared: shared);
    }
  }

  // -------------------------------------------------------------- ledger

  List<LedgerEntry> ledger(String memberId, {bool includeDeleted = false}) => store
      .rows('ledger', includeDeleted: includeDeleted)
      .values
      .map((r) => _open('ledger', r))
      .whereType<Map<String, Object?>>()
      .map(LedgerEntry.new)
      .where((e) => e.member == memberId)
      .toList()
    ..sort((a, b) => b.at.compareTo(a.at));

  int balance(String memberId) => ledger(memberId).fold(0, (s, e) => s + e.points);

  /// Pending rewards to enjoy and punishments to carry out.
  List<LedgerEntry> pendingIncentives(String memberId) =>
      ledger(memberId).where((e) => e.pending).toList();

  /// Can this device write my points? (Not before my private key is here,
  /// unless my score is shared.)
  bool get canScore {
    final me = meId;
    return me != null && (hasMyKey || scorePublic(me) || !myKeyIsElsewhere);
  }

  bool _hasEntry(String id) => store.row('ledger', id) != null;

  /// Writes an entry with a deterministic [id], so my devices computing the
  /// same event independently produce one record, not duplicates.
  void _entry(String id, String me,
      {required String kind,
      required int points,
      required String title,
      String? taskId,
      String? status,
      DateTime? at,
      bool revive = false}) {
    _putMine('ledger', id, me, {
      'kind': kind,
      'points': points,
      'title': title,
      'taskId': taskId,
      'status': status,
      'at': (at ?? now()).millisecondsSinceEpoch,
      // Only a redone completion revives its entry. Penalties never do, so a
      // cancellation from another device always wins over a late penalty.
      if (revive) 'deleted': false,
    }, shared: scorePublic(me));
  }

  /// Marks an entry deleted, even one this device hasn't seen yet: the
  /// marker cancels it whenever it arrives from another device.
  void _deleteEntry(String id) => store.put('ledger', id, {'deleted': true});

  static String _occurrence(Task t, String? due) =>
      t.recur == null ? t.id : '${t.id}:${due ?? ''}';

  Completion _scoreCompletion(Task t, DateTime at) {
    final me = meId;
    if (me == null || !t.countsFor(me) || t.done || !canScore) return const Completion(0, null);
    final dueKey = t.r['due'] as String?;
    final occ = _occurrence(t, dueKey);
    final onTime = t.due != null && !t.isOverdue(at);
    final pts = PointRules.base[t.priority]! + (onTime ? PointRules.onTimeBonus : 0);
    _entry('earn:$occ', me,
        kind: 'earn', points: pts, title: t.title, taskId: t.id, at: at, revive: true);
    String? reward;
    if (onTime) {
      // Finished on time: cancel a penalty another of my devices may have
      // recorded before this completion reached it.
      _deleteEntry('pen:$occ');
      _deleteEntry('tpun:$occ');
      if (t.reward.trim().isNotEmpty) {
        reward = t.reward.trim();
        _entry('trew:$occ', me,
            kind: 'reward', points: 0, title: reward, taskId: t.id, status: 'pending', at: at, revive: true);
      }
    }
    return Completion(pts, reward);
  }

  void _unscore(Task t, String? due) {
    final occ = _occurrence(t, due);
    for (final id in ['earn:$occ', 'trew:$occ']) {
      if (_hasEntry(id)) _deleteEntry(id);
    }
  }

  /// Records penalties for my missed tasks and, while my balance is below
  /// zero, one punishment per day. Safe to run often and on every device.
  /// Returns the entries it created (for popups).
  List<LedgerEntry> evaluate() {
    final me = meId;
    if (me == null || !canScore) return const [];
    final t0 = now();
    final created = <String>[];
    for (final t in open) {
      if (!t.countsFor(me) || t.due == null) continue;
      final due = t.due!;
      final missedAt = due.hasTime ? due.moment.add(PointRules.grace) : addDays(due.date, 1);
      if (t0.isBefore(missedAt)) continue;
      final occ = _occurrence(t, t.r['due'] as String?);
      if (!_hasEntry('pen:$occ')) {
        _entry('pen:$occ', me,
            kind: 'penalty', points: PointRules.penalty[t.priority]!, title: t.title, taskId: t.id);
        created.add('pen:$occ');
      }
      if (t.punishment.trim().isNotEmpty && !_hasEntry('tpun:$occ')) {
        _entry('tpun:$occ', me,
            kind: 'punishment', points: 0, title: t.punishment.trim(), taskId: t.id, status: 'pending');
        created.add('tpun:$occ');
      }
    }
    final mine = punishments(me);
    if (balance(me) < 0 && mine.isNotEmpty) {
      final day = dayOf(t0);
      final id = 'zpun:$me:${Due(day)}';
      if (!_hasEntry(id)) {
        // Same pick on every device: rotate through the list by date.
        final sorted = [...mine]..sort((a, b) => a.id.compareTo(b.id));
        final pick = sorted[day.difference(DateTime(2020)).inDays % sorted.length];
        _entry(id, me, kind: 'punishment', points: 0, title: pick.title, status: 'pending');
        created.add(id);
      }
    }
    return [
      for (final id in created)
        if (_open('ledger', store.row('ledger', id)!) case final r?) LedgerEntry(r)
    ];
  }

  void resolveIncentive(String entryId) => _put('ledger', entryId, {'status': 'done'});

  /// Self-granted points (positive or negative) with a note.
  void adjustPoints(int points, String note) {
    final me = meId;
    if (me == null) return;
    _entry('man:${Store.newId()}', me, kind: 'manual', points: points, title: note);
  }

  // ------------------------------------------------- rewards & punishments

  List<Incentive> _incentives(String table, String? memberId) => store
      .rows(table)
      .values
      .map((r) => _open(table, r))
      .whereType<Map<String, Object?>>()
      .map(Incentive.new)
      .where((i) => memberId == null || i.member == memberId)
      .toList()
    ..sort((a, b) => a.cost.compareTo(b.cost));

  /// Rewards [memberId] can buy (all visible ones when null).
  List<Incentive> rewards(String? memberId) => _incentives('rewards', memberId);
  List<Incentive> punishments(String? memberId) => _incentives('punishments', memberId);

  String addReward(String title, int cost, {bool shared = false}) {
    final id = Store.newId();
    _putMine('rewards', id, meId!, {'title': title.trim(), 'cost': cost}, shared: shared);
    return id;
  }

  String addPunishment(String title, {bool shared = false}) {
    final id = Store.newId();
    _putMine('punishments', id, meId!, {'title': title.trim()}, shared: shared);
    return id;
  }

  void setIncentiveShared(String table, String id, bool shared) =>
      _reseal(table, id, meId!, shared: shared);

  void deleteIncentive(String table, String id) => store.put(table, id, {'deleted': true});

  /// Spends points on a reward. Returns false when the balance is too low.
  bool redeem(String rewardId) {
    final me = meId;
    final r = rewards(me).where((x) => x.id == rewardId).firstOrNull;
    if (me == null || r == null || balance(me) < r.cost) return false;
    _entry('red:${Store.newId()}', me,
        kind: 'redeem', points: -r.cost, title: r.title, status: 'pending');
    return true;
  }
}
