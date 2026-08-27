import 'dart:async';

import 'package:flutter/foundation.dart';

import '../auth/session_manager.dart';
import '../db/sync_repository.dart';
import '../network/api_exception.dart';
import 'sync_api.dart';

/// What the sync status line shows.
enum SyncPhase {
  /// Never run this launch, or run and nothing to report.
  idle,

  /// A round trip is in flight.
  running,

  /// The last run finished cleanly.
  succeeded,

  /// The last run did not finish. [SyncStatus.failure] says why.
  failed,
}

@immutable
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSyncedAt,
    this.failure,
    this.pendingChanges = 0,
  });

  final SyncPhase phase;
  final DateTime? lastSyncedAt;
  final ApiFailureKind? failure;

  /// Rows waiting to be pushed. Shown so "not synced" is a number, not a mood.
  final int pendingChanges;

  bool get isRunning => phase == SyncPhase.running;

  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastSyncedAt,
    ApiFailureKind? failure,
    bool clearFailure = false,
    int? pendingChanges,
  }) {
    return SyncStatus(
      phase: phase ?? this.phase,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      failure: clearFailure ? null : failure ?? this.failure,
      pendingChanges: pendingChanges ?? this.pendingChanges,
    );
  }
}

/// Reconciles this device with the backend.
///
/// **The microphone never waits on this.** Nothing on the speak path awaits a
/// sync, and a sync that fails leaves the local database exactly as it was —
/// the app stays fully usable and the queue drains when the backend returns.
class SyncEngine {
  SyncEngine({
    required SyncApi syncApi,
    required SyncRepository syncRepository,
    required SessionManager sessionManager,
  })  : _api = syncApi,
        _repository = syncRepository,
        _sessions = sessionManager;

  /// A hard stop on how many pages one run will walk, so a device that has
  /// been off for a fortnight cannot spin here forever on a slow connection.
  /// Whatever is left is picked up by the next trigger.
  static const maxPagesPerRun = 20;

  final SyncApi _api;
  final SyncRepository _repository;
  final SessionManager _sessions;

  final _status = ValueNotifier(const SyncStatus());

  /// One run at a time: a resume and a reconnect arriving together must not
  /// both push the same rows.
  Future<void>? _inFlight;

  ValueListenable<SyncStatus> get status => _status;

  Stream<SyncState> watchState() => _repository.watchState();

  /// Runs a full reconciliation. Never throws.
  Future<void> synchronise() {
    return _inFlight ??= _run().whenComplete(() => _inFlight = null);
  }

  Future<void> _run() async {
    _status.value = _status.value.copyWith(phase: SyncPhase.running);

    // No session means the backend has never been reachable from this install.
    // That is a normal first launch on a plane, not an error.
    final session = await _sessions.ensureSession();
    if (session == null) {
      await _fail(ApiFailureKind.unreachable, 'not registered yet');
      return;
    }

    try {
      for (var page = 0; page < maxPagesPerRun; page++) {
        final hasMore = await _syncOnce();
        if (!hasMore) break;
      }
      final state = await _repository.readState();
      _status.value = _status.value.copyWith(
        phase: SyncPhase.succeeded,
        lastSyncedAt: state.lastSyncedAt,
        clearFailure: true,
        pendingChanges: 0,
      );
    } on ApiException catch (error) {
      await _fail(error.kind, error.code ?? error.kind.name);
    } on Object catch (error, stackTrace) {
      // A local failure — a constraint, a disk problem. Report it and leave the
      // rows dirty; nothing has been lost.
      debugPrint('WordNest: sync failed locally: $error\n$stackTrace');
      await _fail(ApiFailureKind.serverError, '$error');
    }
  }

  /// One round trip. Returns whether the server said there is more to pull.
  Future<bool> _syncOnce() async {
    final pending = await _repository.pendingChanges();

    final page = await _api.sync(
      cursor: (await _repository.readState()).cursor,
      utterances: pending.utterances,
      entries: pending.entries,
      occurrences: pending.occurrences,
      reviews: pending.reviews,
    );

    // Rows the server refused will never be accepted, so clearing their dirty
    // flag stops the queue carrying them forever. They stay on this device.
    final refused = {for (final row in page.rejected) row.id};
    if (refused.isNotEmpty) {
      debugPrint('WordNest: server refused ${refused.length} row(s)');
    }

    await _repository.markPushed(
      utterances: {
        for (final row in pending.utterances) row.id: row.updatedAt,
      },
      entries: {for (final row in pending.entries) row.id: row.updatedAt},
      occurrences: {
        for (final row in pending.occurrences) row.id: row.updatedAt,
      },
      reviews: {for (final row in pending.reviews) row.id: row.updatedAt},
    );

    await _repository.applyRemote(
      utterances: page.utterances,
      utteranceExtras: page.utteranceExtras,
      entries: page.entries,
      occurrences: page.occurrences,
      reviews: page.reviews,
    );

    await _repository.recordSuccess(page.cursor);

    // More to pull, or more to push than fitted in one batch.
    final stillPending = await _repository.pendingChanges(limit: 1);
    final hasPending = stillPending.utterances.isNotEmpty ||
        stillPending.entries.isNotEmpty ||
        stillPending.occurrences.isNotEmpty ||
        stillPending.reviews.isNotEmpty;
    return page.hasMore || hasPending;
  }

  Future<void> _fail(ApiFailureKind kind, String reason) async {
    await _repository.recordFailure(reason);
    final state = await _repository.readState();
    final pending = await _repository.pendingChanges(limit: 500);
    _status.value = _status.value.copyWith(
      phase: SyncPhase.failed,
      failure: kind,
      lastSyncedAt: state.lastSyncedAt,
      pendingChanges: pending.utterances.length +
          pending.entries.length +
          pending.occurrences.length +
          pending.reviews.length,
    );
  }

  void dispose() => _status.dispose();
}
