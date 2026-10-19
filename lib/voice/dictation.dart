import 'dart:async';
import 'dart:io';

import 'package:speech_to_text/speech_to_text.dart';

import 'dictation_base.dart';
import 'whisper.dart';

export 'dictation_base.dart';

/// The platform's own recognizer on Android, iOS, macOS and Windows;
/// offline whisper.cpp on Linux (which has no system recognizer).
Dictation dictationForPlatform() =>
    Platform.isLinux ? WhisperDictation() : PlatformDictation();

class PlatformDictation implements Dictation {
  final _stt = SpeechToText();
  void Function(String)? _onError;
  bool _ready = false;

  @override
  bool get live => true;

  @override
  Future<String?> prepare() async {
    if (_ready) return null;
    try {
      _ready = await _stt.initialize(
        onError: (e) => _onError?.call(_describe(e.errorMsg)),
      );
    } catch (e) {
      return 'Speech recognition failed to start: $e';
    }
    return _ready
        ? null
        : 'Speech recognition isn’t available. Allow microphone access, and on '
            'Android make sure the Google app (speech services) is installed.';
  }

  /// Picks the installed locale for [lang], preferring the system's region
  /// (es_CO on a Colombian phone, es_ES in Spain…).
  Future<String?> _locale(String lang) async {
    final all = await _stt.locales();
    final system = await _stt.systemLocale();
    String norm(String id) => id.replaceAll('-', '_').toLowerCase();
    if (system != null && norm(system.localeId).startsWith('${lang}_')) return system.localeId;
    final preferred = lang == 'es' ? ['es_co', 'es_419', 'es_mx', 'es_us', 'es_es'] : ['en_us', 'en_gb'];
    for (final p in preferred) {
      for (final l in all) {
        if (norm(l.localeId) == p) return l.localeId;
      }
    }
    for (final l in all) {
      if (norm(l.localeId).startsWith(lang)) return l.localeId;
    }
    return null;
  }

  @override
  Future<void> start(
      {required String lang,
      required OnText onText,
      required void Function(String error) onError,
      List<String> hints = const []}) async {
    _onError = onError;
    final locale = await _locale(lang);
    await _stt.listen(
      onResult: (r) => onText(r.recognizedWords, r.finalResult),
      listenOptions: SpeechListenOptions(
        localeId: locale,
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: true,
        pauseFor: const Duration(seconds: 4),
        listenFor: const Duration(minutes: 1),
        contextualPhrases: hints,
      ),
    );
  }

  @override
  Future<void> stop() => _stt.stop();

  @override
  Future<void> cancel() => _stt.cancel();

  static String _describe(String code) => switch (code) {
        'error_no_match' || 'error_speech_timeout' => 'Didn’t catch that. Try again.',
        'error_network' || 'error_network_timeout' =>
          'The speech service needs internet on this device (or download the offline language pack).',
        'error_permission' || 'error_insufficient_permissions' => 'Microphone permission is off.',
        'error_language_not_supported' || 'error_language_unavailable' =>
          'This language isn’t installed for speech recognition on this device.',
        _ => 'Speech recognition error ($code)',
      };
}

