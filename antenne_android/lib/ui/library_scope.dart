import 'package:flutter/widgets.dart';

import '../core/library.dart';

/// Donne accès à la bibliothèque et reconstruit les écrans quand elle change.
class LibraryScope extends InheritedNotifier<Library> {
  const LibraryScope({super.key, required Library library, required super.child}) : super(notifier: library);

  static Library of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LibraryScope>()!.notifier!;

  /// Sans s'abonner aux changements (dans un gestionnaire d'événement).
  static Library read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
}
