import 'package:shared_preferences/shared_preferences.dart';

import '../models/language.dart';

/// Remembers the language pair between launches, so the speak screen is ready
/// to listen without asking anything.
abstract interface class LanguagePreferences {
  Future<LanguagePair> load();
  Future<void> save(LanguagePair pair);
}

class SharedPreferencesLanguagePreferences implements LanguagePreferences {
  SharedPreferencesLanguagePreferences({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'wordnest.language_pair';

  final SharedPreferencesAsync _preferences;

  @override
  Future<LanguagePair> load() async {
    final stored = await _preferences.getString(_key);
    if (stored == null) return Languages.defaultPair;
    return LanguagePair.parseKey(stored) ?? Languages.defaultPair;
  }

  @override
  Future<void> save(LanguagePair pair) => _preferences.setString(_key, pair.key);
}
