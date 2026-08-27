import 'package:wordnest/core/tts/speaker.dart';

/// A [Speaker] that records what it was asked to say instead of saying it.
class FakeSpeaker implements Speaker {
  FakeSpeaker({Set<String>? voices})
      : voices = voices ?? {'en', 'es', 'sv', 'de'};

  /// Language codes this device has a voice for.
  final Set<String> voices;

  final spoken = <({String text, String languageCode})>[];
  int stopCount = 0;

  @override
  Future<bool> canSpeak(String languageCode) async =>
      voices.contains(languageCode);

  @override
  Future<void> speak(String text, {required String languageCode}) async {
    if (!voices.contains(languageCode)) {
      throw SpeakerFailure(
        SpeakerFailureKind.voiceUnavailable,
        languageCode: languageCode,
      );
    }
    spoken.add((text: text, languageCode: languageCode));
  }

  @override
  Future<void> stop() async => stopCount++;

  @override
  Future<void> dispose() async {}
}
