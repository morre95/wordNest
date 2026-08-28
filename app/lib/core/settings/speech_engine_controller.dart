import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../speech/speech_engine.dart';

/// The recogniser the app is currently set to use.
///
/// Seeded from storage before the first frame, so nothing downstream has to
/// deal with a loading state for a value that is known at launch and decides
/// which recogniser gets built.
class SpeechEngineController extends Notifier<SpeechEngine> {
  @override
  SpeechEngine build() => ref.read(initialSpeechEngineProvider);

  /// Changes the engine and remembers it.
  ///
  /// The state is written before the save is awaited: the recogniser should
  /// swap the moment the user chooses, and a storage write that fails is a
  /// setting that does not survive a restart, not a setting that did not take.
  Future<void> choose(SpeechEngine engine) async {
    if (engine == state) return;
    state = engine;
    await ref.read(speechEnginePreferencesProvider).save(engine);
  }
}
