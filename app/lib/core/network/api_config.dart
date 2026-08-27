/// Where the backend lives, and how patient the app is with it.
///
/// Supplied at build time so a debug build can point at a laptop and a release
/// build at production, with no runtime switch a user could trip over:
///
/// ```
/// flutter run --dart-define=WORDNEST_API_BASE_URL=http://192.168.1.10:8000
/// ```
abstract final class ApiConfig {
  /// `10.0.2.2` is the host machine as seen from the Android emulator, which is
  /// the most common way this app is run during development.
  static const baseUrl = String.fromEnvironment(
    'WORDNEST_API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );

  static const apiPrefix = '/api/v1';

  /// Short on purpose. The device already has an on-device translation to show;
  /// waiting a long time for a better one is worse than not waiting.
  static const connectTimeout = Duration(seconds: 5);
  static const receiveTimeout = Duration(seconds: 15);
}
