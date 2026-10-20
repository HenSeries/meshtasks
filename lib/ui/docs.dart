import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../app_state.dart';
import '../core/blobs.dart';
import '../model/repo.dart';
import 'common.dart';

/// All team documents, pinned first.
class DocsIndex extends StatefulWidget {
  final AppState app;
  final void Function(String docId) onOpen;
  const DocsIndex(this.app, {super.key, required this.onOpen});

  @override
  State<DocsIndex> createState() => _DocsIndexState();
}

class _DocsIndexState extends State<DocsIndex> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final repo = widget.app.repo;
    final now = repo.now();
    final docs = repo.docs
        .where((d) =>
            q.isEmpty || d.title.toLowerCase().contains(q) || d.body.toLowerCase().contains(q))
        .toList();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search), hintText: 'Search documents', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => q = v.trim().toLowerCase()),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          icon: const Icon(Icons.note_add_outlined),
          label: const Text('New'),
          onPressed: () async {
            final id = await newDoc(context, repo);
            if (id != null) widget.onOpen(id);
          },
        ),
      ]),
      const SizedBox(height: 8),
      if (docs.isEmpty)
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            q.isEmpty
                ? 'Write down what everyone should know: processes, passwords policy, contacts, how-tos…'
                : 'No matches',
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      for (final d in docs)
        Card(
          child: ListTile(
            leading: Text(d.emoji, style: const TextStyle(fontSize: 26)),
            title: Text(d.title),
            subtitle: Text(
              [
                _excerpt(d.body),
                'Edited ${fmtDay(d.updatedAt, now)}${repo.member(d.updatedBy) == null ? '' : ' by ${repo.member(d.updatedBy)!.name}'}',
              ].where((s) => s.isNotEmpty).join('\n'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (d.files.isNotEmpty) Text('📎${d.files.length}'),
              if (d.pinned) const Icon(Icons.push_pin, size: 16),
            ]),
            onTap: () => widget.onOpen(d.id),
          ),
        ),
    ]);
  }

  static String _excerpt(String md) => md
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      .replaceAll(RegExp(r'[#>*_`\[\]]|\(blob:[0-9a-f]+\)'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Future<String?> newDoc(BuildContext context, Repo repo) async {
  final title = await promptText(context, title: 'New document', hint: 'e.g. How we invoice', action: 'Create');
  if (title == null || title.trim().isEmpty) return null;
  return repo.addDoc(title, body: '# ${title.trim()}\n\n');
}

/// One document: rendered Markdown with its files; edit in place.
class DocPage extends StatefulWidget {
  final AppState app;
  final String docId;
  const DocPage(this.app, this.docId, {super.key});

  @override
  State<DocPage> createState() => DocPageState();
}

class DocPageState extends State<DocPage> {
  bool editing = false;
  final _text = TextEditingController();
  String _base = ''; // body when editing started, to detect concurrent edits
  bool _preview = false;

  Repo get repo => widget.app.repo;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void startEditing() {
    final d = repo.doc(widget.docId);
    if (d == null) return;
    setState(() {
      editing = true;
      _base = d.body;
      _text.text = d.body;
    });
  }

  Future<void> save() async {
    final d = repo.doc(widget.docId);
    if (d == null) return;
    var body = _text.text;
    if (d.body != _base && d.body != body) {
      // Someone else saved while we were editing.
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Edited by someone else'),
          content: Text(
              '${repo.member(d.updatedBy)?.name ?? 'A teammate'} changed this document while you were editing. '
              'Keep both versions (theirs is added below yours), or overwrite theirs?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep editing')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'overwrite'), child: const Text('Overwrite')),
            FilledButton(onPressed: () => Navigator.pop(ctx, 'both'), child: const Text('Keep both')),
          ],
        ),
      );
      if (choice == null) return;
      if (choice == 'both') body = '$body\n\n---\n\n<!-- their version -->\n\n${d.body}';
    }
    repo.updateDoc(widget.docId, {'body': body});
    if (mounted) setState(() => editing = false);
  }

  /// Inserts Markdown around the selection (or at the cursor).
  void _wrap(String before, [String after = '', String placeholder = 'text']) {
    final sel = _text.selection;
    final t = _text.text;
    final start = sel.isValid ? sel.start : t.length;
    final end = sel.isValid ? sel.end : t.length;
    final inner = start == end ? placeholder : t.substring(start, end);
    _text.value = TextEditingValue(
      text: t.replaceRange(start, end, '$before$inner$after'),
      selection: TextSelection(baseOffset: start + before.length, extentOffset: start + before.length + inner.length),
    );
  }

  void _linePrefix(String prefix) {
    final sel = _text.selection;
    final t = _text.text;
    final pos = sel.isValid ? sel.start : t.length;
    final lineStart = t.lastIndexOf('\n', pos == 0 ? 0 : pos - 1) + 1;
    _text.value = TextEditingValue(
      text: t.replaceRange(lineStart, lineStart, prefix),
      selection: TextSelection.collapsed(offset: pos + prefix.length),
    );
  }

  Future<void> _insertFiles() async {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Insert file');
    for (final f in picked) {
      final bytes = await f.readAsBytes();
      final String hash;
      try {
        hash = widget.app.blobs.put(bytes);
      } on ArgumentError catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${f.name}: ${e.message}')));
        continue;
      }
      final a = Attachment(hash, f.name, bytes.length);
      repo.attach(widget.docId, a);
      if (editing) {
        _wrap('\n${a.markdown}\n', '', '');
      } else {
        final d = repo.doc(widget.docId)!;
        repo.updateDoc(widget.docId, {'body': '${d.body.trimRight()}\n\n${a.markdown}\n'});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final d = repo.doc(widget.docId);
        if (d == null) return const Center(child: Text('This document was deleted.'));
        final wide = MediaQuery.of(context).size.width >= 1000;
        final viewer = _Rendered(app: widget.app, doc: d, body: editing ? _text.text : d.body);
        if (!editing) {
          return ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 80), children: [
            viewer,
            _Files(app: widget.app, doc: d),
          ]);
        }
        final editor = Column(children: [
          _Toolbar(
            onWrap: _wrap,
            onLine: _linePrefix,
            onFile: _insertFiles,
            preview: _preview,
            showPreviewToggle: !wide,
            onPreview: () => setState(() => _preview = !_preview),
          ),
          Expanded(
            child: (!wide && _preview)
                ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: viewer)
                : TextField(
                    controller: _text,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(16),
                      hintText: '# Title\n\nWrite in Markdown: **bold**, *italic*, - lists, [links](https://…)',
                    ),
                  ),
          ),
        ]);
        if (!wide) return editor;
        return Row(children: [
          Expanded(child: editor),
          const VerticalDivider(width: 1),
          Expanded(child: SingleChildScrollView(padding: const EdgeInsets.all(20), child: viewer)),
        ]);
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  final void Function(String before, [String after, String placeholder]) onWrap;
  final void Function(String prefix) onLine;
  final VoidCallback onFile;
  final bool preview;
  final bool showPreviewToggle;
  final VoidCallback onPreview;
  const _Toolbar(
      {required this.onWrap,
      required this.onLine,
      required this.onFile,
      required this.preview,
      required this.showPreviewToggle,
      required this.onPreview});

  @override
  Widget build(BuildContext context) {
    Widget b(IconData icon, String tip, VoidCallback f) =>
        IconButton(icon: Icon(icon, size: 20), tooltip: tip, onPressed: preview ? null : f);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          b(Icons.title, 'Heading', () => onLine('## ')),
          b(Icons.format_bold, 'Bold', () => onWrap('**', '**')),
          b(Icons.format_italic, 'Italic', () => onWrap('*', '*')),
          b(Icons.format_list_bulleted, 'List', () => onLine('- ')),
          b(Icons.checklist, 'Checklist', () => onLine('- [ ] ')),
          b(Icons.format_quote, 'Quote', () => onLine('> ')),
          b(Icons.code, 'Code', () => onWrap('`', '`', 'code')),
          b(Icons.link, 'Link', () => onWrap('[', '](https://)', 'link text')),
          b(Icons.table_chart_outlined, 'Table',
              () => onWrap('\n| Column | Column |\n|---|---|\n| ', ' |  |\n', 'value')),
          b(Icons.attach_file, 'Insert file or image', onFile),
          if (showPreviewToggle)
            TextButton.icon(
              icon: Icon(preview ? Icons.edit : Icons.visibility_outlined, size: 18),
              label: Text(preview ? 'Edit' : 'Preview'),
              onPressed: onPreview,
            ),
        ]),
      ),
    );
  }
}

/// Markdown with `blob:` images and links resolved to attachments.
class _Rendered extends StatelessWidget {
  final AppState app;
  final Doc doc;
  final String body;
  const _Rendered({required this.app, required this.doc, required this.body});

  @override
  Widget build(BuildContext context) => MarkdownBody(
        data: body,
        selectable: true,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          blockquoteDecoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        imageBuilder: (uri, title, alt) {
          if (uri.scheme != 'blob') {
            return Text('[image: ${alt ?? uri}]');
          }
          final hash = uri.path;
          final file = BlobStore.isHash(hash) && app.blobs.has(hash) ? app.blobs.file(hash) : null;
          if (file == null) return _Missing(alt ?? 'image');
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: Image.file(file, fit: BoxFit.contain),
          );
        },
        onTapLink: (text, href, title) {
          if (href == null) return;
          final uri = Uri.tryParse(href);
          if (uri?.scheme == 'blob') {
            final a = doc.files.where((f) => f.hash == uri!.path).firstOrNull;
            if (a != null) openAttachment(context, app, a);
          }
        },
      );
}

class _Missing extends StatelessWidget {
  final String name;
  const _Missing(this.name);
  @override
  Widget build(BuildContext context) => Chip(
        avatar: const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        label: Text('$name: syncing from a teammate…'),
      );
}

class _Files extends StatelessWidget {
  final AppState app;
  final Doc doc;
  const _Files({required this.app, required this.doc});

  @override
  Widget build(BuildContext context) {
    if (doc.files.isEmpty) return const SizedBox();
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Files', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in doc.files)
            InputChip(
              avatar: Icon(app.blobs.has(f.hash)
                  ? (f.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined)
                  : Icons.cloud_download_outlined),
              label: Text('${f.name} · ${_size(f.size)}'),
              onPressed: () => openAttachment(context, app, f),
              onDeleted: () async {
                if (await confirm(context, 'Remove file?', '“${f.name}” will be removed from this document.')) {
                  app.repo.detach(doc.id, f.hash);
                }
              },
            ),
        ]),
      ]),
    );
  }

  static String _size(int b) => b < 1024
      ? '$b B'
      : b < 1024 * 1024
          ? '${(b / 1024).toStringAsFixed(0)} KB'
          : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// Copies the attachment out under its real name and opens it with the
/// system's default app.
Future<void> openAttachment(BuildContext context, AppState app, Attachment a) async {
  final bytes = app.blobs.read(a.hash);
  if (bytes == null) {
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not on this device yet: it downloads when a teammate who has it is online.')));
    return;
  }
  final dir = Directory('${(await getTemporaryDirectory()).path}/meshtasks-open/${a.hash.substring(0, 12)}');
  await dir.create(recursive: true);
  final safe = a.name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
  final f = File('${dir.path}/$safe');
  if (!f.existsSync()) await f.writeAsBytes(bytes, flush: true);
  final r = await OpenFilex.open(f.path);
  if (r.type != ResultType.done && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Couldn’t open ${a.name}: ${r.message}')));
  }
}
