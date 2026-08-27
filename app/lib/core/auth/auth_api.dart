import '../network/api_client.dart';
import '../network/timestamps.dart';
import 'session.dart';

/// One device signed in to the account, as the settings list shows it.
class DeviceSummary {
  const DeviceSummary({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.isCurrent,
    required this.createdAt,
    this.lastSeenAt,
    this.revokedAt,
  });

  factory DeviceSummary.fromJson(Map<String, Object?> json) {
    return DeviceSummary(
      id: json['id']! as String,
      displayName: json['display_name']! as String,
      platform: json['platform']! as String,
      isCurrent: json['is_current']! as bool,
      createdAt: parseServerTimestamp(json['created_at']! as String),
      lastSeenAt: parseServerTimestampOrNull(json['last_seen_at']),
      revokedAt: parseServerTimestampOrNull(json['revoked_at']),
    );
  }

  final String id;
  final String displayName;
  final String platform;
  final bool isCurrent;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final DateTime? revokedAt;

  bool get isActive => revokedAt == null;

}

/// A code shown on one device and typed into another.
class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;
}

/// The identity endpoints, one method per operation.
abstract interface class AuthApi {
  Future<Session> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  });

  Future<Session> refresh(String refreshToken);

  Future<List<DeviceSummary>> listDevices();

  Future<void> revokeDevice(String deviceId);

  Future<PairingCode> createPairingCode();

  Future<Session> redeemPairingCode(String code);

  Future<DateTime> requestMagicLink(String email);

  Future<Session> redeemMagicLink(String token);
}

class HttpAuthApi implements AuthApi {
  const HttpAuthApi(this._client);

  final ApiClient _client;

  @override
  Future<Session> registerDevice({
    required String deviceId,
    required String displayName,
    required String platform,
  }) async {
    final data = await _client.post(
      '/auth/devices',
      body: {
        'device_id': deviceId,
        'display_name': displayName,
        'platform': platform,
      },
      authenticated: false,
    );
    return _session(data);
  }

  @override
  Future<Session> refresh(String refreshToken) async {
    final data = await _client.post(
      '/auth/refresh',
      body: {'refresh_token': refreshToken},
      authenticated: false,
    );
    return _session(data);
  }

  @override
  Future<List<DeviceSummary>> listDevices() async {
    final data = await _client.get('/auth/devices');
    final devices = data['devices'] as List<dynamic>? ?? const [];
    return devices
        .cast<Map<String, Object?>>()
        .map(DeviceSummary.fromJson)
        .toList(growable: false);
  }

  @override
  Future<void> revokeDevice(String deviceId) =>
      _client.delete('/auth/devices/$deviceId');

  @override
  Future<PairingCode> createPairingCode() async {
    final data = await _client.post('/auth/pairing-codes', body: const {});
    return PairingCode(
      code: data['code']! as String,
      expiresAt: parseServerTimestamp(data['expires_at']! as String),
    );
  }

  @override
  Future<Session> redeemPairingCode(String code) async {
    final data = await _client.post(
      '/auth/pairing-codes/redeem',
      body: {'code': code},
    );
    return _session(data);
  }

  @override
  Future<DateTime> requestMagicLink(String email) async {
    final data = await _client.post('/auth/magic-links', body: {'email': email});
    return parseServerTimestamp(data['expires_at']! as String);
  }

  @override
  Future<Session> redeemMagicLink(String token) async {
    final data = await _client.post(
      '/auth/magic-links/redeem',
      body: {'token': token},
    );
    return _session(data);
  }

  static Session _session(Map<String, dynamic> data) => Session(
        accessToken: data['access_token']! as String,
        refreshToken: data['refresh_token']! as String,
        expiresAt: parseServerTimestamp(data['expires_at']! as String),
        accountId: data['account_id']! as String,
        deviceId: data['device_id']! as String,
        isAnonymous: data['is_anonymous']! as bool,
      );
}
