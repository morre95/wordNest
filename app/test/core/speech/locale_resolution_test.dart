import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/speech/speech_recognizer.dart';

void main() {
  group('resolveSpeechLocale', () {
    test('prefers the system locale when it speaks the wanted language', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'en',
        availableLocaleIds: const ['en_US', 'en_GB', 'sv_SE'],
        systemLocaleId: 'en_GB',
      );

      expect(resolved, (localeId: 'en_GB', hasOnDeviceModel: true));
    });

    test('prefers the plain language tag when the device offers one', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'en',
        availableLocaleIds: const ['en_AU', 'en', 'en_US'],
        systemLocaleId: 'sv_SE',
      );

      expect(resolved, (localeId: 'en', hasOnDeviceModel: true));
    });

    test('falls back to the region that echoes the language', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'de',
        availableLocaleIds: const ['de_AT', 'de_DE', 'de_CH'],
        systemLocaleId: 'en_US',
      );

      expect(resolved, (localeId: 'de_DE', hasOnDeviceModel: true));
    });

    test('accepts any regional variant when nothing distinguishes them', () {
      // sv_FI and sv_SE both recognise Swedish; with no system-locale signal
      // there is no principled winner, so we must still pick one rather than
      // refuse to listen.
      final resolved = resolveSpeechLocale(
        languageCode: 'sv',
        availableLocaleIds: const ['sv_FI'],
        systemLocaleId: 'en_US',
      );

      expect(resolved, (localeId: 'sv_FI', hasOnDeviceModel: true));
    });

    test('accepts dash-separated locale identifiers', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'de',
        availableLocaleIds: const ['de-DE', 'fr-FR'],
      );

      expect(resolved, (localeId: 'de-DE', hasOnDeviceModel: true));
    });

    test('takes any regional variant rather than giving up', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'pt',
        availableLocaleIds: const ['pt_BR'],
      );

      expect(resolved, (localeId: 'pt_BR', hasOnDeviceModel: true));
    });

    test('keeps the language when the device lists no model for it', () {
      // Android lists only what the offline recogniser has, so a Swedish phone
      // with no English pack reports no English — while its online recogniser
      // transcribes English perfectly well. Asking for the bare tag is what
      // lets that session run instead of being refused.
      final resolved = resolveSpeechLocale(
        languageCode: 'en',
        availableLocaleIds: const ['sv_SE'],
        systemLocaleId: 'sv_SE',
      );

      expect(resolved, (localeId: 'en', hasOnDeviceModel: false));
    });

    test('normalises the language tag when nothing matches', () {
      final resolved = resolveSpeechLocale(
        languageCode: 'CY',
        availableLocaleIds: const ['en_US', 'es_ES'],
      );

      expect(resolved, (localeId: 'cy', hasOnDeviceModel: false));
    });
  });
}
