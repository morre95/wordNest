# Decisions

Choices the specification left open, the option taken, and what it costs.
Newest last within each milestone.

## Milestone 1 — vertical slice

**Monorepo with `app/` and `api/`.** One repository, two deployables, rather
than two repos. Trade-off: the Flutter package is at `app/` instead of the
repository root, so `flutter` commands need a `cd app` first; in exchange the
API contract and the client that consumes it change in one commit.

**`drift_flutter` instead of `sqlite3_flutter_libs`.** The package the
specification suggested is now published as `0.6.0+eol` — "Not used anymore".
Since drift 3.0, `package:drift` bundles SQLite itself and `drift_flutter`
supplies the platform paths. Trade-off: none; the suggested package would have
worked today but is unmaintained.

**No `riverpod_generator`.** Providers are written by hand. Trade-off: a few
lines of boilerplate per provider, against one fewer `build_runner` builder and
no generated file to keep in sync. `freezed`, `json_serializable` and
`drift_dev` still run.

**`Language` is a plain value type, not a `freezed` union over ML Kit's enum.**
`core/models/language.dart` knows only BCP-47 tags; `core/translation/mlkit_translator.dart`
is the one file that maps them onto `TranslateLanguage`. Trade-off: the
supported-language list is duplicated from ML Kit and must be refreshed when
ML Kit adds a language; in exchange nothing above `core/translation` depends on
the translation vendor.

**Speech locale is resolved at listen time, not stored.** The user picks a
language (`sv`); `resolveSpeechLocaleId` picks the platform locale (`sv_SE`)
from what the device actually offers. Trade-off: a device with only `sv_FI`
gets `sv_FI` rather than refusing to listen, which is the right failure.

**On-device recognition is preferred, with a visible fallback.** `start()`
tries `onDevice: true` first and falls back to the platform default when no
on-device model exists for the locale. Trade-off: on such a locale the audio
reaches the platform's recogniser service rather than staying local, so the
privacy line on the speak screen changes wording to say so instead of claiming
something untrue. Audio is still never persisted by WordNest either way.

**Provisional translations are debounced at 300 ms.** Fast enough to appear
mid-sentence, slow enough that a fluent speaker does not trigger a translation
per word. Stale results are discarded by transcript revision number rather than
cancelled, because ML Kit's translate call is not cancellable.

**ML Kit model downloads show indeterminate progress.** ML Kit's
`ModelManager.downloadModel` reports completion, not bytes. Trade-off: the
banner shows a spinner and "Downloading…" rather than a percentage; a real
progress bar would mean reimplementing the download, which is not worth it.

**`compileSdk = 37` is pinned in `android/app/build.gradle.kts`.**
`permission_handler_android` requires it, and Flutter's default is still 36.
Trade-off: an Android Gradle Plugin warning about compiling against a newer SDK
than it recommends; the build is otherwise clean.

**Generated code is not committed.** `*.freezed.dart`, `*.g.dart` and drift's
output are in `.gitignore`. Trade-off: a fresh clone must run
`dart run build_runner build` before `flutter test` works, which the README says.
