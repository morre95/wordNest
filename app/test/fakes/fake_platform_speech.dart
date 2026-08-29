import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// A stand-in for the `speech_to_text` plugin, so [PlatformSpeechRecognizer]
/// can be driven the way the platform drives it — results and status callbacks
/// arriving separately — with no platform channel and no microphone.
class FakePlatformSpeech extends stt.SpeechToText {
  FakePlatformSpeech() : super.withMethodChannel();

  stt.SpeechErrorListener? _onError;
  stt.SpeechStatusListener? _onStatus;
  stt.SpeechResultListener? _onResult;

  /// One entry per session the recogniser asked the platform to open.
  final sessions = <stt.SpeechListenOptions>[];
  int stopCount = 0;
  int cancelCount = 0;
  bool _listening = false;

  @override
  bool get isAvailable => true;

  @override
  bool get isListening => _listening;

  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(milliseconds: 2000),
    List<stt.SpeechConfigOption>? options,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    return true;
  }

  @override
  Future<bool> get hasPermission async => true;

  @override
  Future<List<stt.LocaleName>> locales() async =>
      [stt.LocaleName('en_US', 'English (US)')];

  @override
  Future<stt.LocaleName?> systemLocale() async =>
      stt.LocaleName('en_US', 'English (US)');

  @override
  Future<dynamic> listen({
    stt.SpeechResultListener? onResult,
    Duration? listenFor,
    Duration? pauseFor,
    String? localeId,
    stt.SpeechSoundLevelChange? onSoundLevelChange,
    dynamic cancelOnError = false,
    dynamic partialResults = true,
    dynamic onDevice = false,
    stt.ListenMode listenMode = stt.ListenMode.confirmation,
    dynamic sampleRate = 0,
    stt.SpeechListenOptions? listenOptions,
  }) async {
    _onResult = onResult;
    if (listenOptions != null) sessions.add(listenOptions);
    _listening = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _listening = false;
  }

  // --- Driving the recogniser from a test ---------------------------------

  /// A final result, exactly as the platform delivers one: the session is over
  /// but the recogniser has not been released yet.
  void emitFinalResult(String words) {
    _listening = false;
    _onResult?.call(SpeechRecognitionResult.init(
      [SpeechRecognitionWords(words, null, 0.9)],
      ResultType.finalResult,
    ));
  }

  /// The platform releasing the recogniser, which happens after the result.
  void emitDone() => _onStatus?.call('done');

  void emitStatus(String status) => _onStatus?.call(status);

  void emitError(String errorMsg, {bool permanent = true}) =>
      _onError?.call(SpeechRecognitionError(errorMsg, permanent));
}
