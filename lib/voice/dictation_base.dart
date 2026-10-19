// Kept free of Flutter imports so the Linux engine can be tested with plain Dart.
typedef OnText = void Function(String text, bool isFinal);

/// Speech-to-text for dictating tasks in Spanish ('es') or English ('en').
abstract class Dictation {
  /// Null when ready, otherwise what's missing, in plain words.
  Future<String?> prepare();

  /// Whether words appear while speaking (true) or only after stopping.
  bool get live;

  Future<void> start(
      {required String lang,
      required OnText onText,
      required void Function(String error) onError,
      List<String> hints = const []});

  /// Stop listening and deliver the final text.
  Future<void> stop();

  /// Stop and throw away what was heard.
  Future<void> cancel();
}
