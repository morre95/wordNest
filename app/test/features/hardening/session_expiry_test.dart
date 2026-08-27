import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/auth/session.dart';
import 'package:wordnest/core/auth/session_manager.dart';
import 'package:wordnest/core/network/api_exception.dart';

import '../../fakes/fake_session.dart';

/// A session that has expired, been revoked, or been signed out mid-use.
///
/// The rule throughout: nothing on the device is lost, and nothing about the
/// session blocks the microphone. The worst case is that syncing stops until
/// the install has a session again.
void main() {
  late FakeAuthApi auth;
  late InMemorySessionStore store;
  late SessionManager sessions;

  setUp(() {
    auth = FakeAuthApi();
    store = InMemorySessionStore();
    sessions = SessionManager(
      authApi: auth,
      sessionStore: store,
      deviceIdentity: FakeDeviceIdentity(),
    );
  });

  tearDown(() => sessions.dispose());

  Session expiredSession() => Session(
        accessToken: 'stale',
        refreshToken: 'stale-refresh',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        accountId: 'account-1',
        deviceId: 'device-1',
        isAnonymous: true,
      );

  group('a first launch with no network', () {
    test('leaves the app without a session rather than failing', () async {
      auth.failure = const ApiException(ApiFailureKind.unreachable);

      expect(await sessions.ensureSession(), isNull);
      expect(sessions.hasSession, isFalse);
    });

    test('registers as soon as the network comes back', () async {
      auth.failure = const ApiException(ApiFailureKind.unreachable);
      await sessions.ensureSession();

      auth.failure = null;
      final session = await sessions.ensureSession();

      expect(session, isNotNull);
      expect(await store.read(), isNotNull);
    });
  });

  group('an expired access token', () {
    test('is renewed before the request rather than after a rejection',
        () async {
      await store.write(expiredSession());

      final token = await sessions.current();

      expect(auth.refreshCount, 1);
      expect(token, isNot('stale'));
    });

    test('renews once even when several requests notice at the same moment',
        () async {
      // Refresh tokens rotate, so a second use looks like theft to the server
      // and would sign the user out.
      await store.write(expiredSession());

      await Future.wait([
        sessions.renew(),
        sessions.renew(),
        sessions.renew(),
      ]);

      expect(auth.refreshCount, 1);
    });
  });

  group('a revoked session', () {
    test('registers this install again rather than leaving it stuck', () async {
      await store.write(expiredSession());
      auth.failure = const ApiException(
        ApiFailureKind.unauthenticated,
        code: 'INVALID_CREDENTIALS',
      );

      // The refresh fails, the stored session is cleared, and registering is
      // attempted — which also fails here, since the fake refuses everything.
      final renewed = await sessions.renew();

      expect(renewed, isNull);
      expect(await store.read(), isNull);
    });

    test('a fresh session is obtained once the server accepts one', () async {
      await store.write(expiredSession());
      var callsBeforeRecovery = 0;
      auth.failure = const ApiException(ApiFailureKind.unauthenticated);

      await sessions.renew();
      callsBeforeRecovery = auth.registerCount;
      auth.failure = null;
      final recovered = await sessions.ensureSession();

      expect(recovered, isNotNull);
      expect(auth.registerCount, greaterThan(callsBeforeRecovery));
    });
  });

  group('a network failure during renewal', () {
    test('keeps the session, because it may still be good', () async {
      final stored = expiredSession();
      await store.write(stored);
      auth.failure = const ApiException(ApiFailureKind.unreachable);

      final renewed = await sessions.renew();

      expect(renewed, isNull);
      expect(
        (await store.read())?.refreshToken,
        stored.refreshToken,
        reason: 'a flaky connection must not cost the user their session',
      );
    });
  });

  group('expiry', () {
    test('a token is treated as expired slightly early', () {
      // A token that dies in flight has cost a round trip for nothing.
      final almostExpired = Session(
        accessToken: 'a',
        refreshToken: 'b',
        expiresAt: DateTime.now().toUtc().add(const Duration(seconds: 5)),
        accountId: 'account-1',
        deviceId: 'device-1',
        isAnonymous: true,
      );

      expect(almostExpired.isExpiredAt(DateTime.now()), isTrue);
    });

    test('a token with time left is not', () {
      final fresh = Session(
        accessToken: 'a',
        refreshToken: 'b',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
        accountId: 'account-1',
        deviceId: 'device-1',
        isAnonymous: true,
      );

      expect(fresh.isExpiredAt(DateTime.now()), isFalse);
    });
  });
}
