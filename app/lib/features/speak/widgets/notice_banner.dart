import 'package:flutter/material.dart';

import '../../../core/models/language.dart';
import '../speak_notice.dart';

/// Renders a [SpeakNotice] as an inline banner with the one action that
/// resolves it. It never blocks the microphone — the user can always try again.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    required this.notice,
    required this.onDownloadModel,
    required this.onOpenSettings,
    required this.onDismiss,
    super.key,
  });

  final SpeakNotice notice;
  final void Function(Language language) onDownloadModel;
  final VoidCallback onOpenSettings;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (message, action) = _describe();

    return Container(
      key: const Key('speak.notice'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
          ?action,
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
            tooltip: 'Dismiss',
            iconSize: 20,
          ),
        ],
      ),
    );
  }

  (String, Widget?) _describe() => switch (notice) {
        MicrophoneDenied() => (
            'WordNest needs the microphone to hear you.',
            null,
          ),
        MicrophoneBlocked() => (
            'Microphone access is turned off for WordNest.',
            TextButton(onPressed: onOpenSettings, child: const Text('Settings')),
          ),
        RecognitionUnavailable() => (
            'This device has no speech recogniser available.',
            null,
          ),
        LanguageNotRecognised(:final language) => (
            'This device cannot recognise spoken ${language.name}.',
            null,
          ),
        TranslationModelMissing(:final language, :final isDownloading) => (
            isDownloading
                ? 'Downloading the ${language.name} offline model…'
                : 'The ${language.name} offline model is not on this device yet.',
            isDownloading
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: () => onDownloadModel(language),
                    child: const Text('Download'),
                  ),
          ),
        TranslationModelDownloadFailed(:final language) => (
            'The ${language.name} model could not be downloaded.',
            TextButton(
              onPressed: () => onDownloadModel(language),
              child: const Text('Retry'),
            ),
          ),
        NothingHeard() => ("I didn't catch that — try again.", null),
        RecognitionFailed() => ('Speech recognition stopped unexpectedly.', null),
        TranslationFailed() => ('That could not be translated just now.', null),
      };
}
