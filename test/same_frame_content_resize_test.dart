import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// Regression tests for the one frame delay that used to occur whenever the
/// content of a *settled* route changed its size.
///
/// The Overlay lays out every route with a tight constraint, which makes each
/// route subtree a relayout boundary. A content size change therefore never
/// reaches the ancestor [NavigatorResizable] through the layout tree walk, and
/// the size used to be applied only in the following frame. These tests pin
/// down that it is now applied within the very same frame.
void main() {
  group('Same frame content resize test', () {
    ({
      GlobalKey<NavigatorState> navigatorKey,
      GlobalKey<_ResizableContentState> contentKey,
      ValueGetter<Size> getBoxSize,
      Widget testWidget,
    })
    boilerplate({Size initialContentSize = const Size(100, 200)}) {
      final navigatorResizableKey = GlobalKey();
      final navigatorKey = GlobalKey<NavigatorState>();
      final contentKey = GlobalKey<_ResizableContentState>();

      Size getBoxSize() {
        return (navigatorResizableKey.currentContext!.findRenderObject()!
                as RenderBox)
            .size;
      }

      final testWidget = MaterialApp(
        home: Center(
          child: NavigatorResizable(
            key: navigatorResizableKey,
            child: Navigator(
              key: navigatorKey,
              onGenerateInitialRoutes: (navigator, initialRoute) {
                return [
                  ResizablePageRouteBuilder(
                    settings: const RouteSettings(name: 'a'),
                    pageBuilder: (_, _, _) => _ResizableContent(
                      key: contentKey,
                      initialSize: initialContentSize,
                    ),
                    transitionsBuilder: (_, _, _, child) => child,
                  ),
                ];
              },
            ),
          ),
        ),
      );

      return (
        navigatorKey: navigatorKey,
        contentKey: contentKey,
        getBoxSize: getBoxSize,
        testWidget: testWidget,
      );
    }

    testWidgets(
      'Growing the content of the initial route takes a single frame',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();
        expect(env.getBoxSize(), const Size(100, 200));

        env.contentKey.currentState!.size = const Size(200, 300);
        await tester.pump();
        expect(
          env.getBoxSize(),
          const Size(200, 300),
          reason:
              'The new content size must be applied in the same frame '
              'in which the content was rebuilt.',
        );
      },
    );

    testWidgets(
      'Shrinking the content of the initial route takes a single frame',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();
        expect(env.getBoxSize(), const Size(100, 200));

        env.contentKey.currentState!.size = const Size(50, 100);
        await tester.pump();
        expect(env.getBoxSize(), const Size(50, 100));
      },
    );

    testWidgets(
      'No additional frame is scheduled for a content resize',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();
        expect(
          tester.binding.hasScheduledFrame,
          isFalse,
          reason: 'Precondition: the tree must be idle.',
        );

        env.contentKey.currentState!.size = const Size(200, 300);
        await tester.pump();

        expect(env.getBoxSize(), const Size(200, 300));
        expect(
          tester.binding.hasScheduledFrame,
          isFalse,
          reason: 'The resize must not defer any work to a following frame.',
        );
      },
    );

    testWidgets(
      'Consecutive content resizes each take a single frame',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();

        const sizes = [
          Size(200, 300),
          Size(150, 120),
          Size(320, 240),
          Size(100, 200),
        ];
        for (final size in sizes) {
          env.contentKey.currentState!.size = size;
          await tester.pump();
          expect(env.getBoxSize(), size, reason: 'Resizing to $size');
        }
      },
    );

    testWidgets(
      'Resizing the content of a pushed route takes a single frame',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();

        final pushedContentKey = GlobalKey<_ResizableContentState>();
        unawaited(
          env.navigatorKey.currentState!.push(
            ResizablePageRouteBuilder<void>(
              settings: const RouteSettings(name: 'b'),
              pageBuilder: (_, _, _) => _ResizableContent(
                key: pushedContentKey,
                initialSize: const Size(300, 400),
              ),
              transitionsBuilder: (_, _, _, child) => child,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(env.getBoxSize(), const Size(300, 400));

        pushedContentKey.currentState!.size = const Size(180, 260);
        await tester.pump();
        expect(env.getBoxSize(), const Size(180, 260));

        // The route below is still mounted; resizing the top route must keep
        // working after it has been laid out several times.
        pushedContentKey.currentState!.size = const Size(240, 130);
        await tester.pump();
        expect(env.getBoxSize(), const Size(240, 130));
      },
    );

    testWidgets(
      'Content resize is applied in a single frame after popping back',
      (tester) async {
        final env = boilerplate();
        await tester.pumpWidget(env.testWidget);
        await tester.pumpAndSettle();

        unawaited(
          env.navigatorKey.currentState!.push(
            ResizablePageRouteBuilder<void>(
              settings: const RouteSettings(name: 'b'),
              pageBuilder: (_, _, _) => const SizedBox(width: 300, height: 400),
              transitionsBuilder: (_, _, _, child) => child,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(env.getBoxSize(), const Size(300, 400));

        env.navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(env.getBoxSize(), const Size(100, 200));

        env.contentKey.currentState!.size = const Size(220, 140);
        await tester.pump();
        expect(env.getBoxSize(), const Size(220, 140));
      },
    );

    testWidgets(
      'Content that builds during layout resizes without an assertion error',
      (tester) async {
        final navigatorResizableKey = GlobalKey();
        final contentKey = GlobalKey<_ResizableContentState>();

        Size getBoxSize() {
          return (navigatorResizableKey.currentContext!.findRenderObject()!
                  as RenderBox)
              .size;
        }

        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: NavigatorResizable(
                key: navigatorResizableKey,
                child: Navigator(
                  onGenerateInitialRoutes: (navigator, initialRoute) {
                    return [
                      ResizablePageRouteBuilder(
                        settings: const RouteSettings(name: 'a'),
                        // A LayoutBuilder runs its builder during the layout
                        // phase, which is the code path that cannot dirty the
                        // NavigatorResizable directly.
                        pageBuilder: (_, _, _) => LayoutBuilder(
                          builder: (context, constraints) => _ResizableContent(
                            key: contentKey,
                            initialSize: const Size(100, 200),
                          ),
                        ),
                        transitionsBuilder: (_, _, _, child) => child,
                      ),
                    ];
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(getBoxSize(), const Size(100, 200));

        contentKey.currentState!.size = const Size(200, 300);
        await tester.pumpAndSettle();
        expect(getBoxSize(), const Size(200, 300));
        expect(tester.takeException(), isNull);
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
  late Size _size;

  Size get size => _size;
  set size(Size value) => setState(() => _size = value);

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      width: _size.width,
      height: _size.height,
    );
  }
}
