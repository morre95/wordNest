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
api/     FastAPI service `wordnest-api`   (from milestone 3)
```

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

The FastAPI service arrives in milestone 3. This section will cover `uv sync`,
the environment variables that supply LLM API keys, and `docker compose up`.

## Milestones

1. **Vertical slice** — permission, live on-device recognition, on-device
   translation of partials, both on screen. *(done)*
2. Persistence — Drift schema, saved utterances, glossary screen.
3. Backend — FastAPI translation and word extraction, wired into the app.
4. Sync — device registration, delta sync, the merge module, account upgrade.
5. Learning — spaced repetition, review mode, difficulty, text-to-speech.
6. Hardening — offline behaviour, error and empty states, accessibility.

Decisions taken along the way are recorded in [DECISIONS.md](DECISIONS.md).
