import 'package:flutter/material.dart';

import 'core/router.dart';
import 'core/theme/wordnest_theme.dart';

class WordNestApp extends StatefulWidget {
  const WordNestApp({super.key});

  @override
  State<WordNestApp> createState() => _WordNestAppState();
}

class _WordNestAppState extends State<WordNestApp> {
  // Built once: rebuilding the router on every frame would reset navigation.
  final _router = buildRouter();

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
