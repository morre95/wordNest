import 'package:wordnest/core/settings/speech_engine_preferences.dart';
import 'package:wordnest/core/speech/speech_engine.dart';

/// [SpeechEnginePreferences] held in memory, recording every write so a test
/// can assert the choice was persisted and not merely applied.
class FakeSpeechEnginePreferences implements SpeechEnginePreferences {
  FakeSpeechEnginePreferences({
    this.stored = SpeechEngine.phone,
    this.hasAgreed = false,
  });

  SpeechEngine stored;

  /// Whether the user has already been asked about their voice leaving the
  /// device. Set true to test the second and later switches.
  bool hasAgreed;

  final saved = <SpeechEngine>[];
  int agreementCount = 0;

  @override
  Future<SpeechEngine> load() async => stored;

  @override
  Future<void> save(SpeechEngine engine) async {
    stored = engine;
    saved.add(engine);
  }

  @override
  Future<bool> hasAgreedToLeaveDevice() async => hasAgreed;

  @override
  Future<void> recordAgreementToLeaveDevice() async {
    hasAgreed = true;
    agreementCount++;
  }
}
