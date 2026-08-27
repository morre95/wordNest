import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/auth/auth_api.dart';

/// Shows the code a second device types in.
Future<void> showPairingCode(BuildContext context, PairingCode code) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('settings.pairingCodeDialog'),
      title: const Text('Type this on your other device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            code.code,
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(letterSpacing: 8),
          ),
          const SizedBox(height: 12),
          const Text(
            'Open WordNest on the other device, go to Settings, and choose '
            '"Use my words on this device". The code expires in a few minutes.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Clipboard.setData(ClipboardData(text: code.code)),
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Asks for the code shown on the other device. Returns it, or null.
Future<String?> askForPairingCode(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('settings.enterPairingCodeDialog'),
      title: const Text('Use my words on this device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'On the device that already has your words, open Settings and '
            'choose "Add another device". Type the six digits it shows.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('settings.pairingCodeField'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '000000',
              counterText: '',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('settings.pairingCodeSubmit'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
}

/// Asks for an email address to attach to this account.
Future<String?> askForEmail(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('settings.emailDialog'),
      title: const Text('Back up your words'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'We will email you a link. Opening it on any device signs that '
            'device in to the same words. No password to remember.',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('settings.emailField'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'you@example.com',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('settings.emailSubmit'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: const Text('Send link'),
        ),
      ],
    ),
  );
}
