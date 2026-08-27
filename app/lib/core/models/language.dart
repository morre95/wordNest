import 'package:flutter/foundation.dart';

/// A language WordNest can listen in or translate into.
///
/// [code] is the BCP-47 primary language tag. It is the only identifier that
/// crosses a boundary: it is what we hand to the translation engine, what we
/// store on an utterance row, and what the backend sees. Platform speech
/// locales (`en_US`, `sv_SE`, …) are resolved from it at listen time, because
/// which locales exist depends on the device.
@immutable
class Language {
  const Language({required this.code, required this.name});

  final String code;
  final String name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Language && other.code == code);

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'Language($code)';
}

/// An ordered source→target pair. Immutable; swapping produces a new pair.
@immutable
class LanguagePair {
  const LanguagePair({required this.source, required this.target});

  final Language source;
  final Language target;

  LanguagePair get swapped => LanguagePair(source: target, target: source);

  /// Stable key used for filtering the glossary and for the sync payload.
  String get key => '${source.code}-${target.code}';

  static LanguagePair? parseKey(String key) {
    final parts = key.split('-');
    if (parts.length != 2) return null;
    final source = Languages.byCode(parts[0]);
    final target = Languages.byCode(parts[1]);
    if (source == null || target == null) return null;
    return LanguagePair(source: source, target: target);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LanguagePair &&
          other.source == source &&
          other.target == target);

  @override
  int get hashCode => Object.hash(source, target);

  @override
  String toString() => 'LanguagePair($key)';
}

/// The languages supported by on-device translation.
///
/// This mirrors ML Kit's translation language support. It lives here rather
/// than in the ML Kit adapter so that nothing outside `core/translation`
/// depends on the translation vendor.
abstract final class Languages {
  static const all = <Language>[
    Language(code: 'af', name: 'Afrikaans'),
    Language(code: 'sq', name: 'Albanian'),
    Language(code: 'ar', name: 'Arabic'),
    Language(code: 'be', name: 'Belarusian'),
    Language(code: 'bn', name: 'Bengali'),
    Language(code: 'bg', name: 'Bulgarian'),
    Language(code: 'ca', name: 'Catalan'),
    Language(code: 'zh', name: 'Chinese'),
    Language(code: 'hr', name: 'Croatian'),
    Language(code: 'cs', name: 'Czech'),
    Language(code: 'da', name: 'Danish'),
    Language(code: 'nl', name: 'Dutch'),
    Language(code: 'en', name: 'English'),
    Language(code: 'eo', name: 'Esperanto'),
    Language(code: 'et', name: 'Estonian'),
    Language(code: 'fi', name: 'Finnish'),
    Language(code: 'fr', name: 'French'),
    Language(code: 'gl', name: 'Galician'),
    Language(code: 'ka', name: 'Georgian'),
    Language(code: 'de', name: 'German'),
    Language(code: 'el', name: 'Greek'),
    Language(code: 'gu', name: 'Gujarati'),
    Language(code: 'ht', name: 'Haitian'),
    Language(code: 'he', name: 'Hebrew'),
    Language(code: 'hi', name: 'Hindi'),
    Language(code: 'hu', name: 'Hungarian'),
    Language(code: 'is', name: 'Icelandic'),
    Language(code: 'id', name: 'Indonesian'),
    Language(code: 'ga', name: 'Irish'),
    Language(code: 'it', name: 'Italian'),
    Language(code: 'ja', name: 'Japanese'),
    Language(code: 'kn', name: 'Kannada'),
    Language(code: 'ko', name: 'Korean'),
    Language(code: 'lv', name: 'Latvian'),
    Language(code: 'lt', name: 'Lithuanian'),
    Language(code: 'mk', name: 'Macedonian'),
    Language(code: 'ms', name: 'Malay'),
    Language(code: 'mt', name: 'Maltese'),
    Language(code: 'mr', name: 'Marathi'),
    Language(code: 'no', name: 'Norwegian'),
    Language(code: 'fa', name: 'Persian'),
    Language(code: 'pl', name: 'Polish'),
    Language(code: 'pt', name: 'Portuguese'),
    Language(code: 'ro', name: 'Romanian'),
    Language(code: 'ru', name: 'Russian'),
    Language(code: 'sk', name: 'Slovak'),
    Language(code: 'sl', name: 'Slovenian'),
    Language(code: 'es', name: 'Spanish'),
    Language(code: 'sw', name: 'Swahili'),
    Language(code: 'sv', name: 'Swedish'),
    Language(code: 'tl', name: 'Tagalog'),
    Language(code: 'ta', name: 'Tamil'),
    Language(code: 'te', name: 'Telugu'),
    Language(code: 'th', name: 'Thai'),
    Language(code: 'tr', name: 'Turkish'),
    Language(code: 'uk', name: 'Ukrainian'),
    Language(code: 'ur', name: 'Urdu'),
    Language(code: 'vi', name: 'Vietnamese'),
    Language(code: 'cy', name: 'Welsh'),
  ];

  static final Map<String, Language> _byCode = {
    for (final language in all) language.code: language,
  };

  static Language? byCode(String code) => _byCode[code];

  /// Used when nothing has been remembered yet and the device locale is
  /// unhelpful. English→Spanish is the most common pairing worldwide.
  static const defaultPair = LanguagePair(
    source: Language(code: 'en', name: 'English'),
    target: Language(code: 'es', name: 'Spanish'),
  );
}
