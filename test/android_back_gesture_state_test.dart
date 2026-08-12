import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigator_resizable/src/navigator_event_observer.dart';

import 'src/widget_tester_x.dart';

/// A predictive back gesture can end without ever animating.
///
/// `TransitionRoute.handleStartBackGesture` sets the controller to
/// `1 - progress`, so a gesture that is released without being dragged leaves
/// the controller completed, and `_handleDragEnd` starts no animation at all.
/// The same happens on commit when the route has no transition duration.
///
/// The observer's gesture-end handling has a branch for exactly that case, but
/// it used to return before recording that the gesture was over.
void main() {
  Widget buildApp({
    required GlobalKey<NavigatorState> navigatorKey,
    required List<NavigatorEventListener> listeners,
    Duration transitionDuration = const Duration(milliseconds: 300),
  }) {
    return MaterialApp(
      theme: ThemeData(platform: TargetPlatform.android),
      home: NavigatorEventObserver(
        listeners: listeners,
        child: Navigator(
          key: navigatorKey,
          initialRoute: 'a',
          onGenerateRoute: (settings) => _ObservableRoute(
            settings: settings,
            transitionDuration: transitionDuration,
            // Routes whose name starts with 'swipe' get the iOS style drag to
            // go back instead of the Android predictive back gesture.
            transitionsBuilder: settings.name!.startsWith('swipe')
                ? const CupertinoPageTransitionsBuilder()
                : const PredictiveBackFullscreenPageTransitionsBuilder(),
            builder: (_) => Text('Page:${settings.name}'),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'A gesture released without moving does not leave the observer stuck',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final listener = _RecordingListener();

      await tester.pumpWidget(
        buildApp(navigatorKey: navigatorKey, listeners: [listener]),
      );
      unawaited(navigatorKey.currentState!.pushNamed('b'));
      await tester.pumpAndSettle();

      // Start and release without ever updating the progress, so the route's
      // controller stays completed and nothing animates.
      await tester.startAndroidBackGesture(touchOffset: [5, 300]);
      await tester.pump();
      await tester.cancelAndroidBackGesture();
      await tester.pumpAndSettle();

      expect(find.text('Page:b'), findsOneWidget);

      // Now perform a drag to go back on a route that uses the iOS style
      // gesture. It goes through the navigator's userGestureInProgress
      // notifier, which the observer ignores while it believes an Android
      // back gesture is still running.
      unawaited(navigatorKey.currentState!.pushNamed('swipe'));
      await tester.pumpAndSettle();
      listener.transitionStarts.clear();

      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();

      expect(
        listener.transitionStarts,
        isNotEmpty,
        reason:
            'The observer must still report gesture driven transitions after '
            'an Android back gesture that ended without animating.',
      );

      await gesture.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'A committed gesture that does not animate still settles the route',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final listener = _RecordingListener();

      await tester.pumpWidget(
        buildApp(
          navigatorKey: navigatorKey,
          listeners: [listener],
          // With no transition the pop finishes inline, so the controller is
          // no longer animating by the time the observer is told.
          transitionDuration: Duration.zero,
        ),
      );
      unawaited(navigatorKey.currentState!.pushNamed('b'));
      await tester.pumpAndSettle();
      unawaited(navigatorKey.currentState!.pushNamed('c'));
      await tester.pumpAndSettle();
      expect(find.text('Page:c'), findsOneWidget);

      await tester.startAndroidBackGesture(touchOffset: [5, 300]);
      await tester.pump();
      await tester.commitAndroidBackGesture();
      await tester.pumpAndSettle();
      expect(find.text('Page:b'), findsOneWidget);

      // The observer must now consider 'b' to be the settled route. If it
      // still thinks 'c' is, the next gesture trips its own assertion.
      await tester.startAndroidBackGesture(touchOffset: [5, 300]);
      await tester.pump();

      expect(
        tester.takeException(),
        isNull,
        reason:
            'The route that the gesture settled on must have been recorded, '
            'otherwise the next gesture starts from stale state.',
      );

      await tester.cancelAndroidBackGesture();
      await tester.pumpAndSettle();
    },
  );
}

class _ObservableRoute extends MaterialPageRoute<dynamic>
    with ObservableRouteMixin<dynamic> {
  _ObservableRoute({
    super.settings,
    required this.transitionDuration,
    required this.transitionsBuilder,
    required super.builder,
  });

  @override
  final Duration transitionDuration;

  final PageTransitionsBuilder transitionsBuilder;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return transitionsBuilder.buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

class _RecordingListener with NavigatorEventListener {
  final transitionStarts = <Route<dynamic>>[];

  @override
  void didStartTransition(
    Route<dynamic> targetRoute,
    Animation<double> animation, {
    bool isUserGestureInProgress = false,
  }) {
    transitionStarts.add(targetRoute);
  }
}
