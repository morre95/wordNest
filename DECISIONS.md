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

## Milestone 4 — sync

**The sync cursor is a per-account server sequence number.** A counter row per
account, incremented under a row lock inside the same transaction as the writes
it numbers. Per-account rather than global so one busy account cannot push
another's cursor forward. The returned cursor is the highest sequence actually
handed over, never "now", so a row written mid-request is picked up next time
rather than stepped over.

**The merge rules live in one pure module, twice.** `api/.../sync/merge.py` and
`app/lib/core/sync/merge.dart` implement the same rules with the same named
test cases. Trade-off: the same logic in two languages, which can drift; in
exchange each side can merge without asking the other, which is what makes the
app work offline. The named cases are the contract between them.

**Utterances have exactly one writer.** A push from a device other than the one
that recorded the utterance is rejected and reported, not merged. The rejection
is per row: one bad row must not stop a fortnight of good ones from landing.

**Seen counts are recomputed on both sides after every merge**, never copied.
Two devices that each heard a word twice offline converge on four.

**Scheduling state moves as one block, decided by `last_reviewed_at`.** Taking
the interval from one side and the ease factor from the other would produce a
schedule neither device ever computed. The due date is then recomputed from the
winning state, so a stale one cannot resurface a word already scheduled out.

**Magic link plus pairing code, no OAuth.** Both were asked for; of the durable
identities, an emailed link is much the cheapest to operate — no Apple
developer account, no OAuth client registration, no SDK on either platform. The
sender is a `Protocol` with a logging implementation that makes the whole
upgrade flow runnable locally with no provider; `build_email_sender` refuses to
return it in production, so deploying without wiring a real provider fails at
startup rather than silently swallowing sign-ins.

**Pairing codes are rate-limited per device, not counted per code.** The first
design counted a wrong guess against every live code — which would have let one
attacker invalidate every other user's pairing at will. A blind guesser names no
code, so the device is the only honest axis to cap on.

**Refresh tokens rotate and reuse is treated as theft.** A token is good exactly
once; a second use revokes every token for that device. Losing a session is
better than sharing one.

**Merging accounts renumbers the moved rows.** Every row moved into the target
account takes a fresh sequence number from that account's counter — otherwise
devices whose cursors are already past the source's numbering would never see
any of it. Devices follow their account too, so a third device paired to the
merged-away account keeps working.

**Every timestamp on the wire states its zone.** SQLite has no time zone type,
so a row read back from it is naive; serialised as-is, a client an hour off UTC
parsed it as a different instant — enough to lose a last-write-wins comparison
and silently drop a change. Found by the two-device test against the real
service. Fixed on both sides: the server normalises to UTC-aware before
serialising, and the client reads a zoneless timestamp as UTC instead of local.

**Migrations run as their own compose service, never on API startup.** Several
API containers starting together would migrate concurrently, which is the one
thing a migration must never do.

**Sync never blocks the microphone.** Nothing on the speak path awaits it, a
failed sync leaves the local database exactly as it was, and the status line
reports a number of waiting changes rather than an error.

## Milestone 5 — learning

**SM-2, not FSRS.** FSRS needs a fitted model per user and a review history to
fit it against; a new user has neither. SM-2's behaviour is the same shape for a
fraction of the machinery. Trade-off: less accurate scheduling for a heavy user;
the scheduler is a pure module with one entry point, so replacing it later
touches nothing else.

**Four grades, not SM-2's six.** Forgot / Hard / Good / Easy map to qualities
1/3/4/5. The finer distinctions in the original scale are not ones a person can
make reliably about a word they saw a second ago.

**A lapse restarts the ladder but keeps the reduced ease factor.** Resetting the
ease as well would forget that the word has been failed before and schedule it
as if it were new.

**Review order is computed in Dart, not SQL.** The priority is a function of the
current time, the user's flag and the ease factor together. It is expressible in
SQL, but then the rule would live in two places and only one of them would be
tested. The query fetches a generous candidate set and the pure
`reviewPriority` orders it.

**An explicit flag outranks any amount of overdue-ness.** A user who says a word
is hard has told us something no amount of review data can infer. A flagged word
is also offered even when its schedule says it is not due.

**A forgotten card is not re-queued within the session.** SM-2 schedules it for
tomorrow. Drilling it twice in one minute teaches recognition, not recall.

**A provisional translation cannot be spoken.** It is about to be replaced, and
hearing it would teach the wrong pronunciation. The speaker icon appears only
once the translation has settled.

**Text-to-speech runs a shade slower than the platform default (rate 0.45).**
This is a pronunciation model; the point is to be imitable.

**Review state was already in the schema.** Milestone 2 put `interval_days`,
`ease_factor`, `repetition_count`, `due_at` and `last_reviewed_at` on the first
migration, and milestone 4 wrote their merge rules, so this milestone added no
migration and no sync work — which is why it came after sync rather than before.

## Milestone 6 — hardening

**Riverpod 3 retries failed async providers by default, and that hid failures.**
A provider whose future fails stays in `AsyncLoading` while it retries with
backoff, so a device with no network showed a spinner that never resolved and
told the user nothing. Two changes: automatic retry is off for the device list
and the statistics, and every `AsyncValue` branch checks `hasError` *before*
`loading`, because an `AsyncValue` can be both and a spinner would hide the
failure behind something that looks like progress.

**A screen that has never synced says "Not synced yet", not "Everything is
synced".** They are different facts, and saying the wrong one is how a user
comes to distrust the whole line.

**The privacy guarantee has its own screen, reachable from the line that makes
it.** Every sentence on it is a specific claim the code holds up, rather than
"we may collect" boilerplate; the claims about audio are the ones the automated
guard enforces.

**The audio guard now also asserts that nothing outside `core/speech` imports
the recogniser.** Another file importing `speech_to_text` could open a second
session outside every guarantee that directory makes. The filesystem check was
extended to a full save-and-enrich session and to anything that *looks* like
audio by extension or name, not just to unexpected files.

**Accessibility is a test, not a review.** Every screen is checked against
Flutter's four guidelines — Android and iOS tap targets, labelled tap targets
and text contrast. It found a real gap: the hands-free switch announced
"on"/"off" with no idea what it toggled, and is now merged with its label.

**Sentences can be flagged as hard, not only words.** The specification asks for
an explicit signal on "any word or sentence"; the controller had the method and
nothing called it, which is the same as not having the feature.

**Compose publishes Postgres on 5433, not 5432.** Only for a psql client on the
host — the API reaches it over the compose network. A developer machine very
often already has Postgres on 5432, and a default that fails there is a bad
default. Override with `POSTGRES_PORT`.

**The Postgres volume is mounted at `/var/lib/postgresql`, not `.../data`.**
That is what the `postgres:18` image expects, and it is what makes a later
`pg_upgrade --link` possible without a mount-point boundary in the way.
