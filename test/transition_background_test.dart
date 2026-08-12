import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// On Android the package replaces the default page transition with
/// [FadeForwardsPageTransitionsBuilder]. That builder paints a backdrop behind
/// the outgoing route for the duration of the transition, defaulting to
/// [ColorScheme.surface].
///
/// In a full screen navigator the backdrop is invisible. This navigator is
/// clipped to the size of the current route content, so the backdrop shows up
/// as an opaque rectangle filling the gap between two differently sized
/// routes, for exactly as long as the transition runs.
void main() {
  const routeColor = Color(0xFF2196F3);

  testWidgets(
    'The Android page transition paints no backdrop of its own',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Center(
            child: NavigatorResizable(
              child: Navigator(
                key: navigatorKey,
                onGenerateRoute: (settings) => ResizableMaterialPageRoute(
                  settings: settings,
                  builder: (_) => Container(
                    width: settings.name == 'b' ? 300 : 200,
                    height: settings.name == 'b' ? 300 : 200,
                    color: routeColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      unawaited(navigatorKey.currentState!.pushNamed('b'));
      await tester.pump();

      // Sample across the whole transition rather than a single instant: the
      // backdrop is only opaque while the secondary animation is running.
      final unexpected = <Color>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final box in tester.widgetList<ColoredBox>(
          find.byType(ColoredBox),
        )) {
          if (box.color.a != 0 &&
              box.color.toARGB32() != routeColor.toARGB32()) {
            unexpected.add(box.color);
          }
        }
      }
      await tester.pumpAndSettle();

      expect(
        unexpected,
        isEmpty,
        reason:
            'Only the route contents may paint an opaque box during the '
            'transition, but these were painted as well: '
            '${unexpected.toSet()}',
      );
    },
  );
}
