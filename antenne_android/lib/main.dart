import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/library.dart';
import 'ui/home_page.dart';
import 'ui/library_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final library = await Library.load(
    directory: await getApplicationSupportDirectory(),
    cacheDirectory: await getApplicationCacheDirectory(),
  );
  runApp(AntenneApp(library: library));
}

class AntenneApp extends StatelessWidget {
  const AntenneApp({super.key, required this.library});
  final Library library;

  static const _orange = Color(0xFFF2552C);
  static const _night = Color(0xFF111A2E);

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: _orange, brightness: Brightness.dark).copyWith(
      primary: const Color(0xFFFF8A4C),
      surface: _night,
      surfaceContainerLowest: const Color(0xFF0C1322),
      surfaceContainerLow: const Color(0xFF16213A),
      surfaceContainer: const Color(0xFF1A2642),
      surfaceContainerHigh: const Color(0xFF203050),
    );
    return LibraryScope(
      library: library,
      child: MaterialApp(
        title: 'Antenne',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: scheme,
          scaffoldBackgroundColor: _night,
          appBarTheme: const AppBarTheme(backgroundColor: _night, scrolledUnderElevation: 0),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: _orange, foregroundColor: Colors.white),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: Color(0xFF203050),
            contentTextStyle: TextStyle(color: Colors.white),
            actionTextColor: Color(0xFFFF8A4C),
            behavior: SnackBarBehavior.floating,
          ),
          listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
        ),
        home: const HomePage(),
      ),
    );
  }
}
