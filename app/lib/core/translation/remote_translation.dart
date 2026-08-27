import 'package:freezed_annotation/freezed_annotation.dart';

part 'remote_translation.freezed.dart';
part 'remote_translation.g.dart';

/// One word of the source sentence, as the backend broke it down.
@freezed
abstract class TranslatedToken with _$TranslatedToken {
  const factory TranslatedToken({
    required String surfaceForm,
    required String lemma,
    required String partOfSpeech,
    required String targetForm,
    required bool isContentWord,
  }) = _TranslatedToken;

  factory TranslatedToken.fromJson(Map<String, Object?> json) =>
      _$TranslatedTokenFromJson(json);
}

/// The backend's answer: a better translation than on-device models produce,
/// plus the vocabulary breakdown the glossary is built from.
@freezed
abstract class RemoteTranslation with _$RemoteTranslation {
  const factory RemoteTranslation({
    required String sourceText,
    required String sourceLanguage,
    required String targetLanguage,
    required String translation,
    String? literalGloss,
    @Default(<TranslatedToken>[]) List<TranslatedToken> tokens,
  }) = _RemoteTranslation;

  factory RemoteTranslation.fromJson(Map<String, Object?> json) =>
      _$RemoteTranslationFromJson(json);
}
