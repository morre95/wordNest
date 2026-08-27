import 'dart:async';

import 'package:flutter/foundation.dart';

import '../network/api_client.dart';
import '../network/api_exception.dart';
import 'auth_api.dart';
import 'device_identity.dart';
import 'session.dart';
import 'session_store.dart';

/// Owns this install's session: creates one silently, keeps it fresh, and
/// replaces it when the user joins another account.
///
/// **Never blocks the microphone.** Every method here can fail, and failing
/// means the app carries on speaking and saving locally with a queue that
/// drains later. Nothing on the speak path awaits this class.
class SessionManager implements AccessTokens {
  SessionManager({
    required AuthApi authApi,
    required SessionStore sessionStore,
    required DeviceIdentity deviceIdentity,
  })  : _api = authApi,
        _store = sessionStore,
        _identity = deviceIdentity;

  final AuthApi _api;
  final SessionStore _store;
  final DeviceIdentity _identity;

  final _session = ValueNotifier<Session?>(null);

  /// One renewal at a time. Two requests hitting a 401 together must not both
  /// spend the refresh token — the server rotates it, so the second use would
  /// look like theft and sign the user out.
  Future<Session?>? _renewal;

  ValueListenable<Session?> get session => _session;

  bool get hasSession => _session.value != null;

  /// Loads a stored session, or registers this install to create one.
  ///
  /// Returns null when the backend could not be reached. That is a normal
  /// first launch on a plane, not an error: the app works, and this is retried
  /// on the next sync trigger.
  Future<Session?> ensureSession() async {
    final stored = _session.value ?? await _store.read();
    if (stored != null) {
      _session.value = stored;
      return stored;
    }
    return _register();
  }

  Future<Session?> _register() async {
    try {
      final registered = await _api.registerDevice(
        deviceId: await _identity.deviceId(),
        displayName: _identity.displayName(),
        platform: _identity.platform(),
      );
      await _persist(registered);
      return registered;
    } on ApiException catch (error) {
      debugPrint('WordNest: could not register this device: $error');
      return null;
    }
  }

  @override
  Future<String?> current() async {
    final session = _session.value ?? await _store.read();
    if (session == null) return null;
    _session.value = session;
    // Renew before sending rather than after a 401: a request that fails on an
    // expired token has already cost a round trip.
    if (!session.isExpiredAt(DateTime.now())) return session.accessToken;
    return renew();
  }

  @override
  Future<String?> renew() async {
    final renewal = _renewal ??= _renewOnce();
    try {
      return (await renewal)?.accessToken;
    } finally {
      if (identical(_renewal, renewal)) _renewal = null;
    }
  }

  Future<Session?> _renewOnce() async {
    final session = _session.value ?? await _store.read();
    if (session == null) return null;
    try {
      final refreshed = await _api.refresh(session.refreshToken);
      await _persist(refreshed);
      return refreshed;
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.unauthenticated) {
        // The refresh token was revoked, expired, or already used. Nothing on
        // this device is lost — the local database is the source of truth —
        // but this install needs a new session.
        debugPrint('WordNest: session ended (${error.code}); registering again');
        await _store.clear();
        _session.value = null;
        return _register();
      }
      // A network problem. Keep the session; the next trigger will try again.
      return null;
    }
  }

  // --- Bringing in another device ----------------------------------------

  Future<PairingCode> createPairingCode() => _api.createPairingCode();

  /// Joins the account that showed [code]. This device's own words are merged
  /// into that account by the server, not discarded.
  Future<Session> redeemPairingCode(String code) async {
    final joined = await _api.redeemPairingCode(code);
    await _persist(joined);
    return joined;
  }

  Future<DateTime> requestMagicLink(String email) => _api.requestMagicLink(email);

  Future<Session> redeemMagicLink(String token) async {
    final upgraded = await _api.redeemMagicLink(token);
    await _persist(upgraded);
    return upgraded;
  }

  Future<List<DeviceSummary>> listDevices() => _api.listDevices();

  Future<void> revokeDevice(String deviceId) => _api.revokeDevice(deviceId);

  Future<void> _persist(Session session) async {
    await _store.write(session);
    _session.value = session;
  }

  void dispose() => _session.dispose();
}
