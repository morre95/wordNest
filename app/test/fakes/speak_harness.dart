import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';

import 'fake_language_preferences.dart';
import 'fake_microphone_permissions.dart';
import 'fake_speech_recognizer.dart';
import 'fake_translator.dart';

/// The provider overrides every speak test needs, in one place, so a test only
/// spells out the fake whose behaviour it is actually varying.
List<Override> speakOverrides({
  required FakeSpeechRecognizer recognizer,
  required FakeTranslator translator,
  FakeMicrophonePermissions? permissions,
  FakeLanguagePreferences? preferences,
  LanguagePair pair = Languages.defaultPair,
}) {
  return [
    initialLanguagePairProvider.overrideWithValue(pair),
    speechRecognizerProvider.overrideWithValue(recognizer),
    onDeviceTranslatorProvider.overrideWithValue(translator),
    microphonePermissionsProvider
        .overrideWithValue(permissions ?? FakeMicrophonePermissions()),
    languagePreferencesProvider
        .overrideWithValue(preferences ?? FakeLanguagePreferences()),
  ];
}
