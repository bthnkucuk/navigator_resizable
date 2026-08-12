import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// The inherited widgets that [NavigatorResizable] installs carry a [State]
/// whose identity never changes, so a rebuild of [NavigatorResizable] must not
/// propagate to its dependents. One of those dependents is the nested
/// [Navigator] element itself, which is why an unconditional
/// `updateShouldNotify` used to rebuild the whole route stack.
void main() {
  /// Rebuilds the parent of a [NavigatorResizable] once and counts how many
  /// widgets are rebuilt as a result.
  ///
  /// The child [Navigator] is a single constant instance, so nothing below the
  /// [NavigatorResizable] has a structural reason to rebuild.
  Future<int> countRebuildsOnParentSetState(
    WidgetTester tester, {
    required int routeCount,
  }) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    late StateSetter setOuterState;
    var tick = 0;

    final navigator = Navigator(
      key: navigatorKey,
      onGenerateRoute: (settings) => ResizablePageRouteBuilder(
        settings: settings,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => const SizedBox(width: 100, height: 200),
        transitionsBuilder: (_, _, _, child) => child,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              // `tick` is read so that the closure genuinely depends on it.
              return NavigatorResizable(
                key: ValueKey(tick == -1),
                child: navigator,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (var i = 1; i < routeCount; i++) {
      unawaited(navigatorKey.currentState!.pushNamed('route$i'));
      await tester.pumpAndSettle();
    }

    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) => rebuilds++;
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    setOuterState(() => tick++);
    await tester.pump();

    debugOnRebuildDirtyWidget = null;
    return rebuilds;
  }

  testWidgets('Rebuild fan-out does not scale with the route count', (
    tester,
  ) async {
    final one = await countRebuildsOnParentSetState(tester, routeCount: 1);
    final six = await countRebuildsOnParentSetState(tester, routeCount: 6);

    // The absolute numbers depend on the Flutter version, so assert the
    // invariant instead: rebuilding the parent must cost the same no matter
    // how many routes are on the stack. Before this was fixed the counts were
    // 43 and 143, i.e. about 20 extra widgets per route.
    expect(
      six,
      one,
      reason:
          'Rebuilding the parent of a NavigatorResizable rebuilt $six widgets '
          'with 6 routes but only $one with 1, so the cost grows with the '
          'route stack.',
    );

    // Guard against the invariant being satisfied by a large constant.
    expect(one, lessThan(20));
  });
}
