import 'package:flutter/foundation.dart';

/// One content word pulled out of a sentence.
@immutable
class ExtractedWord {
  const ExtractedWord({required this.surfaceForm, required this.lemma});

  /// The word exactly as it appeared in the sentence.
  final String surfaceForm;

  /// The form the glossary is keyed on. Offline this is only a normalisation —
  /// lowercased and stripped of punctuation — not a real lemma. The backend's
  /// lemmatiser corrects it when enrichment arrives.
  final String lemma;

  @override
  bool operator ==(Object other) =>
      other is ExtractedWord &&
      other.surfaceForm == surfaceForm &&
      other.lemma == lemma;

  @override
  int get hashCode => Object.hash(surfaceForm, lemma);

  @override
  String toString() => 'ExtractedWord($surfaceForm → $lemma)';
}

/// Pulls candidate vocabulary out of an utterance with no network and no model.
///
/// This is the offline half of the glossary. It is deliberately crude: it
/// tokenises, drops function words, and normalises case. The backend replaces
/// its guesses with real lemmas and parts of speech when it is reachable, and
/// [ExtractedWord.lemma] is what the two agree on in the meantime.
///
/// Pure and free of I/O so it can be exhaustively tested.
List<ExtractedWord> extractVocabulary(
  String sentence, {
  required String languageCode,
}) {
  final stopwords = _stopwords[languageCode] ?? const <String>{};
  final seen = <String>{};
  final words = <ExtractedWord>[];

  for (final token in _tokenise(sentence)) {
    final lemma = token.toLowerCase();
    if (!_isContentWord(lemma, stopwords)) continue;
    if (!seen.add(lemma)) continue;
    words.add(ExtractedWord(surfaceForm: token, lemma: lemma));
  }
  return words;
}

/// Splits on anything that is not a letter, a mark, or an internal apostrophe
/// or hyphen. Unicode-aware so it does not shred non-Latin scripts.
Iterable<String> _tokenise(String sentence) {
  final token = RegExp(r"[\p{L}\p{M}]+(?:['’\-][\p{L}\p{M}]+)*", unicode: true);
  return token.allMatches(sentence).map((match) => match.group(0)!);
}

bool _isContentWord(String lemma, Set<String> stopwords) {
  // Single characters are almost always articles, particles or noise. Scripts
  // where one character is a word (Chinese, Japanese) have no stopword list
  // here, so they are kept — better a few function words than no vocabulary.
  if (lemma.length < 2 && stopwords.isNotEmpty) return false;
  if (lemma.isEmpty) return false;
  return !stopwords.contains(lemma);
}

/// Function words for the languages most likely to be a user's native tongue.
///
/// A language with no list here yields every token, which over-collects rather
/// than under-collects: an extra entry is visible and can be deleted, a missing
/// one is invisible.
const _stopwords = <String, Set<String>>{
  'en': {
    'a', 'an', 'the', 'and', 'or', 'but', 'if', 'then', 'than', 'so', 'as',
    'of', 'to', 'in', 'on', 'at', 'by', 'for', 'from', 'with', 'without',
    'into', 'about', 'over', 'under', 'up', 'down', 'out', 'off',
    'i', 'you', 'he', 'she', 'it', 'we', 'they', 'me', 'him', 'her', 'us',
    'them', 'my', 'your', 'his', 'its', 'our', 'their', 'this', 'that',
    'these', 'those', 'who', 'whom', 'which', 'what', 'where', 'when', 'why',
    'how', 'is', 'am', 'are', 'was', 'were', 'be', 'been', 'being', 'do',
    'does', 'did', 'have', 'has', 'had', 'will', 'would', 'can', 'could',
    'shall', 'should', 'may', 'might', 'must', 'not', 'no', 'yes', 'there',
    'here', 'very', 'just', 'too', 'also',
  },
  'es': {
    'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas', 'y', 'o', 'pero',
    'si', 'de', 'del', 'a', 'al', 'en', 'con', 'sin', 'por', 'para', 'sobre',
    'yo', 'tú', 'él', 'ella', 'nosotros', 'vosotros', 'ellos', 'ellas', 'me',
    'te', 'se', 'nos', 'os', 'mi', 'tu', 'su', 'este', 'esta', 'esto', 'ese',
    'esa', 'que', 'quien', 'cual', 'donde', 'cuando', 'como', 'es', 'son',
    'era', 'eran', 'ser', 'estar', 'está', 'están', 'hay', 'ha', 'han',
    'no', 'sí', 'muy', 'ya', 'también', 'lo', 'le', 'les',
  },
  'fr': {
    'le', 'la', 'les', 'un', 'une', 'des', 'et', 'ou', 'mais', 'si', 'de',
    'du', 'à', 'au', 'aux', 'en', 'dans', 'avec', 'sans', 'pour', 'par',
    'sur', 'je', 'tu', 'il', 'elle', 'nous', 'vous', 'ils', 'elles', 'me',
    'te', 'se', 'mon', 'ton', 'son', 'ce', 'cette', 'ces', 'qui', 'que',
    'quoi', 'où', 'quand', 'comment', 'est', 'sont', 'était', 'être', 'avoir',
    'a', 'ai', 'as', 'ont', 'ne', 'pas', 'non', 'oui', 'très', 'aussi',
  },
  'de': {
    'der', 'die', 'das', 'den', 'dem', 'des', 'ein', 'eine', 'einen', 'einem',
    'einer', 'und', 'oder', 'aber', 'wenn', 'von', 'zu', 'in', 'im', 'an',
    'am', 'auf', 'mit', 'ohne', 'für', 'über', 'unter', 'ich', 'du', 'er',
    'sie', 'es', 'wir', 'ihr', 'mich', 'dich', 'sich', 'uns', 'mein', 'dein',
    'sein', 'dieser', 'diese', 'dieses', 'wer', 'was', 'wo', 'wann', 'wie',
    'ist', 'sind', 'war', 'waren', 'haben', 'hat', 'hatte', 'nicht',
    'nein', 'ja', 'sehr', 'auch', 'schon', 'noch',
  },
  'sv': {
    'en', 'ett', 'den', 'det', 'de', 'och', 'eller', 'men', 'om', 'av',
    'till', 'i', 'på', 'med', 'utan', 'för', 'över', 'under', 'jag', 'du',
    'han', 'hon', 'vi', 'ni', 'mig', 'dig', 'sig', 'oss', 'min', 'din',
    'sin', 'denna', 'detta', 'dessa', 'vem', 'vad', 'var', 'när', 'hur',
    'är', 'vara', 'har', 'hade', 'ha', 'inte', 'nej', 'ja', 'mycket',
    'också', 'som', 'att', 'så',
  },
  'it': {
    'il', 'lo', 'la', 'i', 'gli', 'le', 'un', 'uno', 'una', 'e', 'o', 'ma',
    'se', 'di', 'del', 'a', 'al', 'in', 'nel', 'con', 'senza', 'per', 'su',
    'io', 'tu', 'lui', 'lei', 'noi', 'voi', 'loro', 'mi', 'ti', 'si', 'ci',
    'mio', 'tuo', 'suo', 'questo', 'questa', 'quello', 'che', 'chi', 'dove',
    'quando', 'come', 'è', 'sono', 'era', 'essere', 'avere', 'ha', 'hanno',
    'non', 'no', 'sì', 'molto', 'anche',
  },
  'pt': {
    'o', 'a', 'os', 'as', 'um', 'uma', 'uns', 'umas', 'e', 'ou', 'mas', 'se',
    'de', 'do', 'da', 'dos', 'das', 'em', 'no', 'na', 'com', 'sem', 'para',
    'por', 'sobre', 'eu', 'tu', 'ele', 'ela', 'nós', 'vós', 'eles', 'elas',
    'me', 'te', 'nos', 'meu', 'teu', 'seu', 'este', 'esta', 'isso',
    'que', 'quem', 'onde', 'quando', 'como', 'é', 'são', 'era', 'ser',
    'estar', 'está', 'ter', 'tem', 'têm', 'não', 'sim', 'muito', 'também',
  },
};
