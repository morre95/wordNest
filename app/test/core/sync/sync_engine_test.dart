import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/auth/session_manager.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/sync_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_exception.dart';
import 'package:wordnest/core/sync/sync_api.dart';
import 'package:wordnest/core/sync/sync_engine.dart';

import '../../fakes/fake_session.dart';
import '../../fakes/fake_sync_api.dart';

/// One simulated device: its own database, its own sync engine, one shared
/// server. Two of these is the scenario the specification asks to be validated
/// — two installs on one account, both going offline, diverging, reconciling.
class SimulatedDevice {
  SimulatedDevice(this.name, FakeSyncApi server, {DateTime? now})
      : clock = now ?? DateTime.utc(2026, 3, 2, 9) {
    database = WordNestDatabase.memory();
    glossary = GlossaryRepository(database: database, clock: () => clock);
    utterances = UtteranceRepository(
      database: database,
      glossaryRepository: glossary,
      clock: () => clock,
    );
    syncRepository = SyncRepository(database: database, clock: () => clock);
    sessions = SessionManager(
      authApi: FakeAuthApi(),
      sessionStore: InMemorySessionStore(),
      deviceIdentity: FakeDeviceIdentity(name),
    );
    engine = SyncEngine(
      syncApi: _DeviceScopedApi(server, name),
      syncRepository: syncRepository,
      sessionManager: sessions,
    );
  }

  final String name;
  DateTime clock;

  late final WordNestDatabase database;
  late final GlossaryRepository glossary;
  late final UtteranceRepository utterances;
  late final SyncRepository syncRepository;
  late final SessionManager sessions;
  late final SyncEngine engine;

  Future<void> say(String sentence) async {
    await utterances.saveFinalised(
      sourceText: sentence,
      translationText: '[es] $sentence',
      pair: const LanguagePair(
        source: Language(code: 'en', name: 'English'),
        target: Language(code: 'es', name: 'Spanish'),
      ),
    );
    clock = clock.add(const Duration(minutes: 1));
  }

  Future<List<String>> sentences() async {
    final rows = await database.select(database.utterances).get();
    return rows.map((row) => row.sourceText).toList()..sort();
  }

  Future<List<String>> lemmas() async {
    final rows = await glossary.watchEntries().first;
    return rows.map((row) => row.entry.lemma).toList()..sort();
  }

  Future<void> dispose() async {
    engine.dispose();
    sessions.dispose();
    await database.close();
  }
}

/// Tags every push with the device that made it, so the server can enforce
/// utterance ownership as the real one does.
class _DeviceScopedApi implements SyncApi {
  _DeviceScopedApi(this._server, this._device);

  final FakeSyncApi _server;
  final String _device;

  @override
  Future<SyncPage> sync({
    required int cursor,
    required List<Utterance> utterances,
    required List<GlossaryEntry> entries,
    required List<GlossaryOccurrence> occurrences,
    required List<ReviewLog> reviews,
  }) {
    _server.deviceId = _device;
    return _server.sync(
      cursor: cursor,
      utterances: utterances,
      entries: entries,
      occurrences: occurrences,
      reviews: reviews,
    );
  }
}

void main() {
  // Several databases at once is the whole point here: each [SimulatedDevice]
  // is a separate install with its own store. They never share an executor, so
  // drift's warning about it does not apply.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  late FakeSyncApi server;
  late SimulatedDevice phone;
  late SimulatedDevice tablet;

  setUp(() {
    server = FakeSyncApi();
    phone = SimulatedDevice('phone', server);
    tablet = SimulatedDevice('tablet', server);
  });

  tearDown(() async {
    await phone.dispose();
    await tablet.dispose();
  });

  group('one device', () {
    test('pushes what it has said and records the cursor', () async {
      await phone.say('the bakery is closed');

      await phone.engine.synchronise();

      final state = await phone.syncRepository.readState();
      expect(state.cursor, greaterThan(0));
      expect(state.lastSyncedAt, isNotNull);
      expect(state.lastError, isNull);
    });

    test('a second sync with nothing new pushes nothing', () async {
      await phone.say('hello');
      await phone.engine.synchronise();
      final callsAfterFirst = server.syncCalls;

      await phone.engine.synchronise();

      expect(server.syncCalls, callsAfterFirst + 1);
      final state = await phone.syncRepository.readState();
      expect(state.lastError, isNull);
    });

    test('rows stop being dirty once the server has them', () async {
      await phone.say('hello');

      await phone.engine.synchronise();

      final pending = await phone.syncRepository.pendingChanges();
      expect(pending.utterances, isEmpty);
      expect(pending.entries, isEmpty);
    });
  });

  group('two devices sharing an account', () {
    test('what one says appears on the other', () async {
      await phone.say('the bakery is closed');
      await phone.engine.synchronise();

      await tablet.engine.synchronise();

      expect(await tablet.sentences(), ['the bakery is closed']);
      expect(await tablet.lemmas(), ['bakery', 'closed']);
    });

    test('both going offline, diverging, and reconciling loses nothing',
        () async {
      // Neither can reach the server.
      server.failure = const ApiException(ApiFailureKind.unreachable);
      for (var index = 0; index < 3; index++) {
        await phone.say('phone sentence $index');
        await tablet.say('tablet sentence $index');
      }
      await phone.engine.synchronise();
      await tablet.engine.synchronise();
      expect(await phone.sentences(), hasLength(3));

      // The network comes back.
      server.failure = null;
      await phone.engine.synchronise();
      await tablet.engine.synchronise();
      await phone.engine.synchronise();

      final expected = [
        for (var index = 0; index < 3; index++) 'phone sentence $index',
        for (var index = 0; index < 3; index++) 'tablet sentence $index',
      ]..sort();
      expect(await phone.sentences(), expected);
      expect(await tablet.sentences(), expected);
    });

    test('the same word learned on both becomes one entry', () async {
      await phone.say('the bakery is closed');
      await tablet.say('which bakery');
      await phone.engine.synchronise();
      await tablet.engine.synchronise();
      await phone.engine.synchronise();

      final onPhone = await phone.lemmas();
      expect(
        onPhone.where((lemma) => lemma == 'bakery').length,
        1,
        reason: 'one word is one row',
      );
    });

    test("a flag on one device reaches the other", () async {
      await phone.say('the bakery is closed');
      await phone.engine.synchronise();
      await tablet.engine.synchronise();

      final entry = (await tablet.glossary.watchEntries(search: 'bakery').first)
          .single
          .entry;
      tablet.clock = tablet.clock.add(const Duration(minutes: 5));
      await tablet.glossary.setFlagged(entry.id, isFlagged: true);
      await tablet.engine.synchronise();
      await phone.engine.synchronise();

      final onPhone =
          (await phone.glossary.watchEntries(search: 'bakery').first).single;
      expect(onPhone.entry.isFlagged, isTrue);
    });

    test('a device cannot rewrite the other device\'s utterance', () async {
      await phone.say('mine');
      await phone.engine.synchronise();
      await tablet.engine.synchronise();

      final row = (await tablet.database.select(tablet.database.utterances).get())
          .single;
      tablet.clock = tablet.clock.add(const Duration(minutes: 5));
      await tablet.utterances.setFlagged(row.id, isFlagged: true);
      await tablet.engine.synchronise();

      // The push was refused, and the sync still completed.
      final state = await tablet.syncRepository.readState();
      expect(state.lastError, isNull);
    });
  });

  group('failures', () {
    test('an unreachable server leaves the local database untouched', () async {
      await phone.say('the bakery is closed');
      server.failure = const ApiException(ApiFailureKind.unreachable);

      await phone.engine.synchronise();

      expect(await phone.sentences(), ['the bakery is closed']);
      expect(phone.engine.status.value.phase, SyncPhase.failed);
      expect(phone.engine.status.value.failure, ApiFailureKind.unreachable);
      final state = await phone.syncRepository.readState();
      expect(state.lastError, isNotNull);
      expect(state.cursor, 0, reason: 'a failed sync must not move the cursor');
    });

    test('the pending count tells the user what is waiting', () async {
      await phone.say('one');
      await phone.say('two');
      server.failure = const ApiException(ApiFailureKind.unreachable);

      await phone.engine.synchronise();

      expect(phone.engine.status.value.pendingChanges, greaterThan(0));
    });

    test('a later success clears the failure', () async {
      await phone.say('hello');
      server.failure = const ApiException(ApiFailureKind.serverError);
      await phone.engine.synchronise();

      server.failure = null;
      await phone.engine.synchronise();

      expect(phone.engine.status.value.phase, SyncPhase.succeeded);
      expect(phone.engine.status.value.failure, isNull);
      final state = await phone.syncRepository.readState();
      expect(state.lastError, isNull);
    });

    test('two triggers at once run one sync', () async {
      await phone.say('hello');
      final before = server.syncCalls;

      await Future.wait([
        phone.engine.synchronise(),
        phone.engine.synchronise(),
      ]);

      expect(server.syncCalls, before + 1);
    });
  });

  group('paging', () {
    test('a fortnight of backlog arrives across several pages', () async {
      final small = FakeSyncApi(pageSize: 5);
      final busy = SimulatedDevice('busy', small);
      final quiet = SimulatedDevice('quiet', small);
      addTearDown(busy.dispose);
      addTearDown(quiet.dispose);

      for (var day = 0; day < 14; day++) {
        await busy.say('day $day');
      }
      await busy.engine.synchronise();

      await quiet.engine.synchronise();

      expect(await quiet.sentences(), hasLength(14));
    });
  });
}
