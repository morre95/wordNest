import 'package:go_router/go_router.dart';

import '../features/glossary/glossary_entry_screen.dart';
import '../features/glossary/glossary_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/speak/speak_screen.dart';

/// Every route in the app, in one place.
abstract final class Routes {
  /// The launch screen is the speaking screen — nothing stands between a cold
  /// start and the microphone.
  static const speak = '/';

  static const glossary = '/glossary';

  static String glossaryEntry(String id) => '/glossary/$id';

  static const settings = '/settings';
}

GoRouter buildRouter() => GoRouter(
      initialLocation: Routes.speak,
      routes: [
        GoRoute(
          path: Routes.speak,
          builder: (context, state) => const SpeakScreen(),
        ),
        GoRoute(
          path: Routes.settings,
          builder: (context, state) => const SettingsScreen(),
        ),
        GoRoute(
          path: Routes.glossary,
          builder: (context, state) => const GlossaryScreen(),
          routes: [
            GoRoute(
              path: ':entryId',
              builder: (context, state) => GlossaryEntryScreen(
                entryId: state.pathParameters['entryId']!,
              ),
            ),
          ],
        ),
      ],
    );
