import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';

void main() {
  group('resolveSpeechLocaleId', () {
    test('prefers the system locale when it speaks the wanted language', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'en',
        availableLocaleIds: const ['en_US', 'en_GB', 'sv_SE'],
        systemLocaleId: 'en_GB',
      );

      expect(resolved, 'en_GB');
    });

    test('prefers the plain language tag when the device offers one', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'en',
        availableLocaleIds: const ['en_AU', 'en', 'en_US'],
        systemLocaleId: 'sv_SE',
      );

      expect(resolved, 'en');
    });

    test('falls back to the region that echoes the language', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'de',
        availableLocaleIds: const ['de_AT', 'de_DE', 'de_CH'],
        systemLocaleId: 'en_US',
      );

      expect(resolved, 'de_DE');
    });

    test('accepts any regional variant when nothing distinguishes them', () {
      // sv_FI and sv_SE both recognise Swedish; with no system-locale signal
      // there is no principled winner, so we must still pick one rather than
      // refuse to listen.
      final resolved = resolveSpeechLocaleId(
        languageCode: 'sv',
        availableLocaleIds: const ['sv_FI'],
        systemLocaleId: 'en_US',
      );

      expect(resolved, 'sv_FI');
    });

    test('accepts dash-separated locale identifiers', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'de',
        availableLocaleIds: const ['de-DE', 'fr-FR'],
      );

      expect(resolved, 'de-DE');
    });

    test('takes any regional variant rather than giving up', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'pt',
        availableLocaleIds: const ['pt_BR'],
      );

      expect(resolved, 'pt_BR');
    });

    test('returns null when the device cannot recognise the language', () {
      final resolved = resolveSpeechLocaleId(
        languageCode: 'cy',
        availableLocaleIds: const ['en_US', 'es_ES'],
      );

      expect(resolved, isNull);
    });
  });
}
