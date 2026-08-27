import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Runs background work at the two moments a backlog is most likely to drain:
/// when the app comes back to the foreground, and when the device regains a
/// network.
///
/// Kept apart from the services it triggers so they stay free of platform
/// plugins and can be tested without either.
class BackgroundTriggers with WidgetsBindingObserver {
  BackgroundTriggers({
    required List<Future<void> Function()> onTrigger,
    Stream<List<ConnectivityResult>>? connectivity,
  })  : _tasks = onTrigger,
        _connectivity = connectivity ?? Connectivity().onConnectivityChanged;

  final List<Future<void> Function()> _tasks;
  final Stream<List<ConnectivityResult>> _connectivity;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _hadConnection = true;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _subscription = _connectivity.listen(_onConnectivityChanged);
    // Catch up on whatever accumulated while the app was closed.
    unawaited(_runTasks());
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_runTasks());
  }

  /// Sequentially, not concurrently: enrichment writes rows that sync then
  /// pushes, so doing them in order sends the enriched version rather than the
  /// rough one followed immediately by a correction.
  Future<void> _runTasks() async {
    for (final task in _tasks) {
      await task();
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection =
        results.any((result) => result != ConnectivityResult.none);
    // Only on the transition into having a network: the platform emits this
    // stream on every interface change, and draining on each would be noise.
    if (hasConnection && !_hadConnection) unawaited(_runTasks());
    _hadConnection = hasConnection;
  }
}
