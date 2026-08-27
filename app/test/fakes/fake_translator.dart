import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/translation/translator.dart';

/// A deterministic [OnDeviceTranslator]: it decorates the input rather than
/// translating it, so assertions can be exact.
class FakeTranslator implements OnDeviceTranslator {
  FakeTranslator({Set<String>? presentModels})
      : presentModels = presentModels ?? {'en', 'es', 'sv', 'de'};

  /// Language codes whose offline model is "downloaded".
  final Set<String> presentModels;

  final translated = <String>[];
  final downloaded = <String>[];

  /// When set, [translate] completes only after this future does, so tests can
  /// interleave a slow translation with a newer transcript.
  Future<void>? gate;

  /// When true, [downloadModel] fails.
  bool downloadFails = false;

  @override
  Future<String> translate(String text, {required LanguagePair pair}) async {
    for (final language in [pair.source, pair.target]) {
      if (!presentModels.contains(language.code)) {
        throw TranslationFailure(
          TranslationFailureKind.modelMissing,
          language: language,
        );
      }
    }
    if (gate != null) await gate;
    translated.add(text);
    return '[${pair.target.code}] $text';
  }

  @override
  Future<ModelState> modelState(Language language) async =>
      presentModels.contains(language.code)
          ? ModelState.present
          : ModelState.absent;

  @override
  Future<void> downloadModel(Language language, {bool requireWifi = true}) async {
    downloaded.add(language.code);
    if (downloadFails) {
      throw TranslationFailure(
        TranslationFailureKind.modelDownloadFailed,
        language: language,
      );
    }
    presentModels.add(language.code);
  }

  @override
  Future<void> deleteModel(Language language) async =>
      presentModels.remove(language.code);

  @override
  Future<void> dispose() async {}
}
