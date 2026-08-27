import 'package:wordnest/core/auth/auth_api.dart';
import 'package:wordnest/core/auth/device_identity.dart';
import 'package:wordnest/core/auth/session.dart';
import 'package:wordnest/core/auth/session_store.dart';
import 'package:wordnest/core/network/api_exception.dart';

class InMemorySessionStore implements SessionStore {
  Session? _stored;

  @override
  Future<Session?> read() async => _stored;

  @override
  Future<void> write(Session session) async => _stored = session;

  @override
  Future<void> clear() async => _stored = null;
}

/// An [AuthApi] that hands out sessions without a server.
class FakeAuthApi implements AuthApi {
  FakeAuthApi({this.accountId = 'account-1'});

  String accountId;

  /// When set, every call throws it — the app with no network.
  ApiException? failure;

  int registerCount = 0;
  int refreshCount = 0;
  final revoked = <String>[];

  Session _session(String deviceId) => Session(
        accessToken: 'access-${refreshCount + registerCount}',
        refreshToken: 'refresh-${refreshCount + registerCount}',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)),
        accountId: accountId,
        deviceId: deviceId,
        isAnonymous: true,
      );

  @override
  Future<Session> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    _check();
    registerCount++;
    return _session(deviceId);
  }

  @override
  Future<Session> refresh(String refreshToken) async {
    _check();
    refreshCount++;
    return _session('device-1');
  }

  @override
  Future<List<DeviceSummary>> listDevices() async {
    _check();
    return const [];
  }

  @override
  Future<void> revokeDevice(String deviceId) async {
    _check();
    revoked.add(deviceId);
  }

  @override
  Future<PairingCode> createPairingCode() async => PairingCode(
        code: '123456',
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
      );

  @override
  Future<Session> redeemPairingCode(String code) async => _session('device-1');

  @override
  Future<DateTime> requestMagicLink(String email) async =>
      DateTime.now().toUtc().add(const Duration(minutes: 20));

  @override
  Future<Session> redeemMagicLink(String token) async => _session('device-1');

  void _check() {
    if (failure != null) throw failure!;
  }
}

class FakeDeviceIdentity implements DeviceIdentity {
  FakeDeviceIdentity([this.id = 'device-1']);

  final String id;

  @override
  Future<String> deviceId() async => id;

  @override
  String displayName() => 'Test device';

  @override
  String platform() => 'android';
}
