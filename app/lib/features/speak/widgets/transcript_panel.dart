import 'package:flutter/material.dart';

import '../speak_state.dart';

/// The source transcript above, the translation below.
///
/// A provisional translation is dimmed and italic so the user reads it as a
/// guess that is about to be replaced, not as the answer.
class TranscriptPanel extends StatelessWidget {
  const TranscriptPanel({required this.state, super.key});

  final SpeakState state;

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
        if (state.translationText.isNotEmpty)
          Semantics(
            label: '${state.pair.target.name} translation',
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
