import 'dart:io';

import 'package:flutter/material.dart';

import '../model/repo.dart';
import '../model/voice.dart';
import '../voice/dictation.dart';

/// One recognizer per app run; initializing again is slow on Android.
final Dictation _dictation = dictationForPlatform();

/// Lets the user dictate a task. Returns quick-add text (e.g.
/// `Llamar a Ana mañana a las 15:00 p1 #Ventas`) or null if cancelled.
Future<String?> showVoiceSheet(BuildContext context, Repo repo) =>
    showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _VoiceSheet(repo),
    );

enum _Phase { preparing, unavailable, listening, transcribing, done, error }

class _VoiceSheet extends StatefulWidget {
  final Repo repo;
  const _VoiceSheet(this.repo);

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> with SingleTickerProviderStateMixin {
  late String _lang = widget.repo.store.getMeta('voice_lang') ??
      (Platform.localeName.toLowerCase().startsWith('en') ? 'en' : 'es');
  _Phase _phase = _Phase.preparing;
  String _heard = '';
  String? _message;
  final _edit = TextEditingController();
  late final _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    if (_phase == _Phase.listening) _dictation.cancel();
    _pulse.dispose();
    _edit.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _phase = _Phase.preparing;
      _heard = '';
      _message = null;
    });
    final problem = await _dictation.prepare();
    if (!mounted) return;
    if (problem != null) {
      setState(() {
        _phase = _Phase.unavailable;
        _message = problem;
      });
      return;
    }
    setState(() => _phase = _Phase.listening);
    await _dictation.start(
      lang: _lang,
      hints: [
        ...widget.repo.projects.map((p) => p.name),
        ...widget.repo.members.map((m) => m.name),
      ],
      onText: (text, isFinal) {
        if (!mounted) return;
        setState(() {
          _heard = text;
          if (isFinal) {
            _phase = _Phase.done;
            _edit.text = text;
          }
        });
      },
      onError: (e) {
        if (!mounted) return;
        setState(() {
          // Keep partial words if we have them.
          if (_heard.isNotEmpty) {
            _phase = _Phase.done;
            _edit.text = _heard;
          } else {
            _phase = _Phase.error;
            _message = e;
          }
        });
      },
    );
  }

  Future<void> _stop() async {
    if (!_dictation.live) setState(() => _phase = _Phase.transcribing);
    await _dictation.stop();
    // Platform recognizers deliver a final result shortly after stopping.
    if (mounted && _phase == _Phase.listening && _heard.isNotEmpty) {
      setState(() {
        _phase = _Phase.done;
        _edit.text = _heard;
      });
    }
  }

  void _setLang(String l) async {
    widget.repo.store.setMeta('voice_lang', l);
    final restart = _phase == _Phase.listening;
    if (restart) await _dictation.cancel();
    setState(() => _lang = l);
    if (restart || _phase == _Phase.error || _phase == _Phase.done) _begin();
  }

  String get _converted => spokenToQuickAdd(_edit.text,
      projects: widget.repo.projects.map((p) => p.name).toList(),
      members: widget.repo.members.map((m) => m.name).toList());

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final es = _lang == 'es';
    final listening = _phase == _Phase.listening;

    Widget mic = AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) => Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: listening ? cs.error : cs.primaryContainer,
          boxShadow: listening
              ? [BoxShadow(color: cs.error.withValues(alpha: 0.35), blurRadius: 8 + 18 * _pulse.value, spreadRadius: 2 + 8 * _pulse.value)]
              : null,
        ),
        child: child,
      ),
      child: IconButton(
        iconSize: 40,
        tooltip: listening ? (es ? 'Detener' : 'Stop') : (es ? 'Hablar' : 'Speak'),
        icon: Icon(listening ? Icons.stop : Icons.mic, color: listening ? cs.onError : cs.onPrimaryContainer),
        onPressed: switch (_phase) {
          _Phase.listening => _stop,
          _Phase.preparing || _Phase.transcribing || _Phase.unavailable => null,
          _ => _begin,
        },
      ),
    );

    final status = switch (_phase) {
      _Phase.preparing => es ? 'Preparando…' : 'Getting ready…',
      _Phase.listening => _heard.isEmpty
          ? (es ? 'Escuchando… di la tarea' : 'Listening… say the task')
          : _heard,
      _Phase.transcribing => es ? 'Transcribiendo…' : 'Transcribing…',
      _Phase.unavailable || _Phase.error => _message ?? '',
      _Phase.done => '',
    };

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(es ? 'Dictar tarea' : 'Dictate a task', style: Theme.of(context).textTheme.titleMedium)),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'es', label: Text('ES')),
              ButtonSegment(value: 'en', label: Text('EN')),
            ],
            selected: {_lang},
            onSelectionChanged: (s) => _setLang(s.first),
          ),
        ]),
        const SizedBox(height: 20),
        Center(child: mic),
        const SizedBox(height: 16),
        if (_phase == _Phase.transcribing) const LinearProgressIndicator(),
        if (status.isNotEmpty)
          Text(status,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: listening && _heard.isNotEmpty ? 18 : 14,
                  color: _phase == _Phase.error || _phase == _Phase.unavailable ? cs.error : null)),
        if (_phase == _Phase.done) ...[
          TextField(
            controller: _edit,
            minLines: 1,
            maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: es ? 'Lo que entendí (puedes corregirlo)' : 'What I heard (you can fix it)',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text('→ $_converted', style: TextStyle(color: cs.onSurfaceVariant, fontFamily: 'monospace', fontSize: 13)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(onPressed: _begin, child: Text(es ? 'Repetir' : 'Try again')),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.check),
              label: Text(es ? 'Usar' : 'Use'),
              onPressed: _edit.text.trim().isEmpty ? null : () => Navigator.pop(context, _converted),
            ),
          ]),
        ],
        if (_phase != _Phase.done) ...[
          const SizedBox(height: 12),
          Text(
            es
                ? 'Ej.: “Llamar a Ana mañana a las 3 de la tarde, prioridad 1, proyecto Ventas”. '
                    'Di “tarea privada” para que solo tú la veas.'
                : 'e.g. “Call Ana tomorrow at 3 pm, priority 1, project Sales”. '
                    'Say “private task” to keep it to yourself.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ]),
    );
  }
}
