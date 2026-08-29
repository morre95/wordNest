import 'package:flutter/material.dart';

import '../speak_state.dart';

/// The one dominant control on the launch screen.
///
/// Hold to talk, or tap the hands-free switch beside it. The ring around it
/// breathes with the input level so the user can see they are being heard.
class MicButton extends StatelessWidget {
  const MicButton({
    required this.status,
    required this.soundLevel,
    required this.onPressStart,
    required this.onPressEnd,
    required this.onTap,
    required this.isHandsFree,
    super.key,
  });

  static const diameter = 128.0;

  final SpeakStatus status;
  final double soundLevel;
  final bool isHandsFree;

  /// Hold-to-talk gestures. Ignored in hands-free mode, where [onTap] toggles.
  final VoidCallback onPressStart;
  final VoidCallback onPressEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = status != SpeakStatus.idle;
    final label = switch (status) {
      SpeakStatus.idle => isHandsFree ? 'Start listening' : 'Hold to speak',
      SpeakStatus.starting => 'Starting speech recognition',
      SpeakStatus.listening => 'Listening. Release to finish.',
      SpeakStatus.finalising => 'Finishing up',
    };

    return Semantics(
      button: true,
      label: label,
      value: status.name,
      child: GestureDetector(
        onTapDown: isHandsFree ? null : (_) => onPressStart(),
        onTapUp: isHandsFree ? null : (_) => onPressEnd(),
        onTapCancel: isHandsFree ? null : onPressEnd,
        onTap: isHandsFree ? onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: diameter + soundLevel * 24,
          height: diameter + soundLevel * 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? scheme.primary : scheme.primaryContainer,
            boxShadow: [
              if (isActive)
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.35),
                  blurRadius: 24 + soundLevel * 32,
                  spreadRadius: soundLevel * 8,
                ),
            ],
          ),
          child: Icon(
            status == SpeakStatus.starting || status == SpeakStatus.finalising
                ? Icons.more_horiz
                : Icons.mic,
            size: 56,
            color: isActive ? scheme.onPrimary : scheme.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
