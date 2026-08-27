import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// This install's stable identifier and how it describes itself.
///
/// Behind an interface like the other platform services, so tests need no
/// platform channel.
abstract interface class DeviceIdentity {
  /// Stable across launches, new after a reinstall.
  Future<String> deviceId();

  /// What the device list in settings shows.
  String displayName();

  String platform();
}

class PlatformDeviceIdentity implements DeviceIdentity {
  PlatformDeviceIdentity({SharedPreferencesAsync? preferences})
      : _preferences = preferences ?? SharedPreferencesAsync();

  static const _key = 'wordnest.device_id';
  static const _uuid = Uuid();

  final SharedPreferencesAsync _preferences;

  /// Generated once and kept, rather than derived from hardware: a hardware id
  /// is a tracking identifier, and a reinstall genuinely is a new device.
  @override
  Future<String> deviceId() async {
    final stored = await _preferences.getString(_key);
    if (stored != null) return stored;
    final generated = _uuid.v7();
    await _preferences.setString(_key, generated);
    return generated;
  }

  /// Deliberately generic — the exact model is more identifying than it is
  /// useful, and the user can tell their phone from their tablet.
  @override
  String displayName() {
    if (Platform.isAndroid) return 'Android phone';
    if (Platform.isIOS) return 'iPhone or iPad';
    if (Platform.isMacOS) return 'Mac';
    if (Platform.isWindows) return 'Windows PC';
    if (Platform.isLinux) return 'Linux computer';
    return 'Device';
  }

  @override
  String platform() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }
}
