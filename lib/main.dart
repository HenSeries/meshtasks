import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/home.dart';
import 'ui/team.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final app = await AppState.load();
  runApp(MeshTasksApp(app));
}

class MeshTasksApp extends StatelessWidget {
  final AppState app;
  const MeshTasksApp(this.app, {super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFDB4035), brightness: b),
          useMaterial3: true,
          visualDensity: VisualDensity.adaptivePlatformDensity,
        );
    return MaterialApp(
      title: 'MeshTasks',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: app,
        builder: (_, _) => app.hasTeam ? HomePage(app) : OnboardingPage(app),
      ),
    );
  }
}
