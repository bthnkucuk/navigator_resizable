import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

void main() {
  group('Outgoing route resizing during a transition', () {
    // Both ends of the interpolation must be read when they are needed. The
    // end is looked up lazily on every tick, but the start used to be a
    // snapshot taken when the transition began, so a content size change in
    // the route being left behind was ignored for the whole transition and
    // only appeared when it ended.
    testWidgets('is reflected while the transition is still running', (
      tester,
    ) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final navigatorResizableKey = GlobalKey();
      final routeAContentKey = GlobalKey<_ResizableContentState>();

      Size boxSize() =>
          (navigatorResizableKey.currentContext!.findRenderObject()!
                  as RenderBox)
              .size;

      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: NavigatorResizable(
              key: navigatorResizableKey,
              interpolationCurve: Curves.linear,
              child: Navigator(
                key: navigatorKey,
                initialRoute: 'a',
                onGenerateRoute: (settings) => ResizablePageRouteBuilder(
                  settings: settings,
                  transitionDuration: const Duration(milliseconds: 300),
                  reverseTransitionDuration: const Duration(milliseconds: 300),
                  pageBuilder: (_, _, _) => settings.name == 'a'
                      ? _ResizableContent(
                          key: routeAContentKey,
                          initialSize: const Size(100, 200),
                        )
                      : const SizedBox(width: 300, height: 400),
                  transitionsBuilder: (_, _, _, child) => child,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(boxSize(), const Size(100, 200));

      unawaited(navigatorKey.currentState!.pushNamed('b'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      // Halfway through a linear interpolation from 100x200 to 300x400.
      expect(boxSize(), const Size(200, 300));

      // Shrink the content of the route that is being left behind.
      routeAContentKey.currentState!.size = const Size(50, 60);
      await tester.pump(const Duration(milliseconds: 30));

      // At t = 0.6 the interpolation now runs from 50x60 to 300x400.
      expect(
        boxSize(),
        const Size(200, 264),
        reason:
            'The start of the interpolation must track the outgoing route, '
            'not a snapshot taken when the transition began.',
      );

      await tester.pumpAndSettle();
      expect(boxSize(), const Size(300, 400));
    });
  });

  group('Starting a gesture driven transition', () {
    // AnimationController.value notifies its listeners before it reports the
    // status change, so the status listener that installs the interpolation
    // runs after the notification it should have reacted to. Installing an
    // interpolation changes what the notifier reports, so it has to say so;
    // otherwise the render box is only laid out because something unrelated
    // in the route subtree happens to dirty it in the same frame.
    testWidgets(
      'marks the render box as needing layout',
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        final navigatorResizableKey = GlobalKey();

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: NavigatorResizable(
                key: navigatorResizableKey,
                interpolationCurve: Curves.linear,
                child: Navigator(
                  key: navigatorKey,
                  initialRoute: 'a',
                  onGenerateRoute: (settings) => ResizableMaterialPageRoute(
                    settings: settings,
                    builder: (_) => SizedBox(
                      width: settings.name == 'a' ? 100 : 200,
                      height: settings.name == 'a' ? 200 : 300,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        unawaited(navigatorKey.currentState!.pushNamed('b'));
        await tester.pumpAndSettle();

        final renderBox =
            navigatorResizableKey.currentContext!.findRenderObject()!
                as RenderBox;
        expect(renderBox.debugNeedsLayout, isFalse);

        // Start the swipe back gesture and move it, without pumping a frame
        // in between: at this point the interpolation has been installed and
        // the size it reports has already changed.
        final gesture = await tester.startGesture(const Offset(300, 300));
        await gesture.moveBy(const Offset(80, 0));

        expect(
          renderBox.debugNeedsLayout,
          isTrue,
          reason:
              'Installing the interpolation changed the preferred size, so '
              'the render box must have been marked as needing layout.',
        );

        await gesture.up();
        await tester.pumpAndSettle();
      },
    );
  });
}

class _ResizableContent extends StatefulWidget {
  const _ResizableContent({super.key, required this.initialSize});

  final Size initialSize;

  @override
  State<_ResizableContent> createState() => _ResizableContentState();
}

class _ResizableContentState extends State<_ResizableContent> {
  late Size _size = widget.initialSize;

  Size get size => _size;
  set size(Size value) => setState(() => _size = value);

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: _size.width, height: _size.height);
  }
}
