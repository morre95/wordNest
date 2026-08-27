@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/features/speak/speak_controller.dart';
import 'package:wordnest/features/speak/speak_screen.dart';
import 'package:wordnest/features/speak/widgets/mic_button.dart';

import '../../fakes/fake_speech_recognizer.dart';
import '../../fakes/fake_translator.dart';
import '../../fakes/speak_harness.dart';

/// WordNest's central privacy promise: microphone audio is never written
/// anywhere. These tests are the mechanical guard on that promise, checked two
/// ways — by reading the source of the audio pipeline, and by watching the
/// filesystem across a complete recognition session.
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

    /// Anything that could open a file, a socket, or a native storage API.
    const forbiddenImports = [
      'dart:io',
      'package:path_provider',
      'package:path/path.dart',
      'package:drift',
      'package:dio',
      'package:http',
      'package:shared_preferences',
    ];

    test('exists where the test expects it', () {
      expect(audioPipeline.existsSync(), isTrue,
          reason: 'The audio pipeline moved; update this guard.');
    });

    test('imports nothing that can persist or transmit bytes', () {
      final offences = <String>[];
      for (final entity in audioPipeline.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final forbidden in forbiddenImports) {
          if (source.contains("import '$forbidden")) {
            offences.add('${entity.path} imports $forbidden');
          }
        }
      }

      expect(offences, isEmpty,
          reason: 'Audio must never reach storage or the network.');
    });

    test('never names a file API', () {
      final offences = <String>[];
      final fileApis = RegExp(
        r'\b(File|Directory|RandomAccessFile|writeAsBytes|openWrite|'
        r'getTemporaryDirectory|getApplicationDocumentsDirectory)\b',
      );
      for (final entity in audioPipeline.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final code = withoutComments(entity.readAsStringSync());
        for (final match in fileApis.allMatches(code)) {
          offences.add('${entity.path}: ${match.group(0)}');
        }
      }

      expect(offences, isEmpty);
    });
  });

  group('a recognition session leaves no trace on disk', () {
    late Directory documents;
    late Directory cache;

    setUp(() {
      documents = Directory.systemTemp.createTempSync('wordnest_documents');
      cache = Directory.systemTemp.createTempSync('wordnest_cache');
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationDocumentsPath' ||
          'getApplicationSupportPath' =>
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
      await tester.tap(find.byType(MicButton));
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
  });
}
