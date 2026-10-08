import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StlWeightApp());
}

class StlWeightApp extends StatelessWidget {
  const StlWeightApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFFFF7A2F);
    return MaterialApp(
      title: 'STL Вага',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
