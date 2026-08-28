import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/providers.dart';

import 'package:wordnest/core/speech/speech_engine.dart';

import 'fake_microphone_stream.dart';
import 'fake_speech_socket.dart';
import 'fake_backend_translator.dart';
import 'fake_language_preferences.dart';
import 'fake_microphone_permissions.dart';
import 'fake_speaker.dart';
import 'fake_speech_engine_preferences.dart';
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
  /// Omit to let the real factory build a recogniser from [engine] — which is
  /// how the engine switch and the cloud path are exercised.
  FakeSpeechRecognizer? recognizer,
  required FakeTranslator translator,
  FakeMicrophonePermissions? permissions,
  FakeLanguagePreferences? preferences,
  WordNestDatabase? database,
  FakeBackendTranslator? backendTranslator,
  FakeSpeaker? speaker,
  LanguagePair pair = Languages.defaultPair,
  SpeechEngine engine = SpeechEngine.phone,
  FakeSpeechEnginePreferences? enginePreferences,
  FakeMicrophoneStream? microphone,
  FakeSpeechSocketFactory? sockets,
}) {
  return [
    initialLanguagePairProvider.overrideWithValue(pair),
    databaseProvider.overrideWithValue(database ?? _throwawayDatabase()),
    // No speak test may reach the network: the real translator would try to
    // contact a development backend that is not running.
    backendTranslatorProvider
        .overrideWithValue(backendTranslator ?? FakeBackendTranslator()),
    speakerProvider.overrideWithValue(speaker ?? FakeSpeaker()),
    if (recognizer != null)
      speechRecognizerProvider.overrideWithValue(recognizer),
    if (microphone != null)
      microphoneStreamProvider.overrideWithValue(microphone),
    if (sockets != null) ...[
      speechSocketFactoryProvider.overrideWithValue(sockets.connect),
      speechCredentialsProvider
          .overrideWithValue(({bool renew = false}) async => 'a-token'),
    ],
    onDeviceTranslatorProvider.overrideWithValue(translator),
    microphonePermissionsProvider
        .overrideWithValue(permissions ?? FakeMicrophonePermissions()),
    languagePreferencesProvider
        .overrideWithValue(preferences ?? FakeLanguagePreferences()),
    initialSpeechEngineProvider.overrideWithValue(engine),
    speechEnginePreferencesProvider.overrideWithValue(
      enginePreferences ?? FakeSpeechEnginePreferences(stored: engine),
    ),
  ];
}
