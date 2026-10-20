import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/store.dart';
import '../core/vault.dart';
import 'dates.dart';
import 'quick_add.dart';

part 'docs.dart';
part 'points.dart';

const palette = [
  0xFFDB4035, 0xFFFF9933, 0xFFFAD000, 0xFF7ECC49, 0xFF299438,
  0xFF6ACCBC, 0xFF158FAD, 0xFF14AAF5, 0xFF4073FF, 0xFF884DFF,
  0xFFAF38EB, 0xFFEB96EB, 0xFFE05194, 0xFF808080, 0xFFB8256F,
];

abstract class Entity {
  final Map<String, Object?> r;
  Entity(this.r);
  String get id => r['id'] as String;
  num get order => (r['order'] as num?) ?? 0;
}

class Member extends Entity {
  Member(super.r);
  String get name => (r['name'] as String?) ?? 'Someone';
  int get color => (r['color'] as int?) ?? palette[id.hashCode % palette.length];
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0].toUpperCase()).join();
  }
}

class Project extends Entity {
  Project(super.r);
  String get name => (r['name'] as String?) ?? 'Untitled';
  int get color => (r['color'] as int?) ?? palette[13];
  bool get archived => r['archived'] == true;
  bool get favorite => r['favorite'] == true;
}

class Section extends Entity {
  Section(super.r);
  String get name => (r['name'] as String?) ?? '';
  String? get projectId => r['projectId'] as String?;
}

class Label extends Entity {
  Label(super.r);
  String get name => (r['name'] as String?) ?? '';
  int get color => (r['color'] as int?) ?? palette[13];
}

class Comment extends Entity {
  Comment(super.r);
  String get taskId => r['taskId'] as String;
  String get text => (r['text'] as String?) ?? '';
  String? get author => r['author'] as String?;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch((r['at'] as int?) ?? 0);
}

class Task extends Entity {
  Task(super.r);
  String get title => (r['title'] as String?) ?? '';
  String get description => (r['description'] as String?) ?? '';
  String? get projectId => r['projectId'] as String?;
  String? get sectionId => r['sectionId'] as String?;
  String? get parentId => r['parentId'] as String?;
  int get priority => (r['priority'] as int?) ?? 4;
  Due? get due => Due.tryParse(r['due']);
  Recurrence? get recur => Recurrence.tryParse(r['recur']);
  List<String> get labels => [...((r['labels'] as List?) ?? const []).cast<String>()];
  String? get assignee => r['assignee'] as String?;
  bool get done => r['done'] == true;
  DateTime? get doneAt => r['doneAt'] == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(r['doneAt'] as int);
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch((r['createdAt'] as int?) ?? 0);
  String? get createdBy => r['createdBy'] as String?;

  /// Member whose personal key seals this task; null for team-visible tasks.
  String? get owner => r['owner'] as String?;
  bool get isPrivate => owner != null;

  /// Minutes before the due time to remind; null means the default
  /// (at the due time for timed tasks, none for all-day ones).
  List<int>? get reminders => (r['reminders'] as List?)?.cast<int>();

  /// Remind like an alarm: full screen, over other apps, with sound.
  bool get alarm => r['alarm'] == true;

  /// Self-set incentive for finishing on time / penalty for missing it.
  String get reward => (r['reward'] as String?) ?? '';
  String get punishment => (r['punishment'] as String?) ?? '';

  /// Whether this task is [memberId]'s responsibility (for reminders and
  /// points): assigned to them, or unassigned and created by them.
  bool countsFor(String? memberId) =>
      memberId != null &&
      (assignee == memberId || (assignee == null && createdBy == memberId));

  bool isOverdue(DateTime now) {
    final d = due;
    if (d == null || done) return false;
    return d.hasTime ? d.moment.isBefore(now) : d.date.isBefore(dayOf(now));
  }
}

/// Typed views and operations over the replicated [Store].
class Repo extends ChangeNotifier {
  final Store store;
  final Vault vault = Vault();
  late final StreamSubscription _sub;
  DateTime Function() now;

  Repo(this.store, {DateTime Function()? now}) : now = now ?? DateTime.now {
    store.metaWithPrefix('pkey:').forEach(
        (k, v) => vault.addKey(k.substring('pkey:'.length), base64Url.decode(v)));
    _sub = store.changes.listen((_) => notifyListeners());
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  // ------------------------------------------------------------------ me

  String? get meId => store.getMeta('me');
  Member? get me => meId == null ? null : member(meId!);
  void setMe(String memberId) {
    store.setMeta('me', memberId);
    notifyListeners();
  }

  // -------------------------------------------------------- private keys

  bool get hasMyKey => meId != null && vault.hasKey(meId!);

  /// True when my member already has a key elsewhere that this device lacks:
  /// it must be imported from one of my other devices before going private.
  bool get myKeyIsElsewhere =>
      !hasMyKey && me?.r['keyId'] != null;

  /// Makes sure this device holds my personal key, creating it on first use.
  /// Returns my member id.
  String ensureMyKey() {
    final me = meId;
    if (me == null) throw StateError('Pick who you are first');
    if (vault.hasKey(me)) return me;
    if (myKeyIsElsewhere) {
      throw StateError('Your private key lives on another of your devices. '
          'Copy it from there (Team & devices → Private key).');
    }
    final key = Vault.newKey();
    store.setMeta('pkey:$me', base64Url.encode(key));
    vault.addKey(me, key);
    store.put('members', me, {'keyId': Vault.fingerprint(key)});
    return me;
  }

  /// Code that moves my personal key to another of my devices.
  String exportMyKey() {
    final me = ensureMyKey();
    return Vault.exportCode(me, base64Url.decode(store.getMeta('pkey:$me')!));
  }

  /// Installs a personal key copied from another device and makes this
  /// device act as that member. Returns the member id.
  String importKey(String code) {
    final (owner, key) = Vault.parseCode(code);
    final published = store.row('members', owner)?['keyId'];
    if (published != null && published != Vault.fingerprint(key)) {
      throw const FormatException('That key doesn’t match this member');
    }
    store.setMeta('pkey:$owner', base64Url.encode(key));
    vault.addKey(owner, key);
    if (published == null) store.put('members', owner, {'keyId': Vault.fingerprint(key)});
    final previous = meId;
    setMe(owner);
    // Drop the throwaway member this device created when it joined.
    if (previous != null && previous != owner && _isUnused(previous)) {
      store.put('members', previous, {'deleted': true});
    }
    return owner;
  }

  bool _isUnused(String memberId) =>
      store.row('members', memberId)?['keyId'] == null &&
      !tasks.any((t) => t.assignee == memberId || t.createdBy == memberId);

  static const _plainFields = {'owner', 'deleted'};

  /// Decrypts a stored row. Returns null for a private row this device can't
  /// read, which hides it completely.
  Map<String, Object?>? _open(String table, Map<String, Object?> r) {
    final owner = r['owner'] as String?;
    if (owner != null && !vault.hasKey(owner)) return null;
    final id = r['id'] as String;
    final out = <String, Object?>{};
    for (final e in r.entries) {
      try {
        out[e.key] = vault.open(table, id, e.key, e.value);
      } on VaultLocked {
        if (owner != null) return null;
        out[e.key] = null;
      }
    }
    return out;
  }

  /// Writes fields, sealing them when the record is private.
  void _put(String table, String id, Map<String, Object?> fields) =>
      _putAs(table, id, fields, store.row(table, id)?['owner'] as String?);

  /// Writes fields sealed for [owner], or in the clear when [owner] is null.
  void _putAs(String table, String id, Map<String, Object?> fields, String? owner) {
    if (owner == null) {
      store.put(table, id, fields);
      return;
    }
    store.put(table, id, {
      for (final e in fields.entries)
        e.key: _plainFields.contains(e.key)
            ? e.value
            : vault.seal(owner, table, id, e.key, e.value),
    });
  }

  /// Makes a task (with its sub-tasks and comments) private to me, or shares
  /// it with the team again.
  void setPrivate(String id, bool private) {
    final t = task(id);
    if (t == null || t.isPrivate == private) return;
    final owner = private ? ensureMyKey() : null;
    final fields = Map<String, Object?>.of(t.r)
      ..remove('id')
      ..remove('owner');
    _putAs('tasks', id, {...fields, 'owner': owner, if (private) 'assignee': owner}, owner);
    for (final c in comments(id)) {
      final f = Map<String, Object?>.of(c.r)
        ..remove('id')
        ..remove('owner');
      _putAs('comments', c.id, {...f, 'owner': owner}, owner);
    }
    for (final s in subtasks(id)) {
      setPrivate(s.id, private);
    }
  }

  // ------------------------------------------------------------- members

  List<Member> get members =>
      store.rows('members').values.map(Member.new).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Member? member(String? id) {
    if (id == null) return null;
    final r = store.row('members', id);
    return r == null || r['deleted'] == true ? null : Member(r);
  }

  String addMember(String name) {
    final id = Store.newId();
    store.put('members', id, {
      'name': name.trim(),
      'color': palette[store.rows('members').length * 4 % palette.length],
    });
    return id;
  }

  void renameMember(String id, String name) =>
      store.put('members', id, {'name': name.trim()});

  // ------------------------------------------------------------ projects

  List<Project> get projects =>
      store.rows('projects').values.map(Project.new).where((p) => !p.archived).toList()
        ..sort(_byOrder);

  List<Project> get archivedProjects =>
      store.rows('projects').values.map(Project.new).where((p) => p.archived).toList()
        ..sort(_byOrder);

  Project? project(String? id) {
    if (id == null) return null;
    final r = store.row('projects', id);
    return r == null || r['deleted'] == true ? null : Project(r);
  }

  String addProject(String name, {int? color}) {
    final id = Store.newId();
    store.put('projects', id, {
      'name': name.trim(),
      'color': color ?? palette[(store.rows('projects').length * 3) % palette.length],
      'order': _nextOrder(store.rows('projects').values),
    });
    return id;
  }

  void updateProject(String id, Map<String, Object?> f) => store.put('projects', id, f);

  void deleteProject(String id) {
    for (final t in tasks.where((t) => t.projectId == id)) {
      _put('tasks', t.id, {'deleted': true});
    }
    for (final s in sections(id)) {
      store.put('sections', s.id, {'deleted': true});
    }
    store.put('projects', id, {'deleted': true});
  }

  // ------------------------------------------------------------ sections

  List<Section> sections(String? projectId) => store
      .rows('sections')
      .values
      .map(Section.new)
      .where((s) => s.projectId == projectId)
      .toList()
    ..sort(_byOrder);

  String addSection(String? projectId, String name) {
    final id = Store.newId();
    store.put('sections', id, {
      'projectId': projectId,
      'name': name.trim(),
      'order': _nextOrder(sections(projectId).map((s) => s.r)),
    });
    return id;
  }

  void renameSection(String id, String name) =>
      store.put('sections', id, {'name': name.trim()});

  void deleteSection(String id) {
    for (final t in tasks.where((t) => t.sectionId == id)) {
      _put('tasks', t.id, {'deleted': true});
    }
    store.put('sections', id, {'deleted': true});
  }

  // -------------------------------------------------------------- labels

  List<Label> get labels => store.rows('labels').values.map(Label.new).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Label? label(String id) {
    final r = store.row('labels', id);
    return r == null || r['deleted'] == true ? null : Label(r);
  }

  String ensureLabel(String name) {
    final existing = labels.where((l) => l.name.toLowerCase() == name.toLowerCase());
    if (existing.isNotEmpty) return existing.first.id;
    final id = Store.newId();
    store.put('labels', id, {
      'name': name,
      'color': palette[(store.rows('labels').length * 5 + 7) % palette.length],
    });
    return id;
  }

  void updateLabel(String id, Map<String, Object?> f) => store.put('labels', id, f);

  void deleteLabel(String id) {
    for (final t in tasks.where((t) => t.labels.contains(id))) {
      _put('tasks', t.id, {'labels': t.labels..remove(id)});
    }
    store.put('labels', id, {'deleted': true});
  }

  // --------------------------------------------------------------- tasks

  /// Every live task, hiding those whose project was deleted.
  List<Task> get tasks {
    final liveProjects = store.rows('projects').keys.toSet();
    return store
        .rows('tasks')
        .values
        .map((r) => _open('tasks', r))
        .whereType<Map<String, Object?>>()
        .map(Task.new)
        .where((t) => t.projectId == null || liveProjects.contains(t.projectId))
        .toList();
  }

  Task? task(String id) {
    final r = store.row('tasks', id);
    if (r == null || r['deleted'] == true) return null;
    final o = _open('tasks', r);
    return o == null ? null : Task(o);
  }

  List<Task> get open => tasks.where((t) => !t.done).toList();

  List<Task> subtasks(String parentId, {bool includeDone = true}) => tasks
      .where((t) => t.parentId == parentId && (includeDone || !t.done))
      .toList()
    ..sort(_byOrder);

  List<Task> inbox() =>
      open.where((t) => t.projectId == null && t.parentId == null).toList()..sort(_byOrder);

  List<Task> inProject(String projectId, {String? sectionId, bool sectioned = true}) => open
      .where((t) =>
          t.projectId == projectId &&
          t.parentId == null &&
          (!sectioned || t.sectionId == sectionId))
      .toList()
    ..sort(_byOrder);

  /// Overdue + due today, earliest first, then by priority.
  List<Task> today() {
    final end = addDays(dayOf(now()), 1);
    return open.where((t) => t.due != null && t.due!.date.isBefore(end)).toList()
      ..sort(byDueThenPriority);
  }

  List<Task> overdue() {
    final today = dayOf(now());
    return open.where((t) => t.due != null && t.due!.date.isBefore(today)).toList()
      ..sort(byDueThenPriority);
  }

  List<Task> dueOn(DateTime day) {
    final d = dayOf(day);
    return open.where((t) => t.due != null && t.due!.date == d).toList()
      ..sort(byDueThenPriority);
  }

  List<Task> withLabel(String labelId) =>
      open.where((t) => t.labels.contains(labelId)).toList()..sort(byDueThenPriority);

  List<Task> assignedTo(String memberId) =>
      open.where((t) => t.assignee == memberId).toList()..sort(byDueThenPriority);

  List<Task> withPriority(int p) =>
      open.where((t) => t.priority == p).toList()..sort(byDueThenPriority);

  List<Task> search(String q) {
    q = q.trim().toLowerCase();
    if (q.isEmpty) return [];
    return tasks
        .where((t) =>
            t.title.toLowerCase().contains(q) || t.description.toLowerCase().contains(q))
        .toList()
      ..sort((a, b) => (a.done ? 1 : 0).compareTo(b.done ? 1 : 0));
  }

  List<Task> completed({String? projectId, int limit = 200}) {
    final done = tasks
        .where((t) => t.done && (projectId == null || t.projectId == projectId))
        .toList()
      ..sort((a, b) => (b.doneAt ?? DateTime(0)).compareTo(a.doneAt ?? DateTime(0)));
    return done.take(limit).toList();
  }

  static int byDueThenPriority(Task a, Task b) {
    final da = a.due, db = b.due;
    if (da != null && db != null) {
      // All-day tasks sort after timed ones on the same day.
      final c = da.date.compareTo(db.date);
      if (c != 0) return c;
      if (da.hasTime != db.hasTime) return da.hasTime ? -1 : 1;
      if (da.hasTime) {
        final t = da.minutes!.compareTo(db.minutes!);
        if (t != 0) return t;
      }
    } else if (da != null || db != null) {
      return da != null ? -1 : 1;
    }
    final p = a.priority.compareTo(b.priority);
    return p != 0 ? p : _byOrder(a, b);
  }

  String addTask({
    required String title,
    String description = '',
    String? projectId,
    String? sectionId,
    String? parentId,
    int priority = 4,
    Due? due,
    Recurrence? recur,
    List<String> labels = const [],
    String? assignee,
    bool private = false,
    bool alarm = false,
    List<int>? reminders,
  }) {
    final id = Store.newId();
    final parentOwner = parentId == null ? null : task(parentId)?.owner;
    final owner = parentOwner ?? (private ? ensureMyKey() : null);
    final siblings = tasks.where((t) =>
        t.parentId == parentId && t.projectId == projectId && t.sectionId == sectionId);
    _putAs('tasks', id, {
      'owner': owner,
      'title': title.trim(),
      'description': description,
      'projectId': projectId,
      'sectionId': sectionId,
      'parentId': parentId,
      'priority': priority,
      'due': due?.toString(),
      'recur': recur?.toString(),
      'labels': labels,
      'assignee': owner ?? assignee,
      'alarm': alarm,
      'reminders': reminders,
      'done': false,
      'order': _nextOrder(siblings.map((t) => t.r)),
      'createdAt': now().millisecondsSinceEpoch,
      'createdBy': meId,
    }, owner);
    return id;
  }

  /// Creates a task from quick-add text. Explicit `#project` / `+member` that
  /// don't exist are kept literally in the title rather than guessed.
  String? quickAdd(String text,
      {String? projectId, String? sectionId, String? parentId, Due? defaultDue}) {
    final q = parseQuickAdd(text,
        now: now(),
        projects: projects.map((p) => p.name).toList(),
        members: members.map((m) => m.name).toList());
    var title = q.title;
    if (q.project != null) {
      final p = _byName(projects, q.project!, (p) => p.name);
      if (p != null) {
        projectId = p.id;
        sectionId = null;
      } else {
        title = '$title #${q.project}';
      }
    }
    if (q.section != null) {
      final s = _byName(sections(projectId), q.section!, (s) => s.name);
      sectionId = s?.id ?? addSection(projectId, q.section!);
    }
    String? assignee;
    if (q.assignee != null) {
      assignee = _byName(members, q.assignee!, (m) => m.name)?.id ??
          members
              .where((m) => m.name.toLowerCase().startsWith(q.assignee!.toLowerCase()))
              .firstOrNull
              ?.id;
      if (assignee == null) title = '$title +${q.assignee}';
    }
    title = title.trim();
    if (title.isEmpty) return null;
    return addTask(
      title: title,
      projectId: projectId,
      sectionId: sectionId,
      parentId: parentId,
      priority: q.priority ?? 4,
      due: q.due ?? defaultDue,
      recur: q.recur,
      labels: [for (final l in q.labels) ensureLabel(l)],
      assignee: assignee,
      private: q.private,
      alarm: q.alarm,
      // Extra reminders add to the default one at the due time.
      reminders: q.reminders.isEmpty
          ? null
          : {if ((q.due ?? defaultDue)?.hasTime ?? false) 0, ...q.reminders}.toList(),
    );
  }

  static T? _byName<T>(List<T> items, String name, String Function(T) nameOf) {
    final n = name.toLowerCase();
    for (final i in items) {
      if (nameOf(i).toLowerCase() == n) return i;
    }
    return null;
  }

  void updateTask(String id, Map<String, Object?> fields) => _put('tasks', id, fields);

  /// Completing a recurring task moves it to its next occurrence instead.
  /// [at] is when it was done (defaults to now; differs when the action came
  /// from a notification while the app was closed).
  Completion complete(String id, {DateTime? at}) {
    final t = task(id);
    if (t == null) return const Completion(0, null);
    final result = _scoreCompletion(t, at ?? now());
    final r = t.recur;
    if (r != null) {
      final base = t.due?.date ?? dayOf(now());
      final nextDate = r.next(base);
      _put('tasks', id, {
        'due': (t.due ?? Due(nextDate)).withDate(nextDate).toString(),
        'lastDoneAt': now().millisecondsSinceEpoch,
      });
      for (final s in subtasks(id)) {
        if (s.done) _put('tasks', s.id, {'done': false, 'doneAt': null});
      }
      return result;
    }
    final ms = (at ?? now()).millisecondsSinceEpoch;
    _put('tasks', id, {'done': true, 'doneAt': ms, 'doneBy': meId});
    for (final s in subtasks(id, includeDone: false)) {
      _put('tasks', s.id, {'done': true, 'doneAt': ms, 'doneBy': meId});
    }
    return result;
  }

  void uncomplete(String id) {
    final t = task(id);
    _put('tasks', id, {'done': false, 'doneAt': null, 'doneBy': null});
    if (t != null) _unscore(t, t.r['due'] as String?);
  }

  /// Undo for a recurring completion: puts the previous due date back and
  /// takes back the points for that occurrence.
  void undoRecurring(String id, String? previousDue) {
    final t = task(id);
    if (t == null) return;
    _put('tasks', id, {'due': previousDue});
    _unscore(t, previousDue);
  }

  void deleteTask(String id) {
    for (final s in subtasks(id)) {
      deleteTask(s.id);
    }
    _put('tasks', id, {'deleted': true});
  }

  /// Moves the item at [oldIndex] of [list] (as displayed) to [newIndex],
  /// writing only that item's order so concurrent moves don't clobber.
  void reorder(List<Entity> list, int oldIndex, int newIndex, String table) {
    if (oldIndex == newIndex) return;
    final items = [...list];
    final moved = items.removeAt(oldIndex);
    items.insert(newIndex, moved);
    final before = newIndex > 0 ? items[newIndex - 1].order : null;
    final after = newIndex < items.length - 1 ? items[newIndex + 1].order : null;
    num order;
    if (before == null && after == null) {
      order = 0;
    } else if (before == null) {
      order = after! - 1;
    } else if (after == null) {
      order = before + 1;
    } else {
      order = (before + after) / 2;
    }
    store.put(table, moved.id, {'order': order});
  }

  // ------------------------------------------------------------ comments

  List<Comment> comments(String taskId) => store
      .rows('comments')
      .values
      .map((r) => _open('comments', r))
      .whereType<Map<String, Object?>>()
      .map(Comment.new)
      .where((c) => c.taskId == taskId)
      .toList()
    ..sort((a, b) => a.at.compareTo(b.at));

  int commentCount(String taskId) => comments(taskId).length;

  void addComment(String taskId, String text) {
    if (text.trim().isEmpty) return;
    final owner = task(taskId)?.owner;
    _putAs('comments', Store.newId(), {
      'owner': owner,
      'taskId': taskId,
      'text': text.trim(),
      'author': meId,
      'at': now().millisecondsSinceEpoch,
    }, owner);
  }

  void deleteComment(String id) => _put('comments', id, {'deleted': true});

  // ------------------------------------------------------------- helpers

  static int _byOrder(Entity a, Entity b) => a.order.compareTo(b.order);

  static num _nextOrder(Iterable<Map<String, Object?>> rows) {
    num max = 0;
    for (final r in rows) {
      final o = (r['order'] as num?) ?? 0;
      if (o > max) max = o;
    }
    return max + 1;
  }
}
