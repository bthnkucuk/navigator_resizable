import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' as p;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'navigator_event_observer.dart';
import 'navigator_size_notifier.dart';
import 'resizable_navigator_routes.dart';

/// A thin wrapper around [Navigator] that **visually** resizes the [child]
/// navigator to match the size of the content displayed in the current route.
///
/// This widget is functionally similar to combining [OverflowBox] and
/// [ClipRect], but it is specifically designed for this use case.
/// It adjusts its size, hit test area, and painting area to align
/// with the size of the widget displayed by the [child] navigator's
/// current route. The navigator itself can overflow this widget,
/// maintaining its size as determined by the parent constraints
/// unless those constraints change. This helps minimize unnecessary
/// layout operations for the navigator and its routes.
///
/// ### Routes and Pages
///
/// The [NavigatorResizable] can respect the content size of a route
/// only if the route mix-ins the [ObservableRouteMixin] and its content
/// is wrapped in a [ResizableNavigatorRouteContentBoundary].
/// This is especially important during route transitions, as the
/// [NavigatorResizable] can animate its size in sync with the transition
/// animation only when both the current route and the next route satisfy
/// these requirements. Otherwise, the size remains unchanged before
/// and after the transition.
///
/// For convenience, the following built-in route and page classes are provided,
/// all of which satisfy the requirements of [NavigatorResizable]:
///
/// - [ResizableMaterialPageRoute]: A replacement for [MaterialPageRoute].
/// - [ResizableMaterialPage]: A replacement for [MaterialPage].
/// - [ResizablePageRouteBuilder]: A replacement for [PageRouteBuilder].
/// - [ResizablePageRoutePageBuilder]: Similar to [ResizablePageRouteBuilder],
///   but creates a [Page].
///
/// Note that the [child] navigator and its routes are constrained by the
/// constraints imposed by the parent widget of the [NavigatorResizable].
/// To ensure that the route content fills the entire available space,
/// the easiest way is to set the content widget's width or height
/// to [double.infinity].
///
/// ```dart
/// ResizableMaterialPageRoute(
///   builder: (context) {
///     return Container(
///       color: Colors.while,
///       width: double.infinity,
///       height: double.infinity,
///     );
///   },
/// );
/// ```
///
/// For more advanced use cases, you can create a custom route
/// compatible with [NavigatorResizable] by mixing in
/// the [ObservableRouteMixin] and returning a
/// [ResizableNavigatorRouteContentBoundary] in [ModalRoute.buildPage].
///
/// ```dart
/// class CustomResizableRoute<T> extends ModalRoute<T>
///   with ObservableRouteMixin<T>{
///   CustomResizableRoute({
///     required super.builder,
///     ...
///   });
///
///   @override
///   Widget buildContent(BuildContext context) {
///     return ResizableNavigatorRouteContentBoundary(
///       child: builder(context),
///     );
///   }
/// }
/// ```
///
/// ### Caveats
/// - Avoid wrapping the navigator in widgets that add additional space
///   (e.g., [Padding]). Zero-size widgets, such as [GestureDetector]
///   or [InheritedWidget], are acceptable.
/// - Do not place [NavigatorResizable] inside a widget with a tight constraint,
///   as this forces [NavigatorResizable] to ignore the size of the current
///   route's content and adopt the size dictated by the constraints.
///   In such cases, an assertion error will be thrown. Typically, [Center]
///   and [Align] are good choices for the parent widget.
/// - The initial route of the [child] navigator must satisfy the requirements
///   of [NavigatorResizable]. Otherwise, [NavigatorResizable] will be unable
///   to determine the initial size and will throw an assertion error.
///
/// ### Example
///
/// The following example demonstrates a resizable window centered within
/// a [Scaffold] that can display multiple pages:
///
/// ```dart
/// Navigator nestedNavigator;
/// return Scaffold(
///   body: Center(
///     child: Material(
///       color: Colors.white,
///       child: NavigatorResizable(
///         child: nestedNavigator,
///       ),
///     ),
///   ),
/// );
/// ```
/// You can use any standard navigation methods, such as [Navigator.push],
/// [Navigator.pop], [named routes][1],
/// and the [Pages API][2],
/// with [NavigatorResizable] as you would with a regular [Navigator]:
///
/// ```dart
/// Navigator.push(
///   context,
///   ResizableMaterialPageRoute(
///     builder: (context) {
///       return Container(
///         color: Colors.red,
///         width: 300,
///         height: 300,
///       );
///     },
///   ),
/// );
/// ```
///
/// For more practical examples, refer to the [/example][3] directory.
///
/// [1]: https://api.flutter.dev/flutter/widgets/Navigator-class.html#:~:text=Using%20named%20navigator%20routes
/// [2]: https://api.flutter.dev/flutter/widgets/Navigator-class.html#:~:text=the%20current%20page.-,Using%20the%20Pages%20API,-The%20Navigator%20will
/// [3]: https://github.com/fujidaiti/navigator_resizable/tree/main/example/lib
class NavigatorResizable extends StatefulWidget {
  /// Creates a thin wrapper around [Navigator] that **visually** resizes
  /// the [child] navigator to match the size of the content displayed
  /// in the current route.
  const NavigatorResizable({
    super.key,
    this.interpolationCurve = Curves.easeInOutCubic,
    required this.child,
  });

  /// The [Curve] used for interpolating the size of this widget
  /// during a route transition animation.
  ///
  /// This widget gradually changes its size during a route transition,
  /// interpolating between the sizes of the previous and the next route
  /// with this curve. The default value is [Curves.easeInOutCubic].
  final Curve interpolationCurve;

  /// The [Navigator] for which the visual resizing should be applied.
  final Widget child;

  @override
  State<NavigatorResizable> createState() => _NavigatorResizableState();
}

class _NavigatorResizableState extends State<NavigatorResizable> {
  late final NavigatorSizeNotifier _preferredSizeNotifier;

  /// The render box created by [_RenderNavigatorResizableWidget], if any.
  _RenderNavigatorResizable? renderNavigatorResizable;

  /// The route content boundaries whose content still has to be measured.
  ///
  /// The [Overlay] lays out each route with a tight constraint, which makes
  /// every route subtree a relayout boundary (see [RenderObject.layout]).
  /// As a result, a content size change never propagates up to
  /// [_RenderNavigatorResizable] through the layout tree walk. Instead,
  /// [_RenderNavigatorResizable] drains this set from within its own
  /// `performLayout`, so that the new content size is available in the same
  /// frame in which it was reported.
  ///
  /// Membership doubles as the "needs to be measured" flag of a boundary:
  /// entries are added by [_RenderRouteContentBoundary.markNeedsLayout] and
  /// removed as soon as the boundary is laid out, no matter which of the two
  /// code paths got it there.
  final pendingMeasurements = <_RenderRouteContentBoundary>{};

  @override
  void initState() {
    super.initState();
    _preferredSizeNotifier = NavigatorSizeNotifier(
      interpolationCurve: widget.interpolationCurve,
    );
  }

  @override
  void didUpdateWidget(NavigatorResizable oldWidget) {
    super.didUpdateWidget(oldWidget);
    _preferredSizeNotifier.interpolationCurve = widget.interpolationCurve;
  }

  @override
  void dispose() {
    _preferredSizeNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NavigatorEventObserver(
      listeners: [_preferredSizeNotifier],
      child: _InheritedNavigatorResizable(
        state: this,
        child: _RenderNavigatorResizableWidget(
          state: this,
          preferredSize: _preferredSizeNotifier,
          child: widget.child,
        ),
      ),
    );
  }

  /// Remembers that [boundary] has to be measured, and makes sure the
  /// [_RenderNavigatorResizable] is laid out in this frame so that it can.
  void scheduleMeasurement(_RenderRouteContentBoundary boundary) {
    pendingMeasurements.add(boundary);
    // A route below the current one cannot change the size this widget
    // displays, so laying out again would be pure waste. Its new content size
    // still has to be recorded, and it will be: the Overlay makes every
    // boundary a relayout boundary, so the pipeline lays it out on its own and
    // `performLayout` reports the size and dequeues it.
    if (_preferredSizeNotifier.affectsPreferredSize(boundary.route)) {
      renderNavigatorResizable?.requestRelayout();
    }
  }

  void didRouteContentSizeChange(ModalRoute<dynamic> route, Size contentSize) {
    _preferredSizeNotifier.didRouteContentSizeChange(route, contentSize);
  }

  static _NavigatorResizableState of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_InheritedNavigatorResizable>()!
        .state;
  }
}

/// Provides a direct access to the state of the ancestor [NavigatorResizable]
/// for the descendant [ResizableNavigatorRouteContentBoundary] widgets.
class _InheritedNavigatorResizable extends InheritedWidget {
  const _InheritedNavigatorResizable({
    required this.state,
    required super.child,
  });

  final _NavigatorResizableState state;

  // The state object is created once per element and never replaced, so
  // dependents can never observe a different value. Notifying them would
  // rebuild every route content boundary for nothing. Everything that does
  // change is delivered through the preferred size listenable instead.
  @override
  bool updateShouldNotify(_InheritedNavigatorResizable oldWidget) =>
      state != oldWidget.state;
}

class _RenderNavigatorResizableWidget extends SingleChildRenderObjectWidget {
  const _RenderNavigatorResizableWidget({
    required this.state,
    required this.preferredSize,
    required super.child,
  });

  final _NavigatorResizableState state;
  final ValueListenable<Size> preferredSize;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderNavigatorResizable(
      state: state,
      preferredSize: preferredSize,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNavigatorResizable renderObject,
  ) {
    renderObject.preferredSize = preferredSize;
  }
}

class _RenderNavigatorResizable extends RenderAligningShiftedBox {
  _RenderNavigatorResizable({
    required _NavigatorResizableState state,
    required ValueListenable<Size> preferredSize,
  }) : _state = state,
       _preferredSize = preferredSize,
       super(
         alignment: Alignment.topLeft,
         textDirection: null,
       ) {
    state.renderNavigatorResizable = this;
    preferredSize.addListener(_onPreferredSizeChanged);
  }

  final _NavigatorResizableState _state;

  @override
  bool get sizedByParent => false;

  /// The visible area of the descendant Navigator.
  ///
  /// Used in [paint] and [hitTest].
  /// The size of this rect should be kept in sync with the value of
  /// [_preferredSize] and the offset should be always [Offset.zero].
  late Rect _visibleBounds;

  ValueListenable<Size> _preferredSize;
  // ignore: avoid_setters_without_getters
  set preferredSize(ValueListenable<Size> value) {
    if (value != _preferredSize) {
      _preferredSize.removeListener(_onPreferredSizeChanged);
      _preferredSize = value..addListener(_onPreferredSizeChanged);
    }
  }

  void _onPreferredSizeChanged() => requestRelayout();

  /// Whether [performLayout] is currently measuring the route contents.
  ///
  /// While this is true, this render box is inside its own
  /// [RenderObject.invokeLayoutCallback] window and has not computed its
  /// [size] yet, so any content size reported during that window is picked
  /// up by the very same layout pass.
  bool _measuring = false;

  /// Marks this render box as needing layout because the preferred size may
  /// have changed.
  ///
  /// Safe to call from any scheduler phase.
  void requestRelayout() {
    if (_measuring) {
      // We are inside our own invokeLayoutCallback window. The new content
      // size is folded into `size` before performLayout returns, so there is
      // nothing left to schedule. Calling markNeedsLayout here would be a
      // no-op anyway: RenderObject.markParentNeedsLayout does not notify the
      // parent while a layout callback is running.
      return;
    }

    // [RenderObject.markNeedsLayout] asserts that no unrelated render subtree
    // is actively performing layout. That holds in the common case, where the
    // route content is dirtied during the build phase, but not when it is
    // dirtied from within some other render object's performLayout, e.g. by a
    // LayoutBuilder inside the route content.
    //
    // In release builds, marking ourselves dirty is safe even then, because
    // [PipelineOwner.flushLayout] keeps draining its dirty list and therefore
    // lays out nodes dirtied mid-pass in the same frame. Only the debug assert
    // needs to be avoided, so this deliberately falls back to the next frame in
    // debug builds only.
    var mayMarkNeedsLayoutNow = true;
    assert(() {
      mayMarkNeedsLayoutNow = !(owner?.debugDoingLayout ?? false);
      return true;
    }());

    if (mayMarkNeedsLayoutNow) {
      markNeedsLayout();
    } else {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        if (!_disposed) markNeedsLayout();
      });
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    assert(!_disposed);
    _preferredSize.removeListener(_onPreferredSizeChanged);
    if (_state.renderNavigatorResizable == this) {
      _state.renderNavigatorResizable = null;
    }
    _disposed = true;
    super.dispose();
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    return constraints.constrain(_preferredSize.value);
  }

  @override
  void performLayout() {
    assert(child != null);
    assert(
      !constraints.isTight,
      'The NavigatorResizable widget was given an tight constraint. '
      'This is not allowed because it needs to size itself to fit '
      'the current route content. Consider wrapping the NavigatorResizable '
      'with a widget that provides non-tight constraints, such as Align '
      'and Center. \n'
      'The given constraints were: $constraints which was given by '
      'the parent: ${parent.runtimeType}',
    );
    assert(
      constraints.hasBoundedHeight && constraints.hasBoundedWidth,
      'The NavigatorResizable widget was given unbounded constraints. '
      'This is not allowed because otherwise the routes within the underlying '
      'Navigator would not know their valid maximum size. This becomes '
      'especially problematic when a route specifies double.infinity for width '
      'or height to expand to the available space, which causes a layout error '
      'since the parent Navigator does not provide finite bounds.\n'
      'Make sure that NavigatorResizable is not wrapped in a widget that '
      'passes unbounded constraints to its children, such as Column or Row. '
      'The given constraints were:\n'
      '$constraints (from parent: ${parent.runtimeType}).',
    );

    // Measure the route contents *before* computing our own size, so that a
    // content size change is reflected in the same frame it is reported.
    //
    // invokeLayoutCallback opens a window in which dirtying nodes outside of
    // our own subtree is permitted, and in which nodes dirtied by the
    // measurement are merged back into the current PipelineOwner.flushLayout
    // pass instead of being deferred to the next frame.
    _measuring = true;
    try {
      invokeLayoutCallback<BoxConstraints>((constraints) {
        // Pass the parent constraints directly to the child Navigator,
        // allowing it to overflow this render box if necessary.
        child!.layout(constraints, parentUsesSize: true);
        // Every route subtree is a relayout boundary, because the Overlay
        // lays it out with a tight constraint. The tree walk above therefore
        // skips route contents whose size changed without the Overlay itself
        // being dirty, so drive those boundaries directly. This mirrors how
        // _RenderLayoutSurrogateProxyBox drives _RenderDeferredLayoutBox in
        // the framework's own OverlayPortal implementation.
        //
        // Draining rather than iterating keeps this correct even if measuring
        // a boundary schedules another one; measureFromNavigatorResizable
        // always removes itself first, so the loop is guaranteed to terminate.
        final pending = _state.pendingMeasurements;
        while (pending.isNotEmpty) {
          pending.first.measureFromNavigatorResizable();
        }
      });
    } finally {
      _measuring = false;
    }

    size = computeDryLayout(constraints);
    _visibleBounds = Offset.zero & size;
    alignChild();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(_visibleBounds.size.nearEqual(size));
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      _visibleBounds,
      super.paint,
      oldLayer: layer as ClipRectLayer?,
    );
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    assert(_visibleBounds.size.nearEqual(size));
    return _visibleBounds.contains(position) &&
        super.hitTest(result, position: position);
  }
}

/// Observes the layout of the [child] widget and notifies the ancestor
/// [NavigatorResizable] when the child's size changes.
///
/// A route is compatible with [NavigatorResizable] only if it mixes-in
/// the [ObservableRouteMixin] and wraps its content in
/// a [ResizableNavigatorRouteContentBoundary]. For example, a subclass
/// of [ModalRoute] should return a [ResizableNavigatorRouteContentBoundary]
/// in [ModalRoute.buildPage].
///
/// It is rarely used directly. Instead, use the built-in route classes
/// that satisfy the requirements of [NavigatorResizable],
/// such as [ResizableMaterialPageRoute] and [ResizablePageRouteBuilder].
class ResizableNavigatorRouteContentBoundary
    extends SingleChildRenderObjectWidget {
  /// Creates a widget that observes the layout of the [child].
  const ResizableNavigatorRouteContentBoundary({
    super.key,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderRouteContentBoundary(
      state: _NavigatorResizableState.of(context),
      route: ModalRoute.of(context)!,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderRouteContentBoundary)
      ..state = _NavigatorResizableState.of(context)
      ..route = ModalRoute.of(context)!;
  }
}

class _RenderRouteContentBoundary extends RenderPositionedBox {
  _RenderRouteContentBoundary({
    required _NavigatorResizableState state,
    required this.route,
  }) : _state = state,
       super(alignment: Alignment.topLeft);

  /// The route whose content this boundary measures.
  ///
  /// Only read to decide whether a measurement can affect the displayed size,
  /// and to report the size, so it needs no invalidation when it changes.
  ModalRoute<dynamic> route;

  _NavigatorResizableState _state;
  // ignore: avoid_setters_without_getters
  set state(_NavigatorResizableState value) {
    if (value == _state) return;
    final wasPending = _state.pendingMeasurements.remove(this);
    _state = value;
    if (wasPending) {
      _state.scheduleMeasurement(this);
    }
  }

  @override
  void detach() {
    _state.pendingMeasurements.remove(this);
    super.detach();
  }

  @override
  void markNeedsLayout() {
    // The Overlay lays this boundary out with a tight constraint, making it a
    // relayout boundary: the dirt stops right here and never reaches the
    // ancestor NavigatorResizable. Enqueue ourselves and dirty it explicitly,
    // so that it is laid out in this very frame, at its own (shallower) depth,
    // and can measure us before computing its size. Without this the new size
    // would only be applied one frame later.
    _state.scheduleMeasurement(this);
    super.markNeedsLayout();
  }

  // performLayout may be driven by the ancestor NavigatorResizable rather than
  // by our parent, so the framework's mutation asserts have to know about it.
  @override
  RenderObject? get debugLayoutParent {
    RenderObject? layoutParent;
    assert(() {
      layoutParent = _state.renderNavigatorResizable ?? parent;
      return true;
    }());
    return layoutParent;
  }

  /// Re-measures the content from within [_RenderNavigatorResizable]'s
  /// `performLayout`, for the frames in which the layout tree walk does not
  /// reach this boundary.
  void measureFromNavigatorResizable() {
    // Dequeue first: [RenderObject.layout] returns early without calling
    // performLayout when the framework's dirty flag was already cleared, and
    // the caller relies on this method always making progress.
    _state.pendingMeasurements.remove(this);
    if (!hasSize) {
      return;
    }
    layout(constraints, parentUsesSize: true);
  }

  @override
  void performLayout() {
    _state.pendingMeasurements.remove(this);
    super.performLayout();
    if (child?.size case final childSize?) {
      _state.didRouteContentSizeChange(
        route,
        // Ensure the size object is immutable.
        Size.copy(childSize),
      );
    }
  }
}

extension _SizeEquality on Size {
  bool nearEqual(Size other) {
    return p.nearEqual(
          height,
          other.height,
          Tolerance.defaultTolerance.distance,
        ) &&
        p.nearEqual(
          width,
          other.width,
          Tolerance.defaultTolerance.distance,
        );
  }
}
