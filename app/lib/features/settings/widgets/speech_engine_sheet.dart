import 'package:flutter/material.dart';

import '../../../core/speech/speech_engine.dart';

/// The two recognisers, with what each one costs the user underneath it.
///
/// Returns the chosen engine, or null if dismissed. A sheet of list tiles
/// rather than a switch: there are two options today and a switch would have to
/// be relabelled the moment there is a third, and a bare switch announces
/// "on"/"off" to a screen reader with no idea what it toggles.
Future<SpeechEngine?> showSpeechEnginePicker(
  BuildContext context, {
  required SpeechEngine selected,
}) {
  return showModalBottomSheet<SpeechEngine>(
    context: context,
    useSafeArea: true,
    builder: (context) => _SpeechEngineSheet(selected: selected),
  );
}

class _SpeechEngineSheet extends StatelessWidget {
  const _SpeechEngineSheet({required this.selected});

  final SpeechEngine selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Speech recognition',
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 12),
          for (final engine in SpeechEngine.values)
            ListTile(
              key: Key('speechEngine.${engine.storageKey}'),
              title: Text(engine.label),
              subtitle: Text(engine.description),
              selected: engine == selected,
              trailing: engine == selected ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(engine),
            ),
        ],
      ),
    );
  }
}

/// Asks before the user's voice starts leaving the device.
///
/// Asked once, not on every switch: the point is informed consent, and a dialog
/// that appears every time is one people learn to dismiss without reading.
/// Returns true only on an explicit yes.
Future<bool> confirmVoiceLeavesDevice(BuildContext context) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('settings.deepgramConsent'),
      title: const Text('Your voice will leave this device'),
      content: const Text(
        'Deepgram transcribes more accurately than your phone, but to do it '
        'WordNest has to send what you say to its own server, which passes it '
        'straight on to Deepgram and passes the text back.\n\n'
        'Nothing is written to a file, and nothing is kept once the words have '
        'been recognised. Recognition will need a connection.\n\n'
        'You can switch back to your phone at any time.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Use Deepgram'),
        ),
      ],
    ),
  );
  return agreed ?? false;
}
