# WordNest

Speak in your language, see it translated as you talk, and keep every word you
produce in a glossary that remembers which ones you struggle with.

WordNest opens straight onto the microphone. There is no onboarding, no
sign-in, and nothing between a cold launch and speaking.

**Your voice never leaves the recogniser.** Speech recognition runs on-device
through the platform speech APIs. No recording is written to disk, no audio is
uploaded, and no audio is cached. Only text — transcript, translation and the
vocabulary derived from them — is stored or transmitted. The guarantee is
enforced mechanically by
`app/test/core/speech/no_audio_persistence_test.dart`, which reads the source of
the audio pipeline and watches the filesystem across a full recognition session.

## Layout

```
app/     Flutter client, package `wordnest`, application id com.wordnest.app
api/     FastAPI service `wordnest-api`
```

The app is local-first: SQLite via Drift is the source of truth on the device,
and every screen reads from it. The backend exists for three things — keeping
LLM API keys off the device, producing better translations with a word-level
breakdown than an on-device model can, and (from milestone 4) being the
authoritative store for cross-device sync. **The app stays fully usable with the
backend down**: sentences are saved locally with an on-device translation and
queued for enrichment, and the queue drains on resume or reconnect.

## Running the app

Requires Flutter 3.47 or newer.

```bash
cd app
flutter pub get
dart run build_runner build        # freezed / json_serializable / drift output
flutter run
```

Generated files (`*.freezed.dart`, `*.g.dart`, drift output) are not committed,
so `build_runner` must run once after cloning and again after changing a model.
While iterating, `dart run build_runner watch` keeps them current.

### Checks

```bash
cd app
flutter analyze
flutter test
```

### Platform requirements

* **Android** — minSdk 24, compileSdk 37. `RECORD_AUDIO` is requested at first
  use; the manifest also declares the `RecognitionService` and `TTS_SERVICE`
  queries needed on Android 11+.
* **iOS** — `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
  are set in `ios/Runner/Info.plist`.

Offline translation uses ML Kit language models, roughly 30 MB per language.
They are downloaded on demand over Wi-Fi; the speak screen offers the download
when a model for the current pair is missing.

## Running the backend

Requires [uv](https://docs.astral.sh/uv/). From `api/`:

```bash
cd api
cp .env.example .env
uv sync --extra dev
uv run uvicorn wordnest_api.main:app --reload
```

The service comes up on `http://127.0.0.1:8000` with interactive docs at
`/docs`. With the default `WORDNEST_TRANSLATION_PROVIDER=fake` it needs no API
key and returns deterministic placeholder translations — enough to run the
whole app end to end.

For real translations, set both in `.env`:

```bash
WORDNEST_TRANSLATION_PROVIDER=anthropic
WORDNEST_ANTHROPIC_API_KEY=sk-ant-...
```

**API keys live only here.** They are read from the environment, never
committed, and never shipped to a device — which is the main reason this
service exists. `.env` is in `.gitignore`; `.env.example` documents every
variable. The fake provider is refused outright when
`WORDNEST_ENVIRONMENT=production`, so a misconfigured deployment fails at
startup rather than silently serving nonsense.

### In Docker

```bash
cd api
docker compose up --build          # API on :8000, Postgres on :5432
```

### Checks

```bash
cd api
uv run ruff check . && uv run ruff format --check .
uv run pytest
```

The suite runs against the deterministic fake provider: no API key, no network.

### Pointing the app at it

The app reads its base URL at build time. `10.0.2.2` (the Android emulator's
view of the host) is the default:

```bash
cd app
flutter run --dart-define=WORDNEST_API_BASE_URL=http://192.168.1.10:8000
```

### Migrations

```bash
cd api
uv run alembic upgrade head          # apply
uv run alembic downgrade -1          # and back, to check it is reversible
```

`docker compose up` runs them as their own service before the API starts. The
test suite runs them too, against a fresh SQLite file per test, so they are
exercised on every run.

### Integration checks

Two suites run the app's real HTTP client against a running service. They are
excluded from the normal test run because they need one:

```bash
cd api && docker compose up --build
cd app && flutter test integration_check --tags contract \
  --dart-define=WORDNEST_API_BASE_URL=http://127.0.0.1:8000
```

`backend_contract_test.dart` checks the translation contract.
`two_devices_test.dart` is milestone 4's acceptance check: two installs sharing
one account, registering, pairing, diverging and reconciling.

## Milestones

1. **Vertical slice** — permission, live on-device recognition, on-device
   translation of partials, both on screen. *(done)*
2. **Persistence** — Drift schema, saved utterances, glossary screen. *(done)*
3. **Backend** — FastAPI translation and word extraction, containerised and
   wired into the app. *(done)*
4. **Sync** — device registration and tokens, the delta-sync endpoint and
   cursor, the merge module, background triggers, sync status, account upgrade
   and device pairing. *(done)*
5. Learning — spaced repetition, review mode, difficulty, text-to-speech.
6. Hardening — offline behaviour, error and empty states, accessibility.

Decisions taken along the way are recorded in [DECISIONS.md](DECISIONS.md).
