/// The one audio boundary in WordNest.
///
/// AUDIO POLICY — read before changing anything in this directory.
///
/// Everything that crosses *this interface* is [String] text. Audio never gets
/// this far up.
///
/// On the default setting, microphone audio is owned end-to-end by the platform
/// recogniser and this app never receives a sample. Choosing Deepgram in
/// settings changes that: WordNest captures PCM frames and streams them to its
/// own server, which relays them on. That is a real weakening of what this
/// directory used to promise, and it is confined as narrowly as it can be —
/// exactly two files may touch a frame, one to read it from the microphone and
/// one to put it on a socket, and each forwards it and forgets it.
///
/// What did not change: no file, ever. There is deliberately no `File`, no
/// `path_provider` and no `dart:io` import anywhere under `lib/core/speech/`,
/// no buffer that could accumulate a recording, and no path by which the two
/// audio-carrying files could reach storage.
/// `test/core/speech/no_audio_persistence_test.dart` asserts all of that
/// mechanically — including which files are allowed the exception — and that a
/// recognition session on either engine writes nothing to the application
/// document or cache directories.
library;

import 'dart:async';

/// Why a recognition session could not start or could not continue.
enum SpeechFailureKind {
  /// The user has not granted microphone access yet.
  permissionDenied,

  /// The user denied permanently; only Settings can undo it.
  permissionPermanentlyDenied,

  /// No recogniser on this device, or the plugin failed to initialise.
  unavailable,

  /// The recogniser works but not for the requested language.
  localeUnsupported,

  /// The recogniser heard nothing before it timed out.
  noSpeechDetected,

  /// The transcription service could not be reached. Not the phone's fault,
  /// and the phone's own recogniser can still be asked instead.
  serviceUnreachable,

  /// The recogniser needed a network it could not reach, or the service
  /// behind it refused. Only the online recogniser can fail this way.
  networkUnavailable,

  /// The microphone itself could not be read — held by another app, or a
  /// capture error. Nothing about the language or the network is wrong.
  audioUnavailable,

  /// Anything the platform reported that we cannot act on specifically.
  recognitionFailed,
}

/// A failure with enough detail for the UI to explain itself.
class SpeechFailure implements Exception {
  const SpeechFailure(this.kind, {this.detail, this.isPermanent = true});

  final SpeechFailureKind kind;
  final String? detail;

  /// A transient failure means the user can simply try again.
  final bool isPermanent;

  @override
  String toString() => 'SpeechFailure($kind, $detail)';
}

/// What the recogniser is doing right now.
enum SpeechLifecycle { idle, listening, processing, done }

/// Everything the recogniser tells us. Text only — never audio.
sealed class SpeechEvent {
  const SpeechEvent();
}

/// An in-progress transcription. Replaces the previous partial in full.
class SpeechPartial extends SpeechEvent {
  const SpeechPartial(this.text);
  final String text;
}

/// The recogniser has settled on this utterance and will not revise it.
class SpeechFinal extends SpeechEvent {
  const SpeechFinal(this.text, {this.confidence});
  final String text;
  final double? confidence;
}

/// Session lifecycle transitions, used to drive the microphone affordance.
class SpeechLifecycleChanged extends SpeechEvent {
  const SpeechLifecycleChanged(this.lifecycle);
  final SpeechLifecycle lifecycle;
}

/// A running estimate of input loudness, 0..1, for the listening animation.
class SpeechSoundLevel extends SpeechEvent {
  const SpeechSoundLevel(this.level);
  final double level;
}

/// Something went wrong. The session may or may not still be alive.
class SpeechFailed extends SpeechEvent {
  const SpeechFailed(this.failure);
  final SpeechFailure failure;
}

/// Where the audio for the running session actually goes.
///
/// A closed set rather than a flag, so the privacy line is a total function of
/// the route and a new engine cannot ship while the screen still describes the
/// old one.
enum SpeechRoute {
  /// The phone's own offline recogniser. The audio does not leave the device.
  onDevice,

  /// The phone's own online recogniser — Google's or Apple's. The audio leaves
  /// the device, but it goes to the phone's maker, not to WordNest.
  phoneOnline,

  /// WordNest's own server, which passes the audio straight on to a
  /// transcription service and passes the text back. Only ever reached because
  /// the user chose it in settings.
  wordnestServer,
}

/// Which recogniser the running session ended up on. Emitted whenever a session
/// starts and again if it moves, so the privacy line on screen describes where
/// the user's voice is actually going rather than where we hoped it would go.
class SpeechRouteChanged extends SpeechEvent {
  const SpeechRouteChanged(this.route);
  final SpeechRoute route;
}

/// How long a session should run and how eagerly it should finalise.
enum ListeningMode {
  /// Hold-to-talk: one utterance, finalised when the user lets go.
  single,

  /// Hands-free: keep listening and emit an utterance per natural pause.
  continuous,
}

/// The narrow interface the rest of the app programs against.
///
/// Implementations: [PlatformSpeechRecognizer] in production, `FakeSpeechRecognizer`
/// in tests. Nothing outside this directory imports `speech_to_text`.
abstract interface class SpeechRecognizer {
  /// Prepares the recogniser. Safe to call more than once; the second call is
  /// a no-op that returns the first call's answer.
  Future<bool> initialize();

  /// Whether [initialize] succeeded and a recogniser exists on this device.
  bool get isAvailable;

  /// Whether a session is currently running.
  bool get isListening;

  /// Platform locale identifiers this device lists, e.g. `en_US`.
  ///
  /// This is a language-selection list, not proof that an offline model is
  /// installed. Android distinguishes installed models from models that are
  /// merely supported, and callers must not infer one from the other.
  Future<List<String>> availableLocaleIds();

  /// A single broadcast stream of text-only events.
  Stream<SpeechEvent> get events;

  /// Starts a session for [languageCode] (BCP-47 primary tag).
  ///
  /// Throws [SpeechFailure] if the session cannot start.
  Future<void> start({
    required String languageCode,
    ListeningMode mode = ListeningMode.single,
  });

  /// Ends the session and asks the recogniser to finalise what it has.
  Future<void> stop();

  /// Ends the session and discards the in-flight utterance.
  Future<void> cancel();

  Future<void> dispose();
}

/// The locale to ask the platform recogniser for, and whether the supplied
/// candidate list contained a matching language.
typedef SpeechLocale = ({String localeId, bool hasOnDeviceModel});

/// Chooses the platform speech locale to use for a BCP-47 language tag.
///
/// When [availableLocaleIds] is an installed-model list, the boolean says an
/// offline model is ready. When it is the broader list from `speech_to_text`,
/// callers use the locale choice only. A miss never means the phone cannot
/// recognise the language online: it falls back to the bare primary tag.
///
/// Pure so it can be tested against the awkward cases: a device that only has
/// `en_GB` when we asked for English, a device that lists nothing for the
/// language at all, and a device that reports locales with a `-` separator.
SpeechLocale resolveSpeechLocale({
  required String languageCode,
  required List<String> availableLocaleIds,
  String? systemLocaleId,
}) {
  String languageOf(String localeId) =>
      localeId.replaceAll('-', '_').split('_').first.toLowerCase();

  final wanted = languageCode.toLowerCase();
  final matches = availableLocaleIds
      .where((id) => languageOf(id) == wanted)
      .toList(growable: false);
  if (matches.isEmpty) {
    return (localeId: wanted, hasOnDeviceModel: false);
  }

  // Prefer the system locale when it is one of the matches, so a British user
  // asking for English gets en_GB rather than whatever sorts first.
  if (systemLocaleId != null && matches.contains(systemLocaleId)) {
    return (localeId: systemLocaleId, hasOnDeviceModel: true);
  }
  // Then prefer the "plain" tag (`en`) or the one whose region echoes the
  // language (`sv_SE`, `de_DE`), which is the conventional default.
  final conventional = '${wanted}_${wanted.toUpperCase()}';
  for (final candidate in [wanted, conventional]) {
    for (final id in matches) {
      if (id.replaceAll('-', '_').toLowerCase() == candidate.toLowerCase()) {
        return (localeId: id, hasOnDeviceModel: true);
      }
    }
  }
  return (localeId: matches.first, hasOnDeviceModel: true);
}
