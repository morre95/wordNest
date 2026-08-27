import 'package:flutter/material.dart';

import '../../../core/models/language.dart';

/// A searchable list of the languages on-device translation supports.
///
/// Returns the chosen [Language], or null if dismissed.
Future<Language?> showLanguagePicker(
  BuildContext context, {
  required String title,
  required Language selected,
}) {
  return showModalBottomSheet<Language>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _LanguagePickerSheet(title: title, selected: selected),
  );
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({required this.title, required this.selected});

  final String title;
  final Language selected;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  String _query = '';

  List<Language> get _matches {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return Languages.all;
    return Languages.all
        .where((language) => language.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              widget.title,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              autofocus: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search languages',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Expanded(
            child: matches.isEmpty
                ? const Center(child: Text('No language matches that search.'))
                : ListView.builder(
                    controller: controller,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final language = matches[index];
                      return ListTile(
                        title: Text(language.name),
                        selected: language == widget.selected,
                        trailing: language == widget.selected
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.of(context).pop(language),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
