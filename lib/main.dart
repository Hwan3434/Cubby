import 'package:flutter/material.dart';

void main() {
  runApp(const CubbyApp());
}

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
      home: const Scaffold(
        body: Center(child: Text('Cubby')),
      ),
    );
  }
}
