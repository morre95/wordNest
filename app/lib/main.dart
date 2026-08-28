import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/settings/language_preferences.dart';
import 'core/settings/speech_engine_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The only thing awaited before the first frame: the two preferences the
  // speak screen's opening state is made of, so it renders what the user last
  // chose rather than flashing a default. Read concurrently, so this is still
  // one round trip's worth of waiting rather than two. Everything else —
  // recogniser, translation models — initialises lazily once the microphone is
  // actually asked for.
  final preferences = SharedPreferencesLanguagePreferences();
  final enginePreferences = SharedPreferencesSpeechEnginePreferences();
  final (pair, engine) = await (preferences.load(), enginePreferences.load())
      .wait;

  runApp(
    ProviderScope(
      overrides: [
        initialLanguagePairProvider.overrideWithValue(pair),
        languagePreferencesProvider.overrideWithValue(preferences),
        initialSpeechEngineProvider.overrideWithValue(engine),
        speechEnginePreferencesProvider.overrideWithValue(enginePreferences),
      ],
      child: const WordNestApp(),
    ),
  );
}
