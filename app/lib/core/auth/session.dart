import 'package:freezed_annotation/freezed_annotation.dart';

part 'session.freezed.dart';
part 'session.g.dart';

/// The credentials this install holds.
///
/// Created silently on first launch — no email, no password, nothing the user
/// has to do — which is what lets sync and backup work from the first sentence.
@freezed
abstract class Session with _$Session {
  const Session._();

  const factory Session({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
    required String accountId,
    required String deviceId,

    /// False once an email is attached. The settings screen uses this to
    /// decide whether to offer "use WordNest on another device".
    required bool isAnonymous,
  }) = _Session;

  factory Session.fromJson(Map<String, Object?> json) =>
      _$SessionFromJson(json);

  /// Treated as expired a little early, so a request is not sent with a token
  /// that will have died by the time it arrives.
  bool isExpiredAt(DateTime now) =>
      !expiresAt.toUtc().subtract(const Duration(seconds: 30)).isAfter(now.toUtc());
}
