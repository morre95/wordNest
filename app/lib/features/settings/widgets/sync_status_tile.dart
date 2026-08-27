import 'package:flutter/material.dart';

import '../../../core/db/sync_repository.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/sync/sync_engine.dart';

/// What sync is doing, when it last worked, and a way to try again now.
///
/// Never alarming: a device that has not synced is still a fully working app,
/// so the wording says what is true rather than what is broken.
class SyncStatusTile extends StatelessWidget {
  const SyncStatusTile({
    required this.status,
    required this.state,
    required this.onRetry,
    super.key,
  });

  final SyncStatus status;
  final SyncState? state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastSynced = state?.lastSyncedAt ?? status.lastSyncedAt;

    return ListTile(
      key: const Key('settings.syncStatus'),
      leading: status.isRunning
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              switch (status.phase) {
                SyncPhase.failed => Icons.cloud_off_outlined,
                SyncPhase.succeeded => Icons.cloud_done_outlined,
                _ => Icons.cloud_queue_outlined,
              },
              color: status.phase == SyncPhase.failed
                  ? theme.colorScheme.error
                  : null,
            ),
      title: Text(_title()),
      subtitle: Text(
        lastSynced == null
            ? 'Your words are safe on this device either way.'
            : 'Last synced ${_ago(lastSynced)}.',
      ),
      trailing: status.isRunning
          ? null
          : TextButton(
              key: const Key('settings.syncRetry'),
              onPressed: onRetry,
              child: const Text('Sync now'),
            ),
    );
  }

  String _title() {
    if (status.isRunning) return 'Syncing…';
    // Never synced is not the same as nothing to sync, and saying the wrong one
    // is how a user comes to distrust the whole line.
    if (status.phase == SyncPhase.idle && state?.lastSyncedAt == null) {
      return 'Not synced yet';
    }
    if (status.phase == SyncPhase.failed) {
      final pending = status.pendingChanges;
      final waiting = pending == 0
          ? ''
          : ' $pending change${pending == 1 ? '' : 's'} waiting.';
      return '${_failureText(status.failure)}$waiting';
    }
    return 'Everything is synced';
  }

  static String _failureText(ApiFailureKind? failure) => switch (failure) {
        ApiFailureKind.unreachable => 'Not connected.',
        ApiFailureKind.unauthenticated => 'Signed out — sign in again.',
        ApiFailureKind.throttled => 'Slowed down by the server.',
        ApiFailureKind.temporarilyUnavailable ||
        ApiFailureKind.serverError =>
          'The server is having trouble.',
        ApiFailureKind.rejected => 'Some changes were refused.',
        null => 'Not synced yet.',
      };

  static String _ago(DateTime moment) {
    final elapsed = DateTime.now().toUtc().difference(moment.toUtc());
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
    return '${elapsed.inDays} d ago';
  }
}
