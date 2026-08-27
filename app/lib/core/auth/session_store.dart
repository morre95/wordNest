import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'session.dart';

/// Where the session lives between launches.
///
/// Behind an interface so tests need no platform channel, and so the storage
/// can be moved to the platform keystore without touching anything above it.
abstract interface class SessionStore {
  Future<Session?> read();
  Future<void> write(Session session);
  Future<void> clear();
}

class PreferencesSessionStore implements SessionStore {
  PreferencesSessionStore({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'wordnest.session';

  final SharedPreferencesAsync _preferences;

  @override
  Future<Session?> read() async {
    final stored = await _preferences.getString(_key);
    if (stored == null) return null;
    try {
      return Session.fromJson(jsonDecode(stored) as Map<String, Object?>);
    } on FormatException {
      // A session we cannot parse is a session we do not have. Registering
      // again is cheap and recovers the account, because the device id is
      // stable; failing to launch is not.
      await clear();
      return null;
    }
  }

  @override
  Future<void> write(Session session) =>
      _preferences.setString(_key, jsonEncode(session.toJson()));

  @override
  Future<void> clear() => _preferences.remove(_key);
}
