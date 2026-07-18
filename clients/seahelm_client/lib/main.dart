import 'package:flutter/material.dart';

import 'screens/connect_screen.dart';

void main() {
  runApp(const SeahelmApp());
}

class SeahelmApp extends StatelessWidget {
  const SeahelmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Seahelm',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF0EA5E9),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF0EA5E9),
        brightness: Brightness.dark,
      ),
      home: const ConnectScreen(),
    );
  }
}
