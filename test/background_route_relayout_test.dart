import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_resizable.dart';
import 'package:navigator_resizable/src/resizable_navigator_routes.dart';

/// Routes below the current one stay in the tree with the default
/// `maintainState: true`, and keep laying out. Their content size cannot
/// affect what [NavigatorResizable] displays, so a change there must not
/// propagate past the route's own boundary.
void main() {
  testWidgets('Resizing a background route does not relayout the ancestor', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final backgroundContentKey = GlobalKey<_ResizableContentState>();
    final counter = _LayoutCounter();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: _CountingBox(
            counter: counter,
            child: NavigatorResizable(
              child: Navigator(
                key: navigatorKey,
                initialRoute: 'a',
                onGenerateRoute: (settings) => ResizablePageRouteBuilder(
                  settings: settings,
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => settings.name == 'a'
                      ? _ResizableContent(
                          key: backgroundContentKey,
                          initialSize: const Size(200, 300),
                        )
                      : const SizedBox(width: 250, height: 350),
                  transitionsBuilder: (_, _, _, child) => child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Cover route 'a' with an opaque route.
    unawaited(navigatorKey.currentState!.pushNamed('b'));
    await tester.pumpAndSettle();

    final box = tester.renderObject<RenderBox>(find.byType(NavigatorResizable));
    expect(box.size, const Size(250, 350));

    // Now resize the content of the route that is no longer visible.
    counter.reset();
    backgroundContentKey.currentState!.size = const Size(120, 140);
    await tester.pump();

    expect(
      box.size,
      const Size(250, 350),
      reason: 'Precondition: the visible size must not change.',
    );
    expect(
      counter.layouts,
      0,
      reason:
          'A background route cannot affect the displayed size, so the '
          'ancestor must not be laid out. It was laid out ${counter.layouts} '
          'times.',
    );
  });
}

class _LayoutCounter {
  int layouts = 0;

  void reset() => layouts = 0;
}

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
