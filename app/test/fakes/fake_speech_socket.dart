import 'dart:async';
import 'dart:typed_data';

import 'package:wordnest/core/speech/speech_socket.dart';

/// A speech socket that never leaves the process.
///
/// It records how much audio it was handed rather than the audio itself — a
/// test double that kept a copy of the bytes would be a small joke at the
/// expense of the guarantee these tests exist to check.
class FakeSpeechSocket implements SpeechSocket {
  final _messages = StreamController<Map<String, Object?>>.broadcast();

  int frameCount = 0;
  int byteCount = 0;
  final controls = <Map<String, Object?>>[];
  bool closed = false;
  DateTime? connectedAt;

  @override
  Stream<Map<String, Object?>> get messages => _messages.stream;

  @override
  void sendAudio(Uint8List frame) {
    if (closed) return;
    frameCount++;
    byteCount += frame.lengthInBytes;
  }

  @override
  void sendControl(Map<String, Object?> message) {
    if (closed) return;
    controls.add(message);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (!_messages.isClosed) await _messages.close();
  }

  // --- Test drivers -------------------------------------------------------

  /// Delivers a frame, or drops it once the socket has closed — which is what
  /// a real one does, and what lets a test send after teardown.
  void _deliver(Map<String, Object?> frame) {
    if (_messages.isClosed) return;
    _messages.add(frame);
  }

  void emitPartial(String text) =>
      _deliver({'type': 'partial', 'text': text});

  void emitFinal(String text, {double? confidence}) {
    final frame = <String, Object?>{'type': 'final', 'text': text};
    if (confidence != null) frame['confidence'] = confidence;
    _deliver(frame);
  }

  void emitError(String code, [String message = 'something went wrong']) =>
      _deliver({'type': 'error', 'code': code, 'message': message});

  /// A frame type this version of the app has never heard of.
  void emitUnknownFrame() => _deliver({'type': 'weather', 'text': 'sunny'});

  /// The connection dropping under the session.
  void drop() {
    if (_messages.isClosed) return;
    _messages.addError(const SpeechSocketRejected(detail: 'dropped'));
  }
}

/// A factory that hands out [socket], recording what it was asked for.
class FakeSpeechSocketFactory {
  FakeSpeechSocketFactory({FakeSpeechSocket? socket, this.rejectWith})
      : socket = socket ?? FakeSpeechSocket();

  final FakeSpeechSocket socket;

  /// When set, the first connection attempt is refused with this. A second
  /// attempt succeeds, which is what makes the renew-once path testable.
  SpeechSocketRejected? rejectWith;

  int attempts = 0;
  final languages = <String>[];
  final tokens = <String?>[];

  SpeechSocketFactory get connect => ({
        required String languageCode,
        required mode,
        required String? bearerToken,
      }) async {
        attempts++;
        languages.add(languageCode);
        tokens.add(bearerToken);
        final rejection = rejectWith;
        if (rejection != null) {
          rejectWith = null;
          throw rejection;
        }
        socket.connectedAt = DateTime.now();
        return socket;
      };
}

/// A factory that always refuses, as an unreachable server would.
SpeechSocketFactory alwaysRefusing({int? closeCode}) => ({
      required String languageCode,
      required mode,
      required String? bearerToken,
    }) async =>
        throw SpeechSocketRejected(closeCode: closeCode, detail: 'refused');
