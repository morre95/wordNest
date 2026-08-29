import 'package:flutter/foundation.dart';

import '../../core/models/language.dart';

/// A recoverable problem worth telling the user about without taking over the
/// screen. Every case carries what the user can do about it, so the banner has
/// no logic of its own.
@immutable
sealed class SpeakNotice {
  const SpeakNotice();
}

/// The microphone has not been granted yet; asking again will work.
class MicrophoneDenied extends SpeakNotice {
  const MicrophoneDenied();

  @override
  bool operator ==(Object other) => other is MicrophoneDenied;
  @override
  int get hashCode => (MicrophoneDenied).hashCode;
}

/// Denied for good — only the system settings screen can undo it.
class MicrophoneBlocked extends SpeakNotice {
  const MicrophoneBlocked();

  @override
  bool operator ==(Object other) => other is MicrophoneBlocked;
  @override
  int get hashCode => (MicrophoneBlocked).hashCode;
}

/// No recogniser on this device at all.
class RecognitionUnavailable extends SpeakNotice {
  const RecognitionUnavailable();

  @override
  bool operator ==(Object other) => other is RecognitionUnavailable;
  @override
  int get hashCode => (RecognitionUnavailable).hashCode;
}

/// The device cannot recognise the chosen source language.
class LanguageNotRecognised extends SpeakNotice {
  const LanguageNotRecognised(this.language);
  final Language language;

  @override
  bool operator ==(Object other) =>
      other is LanguageNotRecognised && other.language == language;
  @override
  int get hashCode => Object.hash(LanguageNotRecognised, language);
}

/// The offline translation model for [language] is not on the device.
class TranslationModelMissing extends SpeakNotice {
  const TranslationModelMissing(this.language, {this.isDownloading = false});
  final Language language;
  final bool isDownloading;

  @override
  bool operator ==(Object other) =>
      other is TranslationModelMissing &&
      other.language == language &&
      other.isDownloading == isDownloading;
  @override
  int get hashCode => Object.hash(TranslationModelMissing, language, isDownloading);
}

/// A model download was started and did not finish.
class TranslationModelDownloadFailed extends SpeakNotice {
  const TranslationModelDownloadFailed(this.language);
  final Language language;

  @override
  bool operator ==(Object other) =>
      other is TranslationModelDownloadFailed && other.language == language;
  @override
  int get hashCode => Object.hash(TranslationModelDownloadFailed, language);
}

/// The session ended without hearing anything.
class NothingHeard extends SpeakNotice {
  const NothingHeard();

  @override
  bool operator ==(Object other) => other is NothingHeard;
  @override
  int get hashCode => (NothingHeard).hashCode;
}

/// The chosen recogniser's service could not be reached, so the phone's own
/// recogniser took the session instead.
class SpeechServiceUnreachable extends SpeakNotice {
  const SpeechServiceUnreachable();

  @override
  bool operator ==(Object other) => other is SpeechServiceUnreachable;
  @override
  int get hashCode => (SpeechServiceUnreachable).hashCode;
}

/// The online recogniser could not be reached. Distinct from
/// [SpeechServiceUnreachable], which is the cloud engine falling back to the
/// phone: here the phone's own recogniser is the one that needed the network.
class SpeechNetworkUnavailable extends SpeakNotice {
  const SpeechNetworkUnavailable();

  @override
  bool operator ==(Object other) => other is SpeechNetworkUnavailable;
  @override
  int get hashCode => (SpeechNetworkUnavailable).hashCode;
}

/// The microphone could not be read, most often because something else holds
/// it. Nothing to do with permission, which has its own notices.
class MicrophoneUnavailable extends SpeakNotice {
  const MicrophoneUnavailable();

  @override
  bool operator ==(Object other) => other is MicrophoneUnavailable;
  @override
  int get hashCode => (MicrophoneUnavailable).hashCode;
}

/// Recognition failed for a reason we cannot name usefully.
class RecognitionFailed extends SpeakNotice {
  const RecognitionFailed({this.detail});
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is RecognitionFailed && other.detail == detail;
  @override
  int get hashCode => Object.hash(RecognitionFailed, detail);
}

/// On-device translation failed for a reason the user cannot fix.
class TranslationFailed extends SpeakNotice {
  const TranslationFailed({this.detail});
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is TranslationFailed && other.detail == detail;
  @override
  int get hashCode => Object.hash(TranslationFailed, detail);
}

/// The utterance could not be written to the local database.
class CouldNotSave extends SpeakNotice {
  const CouldNotSave();

  @override
  bool operator ==(Object other) => other is CouldNotSave;
  @override
  int get hashCode => (CouldNotSave).hashCode;
}
