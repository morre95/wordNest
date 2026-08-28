import 'dart:async';
import 'dart:typed_data';

import 'package:wordnest/core/speech/microphone_stream.dart';

/// A microphone driven by the test rather than by a person.
///
/// Records how it was used — how many times it was opened and closed, and when
/// — so a test can assert the ordering guarantees the recogniser makes about
/// never opening the mic before it has somewhere to send the audio.
class FakeMicrophoneStream implements MicrophoneStream {
  FakeMicrophoneStream({this.permission = true, this.failOnOpen = false});

  bool permission;

  /// When true, [open] throws as a device with the mic already in use would.
  bool failOnOpen;

  int openCount = 0;
  int closeCount = 0;
  int disposeCount = 0;
  DateTime? openedAt;

  StreamController<AudioFrame>? _frames;

  bool get isOpen => _frames != null && !_frames!.isClosed;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<AudioFrame>> open({int sampleRate = 16000}) async {
    if (failOnOpen) throw StateError('microphone busy');
    openCount++;
    openedAt = DateTime.now();
    final controller = StreamController<AudioFrame>();
    _frames = controller;
    return controller.stream;
  }

  @override
  Future<void> close() async {
    if (_frames == null) return;
    closeCount++;
    final controller = _frames!;
    _frames = null;
    if (!controller.isClosed) await controller.close();
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await close();
  }

  // --- Test drivers -------------------------------------------------------

  /// Emits one frame of audio with the given bytes and level.
  void emit(List<int> bytes, {double level = 0.5}) {
    _frames?.add(
      AudioFrame(bytes: Uint8List.fromList(bytes), level: level),
    );
  }

  /// A frame of recognisable, non-silent audio.
  void emitSpeech({double level = 0.6}) => emit([0x7F, 0x41, 0x10, 0x22],
      level: level);
}
