import 'package:permission_handler/permission_handler.dart';

/// What we are allowed to do with the microphone right now.
enum MicrophoneAccess {
  granted,

  /// Refused this time; asking again is allowed.
  denied,

  /// Refused for good; only the system settings screen can change it.
  permanentlyDenied,

  /// The device has no usable microphone or the OS blocks it (parental
  /// controls, MDM policy).
  restricted,
}

/// The single place the app asks for the microphone.
///
/// Wrapped behind an interface so the speak screen can be widget-tested
/// without a platform channel.
abstract interface class MicrophonePermissions {
  Future<MicrophoneAccess> status();

  /// Shows the system prompt if it has not been shown before.
  Future<MicrophoneAccess> request();

  /// Opens the app's settings page so a permanent denial can be undone.
  Future<bool> openSettings();
}

class PlatformMicrophonePermissions implements MicrophonePermissions {
  const PlatformMicrophonePermissions();

  @override
  Future<MicrophoneAccess> status() async =>
      _map(await Permission.microphone.status);

  @override
  Future<MicrophoneAccess> request() async =>
      _map(await Permission.microphone.request());

  @override
  Future<bool> openSettings() => openAppSettings();

  static MicrophoneAccess _map(PermissionStatus status) => switch (status) {
        PermissionStatus.granted ||
        PermissionStatus.limited ||
        PermissionStatus.provisional =>
          MicrophoneAccess.granted,
        PermissionStatus.permanentlyDenied => MicrophoneAccess.permanentlyDenied,
        PermissionStatus.restricted => MicrophoneAccess.restricted,
        PermissionStatus.denied => MicrophoneAccess.denied,
      };
}
