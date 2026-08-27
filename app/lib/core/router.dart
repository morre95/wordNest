import 'package:go_router/go_router.dart';

import '../features/glossary/glossary_entry_screen.dart';
import '../features/glossary/glossary_screen.dart';
import '../features/privacy/privacy_screen.dart';
import '../features/review/review_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/speak/speak_screen.dart';

/// Every route in the app, in one place.
abstract final class Routes {
  /// The launch screen is the speaking screen — nothing stands between a cold
  /// start and the microphone.
  static const speak = '/';

  static const glossary = '/glossary';

  static String glossaryEntry(String id) => '/glossary/$id';

  static const privacy = '/privacy';

  static const review = '/review';

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
          path: Routes.privacy,
          builder: (context, state) => const PrivacyScreen(),
        ),
        GoRoute(
          path: Routes.review,
          builder: (context, state) => const ReviewScreen(),
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
