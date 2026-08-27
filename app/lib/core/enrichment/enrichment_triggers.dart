import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

/// Runs [onTrigger] at the two moments a backlog is most likely to drain: when
/// the app comes back to the foreground, and when the device regains a network.
///
/// Kept apart from [EnrichmentService] so the service stays free of platform
/// plugins and can be tested without either.
class EnrichmentTriggers with WidgetsBindingObserver {
  EnrichmentTriggers({
    required Future<void> Function() drainQueue,
    Stream<List<ConnectivityResult>>? connectivity,
  })  : _onTrigger = drainQueue,
        _connectivity = connectivity ?? Connectivity().onConnectivityChanged;

  final Future<void> Function() _onTrigger;
  final Stream<List<ConnectivityResult>> _connectivity;

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _hadConnection = true;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _subscription = _connectivity.listen(_onConnectivityChanged);
    // Drain whatever accumulated while the app was closed.
    unawaited(_onTrigger());
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_onTrigger());
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection =
        results.any((result) => result != ConnectivityResult.none);
    // Only on the transition into having a network: the platform emits this
    // stream on every interface change, and draining on each would be noise.
    if (hasConnection && !_hadConnection) unawaited(_onTrigger());
    _hadConnection = hasConnection;
  }
}
