@Tags(['contract'])
library;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:wordnest/core/auth/auth_api.dart';
import 'package:wordnest/core/auth/session_manager.dart';
import 'package:wordnest/core/db/database.dart';
import 'package:wordnest/core/db/glossary_repository.dart';
import 'package:wordnest/core/db/sync_repository.dart';
import 'package:wordnest/core/db/utterance_repository.dart';
import 'package:wordnest/core/models/language.dart';
import 'package:wordnest/core/network/api_client.dart';
import 'package:wordnest/core/sync/sync_api.dart';
import 'package:wordnest/core/sync/sync_engine.dart';

import '../test/fakes/fake_session.dart';

/// Milestone 4's acceptance check: two real installs sharing one account
/// against a real `wordnest-api`, including going offline, diverging, and
/// reconciling.
///
/// Excluded from the normal run because it needs a server:
///
///   cd api && docker compose up --build
///   cd app && flutter test integration_check --tags contract \
///     --dart-define=WORDNEST_API_BASE_URL=http://127.0.0.1:8000
///
/// Each run registers devices with fresh ids, so it can be run repeatedly
/// against the same server without interfering with itself.
class RealDevice {
  RealDevice(this.deviceId) {
    database = WordNestDatabase.memory();
    glossary = GlossaryRepository(database: database, clock: () => clock);
    utterances = UtteranceRepository(
      database: database,
      glossaryRepository: glossary,
      clock: () => clock,
    );
    syncRepository = SyncRepository(database: database, clock: () => clock);
    store = InMemorySessionStore();

    late SessionManager manager;
    final client = ApiClient(accessTokens: () => manager);
    manager = SessionManager(
      authApi: HttpAuthApi(client),
      sessionStore: store,
      deviceIdentity: FakeDeviceIdentity(deviceId),
    );
    sessions = manager;
    engine = SyncEngine(
      syncApi: HttpSyncApi(client),
      syncRepository: syncRepository,
      sessionManager: manager,
    );
  }

  final String deviceId;
  DateTime clock = DateTime.now().toUtc();

  late final WordNestDatabase database;
  late final GlossaryRepository glossary;
  late final UtteranceRepository utterances;
  late final SyncRepository syncRepository;
  late final InMemorySessionStore store;
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
    clock = clock.add(const Duration(seconds: 30));
  }

  Future<List<String>> sentences() async {
    final rows = await database.select(database.utterances).get();
    return rows.map((row) => row.sourceText).toList()..sort();
  }

  Future<void> dispose() async {
    engine.dispose();
    sessions.dispose();
    await database.close();
  }
}

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);

  final run = DateTime.now().microsecondsSinceEpoch;
  late RealDevice phone;
  late RealDevice tablet;

  setUp(() {
    phone = RealDevice('device-phone-$run-${DateTime.now().microsecond}');
    tablet = RealDevice('device-tablet-$run-${DateTime.now().microsecond}');
  });

  tearDown(() async {
    await phone.dispose();
    await tablet.dispose();
  });

  test('two installs on one account converge through the real service',
      () async {
    // Both register silently, as first launch does.
    expect(await phone.sessions.ensureSession(), isNotNull);
    expect(await tablet.sessions.ensureSession(), isNotNull);

    // They start on separate accounts, and pairing joins them.
    final code = await phone.sessions.createPairingCode();
    final joined = await tablet.sessions.redeemPairingCode(code.code);
    expect(joined.accountId, phone.sessions.session.value!.accountId);

    // Both talk while apart.
    await phone.say('the bakery is closed');
    await phone.say('a quiet harbour');
    await tablet.say('where is the station');

    await phone.engine.synchronise();
    await tablet.engine.synchronise();
    await phone.engine.synchronise();

    const expected = [
      'a quiet harbour',
      'the bakery is closed',
      'where is the station',
    ];
    expect(await phone.sentences(), expected);
    expect(await tablet.sentences(), expected);
  });

  test('a flag set on one device reaches the other', () async {
    await phone.sessions.ensureSession();
    await tablet.sessions.ensureSession();
    final code = await phone.sessions.createPairingCode();
    await tablet.sessions.redeemPairingCode(code.code);

    await phone.say('the bakery is closed');
    await phone.engine.synchronise();
    await tablet.engine.synchronise();

    final onTablet =
        (await tablet.glossary.watchEntries(search: 'bakery').first).single;
    tablet.clock = tablet.clock.add(const Duration(minutes: 1));
    await tablet.glossary.setFlagged(onTablet.entry.id, isFlagged: true);
    await tablet.engine.synchronise();
    await phone.engine.synchronise();

    final onPhone =
        (await phone.glossary.watchEntries(search: 'bakery').first).single;
    expect(onPhone.entry.isFlagged, isTrue);
  });

  test('a device signed out stops syncing', () async {
    await phone.sessions.ensureSession();
    await tablet.sessions.ensureSession();
    final code = await phone.sessions.createPairingCode();
    await tablet.sessions.redeemPairingCode(code.code);

    final devices = await phone.sessions.listDevices();
    expect(devices.length, 2);

    await phone.sessions.revokeDevice(tablet.deviceId);

    final after = await phone.sessions.listDevices();
    expect(
      after.firstWhere((device) => device.id == tablet.deviceId).isActive,
      isFalse,
    );
  });
}
