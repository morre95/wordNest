import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:wordnest/core/settings/speech_engine_preferences.dart';
import 'package:wordnest/core/speech/speech_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferencesAsync storage;
  late SharedPreferencesSpeechEnginePreferences preferences;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    storage = SharedPreferencesAsync();
    preferences = SharedPreferencesSpeechEnginePreferences(
      preferences: storage,
    );
  });

  group('SpeechEnginePreferences', () {
    test('a device that has never chosen is on the phone', () async {
      expect(await preferences.load(), SpeechEngine.phone);
    });

    test('remembers the chosen engine', () async {
      await preferences.save(SpeechEngine.deepgram);

      expect(await preferences.load(), SpeechEngine.deepgram);
    });

    test('an engine this build does not know falls back to the phone',
        () async {
      // A value written by a newer version. Falling back is right; throwing
      // would take the whole app down over a settings row.
      await storage.setString('wordnest.speech_engine', 'whisper');

      expect(await preferences.load(), SpeechEngine.phone);
    });

    test('nobody has agreed to anything until they say so', () async {
      expect(await preferences.hasAgreedToLeaveDevice(), isFalse);

      await preferences.recordAgreementToLeaveDevice();

      expect(await preferences.hasAgreedToLeaveDevice(), isTrue);
    });
  });

  group('SpeechEngine.byKey', () {
    test('reads back every engine it can write', () {
      for (final engine in SpeechEngine.values) {
        expect(SpeechEngine.byKey(engine.storageKey), engine);
      }
    });

    test('is null for anything else', () {
      expect(SpeechEngine.byKey('nonsense'), isNull);
    });
  });
}
