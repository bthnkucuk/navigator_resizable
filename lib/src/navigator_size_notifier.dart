import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'navigator_event_observer.dart';
import 'navigator_resizable.dart';

const _defaultPreferredSize = Size.infinite;

@internal
class NavigatorSizeNotifier extends ChangeNotifier
    with NavigatorEventListener
    implements ValueListenable<Size> {
  NavigatorSizeNotifier({
    required this.interpolationCurve,
  });

  final _routeContentSizes = <Route<dynamic>, Size>{};
  final Curve interpolationCurve;
  Animation<Size?>? _interpolation;
  Route<dynamic>? _currentRoute;

  void _updateInterpolation(Animation<Size?>? newValue) {
    _interpolation?.removeListener(_notifyIfChanged);
    _interpolation = newValue?..addListener(_notifyIfChanged);
    if (newValue != null) {
      _currentRoute = null;
    }
    // Swapping the interpolation changes what [value] reports, so say so.
    //
    // This matters when a gesture drives the transition: an
    // AnimationController notifies its listeners from the value setter before
    // it reports the status change, so the status listener that installs this
    // interpolation runs after the notification it should have reacted to.
    // Without this the render box is only laid out because something
    // unrelated in the route subtree happens to dirty it in the same frame.
    _notifyIfChanged();
  }

  void _updateCurrentRoute(Route<dynamic>? newRoute) {
    _currentRoute = newRoute;
    if (newRoute != null) {
      _updateInterpolation(null);
    }
    _notifyIfChanged();
  }

  Size? _lastNotifiedValue;

  /// Notifies the listeners only when [value] actually changed since the last
  /// notification.
  ///
  /// The interpolation ticks on every frame of a route transition, but the
  /// interpolated size only moves when the two routes have different content
  /// sizes. Since [NavigatorResizable] is not a relayout boundary, notifying
  /// unconditionally would lay out and repaint it and its ancestors on every
  /// frame of a transition that cannot change anything on screen. The package
  /// documentation recommends sizing route content with `double.infinity`, so
  /// equal-size transitions are a common case rather than an exotic one.
  ///
  /// Comparing against the last *notified* value rather than the value at the
  /// start of the current call also means the listeners can never drift away
  /// from the real size.
  void _notifyIfChanged() {
    final newValue = value;
    if (newValue != _lastNotifiedValue) {
      _lastNotifiedValue = newValue;
      notifyListeners();
    }
  }

  Size? _lastReportedValidValue;

  /// The size that the navigator prefers to be.
  @override
  Size get value {
    final effectiveValue =
        _interpolation?.value ?? _routeContentSizes[_currentRoute];
    if (effectiveValue != null && effectiveValue.isFinite) {
      _lastReportedValidValue = effectiveValue;
      return effectiveValue;
    }
    return _lastReportedValidValue ?? _defaultPreferredSize;
  }

  /// Whether a change to [route]'s content size can change [value].
  ///
  /// While a transition is running, either of the two routes can be an
  /// endpoint of the interpolation, so nothing is ruled out. Once settled,
  /// only the current route contributes; the ones below it are still mounted
  /// with the default `maintainState: true` and keep laying out, but they
  /// cannot affect what is displayed.
  bool affectsPreferredSize(Route<dynamic> route) {
    if (_interpolation != null || _currentRoute == null) {
      return true;
    }
    return route == _currentRoute;
  }

  @override
  void dispose() {
    _updateInterpolation(null);
    _updateCurrentRoute(null);
    super.dispose();
  }

  /// Called by [ResizableNavigatorRouteContentBoundary] when the size of
  /// its child widget changes.
  void didRouteContentSizeChange(Route<dynamic> route, Size contentSize) {
    assert(_routeContentSizes.containsKey(route));
    _routeContentSizes[route] = contentSize;
    _notifyIfChanged();
  }

  @override
  VoidCallback? didInstall(Route<dynamic> route) {
    assert(!_routeContentSizes.containsKey(route));
    _routeContentSizes[route] = _defaultPreferredSize;

    void onDispose() {
      assert(_routeContentSizes.containsKey(route));
      _routeContentSizes.remove(route);
      if (route == _currentRoute) {
        _updateCurrentRoute(null);
      }
    }

    return onDispose;
  }

  @override
  void didStartTransition(
    Route<dynamic> targetRoute,
    Animation<double> animation, {
    bool isUserGestureInProgress = false,
  }) {
    assert(_routeContentSizes.containsKey(targetRoute));
    if (isUserGestureInProgress) {
      _startUserGestureTransition(targetRoute, animation);
    } else if (animation.status == AnimationStatus.forward) {
      _startPushTransition(targetRoute, animation);
    } else {
      assert(animation.status == AnimationStatus.reverse);
      _startPopTransition(targetRoute, animation);
    }
  }

  /// Reads the content size of the route that is being left behind.
  ///
  /// The route is looked up on every tick rather than captured, so that a
  /// content size change there is picked up while the transition is still
  /// running, exactly as the other end of the interpolation already is.
  ///
  /// Falls back to [fallback], the size that was displayed when the transition
  /// started, when there is no settled route to read, which happens when a
  /// transition starts while another one is still in flight, or when that
  /// route has not been measured yet.
  ///
  /// Must be called before [_updateInterpolation], which clears the current
  /// route.
  ValueGetter<Size?> _outgoingSize(Size fallback) {
    final outgoingRoute = _currentRoute;
    return () {
      final size = _routeContentSizes[outgoingRoute];
      return size != null && size.isFinite ? size : fallback;
    };
  }

  void _startUserGestureTransition(
    Route<dynamic> targetRoute,
    Animation<double> animation,
  ) {
    assert(animation.isForwardOrCompleted);
    _updateInterpolation(
      _LazySizeTween(
        start: () => _routeContentSizes[targetRoute],
        end: _outgoingSize(_lastReportedValidValue!),
      ).animate(animation),
    );
  }

  void _startPushTransition(
    Route<dynamic> targetRoute,
    Animation<double> animation,
  ) {
    assert(animation.isForwardOrCompleted);
    _updateInterpolation(
      _LazySizeTween(
        start: _outgoingSize(_lastReportedValidValue!),
        end: () => _routeContentSizes[targetRoute],
      ).chain(CurveTween(curve: interpolationCurve)).animate(animation),
    );
  }

  void _startPopTransition(
    Route<dynamic> targetRoute,
    Animation<double> animation,
  ) {
    assert(!animation.isForwardOrCompleted);
    final initialSize = _lastReportedValidValue!;
    if (animation.value == 1) {
      _updateInterpolation(
        _LazySizeTween(
          start: () => _routeContentSizes[targetRoute],
          end: _outgoingSize(initialSize),
        ).chain(CurveTween(curve: interpolationCurve)).animate(animation),
      );
    } else {
      // In this case, a pop transition has started in the middle of
      // another transition. This can happen, for example, when a route
      // is popped immediately after being pushed.
      // To avoid layout shifts, we start a linear size transition
      // from a synthetic start size to the `targetRoute`'s size,
      // where the synthetic start size is calculated by _lerpEndSize.
      // This transition is such that the size equals the `initialSize`
      // at `animation.value == initialAnimationProgress`, and it eventually
      // reaches the `targetRoute`'s size at `animation.value == 1`.
      final initialAnimationProgress = animation.value;
      _updateInterpolation(
        _LazySizeTween(
          start: () => _routeContentSizes[targetRoute],
          end: () => _lerpEndSize(
            _routeContentSizes[targetRoute]!,
            initialSize,
            initialAnimationProgress,
          ),
        ).animate(animation),
      );
    }
  }

  @override
  void didEndTransition(Route<dynamic> route) {
    assert(_routeContentSizes.containsKey(route));
    _updateCurrentRoute(route);
  }
}

class _LazySizeTween extends Animatable<Size?> {
  _LazySizeTween({
    required this.start,
    required this.end,
  });

  final ValueGetter<Size?> start;
  final ValueGetter<Size?> end;

  @override
  Size? transform(double t) {
    final start = this.start();
    if (start?.isFinite != true) {
      return null;
    }
    final end = this.end();
    if (end?.isFinite != true) {
      return null;
    }
    return Size.lerp(start, end, t);
  }
}

/// Returns `se` that satisfies the equation `st = (1 - t) * se + t * ss`,
/// where [ss] is the start size and [st] is the interpolated size at time [t].
Size _lerpEndSize(Size ss, Size st, double t) {
  assert(0 < t && t <= 1);
  return Size(
    (st.width - (1 - t) * ss.width) / t,
    (st.height - (1 - t) * ss.height) / t,
  );
}
