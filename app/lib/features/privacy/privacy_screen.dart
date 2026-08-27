import 'package:flutter/material.dart';

/// What WordNest does with what you say, in plain language.
///
/// Reachable from the privacy line on the speak screen and from settings. The
/// wording avoids "we may" and "in order to provide the service": every
/// sentence here is a specific claim that the code holds up, and the ones about
/// audio are enforced by `test/core/speech/no_audio_persistence_test.dart`.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Your voice and your words')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
        children: [
          _Promise(
            icon: Icons.mic_off_outlined,
            title: 'Your voice is never recorded',
            body: 'When you speak, your phone turns the sound into text as it '
                'happens. WordNest never receives the sound itself. Nothing is '
                'written to a file, nothing is uploaded, and nothing is kept '
                'once the words have been recognised — not even briefly, and '
                'not even to help us improve anything.',
          ),
          _Promise(
            icon: Icons.phone_iphone,
            title: 'Recognition happens on this device',
            body: 'WordNest asks your phone for on-device speech recognition '
                'first. Some languages have no on-device model; for those, your '
                'phone uses its own online recogniser, and the speak screen '
                'says so at the time. Either way WordNest never handles audio.',
          ),
          _Promise(
            icon: Icons.text_fields,
            title: 'Only text is stored or sent',
            body: 'What you said, its translation, and the words we pull out of '
                'it. That is the whole of it. It is saved on this device first, '
                'and it works with no connection at all.',
          ),
          _Promise(
            icon: Icons.cloud_outlined,
            title: 'What the server is for',
            body: 'Three things: better translations than a phone-sized model '
                'can manage, breaking a sentence into words worth learning, and '
                'keeping your glossary in step across your devices. It sees '
                'sentences you have finished saying. It does not write them to '
                'its logs.',
          ),
          _Promise(
            icon: Icons.person_outline,
            title: 'No account needed',
            body: 'WordNest works from the first launch with no email, no '
                'password, and nothing to sign up for. Adding an email is only '
                'for using the same words on a second device, and you can do it '
                'whenever you want to — or never.',
          ),
          _Promise(
            icon: Icons.delete_outline,
            title: 'Deleting means deleting',
            body: 'A word you remove is marked as removed everywhere, on every '
                'device you use, the next time they sync. Signing a device out '
                'from settings stops it syncing straight away.',
          ),
          const SizedBox(height: 16),
          Text(
            'The promise about audio is checked automatically. A test reads the '
            'code that touches the microphone and fails the build if it can '
            'reach a file or the network, and another watches the filesystem '
            'across a whole recognition session.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Promise extends StatelessWidget {
  const _Promise({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      label: title,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 16),
              child: Icon(icon, color: theme.colorScheme.primary),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(body, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
