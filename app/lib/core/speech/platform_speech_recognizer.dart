import 'dart:async';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../platform/on_device_speech_models.dart';
import 'speech_recognizer.dart';

/// [SpeechRecognizer] backed by the platform recogniser (Android
/// `SpeechRecognizer`, iOS `SFSpeechRecognizer`) via `speech_to_text`.
///
/// AUDIO POLICY: `speech_to_text` streams microphone audio inside the platform
/// recogniser and hands us transcription callbacks. No audio buffer is exposed
/// to Dart, so there is nothing here that could be written to disk even by
/// accident — and nothing in this file opens a file or a socket. This is the
/// default engine, and the one on which WordNest still never handles audio at
/// all.
class PlatformSpeechRecognizer implements SpeechRecognizer {
  PlatformSpeechRecognizer({
    stt.SpeechToText? speech,
    required OnDeviceSpeechModels onDeviceModels,
    Duration listenStartTimeout = const Duration(seconds: 2),
  }) : this._(
         speech: speech ?? stt.SpeechToText(),
         onDeviceModels: onDeviceModels,
         listenStartTimeout: listenStartTimeout,
       );

  PlatformSpeechRecognizer._({
    required this._speech,
    required this._onDeviceModels,
    required this._listenStartTimeout,
  });

  /// How long a pause ends an utterance. Long enough to think mid-sentence,
  /// short enough that a translation feels immediate.
  static const _pauseBeforeFinalising = Duration(seconds: 2);

  /// A hard ceiling so a forgotten hands-free session cannot hold the mic open.
  static const _maxSessionLength = Duration(minutes: 5);

  final stt.SpeechToText _speech;
  final OnDeviceSpeechModels _onDeviceModels;
  final Duration _listenStartTimeout;
  final _events = StreamController<SpeechEvent>.broadcast();

  bool _initialised = false;
  bool _initialising = false;
  Future<bool>? _initialisation;
  ListeningMode _mode = ListeningMode.single;
  String? _languageCode;
  bool _onDevice = true;
  bool _routeAnnounced = false;
  bool _acceptPlatformLifecycle = false;
  int _sessionGeneration = 0;
  Completer<void>? _startConfirmation;

  /// Set when a hands-free utterance finishes, cleared when the next session
  /// has been asked for. The restart waits for the platform to say `done`
  /// rather than happening in the result callback: Android has not released
  /// the recogniser at the moment a final result arrives, and starting there
  /// earns ERROR_RECOGNIZER_BUSY instead of a session.
  bool _restartWhenDone = false;

  @override
  bool get isAvailable => _initialised && _speech.isAvailable;

  @override
  bool get isListening => _speech.isListening;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<bool> initialize() {
    if (_initialised) return Future.value(true);
    if (_initialising) return _initialisation!;
    _initialising = true;
    _initialisation = _speech
        .initialize(onError: _onPlatformError, onStatus: _onPlatformStatus)
        .then((worked) {
          _initialised = worked;
          _initialising = false;
          return worked;
        })
        .catchError((Object error) {
          _initialising = false;
          _emit(
            SpeechFailed(
              SpeechFailure(SpeechFailureKind.unavailable, detail: '$error'),
            ),
          );
          return false;
        });
    return _initialisation!;
  }

  @override
  Future<List<String>> availableLocaleIds() async {
    if (!await initialize()) return const [];
    final locales = await _speech.locales();
    return locales.map((locale) => locale.localeId).toList(growable: false);
  }

  @override
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  }) async {
    if (!await initialize()) {
      throw const SpeechFailure(SpeechFailureKind.unavailable);
    }
    if (!await _speech.hasPermission) {
      throw const SpeechFailure(SpeechFailureKind.permissionDenied);
    }
    if (_speech.isListening) {
      throw const SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: 'recognizer_busy',
      );
    }

    final systemLocale = await _speech.systemLocale();
    final platformLocaleIds = await availableLocaleIds();
    final installedLocaleIds = await _onDeviceModels.installedLocaleIds();
    final availableLocale = resolveSpeechLocale(
      languageCode: languageCode,
      availableLocaleIds: platformLocaleIds,
      systemLocaleId: systemLocale?.localeId,
    );
    final installedLocale = installedLocaleIds == null
        ? null
        : resolveSpeechLocale(
            languageCode: languageCode,
            availableLocaleIds: installedLocaleIds,
            systemLocaleId: systemLocale?.localeId,
          );

    // Android supplies a precise installed-model list through WordNest's
    // native bridge. A model that is merely supported is not enough: forcing
    // it offline produces ERROR_LANGUAGE_UNAVAILABLE. Platforms without that
    // distinction retain speech_to_text's locale-based behaviour.
    final useInstalledModel = installedLocale?.hasOnDeviceModel ?? false;
    final locale = useInstalledModel ? installedLocale! : availableLocale;

    _mode = mode;
    _languageCode = languageCode;
    _onDevice = installedLocaleIds == null
        ? availableLocale.hasOnDeviceModel
        : useInstalledModel;
    _routeAnnounced = false;
    _acceptPlatformLifecycle = true;
    final generation = ++_sessionGeneration;
    final confirmation = Completer<void>();
    _startConfirmation = confirmation;

    try {
      await Future.wait<void>([
        _listen(
          generation: generation,
          localeId: locale.localeId,
          onDevice: _onDevice,
        ),
        confirmation.future.timeout(_listenStartTimeout),
      ], eagerError: true);
    } on TimeoutException {
      _acceptPlatformLifecycle = false;
      if (generation == _sessionGeneration) {
        await _speech.cancel();
      }
      throw const SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: 'listen_not_started',
      );
    } on SpeechFailure {
      _acceptPlatformLifecycle = false;
      if (generation == _sessionGeneration) {
        await _speech.cancel();
      }
      rethrow;
    } on Exception catch (error) {
      _acceptPlatformLifecycle = false;
      if (generation == _sessionGeneration) {
        await _speech.cancel();
      }
      throw SpeechFailure(
        SpeechFailureKind.recognitionFailed,
        detail: '$error',
      );
    } finally {
      if (identical(_startConfirmation, confirmation)) {
        _startConfirmation = null;
      }
    }
  }

  /// Emits, unless this recogniser has been disposed.
  ///
  /// `speech_to_text` routes its callbacks through one platform channel, so a
  /// recogniser replaced mid-flight — by the user changing engine, say — can
  /// still be handed an error the platform had already queued. Emitting it
  /// would add to a closed controller and take the app down.
  void _emit(SpeechEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  Future<void> _listen({
    required int generation,
    required String localeId,
    required bool onDevice,
  }) {
    return _speech.listen(
      onResult: (result) => _onResult(generation, result),
      onSoundLevelChange: (level) => _onSoundLevel(generation, level),
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        onDevice: onDevice,
        partialResults: true,
        cancelOnError: false,
        listenMode: stt.ListenMode.dictation,
        autoPunctuation: true,
        pauseFor: _pauseBeforeFinalising,
        listenFor: _maxSessionLength,
      ),
    );
  }

  void _onResult(int generation, SpeechRecognitionResult result) {
    if (generation != _sessionGeneration) return;
    final text = result.recognizedWords.trim();
    if (result.finalResult) {
      if (text.isEmpty) {
        _emit(
          const SpeechFailed(
            SpeechFailure(
              SpeechFailureKind.noSpeechDetected,
              isPermanent: false,
            ),
          ),
        );
      } else {
        _emit(SpeechFinal(text, confidence: result.confidence));
      }
      if (_mode == ListeningMode.continuous && _languageCode != null) {
        // Hands-free: the platform ends the session at each pause and the next
        // one opens on `done`, once the recogniser has actually been released.
        _restartWhenDone = true;
      }
    } else if (text.isNotEmpty) {
      _emit(SpeechPartial(text));
    }
  }

  Future<void> _restartContinuous() async {
    try {
      await start(languageCode: _languageCode!, mode: ListeningMode.continuous);
    } on SpeechFailure catch (failure) {
      _emit(SpeechFailed(failure));
    }
  }

  void _onSoundLevel(int generation, double level) {
    if (generation != _sessionGeneration) return;
    // speech_to_text reports roughly -2..10 on Android and dB on iOS; clamp to
    // a 0..1 band the animation can use without knowing the platform.
    _emit(SpeechSoundLevel((level / 10).clamp(0.0, 1.0)));
  }

  void _onPlatformStatus(String status) {
    if (!_acceptPlatformLifecycle) return;

    if (status == 'listening') {
      final confirmation = _startConfirmation;
      if (confirmation != null && !confirmation.isCompleted) {
        confirmation.complete();
      }
      if (!_routeAnnounced) {
        _routeAnnounced = true;
        _emit(
          SpeechRouteChanged(
            _onDevice ? SpeechRoute.onDevice : SpeechRoute.phoneOnline,
          ),
        );
      }
    }

    final lifecycle = switch (status) {
      'listening' => SpeechLifecycle.listening,
      'notListening' => SpeechLifecycle.processing,
      'done' => SpeechLifecycle.done,
      _ => null,
    };
    if (lifecycle != null) _emit(SpeechLifecycleChanged(lifecycle));

    if (status != 'done') return;
    if (!_restartWhenDone) {
      _acceptPlatformLifecycle = false;
      return;
    }
    _restartWhenDone = false;
    // A stop or a cancel between the result and this point turns hands-free
    // off, and the session the user ended must stay ended.
    if (_mode != ListeningMode.continuous || _languageCode == null) return;
    unawaited(_restartContinuous());
  }

  void _onPlatformError(SpeechRecognitionError error) {
    final failure = _translateError(error);
    final confirmation = _startConfirmation;
    if (confirmation != null && !confirmation.isCompleted) {
      confirmation.completeError(failure);
      return;
    }
    _acceptPlatformLifecycle = false;
    _emit(SpeechFailed(failure));
  }

  static SpeechFailure _translateError(SpeechRecognitionError error) {
    final kind = switch (error.errorMsg) {
      'error_speech_timeout' ||
      'error_no_match' => SpeechFailureKind.noSpeechDetected,
      'error_permission' => SpeechFailureKind.permissionDenied,
      'error_language_not_supported' ||
      'error_language_unavailable' => SpeechFailureKind.localeUnsupported,
      // The networked recogniser is reached over the internet, so these say
      // nothing about the microphone or the language — only that the service
      // behind it is out of reach right now.
      'error_network' ||
      'error_network_timeout' ||
      'error_server' ||
      'error_server_disconnected' ||
      'error_too_many_requests' => SpeechFailureKind.networkUnavailable,
      'error_audio_error' => SpeechFailureKind.audioUnavailable,
      // Busy and client errors are the recogniser tripping over itself; a
      // second attempt usually works, which is all the user can be told.
      'error_busy' || 'error_client' => SpeechFailureKind.recognitionFailed,
      _ => SpeechFailureKind.recognitionFailed,
    };
    return SpeechFailure(
      kind,
      detail: error.errorMsg,
      isPermanent: error.permanent,
    );
  }

  @override
  Future<void> stop() async {
    _mode = ListeningMode.single;
    _restartWhenDone = false;
    await _speech.stop();
  }

  @override
  Future<void> cancel() async {
    _mode = ListeningMode.single;
    _restartWhenDone = false;
    _acceptPlatformLifecycle = false;
    _sessionGeneration++;
    final confirmation = _startConfirmation;
    if (confirmation != null && !confirmation.isCompleted) {
      confirmation.complete();
    }
    await _speech.cancel();
    _emit(const SpeechLifecycleChanged(SpeechLifecycle.idle));
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _events.close();
  }
}
