import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/glossary_repository.dart';
import '../../core/models/language.dart';
import '../../core/providers.dart';
import '../../core/router.dart';
import 'glossary_controller.dart';
import 'widgets/empty_state.dart';
import 'widgets/glossary_row.dart';

/// Every word the user has produced, searchable and filterable.
///
/// Reads only from the local database, so it works identically offline.
class GlossaryScreen extends ConsumerWidget {
  const GlossaryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(glossaryEntriesProvider);
    final query = ref.watch(glossaryQueryProvider);
    final controller = ref.read(glossaryQueryProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Glossary'),
        actions: [
          PopupMenuButton<GlossarySort>(
            key: const Key('glossary.sortMenu'),
            initialValue: query.sort,
            onSelected: controller.sortBy,
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: GlossarySort.recency,
                child: Text('Most recent'),
              ),
              PopupMenuItem(
                value: GlossarySort.struggle,
                child: Text('Hardest first'),
              ),
              PopupMenuItem(
                value: GlossarySort.alphabetical,
                child: Text('A to Z'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              key: const Key('glossary.search'),
              onChanged: controller.search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search your words',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          _FilterBar(query: query, controller: controller),
          Expanded(
            child: entries.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'Your glossary could not be read',
                message: '$error',
              ),
              data: (rows) => rows.isEmpty
                  ? _emptyState(context, ref, isFiltered: query.isFiltered)
                  : ListView.separated(
                      key: const Key('glossary.list'),
                      itemCount: rows.length,
                      separatorBuilder: (context, index) =>
                          const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return GlossaryRow(
                          row: row,
                          onTap: () => context.push(
                            Routes.glossaryEntry(row.entry.id),
                          ),
                          onToggleFlag: () => ref
                              .read(glossaryRepositoryProvider)
                              .setFlagged(
                                row.entry.id,
                                isFlagged: !row.entry.isFlagged,
                              ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState(
    BuildContext context,
    WidgetRef ref, {
    required bool isFiltered,
  }) {
    if (isFiltered) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'Nothing matches',
        message: 'No saved word fits these filters. Try widening the search.',
        action: TextButton(
          onPressed: ref.read(glossaryQueryProvider.notifier).clearFilters,
          child: const Text('Clear filters'),
        ),
      );
    }
    return EmptyState(
      icon: Icons.eco_outlined,
      title: 'Your nest is empty',
      message: 'Every sentence you speak adds its words here. '
          'Go and say something.',
      action: FilledButton.icon(
        onPressed: () => context.go(Routes.speak),
        icon: const Icon(Icons.mic),
        label: const Text('Start speaking'),
      ),
    );
  }
}

class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.query, required this.controller});

  final GlossaryQuery query;
  final GlossaryQueryController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairs = ref.watch(glossaryLanguagePairsProvider).value ?? [];

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          FilterChip(
            key: const Key('glossary.filter.struggling'),
            label: const Text('Struggling'),
            selected: query.difficulty == GlossaryDifficulty.struggling,
            onSelected: (selected) => controller.filterByDifficulty(
              selected ? GlossaryDifficulty.struggling : GlossaryDifficulty.all,
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            key: const Key('glossary.filter.due'),
            label: const Text('Due'),
            selected: query.difficulty == GlossaryDifficulty.due,
            onSelected: (selected) => controller.filterByDifficulty(
              selected ? GlossaryDifficulty.due : GlossaryDifficulty.all,
            ),
          ),
          // Only worth showing once the user has more than one pair.
          if (pairs.length > 1)
            for (final key in pairs) ...[
              const SizedBox(width: 8),
              FilterChip(
                label: Text(_pairLabel(key)),
                selected: query.languagePairKey == key,
                onSelected: (selected) =>
                    controller.filterByLanguagePair(selected ? key : null),
              ),
            ],
        ],
      ),
    );
  }

  static String _pairLabel(String key) {
    final pair = LanguagePair.parseKey(key);
    if (pair == null) return key;
    return '${pair.source.name} → ${pair.target.name}';
  }
}
