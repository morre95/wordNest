import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/translation/backend_translator.dart';
import 'package:wordnest/core/translation/remote_translation.dart';

/// A [BackendTranslator] the test drives: it either returns a canned breakdown
/// or fails in a specific, classified way.
class FakeBackendTranslator implements BackendTranslator {
  FakeBackendTranslator({this.response, this.failure});

  /// Returned for any sentence unless [responses] has an entry for it.
  RemoteTranslation? response;

  /// Per-sentence answers, for tests with more than one utterance in flight.
  final Map<String, RemoteTranslation> responses = {};

  /// When set, [translate] throws this instead of answering.
  ApiException? failure;

  final requested = <String>[];

  @override
  Future<RemoteTranslation> translate(
    String text, {
    required LanguagePair pair,
  }) async {
    requested.add(text);
    if (failure != null) throw failure!;
    final canned = responses[text] ?? response;
    if (canned != null) return canned;
    return RemoteTranslation(
      sourceText: text,
      sourceLanguage: pair.source.code,
      targetLanguage: pair.target.code,
      translation: 'enriched: $text',
    );
  }
}
