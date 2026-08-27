import 'package:go_router/go_router.dart';

import '../features/speak/speak_screen.dart';

/// Every route in the app, in one place.
abstract final class Routes {
  /// The launch screen is the speaking screen — nothing stands between a cold
  /// start and the microphone.
  static const speak = '/';
}

GoRouter buildRouter() => GoRouter(
      initialLocation: Routes.speak,
      routes: [
        GoRoute(
          path: Routes.speak,
          builder: (context, state) => const SpeakScreen(),
        ),
      ],
    );
