import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/review_repository.dart';
import 'review_controller.dart';

/// What the glossary looks like as a whole. A sheet rather than a screen: it is
/// something to glance at, not somewhere to be.
Future<void> showGlossaryStatistics(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => const _StatisticsSheet(),
  );
}

class _StatisticsSheet extends ConsumerWidget {
  const _StatisticsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statistics = ref.watch(statisticsProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: statistics.when(
        loading: () => const SizedBox(
          height: 160,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (error, _) => Text('Statistics could not be read: $error'),
        data: (data) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your nest', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text(
              data.isEmpty
                  ? 'Nothing in it yet. Everything you say adds to it.'
                  : 'Everything you have said, and what it has taught you.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            _Figures(data: data),
          ],
        ),
      ),
    );
  }
}

class _Figures extends StatelessWidget {
  const _Figures({required this.data});

  final GlossaryStatistics data;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        _Figure(key: const Key('stats.words'), value: data.wordCount, label: 'words'),
        _Figure(
          key: const Key('stats.sentences'),
          value: data.utteranceCount,
          label: 'sentences said',
        ),
        _Figure(
          key: const Key('stats.due'),
          value: data.dueCount,
          label: 'due to review',
        ),
        _Figure(
          key: const Key('stats.struggling'),
          value: data.strugglingCount,
          label: 'you find hard',
        ),
        _Figure(
          key: const Key('stats.learned'),
          value: data.learnedCount,
          label: 'sticking',
        ),
        _Figure(
          key: const Key('stats.reviews'),
          value: data.reviewCount,
          label: 'reviews done',
        ),
      ],
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.value, required this.label, super.key});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$value $label',
      child: ExcludeSemantics(
        child: SizedBox(
          width: 96,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$value',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
