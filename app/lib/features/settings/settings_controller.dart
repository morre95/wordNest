import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_api.dart';
import '../../core/auth/session.dart';
import '../../core/db/sync_repository.dart';
import '../../core/providers.dart';
import '../../core/sync/sync_engine.dart';

/// The session this install holds, or null before it has one.
final sessionProvider = StreamProvider.autoDispose<Session?>((ref) {
  final manager = ref.watch(sessionManagerProvider);
  final controller = StreamController<Session?>();
  void emit() => controller.add(manager.session.value);
  manager.session.addListener(emit);
  emit();
  // Registering is the only way an install without a session gets one, and
  // opening settings is a perfectly good moment to try again.
  ref.onDispose(() {
    manager.session.removeListener(emit);
    controller.close();
  });
  ref.onAddListener(() => manager.ensureSession());
  return controller.stream;
});

/// Sync status, live, straight from the engine.
final syncStatusProvider = StreamProvider.autoDispose<SyncStatus>((ref) {
  final engine = ref.watch(syncEngineProvider);
  final controller = StreamController<SyncStatus>();
  void emit() => controller.add(engine.status.value);
  engine.status.addListener(emit);
  emit();
  ref.onDispose(() {
    engine.status.removeListener(emit);
    controller.close();
  });
  return controller.stream;
});

/// When this device last reconciled, from the local database rather than from
/// memory, so it survives a restart.
final syncStateProvider = StreamProvider.autoDispose<SyncState>(
  (ref) => ref.watch(syncRepositoryProvider).watchState(),
);

/// The devices signed in to this account. Refetched, not streamed: the list
/// only changes when the user does something.
///
/// Automatic retry is off. Riverpod's default is to retry a failed provider
/// with backoff while staying in a loading state, which on a device with no
/// network means a spinner that never resolves — the user is told nothing, and
/// the screen looks broken. Failing visibly is the honest answer; the list is
/// refetched when the user does something that would change it.
final devicesProvider = FutureProvider.autoDispose<List<DeviceSummary>>(
  (ref) => ref.watch(sessionManagerProvider).listDevices(),
  retry: (retryCount, error) => null,
);
