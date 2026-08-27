import 'package:google_mlkit_translation/google_mlkit_translation.dart' as mlkit;

import '../models/language.dart';
import 'translator.dart';

/// [OnDeviceTranslator] backed by ML Kit's downloadable translation models.
///
/// This is the only file that knows ML Kit exists. It is imported with a
/// prefix because ML Kit's own class is also called `OnDeviceTranslator`.
///
/// One native translator is cached per language pair: constructing one is
/// cheap, but each keeps a session open on the platform side.
class MlKitTranslator implements OnDeviceTranslator {
  MlKitTranslator({mlkit.OnDeviceTranslatorModelManager? modelManager})
      : _models = modelManager ?? mlkit.OnDeviceTranslatorModelManager();

  final mlkit.OnDeviceTranslatorModelManager _models;
  final _translators = <String, mlkit.OnDeviceTranslator>{};
  final _downloading = <String>{};

  @override
  Future<String> translate(String text, {required LanguagePair pair}) async {
    if (text.trim().isEmpty) return '';
    final source = _toMlKit(pair.source);
    final target = _toMlKit(pair.target);

    for (final entry in [(pair.source, source), (pair.target, target)]) {
      if (!await _models.isModelDownloaded(entry.$2.bcpCode)) {
        throw TranslationFailure(
          TranslationFailureKind.modelMissing,
          language: entry.$1,
        );
      }
    }

    final translator = _translators.putIfAbsent(
      pair.key,
      () => mlkit.OnDeviceTranslator(
        sourceLanguage: source,
        targetLanguage: target,
      ),
    );
    try {
      return await translator.translateText(text);
    } on Exception catch (error) {
      throw TranslationFailure(
        TranslationFailureKind.translationFailed,
        detail: '$error',
      );
    }
  }

  @override
  Future<ModelState> modelState(Language language) async {
    final code = _toMlKit(language).bcpCode;
    if (_downloading.contains(code)) return ModelState.downloading;
    return await _models.isModelDownloaded(code)
        ? ModelState.present
        : ModelState.absent;
  }

  @override
  Future<void> downloadModel(
    Language language, {
    bool requireWifi = true,
  }) async {
    final code = _toMlKit(language).bcpCode;
    _downloading.add(code);
    try {
      final downloaded = await _models.downloadModel(
        code,
        isWifiRequired: requireWifi,
      );
      if (!downloaded) {
        throw TranslationFailure(
          TranslationFailureKind.modelDownloadFailed,
          language: language,
        );
      }
    } on TranslationFailure {
      rethrow;
    } on Exception catch (error) {
      throw TranslationFailure(
        TranslationFailureKind.modelDownloadFailed,
        language: language,
        detail: '$error',
      );
    } finally {
      _downloading.remove(code);
    }
  }

  @override
  Future<void> deleteModel(Language language) async {
    final code = _toMlKit(language).bcpCode;
    await _models.deleteModel(code);
    final stale = _translators.keys
        .where((key) => key.split('-').contains(language.code))
        .toList(growable: false);
    for (final key in stale) {
      await _translators.remove(key)!.close();
    }
  }

  @override
  Future<void> dispose() async {
    for (final translator in _translators.values) {
      await translator.close();
    }
    _translators.clear();
  }

  static mlkit.TranslateLanguage _toMlKit(Language language) {
    final translateLanguage = mlkit.BCP47Code.fromRawValue(language.code);
    if (translateLanguage == null) {
      throw TranslationFailure(
        TranslationFailureKind.pairUnsupported,
        language: language,
      );
    }
    return translateLanguage;
  }
}
