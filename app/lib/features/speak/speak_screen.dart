import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models/language.dart';
import '../../core/providers.dart';
import '../../core/router.dart';
import '../../core/tts/speaker.dart';
import '../../core/speech/speech_recognizer.dart';
import 'speak_controller.dart';
import 'speak_state.dart';
import 'widgets/language_bar.dart';
import 'widgets/language_picker_sheet.dart';
import 'widgets/mic_button.dart';
import 'widgets/notice_banner.dart';
import 'widgets/transcript_panel.dart';

/// The launch screen. Nothing stands between a cold start and the microphone:
/// no onboarding, no sign-in, no modal.
class SpeakScreen extends ConsumerWidget {
  const SpeakScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(speakControllerProvider);
    final controller = ref.read(speakControllerProvider.notifier);
    final isHandsFree = state.mode == ListeningMode.continuous;

    return Scaffold(
      appBar: AppBar(
        title: const Text('WordNest'),
        actions: [
          IconButton(
            key: const Key('speak.openSettings'),
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push(Routes.settings),
          ),
          IconButton(
            key: const Key('speak.openGlossary'),
            tooltip: 'Glossary',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => context.push(Routes.glossary),
          ),
          _HandsFreeToggle(
            isHandsFree: isHandsFree,
            onChanged: (value) => controller.setMode(
              value ? ListeningMode.continuous : ListeningMode.single,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              LanguageBar(
                pair: state.pair,
                onSwap: controller.swapLanguages,
                onSelectSource: () => _pickLanguage(
                  context,
                  controller: controller,
                  state: state,
                  isSource: true,
                ),
                onSelectTarget: () => _pickLanguage(
                  context,
                  controller: controller,
                  state: state,
                  isSource: false,
                ),
              ),
              if (state.notice != null) ...[
                const SizedBox(height: 8),
                NoticeBanner(
                  notice: state.notice!,
                  onDownloadModel: controller.downloadMissingModel,
                  onOpenSettings: controller.openSystemSettings,
                  onDismiss: controller.dismissNotice,
                ),
              ],
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: TranscriptPanel(
                      state: state,
                      onSpeakTranslation: () => _speakTranslation(
                        context,
                        ref,
                        state.translationText,
                        state.pair.target,
                      ),
                    ),
                  ),
                ),
              ),
              MicButton(
                status: state.status,
                soundLevel: state.soundLevel,
                isHandsFree: isHandsFree,
                onPressStart: controller.startListening,
                onPressEnd: controller.stopListening,
                onTap: () => state.isListening
                    ? controller.stopListening()
                    : controller.startListening(mode: ListeningMode.continuous),
              ),
              const SizedBox(height: 12),
              _PrivacyLine(isOnDevice: state.isRecognitionOnDevice),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  /// Speaks the translation so the user can hear the target-language
  /// pronunciation. Failures are a snack bar, never an interruption.
  Future<void> _speakTranslation(
    BuildContext context,
    WidgetRef ref,
    String text,
    Language language,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(speakerProvider).speak(text, languageCode: language.code);
    } on SpeakerFailure {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'This device has no ${language.name} voice installed yet.',
          ),
        ),
      );
    }
  }

  Future<void> _pickLanguage(
    BuildContext context, {
    required SpeakController controller,
    required SpeakState state,
    required bool isSource,
  }) async {
    final chosen = await showLanguagePicker(
      context,
      title: isSource ? 'Speak in' : 'Translate into',
      selected: isSource ? state.pair.source : state.pair.target,
    );
    if (chosen == null) return;
    final pair = isSource
        ? LanguagePair(source: chosen, target: state.pair.target)
        : LanguagePair(source: state.pair.source, target: chosen);
    // Choosing the language already on the other side means the user wants
    // them swapped, not a pair that translates a language into itself.
    await controller.setLanguagePair(
      pair.source == pair.target ? state.pair.swapped : pair,
    );
  }
}

class _HandsFreeToggle extends StatelessWidget {
  const _HandsFreeToggle({required this.isHandsFree, required this.onChanged});

  final bool isHandsFree;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: isHandsFree,
      label: 'Hands-free listening',
      child: Row(
        children: [
          const Text('Hands-free'),
          Switch(
            key: const Key('speak.handsFreeToggle'),
            value: isHandsFree,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// The privacy guarantee, in plain language, on the screen where it matters.
class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine({required this.isOnDevice});

  final bool isOnDevice;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: isOnDevice
          ? 'Your voice is processed on this device and never recorded or saved.'
          : 'This language is recognised by your phone using its online '
              'recogniser. Nothing is recorded or saved.',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isOnDevice ? Icons.lock_outline : Icons.cloud_outlined,
            size: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isOnDevice
                  ? 'Your voice stays on this device. Nothing is recorded.'
                  : 'Recognised by your phone online. Nothing is recorded.',
              key: const Key('speak.privacyLine'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
