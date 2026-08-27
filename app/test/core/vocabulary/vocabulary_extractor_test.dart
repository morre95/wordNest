import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/vocabulary/vocabulary_extractor.dart';

List<String> lemmasOf(String sentence, {String languageCode = 'en'}) =>
    extractVocabulary(sentence, languageCode: languageCode)
        .map((word) => word.lemma)
        .toList(growable: false);

void main() {
  group('extractVocabulary', () {
    test('keeps content words and drops function words', () {
      expect(
        lemmasOf('I would like a cup of coffee please'),
        ['like', 'cup', 'coffee', 'please'],
      );
    });

    test('normalises case but remembers the form that was said', () {
      final words = extractVocabulary('Coffee please', languageCode: 'en');

      expect(words.first.surfaceForm, 'Coffee');
      expect(words.first.lemma, 'coffee');
    });

    test('strips punctuation without splitting words apart', () {
      expect(
        lemmasOf("Well, that's a state-of-the-art bakery!"),
        ["well", "that's", 'state-of-the-art', 'bakery'],
      );
    });

    test('collects a word said twice only once', () {
      expect(lemmasOf('coffee and more coffee'), ['coffee', 'more']);
    });

    test('ignores digits, which are not vocabulary', () {
      expect(lemmasOf('I need 3 coffees'), ['need', 'coffees']);
    });

    test('handles a language with its own stopword list', () {
      expect(
        lemmasOf('jag vill ha en kopp kaffe', languageCode: 'sv'),
        ['vill', 'kopp', 'kaffe'],
      );
    });

    test('keeps accented and non-Latin scripts intact', () {
      expect(
        lemmasOf('quisiera una panadería cercana', languageCode: 'es'),
        ['quisiera', 'panadería', 'cercana'],
      );
      expect(lemmasOf('καλημέρα κόσμε', languageCode: 'el'),
          ['καλημέρα', 'κόσμε']);
    });

    test('over-collects rather than under-collects for unlisted languages', () {
      // No stopword list for Japanese, so everything the tokeniser finds is
      // kept. An extra entry is visible and deletable; a missing one is not.
      expect(lemmasOf('こんにちは', languageCode: 'ja'), isNotEmpty);
    });

    test('an empty or wordless utterance yields nothing', () {
      expect(lemmasOf(''), isEmpty);
      expect(lemmasOf('   '), isEmpty);
      expect(lemmasOf('!!! ... ???'), isEmpty);
      expect(lemmasOf('the and of'), isEmpty);
    });
  });
}
