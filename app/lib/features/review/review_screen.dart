import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/db/review_repository.dart';
import '../../core/providers.dart';
import '../../core/review/scheduler.dart';
import '../../core/tts/speaker.dart';
import '../glossary/widgets/empty_state.dart';
import 'review_controller.dart';

/// One word at a time: recall it, hear it, say how it went.
class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(reviewControllerProvider);
    final controller = ref.read(reviewControllerProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: [
          if (session.current != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${session.position + 1} of ${session.cards.length}',
                  key: const Key('review.progress'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: switch (session) {
          ReviewSession(isLoading: true) =>
            const Center(child: CircularProgressIndicator()),
          ReviewSession(isFinished: true) => _Finished(session: session),
          _ => _Card(session: session, controller: controller),
        },
      ),
    );
  }
}

class _Finished extends StatelessWidget {
  const _Finished({required this.session});

  final ReviewSession session;

  @override
  Widget build(BuildContext context) {
    final reviewed = session.reviewed;
    return EmptyState(
      key: const Key('review.finished'),
      icon: reviewed == 0 ? Icons.eco_outlined : Icons.check_circle_outline,
      title: reviewed == 0 ? 'Nothing to review' : 'Done for now',
      message: reviewed == 0
          ? 'Words appear here once they are due. Go and speak — everything you '
              'say adds to your nest.'
          : 'You reviewed $reviewed word${reviewed == 1 ? '' : 's'}. '
              'They will come back when it is time.',
      action: FilledButton.icon(
        onPressed: () => context.pop(),
        icon: const Icon(Icons.arrow_back),
        label: const Text('Back'),
      ),
    );
  }
}

class _Card extends ConsumerWidget {
  const _Card({required this.session, required this.controller});

  final ReviewSession session;
  final ReviewController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final card = session.current!;
    final entry = card.entry;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.lemma,
                      key: const Key('review.prompt'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.displaySmall,
                    ),
                    if (entry.partOfSpeech != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        entry.partOfSpeech!.toLowerCase(),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    if (session.isAnswerVisible)
                      _Answer(card: card)
                    else
                      FilledButton.tonal(
                        key: const Key('review.reveal'),
                        onPressed: controller.revealAnswer,
                        child: const Text('Show the answer'),
                      ),
                  ],
                ),
              ),
            ),
          ),
          _CardActions(
            session: session,
            controller: controller,
            isFlagged: entry.isFlagged,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _Answer extends ConsumerWidget {
  const _Answer({required this.card});

  final ReviewCard card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final target = card.entry.targetForm;

    return Column(
      children: [
        Text(
          target ?? 'Not translated yet',
          key: const Key('review.answer'),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(
            color: target == null
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.primary,
          ),
        ),
        if (target != null) ...[
          const SizedBox(height: 8),
          IconButton.filledTonal(
            key: const Key('review.listen'),
            tooltip: 'Hear it',
            onPressed: () => _speak(context, ref, target),
            icon: const Icon(Icons.volume_up_outlined),
          ),
        ],
        if (card.example != null) ...[
          const SizedBox(height: 28),
          Text(
            'You said',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            card.example!.sourceText,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge,
          ),
        ],
      ],
    );
  }

  Future<void> _speak(
    BuildContext context,
    WidgetRef ref,
    String text,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(speakerProvider).speak(
            text,
            languageCode: card.entry.targetLanguage,
          );
    } on SpeakerFailure {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('This device has no voice for that language yet.'),
        ),
      );
    }
  }
}

class _CardActions extends StatelessWidget {
  const _CardActions({
    required this.session,
    required this.controller,
    required this.isFlagged,
  });

  final ReviewSession session;
  final ReviewController controller;
  final bool isFlagged;

  @override
  Widget build(BuildContext context) {
    if (!session.isAnswerVisible) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          TextButton(
            key: const Key('review.skip'),
            onPressed: controller.skip,
            child: const Text('Skip'),
          ),
          _FlagButton(isFlagged: isFlagged, controller: controller),
        ],
      );
    }

    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: _FlagButton(isFlagged: isFlagged, controller: controller),
        ),
        const SizedBox(height: 8),
        // Four steps, not five: the finer distinctions in SM-2's scale are not
        // ones a person can make reliably about a word they just saw.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final grade in ReviewGrade.values)
              FilledButton.tonal(
                key: Key('review.grade.${grade.name}'),
                onPressed: () => controller.grade(grade),
                child: Text(_label(grade)),
              ),
          ],
        ),
      ],
    );
  }

  static String _label(ReviewGrade grade) => switch (grade) {
        ReviewGrade.forgot => 'Forgot',
        ReviewGrade.hard => 'Hard',
        ReviewGrade.good => 'Good',
        ReviewGrade.easy => 'Easy',
      };
}

class _FlagButton extends StatelessWidget {
  const _FlagButton({required this.isFlagged, required this.controller});

  final bool isFlagged;
  final ReviewController controller;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: const Key('review.flag'),
      onPressed: () => controller.setFlagged(isFlagged: !isFlagged),
      icon: Icon(isFlagged ? Icons.star : Icons.star_border),
      label: Text(isFlagged ? 'Marked hard' : 'Mark as hard'),
    );
  }
}
