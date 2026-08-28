import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../network/api_config.dart';
import 'speech_recognizer.dart';

/// The socket that carries audio to WordNest's server and text back.
///
/// AUDIO POLICY: this is one of exactly two files permitted to handle raw
/// audio, and the only one permitted to open a connection of any kind. It sends
/// each frame as it arrives and keeps no reference to it; there is no queue and
/// no retry buffer, because a retry buffer is a recording.
///
/// The frames are WordNest's own vocabulary, never the transcription vendor's,
/// so the app has no idea which service is behind the server.
abstract interface class SpeechSocket {
  /// Decoded text frames from the server. Binary frames are dropped: the
  /// server has no business sending audio back.
  Stream<Map<String, Object?>> get messages;

  /// Forwards one PCM frame. A no-op once the socket has closed — dropping a
  /// frame is the right failure, because the alternative is holding it.
  void sendAudio(Uint8List frame);

  void sendControl(Map<String, Object?> message);

  Future<void> close();
}

/// Opens a socket, or throws [SpeechSocketRejected] if the server refuses.
typedef SpeechSocketFactory = Future<SpeechSocket> Function({
  required String languageCode,
  required ListeningMode mode,
  required String? bearerToken,
});

/// The server would not take the session.
class SpeechSocketRejected implements Exception {
  const SpeechSocketRejected({this.closeCode, this.detail});

  /// The application close code, when the server sent one. 4401 means the
  /// session is stale and worth renewing once.
  final int? closeCode;
  final String? detail;

  @override
  String toString() => 'SpeechSocketRejected($closeCode, $detail)';
}

/// Close codes the server uses, mirrored from `api/features/speech/protocol.py`.
abstract final class SpeechCloseCodes {
  static const unauthenticated = 4401;
  static const rateLimited = 4429;
  static const sessionExpired = 4408;
}

/// Where the speech socket lives, derived from the same base URL every other
/// call uses so a development build cannot end up pointing two ways at once.
Uri speechSocketUri({
  required String languageCode,
  required ListeningMode mode,
  String baseUrl = ApiConfig.baseUrl,
  String prefix = ApiConfig.apiPrefix,
}) {
  final base = Uri.parse(baseUrl);
  final scheme = switch (base.scheme) {
    'http' => 'ws',
    'https' => 'wss',
    final other => throw ArgumentError.value(
        other,
        'baseUrl',
        'A speech socket needs an http or https base URL',
      ),
  };
  final path = '${base.path}$prefix/speech/stream'.replaceAll('//', '/');
  return base.replace(
    scheme: scheme,
    path: path,
    queryParameters: {
      'language': languageCode,
      'mode': mode.name,
      'encoding': 'linear16',
      'sample_rate': '16000',
      'channels': '1',
    },
  );
}

/// The production factory.
Future<SpeechSocket> connectSpeechSocket({
  required String languageCode,
  required ListeningMode mode,
  required String? bearerToken,
}) async {
  final uri = speechSocketUri(languageCode: languageCode, mode: mode);
  final IOWebSocketChannel channel;
  try {
    channel = IOWebSocketChannel.connect(
      uri,
      // A header rather than a query parameter, so the token does not land in
      // anyone's access log. The same choice ApiClient already makes.
      headers: bearerToken == null
          ? null
          : {'Authorization': 'Bearer $bearerToken'},
      connectTimeout: ApiConfig.connectTimeout,
    );
    await channel.ready;
  } on WebSocketChannelException catch (error) {
    throw SpeechSocketRejected(detail: '$error');
  } on Object catch (error) {
    throw SpeechSocketRejected(detail: '$error');
  }
  return _ChannelSpeechSocket(channel);
}

class _ChannelSpeechSocket implements SpeechSocket {
  _ChannelSpeechSocket(this._channel) {
    _subscription = _channel.stream.listen(
      (frame) {
        if (frame is! String) return;
        final decoded = jsonDecode(frame);
        if (decoded is Map<String, Object?>) _messages.add(decoded);
      },
      onError: (Object error) => _messages.addError(
        SpeechSocketRejected(closeCode: _channel.closeCode, detail: '$error'),
      ),
      onDone: () {
        final code = _channel.closeCode;
        // A close the client did not ask for is a failure the session needs to
        // hear about; an ordinary close is just the end of the stream.
        if (!_closing && code != null && code >= 4000) {
          _messages.addError(SpeechSocketRejected(closeCode: code));
        }
        _messages.close();
      },
    );
  }

  final IOWebSocketChannel _channel;
  final _messages = StreamController<Map<String, Object?>>.broadcast();
  late final StreamSubscription<dynamic> _subscription;
  var _closing = false;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void sendAudio(Uint8List frame) {
    if (_closing) return;
    _channel.sink.add(frame);
  }

  @override
  void sendControl(Map<String, Object?> message) {
    if (_closing) return;
    _channel.sink.add(jsonEncode(message));
  }

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    await _subscription.cancel();
    await _channel.sink.close();
    if (!_messages.isClosed) await _messages.close();
  }
}
