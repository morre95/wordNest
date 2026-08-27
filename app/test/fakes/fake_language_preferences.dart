import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/settings/language_preferences.dart';

class FakeLanguagePreferences implements LanguagePreferences {
  FakeLanguagePreferences([this.stored = Languages.defaultPair]);

  LanguagePair stored;
  final saved = <LanguagePair>[];

  @override
  Future<LanguagePair> load() async => stored;

  @override
  Future<void> save(LanguagePair pair) async {
    stored = pair;
    saved.add(pair);
  }
}
