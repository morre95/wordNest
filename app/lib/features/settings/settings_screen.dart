import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_api.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../glossary/widgets/empty_state.dart';
import 'settings_controller.dart';
import 'widgets/pairing_dialogs.dart';
import 'widgets/sync_status_tile.dart';

/// Sync status, the devices on this account, and the two ways to add another.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    final status = ref.watch(syncStatusProvider).value;
    final state = ref.watch(syncStateProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _SectionHeader('Sync'),
          if (status != null)
            SyncStatusTile(
              status: status,
              state: state,
              onRetry: () => ref.read(syncEngineProvider).synchronise(),
            ),
          const _SectionHeader('Your words'),
          if (session == null)
            const ListTile(
              leading: Icon(Icons.wifi_off_outlined),
              title: Text('Not connected yet'),
              subtitle: Text(
                'Everything you say is saved on this device. It will back up '
                'as soon as WordNest can reach the internet.',
              ),
            )
          else ...[
            if (session.isAnonymous)
              ListTile(
                key: const Key('settings.backUp'),
                leading: const Icon(Icons.mail_outline),
                title: const Text('Back up your words'),
                subtitle: const Text(
                  'Add an email so you can pick up where you left off on '
                  'another device.',
                ),
                onTap: () => _attachEmail(context, ref),
              )
            else
              const ListTile(
                leading: Icon(Icons.verified_outlined),
                title: Text('Backed up'),
                subtitle: Text('Your words are saved to your account.'),
              ),
            ListTile(
              key: const Key('settings.addDevice'),
              leading: const Icon(Icons.qr_code_2_outlined),
              title: const Text('Add another device'),
              subtitle: const Text('Show a code to type on your other device.'),
              onTap: () => _showCode(context, ref),
            ),
            ListTile(
              key: const Key('settings.joinDevice'),
              leading: const Icon(Icons.login_outlined),
              title: const Text('Use my words on this device'),
              subtitle: const Text('Type the code from your other device.'),
              onTap: () => _joinWithCode(context, ref),
            ),
          ],
          const _SectionHeader('Devices'),
          _DeviceList(),
          const _SectionHeader('Privacy'),
          const ListTile(
            leading: Icon(Icons.mic_none_outlined),
            title: Text('Your voice is never recorded'),
            subtitle: Text(
              'Speech is turned into text on this device. No audio is saved to '
              'disk, uploaded, or kept after the words are recognised. Only '
              'text is stored or sent.',
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _showCode(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final code = await ref.read(sessionManagerProvider).createPairingCode();
      if (!context.mounted) return;
      await showPairingCode(context, code);
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(_explain(error))));
    }
  }

  Future<void> _joinWithCode(BuildContext context, WidgetRef ref) async {
    final code = await askForPairingCode(context);
    if (code == null || code.isEmpty) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(sessionManagerProvider).redeemPairingCode(code);
      // The account changed underneath us, so everything on the other device
      // has to be pulled down before the glossary makes sense.
      await ref.read(syncEngineProvider).synchronise();
      ref.invalidate(devicesProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('Your words are on their way.')),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.code == 'PAIRING_CODE_INVALID'
                ? 'That code is not right, or it has expired. Ask the other '
                    'device for a new one.'
                : _explain(error),
          ),
        ),
      );
    }
  }

  Future<void> _attachEmail(BuildContext context, WidgetRef ref) async {
    final email = await askForEmail(context);
    if (email == null || email.isEmpty) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);

    try {
      await ref.read(sessionManagerProvider).requestMagicLink(email);
      messenger.showSnackBar(
        SnackBar(content: Text('Check $email for a link.')),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(_explain(error))));
    }
  }

  static String _explain(ApiException error) => switch (error.kind) {
        ApiFailureKind.unreachable =>
          'No connection. Your words are safe on this device.',
        ApiFailureKind.throttled => 'Too many tries. Wait a moment.',
        ApiFailureKind.unauthenticated => 'You have been signed out.',
        _ => 'That did not work. Try again in a moment.',
      };
}

class _DeviceList extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(devicesProvider);

    return devices.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => const ListTile(
        leading: Icon(Icons.cloud_off_outlined),
        title: Text('Your devices could not be listed'),
        subtitle: Text('This needs a connection. Nothing is lost.'),
      ),
      data: (list) => list.isEmpty
          ? const EmptyState(
              icon: Icons.devices_other_outlined,
              title: 'No other devices',
              message: 'Add one to pick up where you left off.',
            )
          : Column(
              children: [
                for (final device in list)
                  ListTile(
                    key: Key('settings.device.${device.id}'),
                    leading: Icon(
                      device.platform == 'ios'
                          ? Icons.phone_iphone
                          : Icons.phone_android,
                    ),
                    title: Text(
                      device.isCurrent
                          ? '${device.displayName} (this device)'
                          : device.displayName,
                    ),
                    subtitle: Text(
                      device.isActive
                          ? 'Added ${device.createdAt.toLocal().toString().split(' ').first}'
                          : 'Signed out',
                    ),
                    trailing: device.isCurrent || !device.isActive
                        ? null
                        : TextButton(
                            onPressed: () => _revoke(context, ref, device),
                            child: const Text('Sign out'),
                          ),
                  ),
              ],
            ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    DeviceSummary device,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign out ${device.displayName}?'),
        content: const Text(
          'That device will stop syncing. The words it already has stay on it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(sessionManagerProvider).revokeDevice(device.id);
    ref.invalidate(devicesProvider);
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
