import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/models/language.dart';

void main() {
  group('LanguagePair', () {
    test('round-trips through its storage key', () {
      const pair = LanguagePair(
        source: Language(code: 'sv', name: 'Swedish'),
        target: Language(code: 'de', name: 'German'),
      );

      expect(LanguagePair.parseKey(pair.key), pair);
    });

    test('rejects a malformed key rather than guessing', () {
      expect(LanguagePair.parseKey('sv'), isNull);
      expect(LanguagePair.parseKey('sv-zz'), isNull);
      expect(LanguagePair.parseKey(''), isNull);
    });

    test('swapping reverses the direction', () {
      const pair = LanguagePair(
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'es', name: 'Spanish'),
      );

      expect(pair.swapped.source.code, 'es');
      expect(pair.swapped.target.code, 'en');
      expect(pair.swapped.swapped, pair);
    });
  });

  group('Languages', () {
    test('every supported language has a unique code', () {
      final codes = Languages.all.map((language) => language.code).toSet();

      expect(codes.length, Languages.all.length);
    });

    test('the default pair is made of supported languages', () {
      expect(Languages.byCode(Languages.defaultPair.source.code), isNotNull);
      expect(Languages.byCode(Languages.defaultPair.target.code), isNotNull);
    });
  });
}
