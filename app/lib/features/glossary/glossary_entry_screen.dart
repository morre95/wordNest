import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/db/glossary_repository.dart';
import '../../core/models/language.dart';
import '../../core/providers.dart';
import 'glossary_controller.dart';
import 'widgets/empty_state.dart';

/// One word in full: its translation, how often it has been heard, and every
/// sentence the user said it in.
class GlossaryEntryScreen extends ConsumerWidget {
  const GlossaryEntryScreen({required this.entryId, super.key});

  final String entryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(glossaryEntryProvider(entryId));
    final loaded = entry.value;

    return Scaffold(
      appBar: AppBar(
        title: Text(loaded?.entry.lemma ?? 'Word'),
        actions: [
          if (loaded != null)
            IconButton(
              key: const Key('glossaryEntry.flag'),
              tooltip: loaded.entry.isFlagged
                  ? 'Unmark as difficult'
                  : 'Mark as difficult',
              icon: Icon(
                loaded.entry.isFlagged ? Icons.star : Icons.star_border,
              ),
              onPressed: () => ref.read(glossaryRepositoryProvider).setFlagged(
                    entryId,
                    isFlagged: !loaded.entry.isFlagged,
                  ),
            ),
        ],
      ),
      body: entry.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'This word could not be read',
          message: '$error',
        ),
        data: (row) => row == null
            ? const EmptyState(
                icon: Icons.search_off,
                title: 'No longer in your glossary',
                message: 'This word has been removed.',
              )
            : _EntryDetail(entryId: entryId, row: row),
      ),
    );
  }
}

class _EntryDetail extends ConsumerWidget {
  const _EntryDetail({required this.entryId, required this.row});

  final String entryId;
  final GlossaryEntryWithExample row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entry = row.entry;
    final occurrences = ref.watch(glossaryOccurrencesProvider(entryId));
    final pair = LanguagePair.parseKey(
      '${entry.sourceLanguage}-${entry.targetLanguage}',
    );

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(entry.lemma, style: theme.textTheme.displaySmall),
        const SizedBox(height: 8),
        Text(
          entry.targetForm ?? 'Not translated yet',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: entry.targetForm == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (pair != null)
              _Fact(label: '${pair.source.name} → ${pair.target.name}'),
            if (entry.partOfSpeech != null)
              _Fact(label: entry.partOfSpeech!.toLowerCase()),
            _Fact(
              label: entry.seenCount == 1
                  ? 'said once'
                  : 'said ${entry.seenCount} times',
            ),
            if (entry.surfaceForm.toLowerCase() != entry.lemma)
              _Fact(label: 'first heard as "${entry.surfaceForm}"'),
          ],
        ),
        const SizedBox(height: 28),
        Text('Where you said it', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        occurrences.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (error, _) => Text('Examples could not be read: $error'),
          data: (utterances) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final utterance in utterances)
                _ExampleCard(utterance: utterance),
            ],
          ),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _ExampleCard extends StatelessWidget {
  const _ExampleCard({required this.utterance});

  final Utterance utterance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(utterance.sourceText, style: theme.textTheme.bodyLarge),
            if (utterance.translationText.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                utterance.translationText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
