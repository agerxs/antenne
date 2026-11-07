import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'core/library.dart';
import 'ui/device.dart';
import 'ui/home_page.dart';
import 'ui/library_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await detectTelevision();
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
    // Bouton sélectionné à la télécommande ou au clavier : liseré blanc. Rien ne change au toucher.
    BorderSide? focusRing(Set<WidgetState> states, [BorderSide? otherwise]) =>
        states.contains(WidgetState.focused) ? const BorderSide(color: Colors.white, width: 2) : otherwise;
    final ring = ButtonStyle(side: WidgetStateProperty.resolveWith(focusRing));
    final outlinedRing = ButtonStyle(
      side: WidgetStateProperty.resolveWith((states) => focusRing(
          states,
          BorderSide(
              color: states.contains(WidgetState.disabled) ? scheme.onSurface.withValues(alpha: 0.12) : scheme.outline))),
    );
    return LibraryScope(
      library: library,
      child: MaterialApp(
        title: 'Antenne',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: scheme,
          scaffoldBackgroundColor: _night,
          // Sur un téléviseur, la ligne sélectionnée à la télécommande doit se voir depuis le canapé.
          focusColor: const Color(0x55FF8A4C),
          appBarTheme: const AppBarTheme(backgroundColor: _night, scrolledUnderElevation: 0),
          floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: _orange, foregroundColor: Colors.white, focusColor: Colors.white38),
          filledButtonTheme: FilledButtonThemeData(style: ring),
          textButtonTheme: TextButtonThemeData(style: ring),
          iconButtonTheme: IconButtonThemeData(style: ring),
          outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedRing),
          segmentedButtonTheme: SegmentedButtonThemeData(style: outlinedRing),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: Color(0xFF203050),
            contentTextStyle: TextStyle(color: Colors.white),
            actionTextColor: Color(0xFFFF8A4C),
            behavior: SnackBarBehavior.floating,
          ),
          listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
        ),
        home: const HomePage(),
        // À la télécommande, haut et bas passent d'un champ de saisie au suivant au lieu d'y rester bloqués.
        builder: (context, child) => isTelevision
            ? Shortcuts(shortcuts: const {
                SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up, ignoreTextFields: false),
                SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down, ignoreTextFields: false),
              }, child: child!)
            : child!,
      ),
    );
  }
}
