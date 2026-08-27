import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/db/glossary_repository.dart';
import '../../core/providers.dart';

/// What the glossary list is currently filtered and sorted by.
///
/// Held separately from the results so that changing a filter does not
/// re-subscribe anything the user has not changed.
class GlossaryQuery {
  const GlossaryQuery({
    this.search = '',
    this.languagePairKey,
    this.difficulty = GlossaryDifficulty.all,
    this.sort = GlossarySort.recency,
  });

  final String search;

  /// Null means every pair.
  final String? languagePairKey;
  final GlossaryDifficulty difficulty;
  final GlossarySort sort;

  bool get isFiltered =>
      search.trim().isNotEmpty ||
      languagePairKey != null ||
      difficulty != GlossaryDifficulty.all;

  GlossaryQuery copyWith({
    String? search,
    String? languagePairKey,
    bool clearLanguagePair = false,
    GlossaryDifficulty? difficulty,
    GlossarySort? sort,
  }) {
    return GlossaryQuery(
      search: search ?? this.search,
      languagePairKey:
          clearLanguagePair ? null : languagePairKey ?? this.languagePairKey,
      difficulty: difficulty ?? this.difficulty,
      sort: sort ?? this.sort,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GlossaryQuery &&
      other.search == search &&
      other.languagePairKey == languagePairKey &&
      other.difficulty == difficulty &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(search, languagePairKey, difficulty, sort);
}

class GlossaryQueryController extends Notifier<GlossaryQuery> {
  @override
  GlossaryQuery build() => const GlossaryQuery();

  void search(String term) => state = state.copyWith(search: term);

  void filterByLanguagePair(String? key) => state = key == null
      ? state.copyWith(clearLanguagePair: true)
      : state.copyWith(languagePairKey: key);

  void filterByDifficulty(GlossaryDifficulty difficulty) =>
      state = state.copyWith(difficulty: difficulty);

  void sortBy(GlossarySort sort) => state = state.copyWith(sort: sort);

  void clearFilters() => state = const GlossaryQuery();
}

final glossaryQueryProvider =
    NotifierProvider<GlossaryQueryController, GlossaryQuery>(
  GlossaryQueryController.new,
);

/// The list itself, straight from the local database. The UI never reads from
/// the network, so it behaves the same whether the backend is up or not.
final glossaryEntriesProvider =
    StreamProvider.autoDispose<List<GlossaryEntryWithExample>>((ref) {
  final query = ref.watch(glossaryQueryProvider);
  return ref.watch(glossaryRepositoryProvider).watchEntries(
        search: query.search,
        languagePairKey: query.languagePairKey,
        difficulty: query.difficulty,
        sort: query.sort,
      );
});

/// The language pairs the glossary actually contains, for the filter chips.
final glossaryLanguagePairsProvider =
    StreamProvider.autoDispose<List<String>>((ref) {
  return ref.watch(glossaryRepositoryProvider).watchLanguagePairKeys();
});

final glossaryEntryProvider = StreamProvider.autoDispose
    .family<GlossaryEntryWithExample?, String>((ref, id) {
  return ref.watch(glossaryRepositoryProvider).watchEntry(id);
});

/// Every sentence a word has appeared in, for the detail view.
final glossaryOccurrencesProvider =
    StreamProvider.autoDispose.family<List<Utterance>, String>((ref, id) {
  return ref.watch(glossaryRepositoryProvider).watchOccurrences(id);
});
