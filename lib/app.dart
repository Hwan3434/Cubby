import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/app_preferences.dart';
import 'ui/permission_gate_screen.dart';
import 'ui/theme/cubby_theme.dart';

class CubbyApp extends ConsumerWidget {
  const CubbyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Cubby',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: mode,
      home: const PermissionGateScreen(),
    );
  }
}
