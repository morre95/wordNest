@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/speech/speech_engine.dart';
import 'package:wordnest/features/speak/speak_controller.dart';
import 'package:wordnest/features/speak/speak_screen.dart';
import 'package:wordnest/features/speak/widgets/mic_button.dart';

import '../../fakes/fake_microphone_stream.dart';
import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_speech_socket.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// WordNest's central privacy promise: microphone audio is never written
/// anywhere. These tests are the mechanical guard on that promise, checked two
/// ways — by reading the source of the audio pipeline, and by watching the
/// filesystem across a complete recognition session.
///
/// The promise used to be stronger: no audio reached Dart at all. Choosing
/// Deepgram in settings ends that, because streaming to a server means holding
/// the frames long enough to send them. What is left is narrower and has to be
/// checked rather than asserted in prose — hence [audioCarriers] below, which
/// is the entire carve-out, and the rules that keep everything else exactly as
/// strict as it was.
///
/// Strips comments so the guards below check code, not the prose in this
/// directory's own documentation of the policy.
String withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the audio pipeline cannot write to disk', () {
    /// The only code allowed anywhere near microphone audio.
    final audioPipeline = Directory('lib/core/speech');

    /// The file that may capture audio, and the file that may send it. Nothing
    /// else in the tree may do either.
    ///
    /// Each entry was argued for once and is a code review to add to. Widening
    /// this map is the visible act that says the privacy promise changed; it
    /// should never happen quietly as a side effect of some other work.
    const captureCarrier = 'lib/core/speech/microphone_stream.dart';
    const transportCarrier = 'lib/core/speech/speech_socket.dart';
    const audioCarriers = {captureCarrier, transportCarrier};

    /// Imports permitted only in the files named. Everything not listed here is
    /// forbidden to every file in the tree.
    const carveOuts = <String, Set<String>>{
      'package:record': {captureCarrier},
      'package:web_socket_channel': {transportCarrier},
      'dart:typed_data': audioCarriers,
    };

    /// Anything that could open a file or a native storage API. Forbidden
    /// everywhere, carriers included: audio may now leave the device, but it
    /// may still never touch the disk.
    const forbiddenEverywhere = [
      'dart:io',
      'package:path_provider',
      'package:path/path.dart',
      'package:drift',
      'package:dio',
      'package:http',
      'package:shared_preferences',
      'package:sqflite',
      'package:hive',
      'package:file',
      'package:archive',
    ];

    List<File> pipelineSources() => audioPipeline
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList(growable: false);

    /// Comparable to the constants above on any platform.
    String normalise(File file) => file.uri.pathSegments.join('/');

    test('exists where the test expects it', () {
      expect(audioPipeline.existsSync(), isTrue,
          reason: 'The audio pipeline moved; update this guard.');
    });

    test('every carve-out names a file that still exists', () {
      // A carve-out pointing at a renamed file grants nothing, but it rots
      // quietly and leaves the next reader trusting a list that is wrong.
      final present = pipelineSources().map(normalise).toSet();
      for (final permitted in carveOuts.values.expand((files) => files)) {
        expect(present, contains(permitted),
            reason: '$permitted is allowed an exception but does not exist.');
      }
    });

    test('imports nothing that can persist bytes', () {
      final offences = <String>[];
      for (final file in pipelineSources()) {
        final source = file.readAsStringSync();
        for (final forbidden in forbiddenEverywhere) {
          if (source.contains("import '$forbidden")) {
            offences.add('${file.path} imports $forbidden');
          }
        }
      }

      expect(offences, isEmpty,
          reason: 'Audio must never reach storage.');
    });

    test('only the named files may capture or transmit audio', () {
      // The rule the guard used to be missing. It forbade disk and nothing
      // else, so any file here could have opened a socket and streamed the
      // microphone out with nothing complaining.
      final offences = <String>[];
      for (final file in pipelineSources()) {
        final source = file.readAsStringSync();
        for (final MapEntry(key: package, value: permitted)
            in carveOuts.entries) {
          if (!source.contains("import '$package")) continue;
          if (!permitted.contains(normalise(file))) {
            offences.add('${file.path} imports $package');
          }
        }
      }

      expect(offences, isEmpty,
          reason: 'Only the audio carriers may touch audio or the network.');
    });

    test('never names a file API', () {
      final offences = <String>[];
      final fileApis = RegExp(
        r'\b(File|Directory|RandomAccessFile|IOSink|FileMode|writeAsBytes|'
        r'writeAsString|openWrite|openRead|toFilePath|getTemporaryDirectory|'
        r'getApplicationDocumentsDirectory|getApplicationSupportDirectory|'
        r'getExternalStorageDirectory|getDownloadsDirectory)\b',
      );
      for (final file in pipelineSources()) {
        final code = withoutComments(file.readAsStringSync());
        for (final match in fileApis.allMatches(code)) {
          offences.add('${file.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });

    test('only the transport carrier may name a connection', () {
      // Banning the import alone is not enough: a platform channel is the
      // other way bytes leave Dart, and nothing we write should name one.
      final connections = RegExp(
        r'\b(WebSocket|WebSocketChannel|IOWebSocketChannel|HttpClient|'
        r'RawDatagramSocket|MethodChannel|EventChannel)\b',
      );
      final offences = <String>[];
      for (final file in pipelineSources()) {
        if (normalise(file) == transportCarrier) continue;
        final code = withoutComments(file.readAsStringSync());
        for (final match in connections.allMatches(code)) {
          offences.add('${file.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });

    test('only the capture carrier may name the recorder', () {
      final recorder = RegExp(r'\b(AudioRecorder|RecordConfig|AudioEncoder)\b');
      final offences = <String>[];
      for (final file in pipelineSources()) {
        if (normalise(file) == captureCarrier) continue;
        final code = withoutComments(file.readAsStringSync());
        for (final match in recorder.allMatches(code)) {
          offences.add('${file.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });

    test('the recorder streams and never writes', () {
      // This is what makes the `record` carve-out safe, and it is a source
      // check rather than a filesystem one on purpose: `record` writes through
      // its own native code to a native temp directory, which the filesystem
      // watch below mocks `path_provider` for and therefore cannot see.
      final code = withoutComments(File(captureCarrier).readAsStringSync());

      expect(code, contains('startStream'),
          reason: 'startStream is the API that does not write a file.');
      expect(code, isNot(matches(RegExp(r'\.start\s*\('))),
          reason: 'AudioRecorder.start writes a file. Only startStream may be '
              'used here.');
      expect(code, isNot(contains('path:')),
          reason: 'A path argument to the recorder is a recording.');
    });

    test('no raw audio is held anywhere in the pipeline', () {
      // "Do not buffer" expressed as something a machine can check. A retry
      // queue for unsent frames would be a recording by another name.
      final accumulators = RegExp(
        r'\b(BytesBuilder|Uint8Buffer)\b|List<Uint8List>|<Uint8List>\[\]',
      );
      final offences = <String>[];
      for (final file in pipelineSources()) {
        final code = withoutComments(file.readAsStringSync());
        for (final match in accumulators.allMatches(code)) {
          offences.add('${file.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });

    test('only the carriers may name a byte buffer', () {
      // `package:flutter/foundation.dart` re-exports Uint8List, so banning the
      // dart:typed_data import on its own leaves a hole to walk through.
      final byteTypes = RegExp(
        r'\b(Uint8List|ByteData|ByteBuffer|Int16List|Float32List)\b',
      );
      final offences = <String>[];
      for (final file in pipelineSources()) {
        if (audioCarriers.contains(normalise(file))) continue;
        final code = withoutComments(file.readAsStringSync());
        for (final match in byteTypes.allMatches(code)) {
          offences.add('${file.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });

    test('the recogniser that owns a session cannot reach anything', () {
      // The orchestration logic is provably incapable of transport: the
      // microphone and the socket are interfaces to it, and the two files
      // behind them are the only ones that can do anything with either.
      const orchestrator = 'lib/core/speech/deepgram_speech_recognizer.dart';
      final code = withoutComments(File(orchestrator).readAsStringSync());
      final packageImports = RegExp(r"import 'package:[^']+'");
      final dartImports = RegExp(r"import 'dart:([^']+)'");

      expect(packageImports.allMatches(code), isEmpty,
          reason: '$orchestrator must depend on nothing but this directory.');
      expect(
        dartImports.allMatches(code).map((match) => match.group(1)),
        everyElement('async'),
      );
    });

    test('no other part of the app imports the audio packages', () {
      // The audio pipeline is the boundary. Another file importing any of
      // these could open a second session — or a second microphone — outside
      // every guarantee this directory makes.
      const boundaryPackages = [
        'package:speech_to_text',
        'package:record',
        'package:web_socket_channel',
      ];
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.startsWith(audioPipeline.path)) continue;
        final source = entity.readAsStringSync();
        for (final package in boundaryPackages) {
          if (source.contains("import '$package")) {
            offenders.add('${entity.path} imports $package');
          }
        }
      }

      expect(offenders, isEmpty);
    });
  });

  group('a recognition session leaves no trace on disk', () {
    late Directory documents;
    late Directory cache;

    setUp(() {
      documents = Directory.systemTemp.createTempSync('wordnest_documents');
      cache = Directory.systemTemp.createTempSync('wordnest_cache');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationDocumentsPath' || 'getApplicationSupportPath' =>
            documents.path,
          'getTemporaryPath' || 'getApplicationCachePath' => cache.path,
          _ => null,
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      documents.deleteSync(recursive: true);
      cache.deleteSync(recursive: true);
    });

    /// Files WordNest is allowed to create. Everything is text or a database
    /// of text; nothing on this list can hold a recording.
    bool isPermitted(File file) {
      const permitted = {
        'wordnest.sqlite',
        'wordnest.sqlite-wal',
        'wordnest.sqlite-shm',
        'wordnest.sqlite-journal',
      };
      return permitted.contains(file.uri.pathSegments.last);
    }

    List<File> filesUnder(Directory directory) => directory
        .listSync(recursive: true)
        .whereType<File>()
        .toList(growable: false);

    testWidgets('speaking, pausing and finalising writes no audio',
        (tester) async {
      final recognizer = FakeSpeechRecognizer();
      final translator = FakeTranslator();

      await tester.pumpWidget(
        ProviderScope(
          overrides: speakOverrides(
            recognizer: recognizer,
            translator: translator,
          ),
          child: const MaterialApp(home: SpeakScreen()),
        ),
      );
      await tester.pump();

      // A full session: start, several partials, a pause, a final result.
      // Held rather than tapped: the mic button is hold-to-talk, and a tap is
      // a press and a release, which closes the session it just opened.
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MicButton)),
      );
      addTearDown(() async => gesture.up());
      await tester.pump();
      recognizer
        ..emitSoundLevel(0.4)
        ..emitPartial('the quick brown')
        ..emitSoundLevel(0.8)
        ..emitPartial('the quick brown fox');
      await tester.pump(SpeakController.provisionalTranslationDebounce);
      await tester.pump();
      recognizer.emitFinal('the quick brown fox jumps');
      await tester.pump();
      await tester.pump();

      final written = [
        ...filesUnder(documents),
        ...filesUnder(cache),
      ].where((file) => !isPermitted(file)).toList(growable: false);

      expect(
        written.map((file) => file.path),
        isEmpty,
        reason: 'A recognition session wrote unexpected files.',
      );
    });

    testWidgets('a whole session, saved and enriched, writes no audio',
        (tester) async {
      // The full loop this time: speak, finalise, save to the database, and
      // let the backend enrichment run. The database file is permitted; an
      // audio file of any kind is not.
      final recognizer = FakeSpeechRecognizer();
      final database = WordNestDatabase.memory();
      addTearDown(database.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: speakOverrides(
            recognizer: recognizer,
            translator: FakeTranslator(),
            database: database,
          ),
          child: const MaterialApp(home: SpeakScreen()),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MicButton)),
      );
      addTearDown(() async => gesture.up());
      await tester.pump();
      recognizer
        ..emitSoundLevel(0.9)
        ..emitPartial('the bakery')
        ..emitFinal('the bakery is closed');
      for (var index = 0; index < 6; index++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final everything = [...filesUnder(documents), ...filesUnder(cache)];
      expect(
        everything.where((file) => !isPermitted(file)).map((f) => f.path),
        isEmpty,
      );
      expect(
        everything.where((file) => _looksLikeAudio(file.path)),
        isEmpty,
        reason: 'nothing that could hold a recording may exist',
      );
    });

    testWidgets('a cloud session writes no audio either', (tester) async {
      // The path where WordNest genuinely handles PCM frames. Driven through
      // the real DeepgramSpeechRecognizer with a fake microphone and a fake
      // socket, so the orchestration under test is the production one.
      final microphone = FakeMicrophoneStream();
      final sockets = FakeSpeechSocketFactory();
      final database = WordNestDatabase.memory();
      addTearDown(database.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: speakOverrides(
            translator: FakeTranslator(),
            engine: SpeechEngine.deepgram,
            microphone: microphone,
            sockets: sockets,
            database: database,
          ),
          child: const MaterialApp(home: SpeakScreen()),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(MicButton)),
      );
      addTearDown(() async => gesture.up());
      await tester.pump();
      for (var frame = 0; frame < 8; frame++) {
        microphone.emitSpeech();
      }
      await tester.pump();
      sockets.socket
        ..emitPartial('the bakery')
        ..emitFinal('the bakery is closed');
      for (var index = 0; index < 8; index++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The audio really did travel — otherwise this test would pass by
      // proving nothing.
      expect(sockets.socket.frameCount, 8);

      final everything = [...filesUnder(documents), ...filesUnder(cache)];
      expect(
        everything.where((file) => !isPermitted(file)).map((f) => f.path),
        isEmpty,
      );
      expect(
        everything.where((file) => _looksLikeAudio(file.path)),
        isEmpty,
        reason: 'nothing that could hold a recording may exist',
      );
    });
  });

  test('the engine that sends audio away is never the default', () {
    // Everything above concerns what the cloud path may do. This is the
    // promise that it is not what anyone gets without asking.
    expect(SpeechEngine.fallback, SpeechEngine.phone);
  });
}

/// Extensions and names that would betray a recording, whatever it was called.
bool _looksLikeAudio(String path) {
  const audioExtensions = [
    '.wav', '.mp3', '.m4a', '.aac', '.caf', '.pcm', '.opus', '.ogg',
    '.flac', '.amr', '.3gp', '.raw',
  ];
  final lower = path.toLowerCase();
  return audioExtensions.any(lower.endsWith) ||
      lower.contains('audio') ||
      lower.contains('record');
}
