import 'package:flutter/material.dart';

import 'ui/permission_gate_screen.dart';

class CubbyApp extends StatelessWidget {
  const CubbyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cubby',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const PermissionGateScreen(),
    );
  }
}
