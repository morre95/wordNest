"""The merge rules, against the cases that actually go wrong.

Every test here is a scenario a real pair of devices can produce. The four the
specification calls out have their own group at the end.
"""

from datetime import UTC, datetime, timedelta

import pytest

from wordnest_api.features.sync.merge import (
    GlossaryEntrySnapshot,
    GlossaryOccurrenceSnapshot,
    MergeOutcome,
    ReviewLogSnapshot,
    UtteranceSnapshot,
    due_date_from,
    merge_glossary_entry,
    merge_glossary_occurrence,
    merge_review_log,
    merge_utterance,
)

MONDAY = datetime(2026, 3, 2, 9, 0, tzinfo=UTC)
TUESDAY = MONDAY + timedelta(days=1)
WEDNESDAY = MONDAY + timedelta(days=2)


def utterance(**overrides: object) -> UtteranceSnapshot:
    defaults = {
        "id": "utt-1",
        "origin_device_id": "device-a",
        "updated_at": MONDAY,
        "deleted_at": None,
        "source_text": "the bakery is closed",
        "translation_text": "la panadería está cerrada",
        "literal_gloss": None,
        "enrichment_state": "pending",
        "is_flagged": False,
    }
    return UtteranceSnapshot(**(defaults | overrides))  # type: ignore[arg-type]


def entry(**overrides: object) -> GlossaryEntrySnapshot:
    defaults = {
        "id": "entry-1",
        "lemma": "bakery",
        "surface_form": "bakery",
        "part_of_speech": None,
        "target_form": None,
        "source_language": "en",
        "target_language": "es",
        "seen_count": 1,
        "example_utterance_id": "utt-1",
        "is_flagged": False,
        "interval_days": 0,
        "ease_factor": 2.5,
        "repetition_count": 0,
        "due_at": None,
        "last_reviewed_at": None,
        "updated_at": MONDAY,
        "deleted_at": None,
    }
    return GlossaryEntrySnapshot(**(defaults | overrides))  # type: ignore[arg-type]


def review(**overrides: object) -> ReviewLogSnapshot:
    defaults = {
        "id": "review-1",
        "glossary_entry_id": "entry-1",
        "reviewed_at": MONDAY,
        "grade": 4,
        "scheduled_interval_days": 1,
        "scheduled_ease_factor": 2.5,
        "updated_at": MONDAY,
        "deleted_at": None,
    }
    return ReviewLogSnapshot(**(defaults | overrides))  # type: ignore[arg-type]


def occurrence(**overrides: object) -> GlossaryOccurrenceSnapshot:
    defaults = {
        "id": "occ-1",
        "glossary_entry_id": "entry-1",
        "utterance_id": "utt-1",
        "surface_form": "bakery",
        "updated_at": MONDAY,
        "deleted_at": None,
    }
    return GlossaryOccurrenceSnapshot(**(defaults | overrides))  # type: ignore[arg-type]


class TestUtterances:
    def test_a_new_utterance_is_inserted_and_stamped_with_its_writer(self) -> None:
        result = merge_utterance(
            stored=None, incoming=utterance(), writing_device_id="device-a"
        )

        assert result.outcome is MergeOutcome.inserted
        assert result.value.origin_device_id == "device-a"

    def test_a_retried_push_does_not_duplicate(self) -> None:
        stored = utterance()

        result = merge_utterance(
            stored=stored, incoming=utterance(), writing_device_id="device-a"
        )

        assert result.outcome is MergeOutcome.kept
        assert result.should_write is False

    def test_the_originating_device_may_attach_enrichment_later(self) -> None:
        stored = utterance()

        result = merge_utterance(
            stored=stored,
            incoming=utterance(
                updated_at=TUESDAY,
                translation_text="la panadería ha cerrado",
                enrichment_state="enriched",
            ),
            writing_device_id="device-a",
        )

        assert result.outcome is MergeOutcome.replaced
        assert result.value.translation_text == "la panadería ha cerrado"

    def test_another_device_cannot_rewrite_someone_elses_utterance(self) -> None:
        # Utterances are append-only with exactly one writer. A push from a
        # second device is a bug or an attack, not a conflict to resolve.
        result = merge_utterance(
            stored=utterance(),
            incoming=utterance(updated_at=TUESDAY, source_text="rewritten"),
            writing_device_id="device-b",
        )

        assert result.outcome is MergeOutcome.rejected
        assert result.value.source_text == "the bakery is closed"

    def test_an_older_write_does_not_undo_a_newer_one(self) -> None:
        stored = utterance(updated_at=WEDNESDAY, enrichment_state="enriched")

        result = merge_utterance(
            stored=stored,
            incoming=utterance(updated_at=MONDAY),
            writing_device_id="device-a",
        )

        assert result.outcome is MergeOutcome.kept


class TestReviewLogs:
    def test_a_new_review_is_recorded(self) -> None:
        result = merge_review_log(stored=None, incoming=review())

        assert result.outcome is MergeOutcome.inserted

    def test_the_same_review_pushed_twice_is_recorded_once(self) -> None:
        result = merge_review_log(stored=review(), incoming=review(grade=1))

        assert result.outcome is MergeOutcome.kept
        assert result.value.grade == 4, "an event never changes after the fact"

    def test_two_devices_reviewing_offline_both_contribute(self) -> None:
        # Different ids, so neither collides with the other: both are stored.
        from_a = merge_review_log(stored=None, incoming=review(id="review-a"))
        from_b = merge_review_log(stored=None, incoming=review(id="review-b"))

        assert from_a.outcome is MergeOutcome.inserted
        assert from_b.outcome is MergeOutcome.inserted


class TestGlossaryEntries:
    def test_a_new_entry_gets_a_due_date_derived_from_its_schedule(self) -> None:
        result = merge_glossary_entry(
            stored=None,
            incoming=entry(last_reviewed_at=MONDAY, interval_days=3),
        )

        assert result.outcome is MergeOutcome.inserted
        assert result.value.due_at == MONDAY + timedelta(days=3)

    def test_the_seen_count_is_never_copied_across(self) -> None:
        # It is recomputed from the occurrence rows after the merge; whatever
        # number the other device happened to hold must not overwrite ours.
        result = merge_glossary_entry(
            stored=entry(seen_count=2),
            incoming=entry(seen_count=7, updated_at=TUESDAY),
        )

        assert result.value.seen_count == 2

    def test_the_users_flag_is_last_write_wins(self) -> None:
        result = merge_glossary_entry(
            stored=entry(is_flagged=False, updated_at=MONDAY),
            incoming=entry(is_flagged=True, updated_at=TUESDAY),
        )

        assert result.value.is_flagged is True

    def test_an_older_flag_does_not_overwrite_a_newer_one(self) -> None:
        result = merge_glossary_entry(
            stored=entry(is_flagged=True, updated_at=WEDNESDAY),
            incoming=entry(is_flagged=False, updated_at=MONDAY),
        )

        assert result.value.is_flagged is True

    def test_a_tie_leaves_the_stored_version_alone(self) -> None:
        # Rewriting on a tie would burn a sequence number and wake every other
        # device for a change that is not one.
        result = merge_glossary_entry(stored=entry(), incoming=entry())

        assert result.outcome is MergeOutcome.kept
        assert result.should_write is False

    def test_the_schedule_follows_whoever_reviewed_most_recently(self) -> None:
        result = merge_glossary_entry(
            stored=entry(
                last_reviewed_at=MONDAY,
                interval_days=1,
                ease_factor=2.5,
                repetition_count=1,
                updated_at=WEDNESDAY,
            ),
            incoming=entry(
                last_reviewed_at=TUESDAY,
                interval_days=6,
                ease_factor=2.6,
                repetition_count=2,
                updated_at=MONDAY,
            ),
        )

        assert result.value.interval_days == 6
        assert result.value.ease_factor == pytest.approx(2.6)
        assert result.value.repetition_count == 2
        assert result.value.last_reviewed_at == TUESDAY

    def test_the_schedule_moves_as_one_block(self) -> None:
        # Taking the interval from one side and the ease from the other would
        # produce a schedule neither device ever computed.
        result = merge_glossary_entry(
            stored=entry(last_reviewed_at=TUESDAY, interval_days=10, ease_factor=2.9),
            incoming=entry(
                last_reviewed_at=MONDAY,
                interval_days=1,
                ease_factor=1.7,
                updated_at=WEDNESDAY,
            ),
        )

        assert (result.value.interval_days, result.value.ease_factor) == (10, 2.9)

    def test_the_due_date_is_recomputed_so_a_stale_one_cannot_resurface(
        self,
    ) -> None:
        # The losing side thinks the word is due immediately. If its due date
        # survived, the word would come back up in review despite the winning
        # side having scheduled it ten days out.
        result = merge_glossary_entry(
            stored=entry(
                last_reviewed_at=TUESDAY,
                interval_days=10,
                due_at=TUESDAY + timedelta(days=10),
            ),
            incoming=entry(
                last_reviewed_at=MONDAY,
                interval_days=0,
                due_at=MONDAY,
                updated_at=WEDNESDAY,
            ),
        )

        assert result.value.due_at == TUESDAY + timedelta(days=10)

    def test_enrichment_from_the_other_device_is_taken(self) -> None:
        result = merge_glossary_entry(
            stored=entry(part_of_speech=None, target_form=None),
            incoming=entry(
                part_of_speech="NOUN", target_form="panadería", updated_at=TUESDAY
            ),
        )

        assert result.value.part_of_speech == "NOUN"
        assert result.value.target_form == "panadería"

    def test_naive_timestamps_are_treated_as_utc(self) -> None:
        # A device that sends a timestamp without a zone must not be treated as
        # infinitely old or infinitely new.
        naive_tuesday = TUESDAY.replace(tzinfo=None)

        result = merge_glossary_entry(
            stored=entry(updated_at=MONDAY),
            incoming=entry(updated_at=naive_tuesday, is_flagged=True),
        )

        assert result.value.is_flagged is True


class TestOccurrences:
    def test_a_new_sighting_is_recorded(self) -> None:
        assert (
            merge_glossary_occurrence(stored=None, incoming=occurrence()).outcome
            is MergeOutcome.inserted
        )

    def test_the_same_sighting_pushed_twice_is_recorded_once(self) -> None:
        result = merge_glossary_occurrence(stored=occurrence(), incoming=occurrence())

        assert result.outcome is MergeOutcome.kept

    def test_a_re_keyed_occurrence_follows_its_new_entry(self) -> None:
        # Enrichment lemmatised "opens" onto an existing "open" entry.
        result = merge_glossary_occurrence(
            stored=occurrence(glossary_entry_id="entry-opens"),
            incoming=occurrence(glossary_entry_id="entry-open", updated_at=TUESDAY),
        )

        assert result.value.glossary_entry_id == "entry-open"


class TestTheAwkwardCases:
    """The four the specification names."""

    def test_the_same_word_learned_independently_on_two_offline_devices(
        self,
    ) -> None:
        # Both devices generated their own row id for the same word, so the
        # server sees two rows. Uniqueness on (account, lemma, pair) is what
        # makes them one; here we check the merge of their content.
        from_a = entry(
            id="entry-a", seen_count=2, surface_form="bakery", updated_at=MONDAY
        )
        from_b = entry(
            id="entry-b",
            seen_count=3,
            surface_form="Bakery",
            target_form="panadería",
            updated_at=TUESDAY,
        )

        result = merge_glossary_entry(stored=from_a, incoming=from_b)

        assert result.value.id == "entry-a", "the stored row keeps its identity"
        assert result.value.target_form == "panadería", "enrichment is kept"
        assert result.value.seen_count == 2, "recomputed afterwards, not copied"

    def test_a_review_on_device_a_and_an_edit_on_device_b(self) -> None:
        reviewed_on_a = entry(
            last_reviewed_at=TUESDAY,
            interval_days=6,
            ease_factor=2.6,
            repetition_count=2,
            updated_at=TUESDAY,
        )
        flagged_on_b = entry(
            is_flagged=True,
            last_reviewed_at=None,
            interval_days=0,
            ease_factor=2.5,
            updated_at=WEDNESDAY,
        )

        result = merge_glossary_entry(stored=reviewed_on_a, incoming=flagged_on_b)

        assert result.outcome is MergeOutcome.merged
        assert result.value.is_flagged is True, "B's edit survives"
        assert result.value.interval_days == 6, "A's review survives"
        assert result.value.due_at == TUESDAY + timedelta(days=6)

    def test_a_deletion_racing_an_update(self) -> None:
        deleted_on_a = entry(deleted_at=WEDNESDAY, updated_at=WEDNESDAY)
        edited_on_b = entry(is_flagged=True, updated_at=TUESDAY)

        deletion_wins = merge_glossary_entry(stored=edited_on_b, incoming=deleted_on_a)
        assert deletion_wins.value.deleted_at == WEDNESDAY

        # The other order must reach the same answer, or the two devices never
        # converge.
        same_answer = merge_glossary_entry(stored=deleted_on_a, incoming=edited_on_b)
        assert same_answer.value.deleted_at == WEDNESDAY

    def test_a_deleted_word_said_again_comes_back(self) -> None:
        result = merge_glossary_entry(
            stored=entry(deleted_at=MONDAY, updated_at=MONDAY),
            incoming=entry(deleted_at=None, updated_at=WEDNESDAY),
        )

        assert result.value.deleted_at is None

    def test_a_fortnight_of_queued_changes_converges(self) -> None:
        # Device B was offline for two weeks. Its changes arrive all at once,
        # out of order, and must land on the same answer whatever the order.
        stored = entry(updated_at=MONDAY)
        backlog = [
            entry(is_flagged=True, updated_at=MONDAY + timedelta(days=3)),
            entry(
                last_reviewed_at=MONDAY + timedelta(days=5),
                interval_days=4,
                updated_at=MONDAY + timedelta(days=5),
            ),
            entry(target_form="panadería", updated_at=MONDAY + timedelta(days=14)),
        ]

        forwards = stored
        for change in backlog:
            forwards = merge_glossary_entry(stored=forwards, incoming=change).value

        backwards = stored
        for change in reversed(backlog):
            backwards = merge_glossary_entry(stored=backwards, incoming=change).value

        assert forwards.target_form == backwards.target_form == "panadería"
        assert forwards.interval_days == backwards.interval_days == 4
        assert forwards.last_reviewed_at == backwards.last_reviewed_at
        assert forwards.due_at == backwards.due_at


class TestDueDates:
    def test_an_entry_never_reviewed_has_no_due_date(self) -> None:
        assert due_date_from(last_reviewed_at=None, interval_days=5) is None

    def test_a_zero_interval_is_due_immediately(self) -> None:
        assert due_date_from(last_reviewed_at=MONDAY, interval_days=0) == MONDAY

    def test_a_negative_interval_cannot_schedule_into_the_past(self) -> None:
        assert due_date_from(last_reviewed_at=MONDAY, interval_days=-5) == MONDAY
