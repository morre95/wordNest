import '../models/language.dart';

/// Why an on-device translation could not be produced.
enum TranslationFailureKind {
  /// The language model for one side of the pair is not downloaded.
  modelMissing,

  /// A download was attempted and did not complete.
  modelDownloadFailed,

  /// The pair itself is not supported by the engine.
  pairUnsupported,

  /// Anything else the engine reported.
  translationFailed,
}

class TranslationFailure implements Exception {
  const TranslationFailure(this.kind, {this.language, this.detail});

  final TranslationFailureKind kind;

  /// The language the failure is about, when it is about one.
  final Language? language;
  final String? detail;

  @override
  String toString() => 'TranslationFailure($kind, ${language?.code}, $detail)';
}

/// Where a language model stands on this device.
enum ModelState { absent, downloading, present, failed }

/// Translation that works with no network, used for live partials.
///
/// Kept narrow on purpose: the backend translator (milestone 3) implements a
/// different, richer interface, and the speak flow chooses between them.
abstract interface class OnDeviceTranslator {
  /// Translates [text] from [pair].source into [pair].target.
  ///
  /// Throws [TranslationFailure] when a model is missing, so callers can offer
  /// the download rather than showing an empty translation.
  Future<String> translate(String text, {required LanguagePair pair});

  Future<ModelState> modelState(Language language);

  /// Downloads a language model. [requireWifi] defaults to true because these
  /// are ~30 MB each and the user did not ask to spend mobile data.
  Future<void> downloadModel(Language language, {bool requireWifi = true});

  Future<void> deleteModel(Language language);

  Future<void> dispose();
}
