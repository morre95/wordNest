import 'package:flutter/material.dart';

import '../../../core/models/language.dart';

/// Source ⇄ target, shown above the microphone so the user can confirm the
/// pair at a glance and swap it in one tap.
class LanguageBar extends StatelessWidget {
  const LanguageBar({
    required this.pair,
    required this.onSwap,
    required this.onSelectSource,
    required this.onSelectTarget,
    super.key,
  });

  final LanguagePair pair;
  final VoidCallback onSwap;
  final VoidCallback onSelectSource;
  final VoidCallback onSelectTarget;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Expanded(
          child: _LanguageChip(
            language: pair.source,
            semanticsLabel: 'Speaking in ${pair.source.name}. Change language.',
            alignment: Alignment.centerRight,
            onPressed: onSelectSource,
          ),
        ),
        IconButton(
          onPressed: onSwap,
          icon: const Icon(Icons.swap_horiz),
          tooltip: 'Swap languages',
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        Expanded(
          child: _LanguageChip(
            language: pair.target,
            semanticsLabel:
                'Translating into ${pair.target.name}. Change language.',
            alignment: Alignment.centerLeft,
            onPressed: onSelectTarget,
          ),
        ),
      ],
    );
  }
}

class _LanguageChip extends StatelessWidget {
  const _LanguageChip({
    required this.language,
    required this.semanticsLabel,
    required this.alignment,
    required this.onPressed,
  });

  final Language language;
  final String semanticsLabel;
  final Alignment alignment;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: TextButton(
          onPressed: onPressed,
          child: Text(
            language.name,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
    );
  }
}
