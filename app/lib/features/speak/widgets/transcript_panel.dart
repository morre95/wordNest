import 'package:flutter/material.dart';

import '../speak_state.dart';

/// The source transcript above, the translation below.
///
/// A provisional translation is dimmed and italic so the user reads it as a
/// guess that is about to be replaced, not as the answer. Tapping a settled
/// translation speaks it aloud, which is how the user hears the pronunciation
/// they are trying to learn.
class TranscriptPanel extends StatelessWidget {
  const TranscriptPanel({
    required this.state,
    required this.onSpeakTranslation,
    required this.onToggleFlag,
    super.key,
  });

  final SpeakState state;
  final VoidCallback onSpeakTranslation;
  final VoidCallback onToggleFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (!state.hasTranscript) {
      return _EmptyPrompt(isListening: state.isListening);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          label: '${state.pair.source.name} transcript',
          child: Text(
            state.sourceText,
            key: const Key('speak.sourceText'),
            style: theme.textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 20),
        if (state.savedUtteranceId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('speak.flagUtterance'),
              onPressed: onToggleFlag,
              icon: Icon(
                state.isLastUtteranceFlagged ? Icons.star : Icons.star_border,
                size: 18,
              ),
              label: Text(
                state.isLastUtteranceFlagged
                    ? 'Marked as hard'
                    : 'That one was hard',
              ),
            ),
          ),
        if (state.translationText.isNotEmpty)
          Semantics(
            button: !state.isTranslationProvisional,
            label: state.isTranslationProvisional
                ? '${state.pair.target.name} translation, still being worked out'
                : '${state.pair.target.name} translation. '
                    'Double tap to hear it spoken.',
            child: ExcludeSemantics(
              child: InkWell(
                // A provisional translation is about to change; hearing it
                // would teach the wrong pronunciation.
                onTap: state.isTranslationProvisional
                    ? null
                    : onSpeakTranslation,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          state.translationText,
                          key: const Key('speak.translationText'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: state.isTranslationProvisional
                                ? scheme.onSurfaceVariant
                                : scheme.primary,
                            fontStyle: state.isTranslationProvisional
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ),
                      if (!state.isTranslationProvisional) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.volume_up_outlined,
                          size: 22,
                          color: scheme.primary,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EmptyPrompt extends StatelessWidget {
  const _EmptyPrompt({required this.isListening});

  final bool isListening;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isListening ? Icons.graphic_eq : Icons.eco_outlined,
          size: 40,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text(
          isListening ? 'Go ahead — I am listening.' : 'Say something.',
          key: const Key('speak.emptyPrompt'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
