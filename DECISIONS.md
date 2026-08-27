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

## Milestone 2 — persistence

**Sync columns are in the first migration, on every table.** `id` (client
UUIDv7), `updated_at`, `deleted_at`, `dirty` come from a `SyncedRow` mixin.
Trade-off: four columns carried before anything uses them, against never having
to migrate a user's glossary when sync ships.

**Timestamps are stored as ISO-8601 text, not Unix seconds.**
`store_date_time_values_as_text: true` in `build.yaml`. Trade-off: slightly
larger rows and string comparison instead of integer; in exchange `updated_at`
keeps milliseconds, so last-write-wins has far fewer unresolvable ties, and the
stored value is unambiguously UTC.

**Deletes are tombstones everywhere.** `delete()` sets `deleted_at` and leaves
the row. Trade-off: the database only grows until a compaction job exists;
without tombstones a delete on one device would be undone by the next pull.

**Seen counts are derived, never incremented.** A `glossary_occurrences` row is
written per (word, sentence) pair and the count is recomputed from it.
Trade-off: one extra row per word per sentence, against the alternative — two
offline devices each incrementing a counter and one of them losing.

**The example sentence follows the most recent hearing.** Trade-off: the user
loses the first context they met the word in; a recent sentence is more useful
for recall, and every past sentence is still listed on the detail screen.

**Saying a deleted word again revives its row.** `deleted_at` is cleared rather
than a second row created. Trade-off: a user who deleted a word deliberately
sees it return if they say it again; the alternative is two rows for one word,
which breaks the uniqueness the merge rules depend on.

**Offline vocabulary extraction is a stopword filter, not a lemmatiser.**
`extractVocabulary` tokenises, lowercases and drops function words, with lists
for the seven languages most likely to be a user's native tongue. Trade-off:
"opens" and "open" are two entries until the backend's lemmatiser corrects
them; the alternative is an empty glossary whenever the network is down. A
language with no stopword list keeps every token — over-collecting is visible
and fixable, under-collecting is not.

**The utterance is saved even when translation fails.** The row is written with
an empty translation and left `pending`, so the sentence survives and the
backend can fill it in later.

## Milestone 3 — the backend

**No database in the API yet.** Translation is stateless, so SQLAlchemy,
Alembic and the Postgres schema arrive with sync in milestone 4, where the
first migration has something to create. `docker-compose.yml` already runs
Postgres so the container topology does not change later. Trade-off: milestone
4 is a bigger step; the alternative was an empty first migration.

**`claude-opus-5` with structured outputs.** `messages.parse()` with a Pydantic
model, so the word breakdown is schema-validated rather than parsed out of
prose. Trade-off: Opus is the expensive tier for what is often one short
sentence; it is also the one that gets lemmas and parts of speech right in
languages with real morphology, and the model is one config line
(`WORDNEST_TRANSLATION_MODEL`) away from being changed.

**Prompts are Jinja2 templates in `prompts/`, rendered with `StrictUndefined`.**
A change to what the model is asked shows up as a reviewable diff, and a missing
variable fails at render time instead of producing a prompt with a hole in it.

**The provider is a `Protocol` with a deterministic fake.** The whole test suite
runs with no API key and no network, and `WORDNEST_TRANSLATION_PROVIDER=fake`
runs the app end to end. The fake is refused when
`WORDNEST_ENVIRONMENT=production`, so a misconfigured deployment fails at
startup rather than serving nonsense.

**Rate limiting is an in-process token bucket, not Redis.** The effective limit
is `limit x workers`. Trade-off: not an exact quota; it exists to stop abuse,
not to meter a paid plan, and it refills continuously so one burst does not lock
a user out for a whole minute. Keyed by IP now, by device token from milestone 4
— an IP is shared by everyone behind one NAT.

**Enrichment is fire-and-forget, never awaited by the speak screen.** The
utterance is saved locally with its on-device translation first; the backend's
better translation replaces it when it arrives. A backend that is down leaves
the row `pending` and shows the user nothing. Trade-off: the user briefly sees
the rougher translation.

**A rejected sentence is marked `failed`, a retryable one is left `pending`.**
`4xx` means the server will never accept that row, so the queue stops carrying
it; `429`, `503`, `5xx` and no-network stop the whole run rather than hammering
a service that is already struggling.

**Backend lemmas re-key glossary entries, and re-keying can merge two rows.**
When "opens" is lemmatised to "open" and an "open" entry already exists, the
occurrences move onto it and the duplicate is tombstoned. Trade-off: real work
on the enrichment path; without it one word becomes two rows, which breaks the
uniqueness the sync merge rules depend on.

**Body logging is off by default and says so loudly when on.** User sentences in
an access log are a data-retention problem nobody asked for. Turning it on logs
a warning that it is on.
