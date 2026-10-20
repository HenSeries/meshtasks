part of 'repo.dart';

/// A file attached to a document. The bytes live in the blob store, found
/// by [hash]; any device that has them can pass them on.
class Attachment {
  final String hash;
  final String name;
  final int size;
  const Attachment(this.hash, this.name, this.size);

  Map<String, Object?> toJson() => {'hash': hash, 'name': name, 'size': size};
  factory Attachment.fromJson(Map j) =>
      Attachment(j['hash'] as String, (j['name'] as String?) ?? 'file', (j['size'] as int?) ?? 0);

  bool get isImage => RegExp(r'\.(png|jpe?g|gif|webp|bmp)$', caseSensitive: false).hasMatch(name);
  bool get isVideo =>
      RegExp(r'\.(mp4|mov|m4v|webm|mkv|avi|3gp)$', caseSensitive: false).hasMatch(name);

  /// How the document's markdown refers to it.
  String get markdown => isImage
      ? '![$name](blob:$hash)'
      : '[${isVideo ? '🎬' : '📎'} $name](blob:$hash)';
}

/// Team documentation page written in Markdown.
class Doc extends Entity {
  Doc(super.r);
  String get title => (r['title'] as String?) ?? 'Untitled';
  String get body => (r['body'] as String?) ?? '';
  bool get pinned => r['pinned'] == true;
  String get emoji => (r['emoji'] as String?) ?? '📄';
  List<Attachment> get files => [
        for (final f in (r['files'] as List?) ?? const []) Attachment.fromJson(f as Map),
      ];
  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch((r['updatedAt'] as int?) ?? 0);
  String? get updatedBy => r['updatedBy'] as String?;
}

extension Docs on Repo {
  List<Doc> get docs => store.rows('docs').values.map(Doc.new).toList()
    ..sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });

  Doc? doc(String id) {
    final r = store.row('docs', id);
    return r == null || r['deleted'] == true ? null : Doc(r);
  }

  String addDoc(String title, {String body = ''}) {
    final id = Store.newId();
    updateDoc(id, {'title': title.trim(), 'body': body, 'files': <Object>[], 'createdBy': meId});
    return id;
  }

  void updateDoc(String id, Map<String, Object?> fields) => store.put('docs', id, {
        ...fields,
        'updatedAt': now().millisecondsSinceEpoch,
        'updatedBy': meId,
      });

  void deleteDoc(String id) => store.put('docs', id, {'deleted': true});

  /// Adds an already-stored blob to a document's file list.
  void attach(String docId, Attachment a) {
    final d = doc(docId);
    if (d == null) return;
    final files = d.files.where((f) => f.hash != a.hash).toList()..add(a);
    updateDoc(docId, {'files': [for (final f in files) f.toJson()]});
  }

  void detach(String docId, String hash) {
    final d = doc(docId);
    if (d == null) return;
    updateDoc(docId, {
      'files': [for (final f in d.files) if (f.hash != hash) f.toJson()],
    });
  }

  /// Every attachment any document refers to: what this device should hold.
  Set<String> get wantedBlobs => {
        for (final d in docs)
          for (final f in d.files) f.hash,
      };
}
