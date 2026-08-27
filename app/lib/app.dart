import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/enrichment/enrichment_triggers.dart';
import 'core/providers.dart';
import 'core/router.dart';
import 'core/theme/wordnest_theme.dart';

class WordNestApp extends ConsumerStatefulWidget {
  const WordNestApp({super.key});

  @override
  ConsumerState<WordNestApp> createState() => _WordNestAppState();
}

class _WordNestAppState extends ConsumerState<WordNestApp> {
  // Built once: rebuilding the router on every frame would reset navigation.
  final _router = buildRouter();
  late final EnrichmentTriggers _triggers;

  @override
  void initState() {
    super.initState();
    _triggers = EnrichmentTriggers(
      drainQueue: ref.read(enrichmentServiceProvider).drainQueue,
    );
    _triggers.start();
  }

  @override
  void dispose() {
    _triggers.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'WordNest',
      theme: WordNestTheme.light(),
      darkTheme: WordNestTheme.dark(),
      routerConfig: _router,
      debugShowCheckedModeBanner: false,
    );
  }
}
