import 'package:wordnest/core/permissions/microphone_permission.dart';

class FakeMicrophonePermissions implements MicrophonePermissions {
  FakeMicrophonePermissions({
    this.current = MicrophoneAccess.granted,
    this.afterRequest,
  });

  MicrophoneAccess current;

  /// What the system prompt resolves to. Defaults to leaving [current] alone.
  MicrophoneAccess? afterRequest;

  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<MicrophoneAccess> status() async => current;

  @override
  Future<MicrophoneAccess> request() async {
    requestCount++;
    current = afterRequest ?? current;
    return current;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCount++;
    return true;
  }
}
