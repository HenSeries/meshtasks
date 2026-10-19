import 'dart:async';
import 'dart:io';

import 'dictation_base.dart';

/// Linux: records with PipeWire/PulseAudio/ALSA and transcribes offline with
/// whisper.cpp. Nothing leaves the computer.
class WhisperDictation implements Dictation {
  String? _recorder;
  String? _whisper;
  String? _model;
  Process? _rec;
  File? _wav;
  String _lang = 'es';
  OnText? _onText;
  void Function(String)? _onError;

  @override
  bool get live => false;

  static const _modelPreference = [
    'large-v3-turbo', 'medium', 'small', 'base', 'tiny',
  ];

  @override
  Future<String?> prepare() async {
    _recorder ??= await _which(['pw-record', 'parecord', 'arecord']);
    _whisper ??= await _which(['whisper-cli', 'whisper-cpp', 'whisper.cpp']);
    _model ??= _findModel();
    final missing = <String>[
      if (_recorder == null) 'a recorder (pipewire, pulseaudio-utils or alsa-utils)',
      if (_whisper == null) 'whisper.cpp (the `whisper-cli` command)',
      if (_model == null)
        'a multilingual whisper model (e.g. ggml-small.bin) in ~/.local/share/meshtasks/whisper/',
    ];
    if (missing.isEmpty) return null;
    return 'Voice on Linux runs offline with whisper.cpp. Missing: ${missing.join('; ')}.';
  }

  static Future<String?> _which(List<String> names) async {
    // Apps started from a desktop menu may not have ~/.local/bin on PATH.
    final home = Platform.environment['HOME'] ?? '';
    for (final n in names) {
      for (final dir in ['$home/.local/bin', '/usr/local/bin']) {
        if (File('$dir/$n').existsSync()) return '$dir/$n';
      }
    }
    for (final n in names) {
      final r = await Process.run('sh', ['-c', 'command -v $n']);
      if (r.exitCode == 0 && (r.stdout as String).trim().isNotEmpty) {
        return (r.stdout as String).trim();
      }
    }
    return null;
  }

  static String? _findModel() {
    final env = Platform.environment['MESHTASKS_WHISPER_MODEL'];
    if (env != null && File(env).existsSync()) return env;
    final home = Platform.environment['HOME'] ?? '';
    final dirs = [
      '$home/.local/share/meshtasks/whisper',
      '$home/.local/share/whisper',
      '$home/.cache/whisper',
      '/usr/share/whisper.cpp',
      '/usr/share/whisper.cpp-model',
      '/usr/local/share/whisper.cpp',
    ];
    final found = <String>[];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        final name = f.uri.pathSegments.last;
        // English-only models (*.en.bin) can't do Spanish.
        if (name.startsWith('ggml-') && name.endsWith('.bin') && !name.contains('.en.')) {
          found.add(f.path);
        }
      }
    }
    for (final pref in _modelPreference) {
      for (final f in found) {
        if (f.contains('ggml-$pref')) return f;
      }
    }
    return found.isEmpty ? null : found.first;
  }

  @override
  Future<void> start(
      {required String lang,
      required OnText onText,
      required void Function(String error) onError,
      List<String> hints = const []}) async {
    _lang = lang;
    _onText = onText;
    _onError = onError;
    _wav = File('${Directory.systemTemp.path}/meshtasks-dictation-$pid.wav');
    final path = _wav!.path;
    final args = switch (_recorder!.split('/').last) {
      'pw-record' => ['--rate', '16000', '--channels', '1', '--format', 's16', path],
      'parecord' => ['--rate=16000', '--channels=1', '--format=s16le', '--file-format=wav', path],
      _ => ['-q', '-f', 'S16_LE', '-r', '16000', '-c', '1', path],
    };
    _rec = await Process.start(_recorder!, args);
  }

  Future<void> _stopRecorder() async {
    final rec = _rec;
    _rec = null;
    if (rec == null) return;
    rec.kill(ProcessSignal.sigint); // lets the recorder finish the WAV header
    await rec.exitCode.timeout(const Duration(seconds: 3), onTimeout: () {
      rec.kill(ProcessSignal.sigkill);
      return -1;
    });
  }

  @override
  Future<void> stop() async {
    await _stopRecorder();
    final wav = _wav;
    if (wav == null || !wav.existsSync() || wav.lengthSync() < 8000) {
      _onError?.call('Didn’t catch that. Try again.');
      return;
    }
    try {
      final r = await Process.run(_whisper!, [
        '-m', _model!, '-l', _lang, '-nt', '-np',
        '-t', '${Platform.numberOfProcessors.clamp(1, 8)}', '-f', wav.path,
      ]);
      if (r.exitCode != 0) {
        _onError?.call('whisper.cpp failed: ${(r.stderr as String).trim().split('\n').last}');
        return;
      }
      final text = (r.stdout as String)
          .replaceAll(RegExp(r'\[[A-Z_ ]+\]|\([^)]*\)'), ' ') // [BLANK_AUDIO], (music)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isEmpty) {
        _onError?.call('Didn’t catch that. Try again.');
      } else {
        _onText?.call(text, true);
      }
    } finally {
      if (wav.existsSync()) wav.deleteSync();
    }
  }

  @override
  Future<void> cancel() async {
    await _stopRecorder();
    if (_wav?.existsSync() ?? false) _wav!.deleteSync();
  }
}
