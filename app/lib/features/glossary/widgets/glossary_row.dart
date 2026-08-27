import 'package:flutter/material.dart';

import '../../../core/db/glossary_repository.dart';

/// One word in the glossary list: the word, its translation, the sentence it
/// came from, and how often it has been heard.
///
/// The single row component for a saved word — anywhere words are listed, this
/// is what lists them.
class GlossaryRow extends StatelessWidget {
  const GlossaryRow({
    required this.row,
    required this.onTap,
    required this.onToggleFlag,
    super.key,
  });

  final GlossaryEntryWithExample row;
  final VoidCallback onTap;
  final VoidCallback onToggleFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = row.entry;
    final target = entry.targetForm;
    final heard = entry.seenCount == 1 ? 'heard once' : 'heard ${entry.seenCount} times';

    return Semantics(
      button: true,
      label: '${entry.lemma}, ${target ?? 'not translated yet'}, $heard',
      child: ExcludeSemantics(
        child: ListTile(
          onTap: onTap,
          leading: _SeenCountBadge(count: entry.seenCount),
          title: Text(entry.lemma, style: theme.textTheme.titleMedium),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                target ?? 'Not translated yet',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: target == null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.primary,
                  fontStyle:
                      target == null ? FontStyle.italic : FontStyle.normal,
                ),
              ),
              if (row.example != null)
                Text(
                  row.example!.sourceText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          trailing: IconButton(
            onPressed: onToggleFlag,
            tooltip:
                entry.isFlagged ? 'Unmark as difficult' : 'Mark as difficult',
            icon: Icon(
              entry.isFlagged ? Icons.star : Icons.star_border,
              color: entry.isFlagged ? theme.colorScheme.primary : null,
            ),
          ),
          isThreeLine: row.example != null,
          minVerticalPadding: 8,
        ),
      ),
    );
  }
}

class _SeenCountBadge extends StatelessWidget {
  const _SeenCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CircleAvatar(
      radius: 18,
      backgroundColor: theme.colorScheme.secondaryContainer,
      child: Text(
        '$count',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
