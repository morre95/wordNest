import 'package:shared_preferences/shared_preferences.dart';

import '../speech/speech_engine.dart';

/// Remembers which recogniser the user chose, and whether they have been told
/// what choosing Deepgram means.
///
/// Lives here rather than under `core/speech` because it reads storage, and
/// nothing in the audio pipeline is allowed to.
abstract interface class SpeechEnginePreferences {
  Future<SpeechEngine> load();
  Future<void> save(SpeechEngine engine);

  /// Whether the user has already agreed to their voice leaving the device.
  /// Asked once, not every time they switch back and forth.
  Future<bool> hasAgreedToLeaveDevice();
  Future<void> recordAgreementToLeaveDevice();
}

class SharedPreferencesSpeechEnginePreferences
    implements SpeechEnginePreferences {
  SharedPreferencesSpeechEnginePreferences({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _engineKey = 'wordnest.speech_engine';
  static const _agreementKey = 'wordnest.speech_engine_agreement';

  final SharedPreferencesAsync _preferences;

  @override
  Future<SpeechEngine> load() async {
    final stored = await _preferences.getString(_engineKey);
    if (stored == null) return SpeechEngine.fallback;
    return SpeechEngine.byKey(stored) ?? SpeechEngine.fallback;
  }

  @override
  Future<void> save(SpeechEngine engine) =>
      _preferences.setString(_engineKey, engine.storageKey);

  @override
  Future<bool> hasAgreedToLeaveDevice() async =>
      await _preferences.getBool(_agreementKey) ?? false;

  @override
  Future<void> recordAgreementToLeaveDevice() =>
      _preferences.setBool(_agreementKey, true);
}
