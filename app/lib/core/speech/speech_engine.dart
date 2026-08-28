/// Which recogniser transcribes what the user says.
///
/// The choice is the user's, made in settings, and it decides where their voice
/// goes — so the labels here are what settings shows and the descriptions are
/// what the picker puts under them. Deliberately a closed set with no
/// "automatic": a person who cares enough to look at this setting is owed a
/// straight answer about which one is running.
enum SpeechEngine {
  /// The platform recogniser. Free, works with no connection, and on most
  /// languages never sends audio anywhere.
  phone(
    storageKey: 'phone',
    label: 'Your phone',
    description: 'On-device where possible. Free, and works with no connection.',
  ),

  /// Streamed through WordNest's own server to Deepgram. More accurate, and
  /// the only option that requires the network.
  deepgram(
    storageKey: 'deepgram',
    label: 'Deepgram',
    description: 'More accurate. Needs a connection, and your voice leaves '
        'this device.',
  );

  const SpeechEngine({
    required this.storageKey,
    required this.label,
    required this.description,
  });

  /// Written to storage. Fixed strings rather than [index] so reordering this
  /// enum cannot silently change what a user already chose.
  final String storageKey;

  final String label;
  final String description;

  /// The engine everyone starts on, and the answer to anything unreadable.
  static const fallback = SpeechEngine.phone;

  /// Null for anything this version does not recognise — a value written by a
  /// newer build, say. Callers fall back rather than throwing.
  static SpeechEngine? byKey(String key) {
    for (final engine in values) {
      if (engine.storageKey == key) return engine;
    }
    return null;
  }
}
