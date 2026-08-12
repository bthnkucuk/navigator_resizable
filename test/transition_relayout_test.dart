import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// During a route transition the size is interpolated on every tick, and the
/// notification is what dirties [NavigatorResizable]. When both routes have
/// the same content size the interpolated value never changes, so none of that
/// work can affect what is on screen.
///
/// [NavigatorResizable] is not a relayout boundary, so each of those
/// notifications also lays out and repaints its ancestors up to the nearest
/// boundary.
void main() {
  ({
    GlobalKey<NavigatorState> navigatorKey,
    _LayoutCounter counter,
    ValueGetter<Size> getBoxSize,
    Widget testWidget,
  })
  boilerplate({
    required Map<String, Size> routeSizes,
    Duration transitionDuration = const Duration(milliseconds: 300),
  }) {
    final navigatorKey = GlobalKey<NavigatorState>();
    final navigatorResizableKey = GlobalKey();
    final counter = _LayoutCounter();

    Size getBoxSize() {
      return (navigatorResizableKey.currentContext!.findRenderObject()!
              as RenderBox)
          .size;
    }

    final testWidget = MaterialApp(
      home: Center(
        child: _CountingBox(
          counter: counter,
          child: NavigatorResizable(
            key: navigatorResizableKey,
            child: Navigator(
              key: navigatorKey,
              initialRoute: 'a',
              onGenerateRoute: (settings) {
                final size = routeSizes[settings.name]!;
                return ResizablePageRouteBuilder(
                  settings: settings,
                  transitionDuration: transitionDuration,
                  reverseTransitionDuration: transitionDuration,
                  pageBuilder: (_, _, _) =>
                      SizedBox(width: size.width, height: size.height),
                  transitionsBuilder: (_, _, _, child) => child,
                );
              },
            ),
          ),
        ),
      ),
    );

    return (
      navigatorKey: navigatorKey,
      counter: counter,
      getBoxSize: getBoxSize,
      testWidget: testWidget,
    );
  }

  /// Runs one equal-size transition and returns how often the ancestor was
  /// laid out during the transition frames.
  ///
  /// The frames are pumped one at a time at a realistic interval, rather than
  /// through `pumpAndSettle`, which advances in 100 ms steps and would hide
  /// per-frame work.
  Future<int> countAncestorLayouts(
    WidgetTester tester, {
    required Duration transitionDuration,
    required bool pop,
  }) async {
    final env = boilerplate(
      routeSizes: const {'a': Size(200, 300), 'b': Size(200, 300)},
      transitionDuration: transitionDuration,
    );
    await tester.pumpWidget(env.testWidget);
    await tester.pumpAndSettle();

    if (pop) {
      unawaited(env.navigatorKey.currentState!.pushNamed('b'));
      await tester.pumpAndSettle();
      env.navigatorKey.currentState!.pop();
    } else {
      unawaited(env.navigatorKey.currentState!.pushNamed('b'));
    }
    // The frame that starts the transition legitimately lays out: an overlay
    // entry is added or removed.
    await tester.pump();

    env.counter.reset();
    final frames = transitionDuration.inMilliseconds ~/ 16 + 4;
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();

    expect(
      env.getBoxSize(),
      const Size(200, 300),
      reason: 'Precondition: the size must not change during this transition.',
    );
    expect(env.counter.paints, env.counter.layouts);
    return env.counter.layouts;
  }

  testWidgets('An equal-size push does not relayout the ancestor per frame', (
    tester,
  ) async {
    final short = await countAncestorLayouts(
      tester,
      transitionDuration: const Duration(milliseconds: 300),
      pop: false,
    );
    final long = await countAncestorLayouts(
      tester,
      transitionDuration: const Duration(milliseconds: 900),
      pop: false,
    );

    // The interpolated size never changes, so the work must not scale with the
    // number of transition frames. Before this was fixed the counts were 19
    // and 57, i.e. exactly one relayout and one repaint per frame.
    expect(
      long,
      short,
      reason:
          'A 900 ms transition laid the ancestor out $long times but a 300 ms '
          'one only $short, so the cost scales with the frame count.',
    );
    // One relayout is expected at the frame the transition ends, where the
    // route below stops being painted and the overlay really does change.
    expect(short, lessThanOrEqualTo(1));
  });

  testWidgets('An equal-size pop does not relayout the ancestor per frame', (
    tester,
  ) async {
    final short = await countAncestorLayouts(
      tester,
      transitionDuration: const Duration(milliseconds: 300),
      pop: true,
    );
    final long = await countAncestorLayouts(
      tester,
      transitionDuration: const Duration(milliseconds: 900),
      pop: true,
    );

    expect(long, short);
    expect(short, lessThanOrEqualTo(1));
  });

  testWidgets('A resizing transition still animates every frame', (
    tester,
  ) async {
    final env = boilerplate(
      routeSizes: const {'a': Size(200, 300), 'b': Size(300, 400)},
    );
    await tester.pumpWidget(env.testWidget);
    await tester.pumpAndSettle();

    unawaited(env.navigatorKey.currentState!.pushNamed('b'));
    await tester.pump();

    env.counter.reset();
    final sizes = <Size>[];
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      sizes.add(env.getBoxSize());
    }
    await tester.pumpAndSettle();

    expect(
      env.counter.layouts,
      greaterThan(10),
      reason: 'A genuinely resizing transition must keep laying out.',
    );
    expect(
      sizes.toSet().length,
      greaterThan(10),
      reason: 'The size must actually move on most frames.',
    );
    expect(env.getBoxSize(), const Size(300, 400));
  });
}

class _LayoutCounter {
  int layouts = 0;
  int paints = 0;

  void reset() {
    layouts = 0;
    paints = 0;
  }
}

/// A pass-through box that records how often it is laid out and painted.
///
/// It lays its child out with `parentUsesSize: true` and non-tight
/// constraints, so it is not a relayout boundary and therefore sees every
/// [NavigatorResizable] relayout.
class _CountingBox extends SingleChildRenderObjectWidget {
  const _CountingBox({required this.counter, required Widget super.child});

  final _LayoutCounter counter;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCountingBox(counter);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCountingBox renderObject,
  ) {
    renderObject.counter = counter;
  }
}

class _RenderCountingBox extends RenderProxyBox {
  _RenderCountingBox(this.counter);

  _LayoutCounter counter;

  @override
  void performLayout() {
    counter.layouts++;
    super.performLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    counter.paints++;
    super.paint(context, offset);
  }
}
