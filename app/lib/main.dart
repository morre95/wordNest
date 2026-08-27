import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/providers.dart';
import 'core/settings/language_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The only thing awaited before the first frame: one preferences read, so
  // the speak screen opens on the pair the user last used rather than flashing
  // a default. Everything else — recogniser, translation models — initialises
  // lazily once the microphone is actually asked for.
  final preferences = SharedPreferencesLanguagePreferences();
  final pair = await preferences.load();

  runApp(
    ProviderScope(
      overrides: [
        initialLanguagePairProvider.overrideWithValue(pair),
        languagePreferencesProvider.overrideWithValue(preferences),
      ],
      child: const WordNestApp(),
    ),
  );
}
