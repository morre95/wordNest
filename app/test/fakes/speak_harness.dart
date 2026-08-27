import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';

import 'fake_language_preferences.dart';
import 'fake_microphone_permissions.dart';
import 'fake_speech_recognizer.dart';
import 'fake_translator.dart';

/// An in-memory database for a test that does not care what was written, torn
/// down with the test. No test may ever reach the real on-device database.
WordNestDatabase _throwawayDatabase() {
  final database = WordNestDatabase.memory();
  addTearDown(database.close);
  return database;
}

/// The provider overrides every speak test needs, in one place, so a test only
/// spells out the fake whose behaviour it is actually varying.
List<Override> speakOverrides({
  required FakeSpeechRecognizer recognizer,
  required FakeTranslator translator,
  FakeMicrophonePermissions? permissions,
  FakeLanguagePreferences? preferences,
  WordNestDatabase? database,
  LanguagePair pair = Languages.defaultPair,
}) {
  return [
    initialLanguagePairProvider.overrideWithValue(pair),
    databaseProvider.overrideWithValue(database ?? _throwawayDatabase()),
    speechRecognizerProvider.overrideWithValue(recognizer),
    onDeviceTranslatorProvider.overrideWithValue(translator),
    microphonePermissionsProvider
        .overrideWithValue(permissions ?? FakeMicrophonePermissions()),
    languagePreferencesProvider
        .overrideWithValue(preferences ?? FakeLanguagePreferences()),
  ];
}
