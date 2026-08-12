import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// [NavigatorResizable.interpolationCurve] used to be read once, when the
/// state was created, so passing a different curve later had no effect at all
/// and nothing said so.
void main() {
  testWidgets('interpolationCurve can be changed after the first build', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final navigatorResizableKey = GlobalKey();
    late StateSetter setOuterState;
    Curve curve = const _ConstantCurve(0.25);

    Size boxSize() =>
        (navigatorResizableKey.currentContext!.findRenderObject()! as RenderBox)
            .size;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return NavigatorResizable(
                key: navigatorResizableKey,
                interpolationCurve: curve,
                child: Navigator(
                  key: navigatorKey,
                  initialRoute: 'a',
                  onGenerateRoute: (settings) => ResizablePageRouteBuilder(
                    settings: settings,
                    transitionDuration: const Duration(milliseconds: 300),
                    reverseTransitionDuration: const Duration(
                      milliseconds: 300,
                    ),
                    pageBuilder: (_, _, _) => SizedBox(
                      width: settings.name == 'a' ? 100 : 300,
                      height: settings.name == 'a' ? 200 : 400,
                    ),
                    transitionsBuilder: (_, _, _, child) => child,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(boxSize(), const Size(100, 200));

    // A constant curve makes the size the same on every frame of the
    // transition, which keeps the assertions independent of the exact timing.
    unawaited(navigatorKey.currentState!.pushNamed('b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      boxSize(),
      const Size(150, 250),
      reason: 'Precondition: lerp(100x200, 300x400, 0.25).',
    );

    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(boxSize(), const Size(100, 200));

    // Hand the widget a different curve.
    setOuterState(() => curve = const _ConstantCurve(0.75));
    await tester.pump();

    unawaited(navigatorKey.currentState!.pushNamed('b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
      boxSize(),
      const Size(250, 350),
      reason:
          'The transition must use the curve the widget currently carries, '
          'lerp(100x200, 300x400, 0.75).',
    );

    await tester.pumpAndSettle();
    expect(boxSize(), const Size(300, 400));
  });

  testWidgets('A curve change during a running transition takes effect', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final navigatorResizableKey = GlobalKey();
    late StateSetter setOuterState;
    Curve curve = const _ConstantCurve(0.25);

    Size boxSize() =>
        (navigatorResizableKey.currentContext!.findRenderObject()! as RenderBox)
            .size;

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return NavigatorResizable(
                key: navigatorResizableKey,
                interpolationCurve: curve,
                child: Navigator(
                  key: navigatorKey,
                  initialRoute: 'a',
                  onGenerateRoute: (settings) => ResizablePageRouteBuilder(
                    settings: settings,
                    transitionDuration: const Duration(milliseconds: 300),
                    pageBuilder: (_, _, _) => SizedBox(
                      width: settings.name == 'a' ? 100 : 300,
                      height: settings.name == 'a' ? 200 : 400,
                    ),
                    transitionsBuilder: (_, _, _, child) => child,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    unawaited(navigatorKey.currentState!.pushNamed('b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(boxSize(), const Size(150, 250));

    setOuterState(() => curve = const _ConstantCurve(0.75));
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      boxSize(),
      const Size(250, 350),
      reason: 'The interpolation in flight must pick up the new curve.',
    );

    await tester.pumpAndSettle();
    expect(boxSize(), const Size(300, 400));
  });
}

/// Maps every value strictly between 0 and 1 to [value].
///
/// [Curve.transform] short-circuits the endpoints, so a transition driven by
/// this curve still starts and ends where it should, while every frame in
/// between sits at the same place. That makes the assertions independent of
/// how many milliseconds each pump advances.
class _ConstantCurve extends Curve {
  const _ConstantCurve(this.value);

  final double value;

  @override
  double transformInternal(double t) => value;
}
