library property;

import 'dart:async';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:flutter/widgets.dart';

enum PropertyState {
  some,
  none,
  waiting,
  emptyList,
  emptyMap,
  listening,
  streamEvent,
  streamPaused,
  error,
  timeout,
  debouncing,
  throttled,
}

enum PropertyEvent {
  rebuild,
}

typedef DefaultValueSupplier<T> = T Function();

class Property<T extends Object> {
  Property(
    this.init, {
    this.autoDisposeSubscription = false,
    this.autoDispose = false,
    this.resetOnDispose = false,
  }) {
    controller = StreamController<PropertyEvent>.broadcast();
    _state = PropertyState.none;
  }

  Option<T> _value = Option<T>.none();

  DefaultValueSupplier<Option> init;

  Object? _error;
  StackTrace? _stackTrace;

  late PropertyState _state;

  final bool autoDispose;
  final bool autoDisposeSubscription;
  final bool resetOnDispose;

  StreamSubscription? _streamSubscription;
  late StreamController<PropertyEvent> controller;

  bool get isNone => _value.isNone();
  bool get isSome => _value.isSome();

  Option<T> get value => _value;
  PropertyState get state => _state;
  Object? get error => _error;
  StackTrace? get stackTrace => _stackTrace;

  void initController() {
    if (controller.isClosed) {
      controller = StreamController<PropertyEvent>.broadcast();
    }
  }

  void resetToNone({
    bool rebuild = true,
  }) {
    _value = const None();
    rebuild ? controller.add(PropertyEvent.rebuild) : null;
  }

  Future<void> _applyDebounce(
      Duration debounceDuration,
      void Function()? onDebounce,
      void Function()? afterDebounce,
      FutureOr<Option<T>> Function(Option<T> value) updateAction) async {
    _state = PropertyState.debouncing;
    controller.add(PropertyEvent.rebuild);
    _Debounce.debounce(
      id: hashCode,
      duration: debounceDuration,
      onExecute: () async {
        await _updateInternal(updateAction);
      },
      onDebounce: onDebounce,
      afterDebounce: afterDebounce,
    );
  }

  Future<void> _applyThrottle(
      Duration throttleDuration,
      void Function()? beforeThrottle,
      void Function()? onThrottle,
      void Function()? afterThrottle,
      bool immediateTiming,
      FutureOr<Option<T>> Function(Option<T> value) updateAction) async {
    _state = PropertyState.throttled;
    controller.add(PropertyEvent.rebuild);
    _Throttle.throttle(
      id: hashCode,
      duration: throttleDuration,
      onExecute: () async {
        await _updateInternal(updateAction);
      },
      beforeThrottle: beforeThrottle,
      onThrottle: onThrottle,
      afterThrottle: afterThrottle,
      immediateTiming: immediateTiming,
    );
  }

  Future<void> update({
    required FutureOr<Some<T>> Function(T value) ifSome,
    required FutureOr<Option<T>> Function() ifNone,
    Duration? debounceDuration,
    Duration? throttleDuration,
    void Function()? onDebounce,
    void Function()? afterDebounce,
    void Function()? beforeThrottle,
    void Function()? onThrottle,
    void Function()? afterThrottle,
    bool immediateTiming = false,
  }) async {
    FutureOr<Option<T>> updateAction(Option<T> value) async {
      return value.match(
        () => ifNone(),
        (v) => ifSome(v),
      );
    }

    if (debounceDuration != null) {
      await _applyDebounce(
          debounceDuration, onDebounce, afterDebounce, updateAction);
    } else if (throttleDuration != null) {
      await _applyThrottle(throttleDuration, beforeThrottle, onThrottle,
          afterThrottle, immediateTiming, updateAction);
    } else {
      await _updateInternal(updateAction);
    }
  }

  Future<void> _updateInternal(
    FutureOr<Option<T>> Function(Option<T> value) newValue,
  ) async {
    try {
      _error = null;
      _stackTrace = null;
      _state = PropertyState.waiting;
      controller.add(PropertyEvent.rebuild);
      FutureOr<Option<T>> result = newValue.call(_value);
      if (result is Future<Option<T>>) {
        _value = await result;
      } else {
        _value = result;
      }
      _updateState();
      controller.add(PropertyEvent.rebuild);
    } catch (error, stackTrace) {
      _state = PropertyState.error;
      _error = error;
      _stackTrace = stackTrace;
      rethrow;
    }
  }

  void _updateState() {
    if (_value is None) {
      _state = PropertyState.none;
    } else if (_value is List && (_value as List).isEmpty) {
      _state = PropertyState.emptyList;
    } else if (_value is Map && (_value as Map).isEmpty) {
      _state = PropertyState.emptyMap;
    } else {
      _state = PropertyState.some;
    }
  }

  void subscribeToStream<E>(
      {required Stream<E> stream, Function(E event)? onEvent}) {
    _streamSubscription?.cancel();
    _state = PropertyState.listening;
    _streamSubscription = stream.listen((event) {
      _state = PropertyState.some;
      controller.add(PropertyEvent.rebuild);
      onEvent?.call(event);
    });
  }

  void pause() {
    _streamSubscription?.pause();
    _state = PropertyState.streamPaused;
    controller.add(PropertyEvent.rebuild);
  }

  void resume() {
    _streamSubscription?.resume();
    _state = PropertyState.listening;
    controller.add(PropertyEvent.rebuild);
  }

  int? get debounceRemainingTime {
    return _Debounce._operations[hashCode] != null &&
            _Debounce._operations[hashCode]!.timer.isActive
        ? _Debounce._operations[hashCode]!.timer.tick
        : null;
  }

  int? get throttleRemainingTime {
    return _Throttle._operations[hashCode] != null &&
            _Throttle._operations[hashCode]!.timer.isActive
        ? _Throttle._operations[hashCode]!.timer.tick
        : null;
  }

  void dispose() {
    if (autoDispose) {
      controller.close();
    }
    if (autoDisposeSubscription) {
      _streamSubscription?.cancel();
    }
  }

  R match<R>({
    required R Function(T value) onSome,
    required R Function() onNone,
    R Function()? onWaiting,
    R Function()? onNullValue,
    R Function()? onEmptyList,
    R Function()? onEmptyMap,
    R Function(T value)? onListening,
    R Function(Object error, StackTrace stackTrace)? onError,
    R Function()? onTimeout,
    R Function()? onDebounce,
    R Function()? onThrottle,
    required R fallback,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    switch (state) {
      case PropertyState.some:
        return value.match(() => fallback, (t) => onSome.call(t) ?? fallback);
      case PropertyState.none:
        return value.match(() => fallback, (t) => onNone.call() ?? fallback);
      case PropertyState.waiting:
        return value.match(
            () => fallback, (t) => onWaiting?.call() ?? fallback);
      case PropertyState.emptyList:
        return value.match(
            () => fallback, (t) => onEmptyList?.call() ?? fallback);
      case PropertyState.emptyMap:
        return value.match(
            () => fallback, (t) => onEmptyMap?.call() ?? fallback);
      case PropertyState.listening:
        return value.match(
            () => fallback, (t) => onListening?.call(t) ?? fallback);
      case PropertyState.streamEvent:
        return fallback;
      case PropertyState.streamPaused:
        return fallback;
      case PropertyState.error:
        return value.match(() => fallback,
            (t) => onError?.call(t, StackTrace.fromString('')) ?? fallback);
      case PropertyState.timeout:
        return value.match(
            () => fallback, (t) => onTimeout?.call() ?? fallback);
      case PropertyState.debouncing:
        return value.match(
            () => fallback, (t) => onDebounce?.call() ?? fallback);
      case PropertyState.throttled:
        return value.match(
            () => fallback, (t) => onThrottle?.call() ?? fallback);
    }
  }

  Widget widget({
    required Widget Function(T value) onSome,
    required Widget Function() onNone,
    Widget fallback = const SizedBox.shrink(),
    Widget Function()? onWaiting,
    Widget Function()? onNull,
    Widget Function()? onEmptyList,
    Widget Function()? onEmptyMap,
    Widget Function(T value)? onListening,
    Widget Function(Object error, StackTrace stackTrace)? onError,
    Widget Function()? onTimeout,
    Widget Function()? onDebounce,
    Widget Function()? onThrottle,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    return PropertyWidget<Option<T>>(
      key: ValueKey(hashCode),
      property: this,
      onSome: (value) => value.match(() => onNone(), (t) => onSome(t)),
      onNone: () => onNone(),
      onWaiting: (value) => value.match(() => onWaiting?.call() ?? fallback,
          (t) => onWaiting?.call() ?? fallback),
      onEmptyList: onEmptyList,
      onEmptyMap: onEmptyMap,
      onListening: (value) => value.match(() => onWaiting?.call() ?? fallback,
          (t) => onListening?.call(t) ?? fallback),
      onError: (value, error, stackTrace) => value.match(
          () => onError?.call(error, stackTrace) ?? fallback,
          (t) => onError?.call(error, stackTrace) ?? fallback),
      onTimeout: (value) => value.match(() => onTimeout?.call() ?? fallback,
          (t) => onTimeout?.call() ?? fallback),
      onDebounce: (value) => value.match(() => onDebounce?.call() ?? fallback,
          (t) => onDebounce?.call() ?? fallback),
      onThrottle: (value) => value.match(() => onThrottle?.call() ?? fallback,
          (t) => onThrottle?.call() ?? fallback),
      skipWaiting: skipWaiting,
      skipDebounce: skipDebounce,
      skipThrottle: skipThrottle,
    );
  }

  void on({
    required void Function(T value) onValue,
    void Function()? onNone,
    void Function(T value)? onWaiting,
    void Function()? onNull,
    void Function()? onEmptyList,
    void Function()? onEmptyMap,
    void Function(T value)? onListening,
    void Function(T value, Object error, StackTrace stackTrace)? onError,
    void Function(T value)? onTimeout,
    void Function(T value, int timeRemaining)? onDebounce,
    void Function(T value, int timeRemaining)? onThrottle,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    PropertyState state = this.state;

    switch (state) {
      case PropertyState.some:
        onValue(_value as T);
        break;
      case PropertyState.waiting:
        if (!skipWaiting && onWaiting != null) {
          onWaiting(_value as T);
        }
        break;
      case PropertyState.debouncing:
        if (!skipDebounce && onDebounce != null) {
          onDebounce(_value as T, debounceRemainingTime!);
        }
        break;
      case PropertyState.throttled:
        if (!skipThrottle && onThrottle != null) {
          onThrottle(_value as T, throttleRemainingTime!);
        }
        break;
      case PropertyState.emptyList:
        if (onEmptyList != null) {
          onEmptyList.call();
        }
        break;
      case PropertyState.emptyMap:
        if (onEmptyMap != null) {
          onEmptyMap.call();
        }
        break;
      case PropertyState.listening:
        if (onListening != null) {
          onListening(_value as T);
        }
        break;
      case PropertyState.error:
        if (onError != null) {
          onError(_value as T, _error!, _stackTrace!);
        }
        break;
      case PropertyState.timeout:
        if (onTimeout != null) {
          onTimeout(_value as T);
        }
        break;
      default:
        break;
    }
  }
}

class PropertyWidget<T extends Object> extends StatefulWidget {
  const PropertyWidget({
    Key? key,
    required this.property,
    required this.onSome,
    required this.onNone,
    this.onWaiting,
    this.onEmptyList,
    this.onEmptyMap,
    this.onListening,
    this.onError,
    this.onTimeout,
    this.skipWaiting = false,
    this.skipDebounce = false,
    this.skipThrottle = false,
    this.onDebounce,
    this.onThrottle,
  }) : super(key: key);

  final Property property;
  final Widget Function() onNone;
  final Widget Function()? onEmptyMap;
  final Widget Function()? onEmptyList;
  final Widget Function(T value) onSome;
  final Widget Function(T value)? onWaiting;
  final Widget Function(T value)? onListening;
  final Widget Function(T value, Object error, StackTrace stackTrace)? onError;
  final Widget Function(T value)? onTimeout;
  final Widget Function(T value)? onDebounce;
  final Widget Function(T value)? onThrottle;
  final bool skipWaiting;
  final bool skipDebounce;
  final bool skipThrottle;

  @override
  PropertyWidgetState<T> createState() => PropertyWidgetState<T>();
}

class PropertyWidgetState<T extends Object> extends State<PropertyWidget<T>> {
  late StreamSubscription<PropertyEvent> _subscription;

  @override
  void initState() {
    widget.property.initController();
    _subscription = widget.property.controller.stream.listen((event) {
      _onPropertyEvent(event);
    });
    super.initState();
  }

  @override
  void didUpdateWidget(PropertyWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.property != widget.property) {
      _subscription.cancel();
      widget.property.initController();
      _subscription = widget.property.controller.stream.listen((event) {
        _onPropertyEvent(event);
      });
    }
  }

  void _onPropertyEvent(PropertyEvent event) {
    if (mounted && widget.property.state != event) {
      if ((widget.skipWaiting &&
              widget.property.state == PropertyState.waiting) ||
          (widget.skipDebounce &&
              widget.property.state == PropertyState.debouncing) ||
          (widget.skipThrottle &&
              widget.property.state == PropertyState.throttled)) {
        return;
      }
      setState(() {});
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    if (mounted) {
      widget.property.resetOnDispose ? widget.property.resetToNone() : null;
      widget.property.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    print('rebuild');
    Widget widgetToBuild;
    PropertyState state = widget.property.state;
    T? value = widget.property.value as T;
    Object? error = widget.property.error;
    StackTrace? stackTrace = widget.property.stackTrace;

    if (state == PropertyState.waiting) {
      widgetToBuild = widget.onWaiting?.call(widget.property.value as T) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.some) {
      widgetToBuild = widget.onSome.call(value);
    } else if (state == PropertyState.none) {
      widgetToBuild = widget.onNone.call();
    } else if (state == PropertyState.emptyList) {
      widgetToBuild = widget.onEmptyList?.call() ?? const SizedBox.shrink();
    } else if (state == PropertyState.emptyMap) {
      widgetToBuild = widget.onEmptyMap?.call() ?? const SizedBox.shrink();
    } else if (state == PropertyState.listening) {
      widgetToBuild = widget.onListening?.call(widget.property.value as T) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.error) {
      widgetToBuild = widget.onError
              ?.call(widget.property.value as T, error!, stackTrace!) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.timeout) {
      widgetToBuild = widget.onTimeout?.call(widget.property.value as T) ??
          const SizedBox.shrink();
    } else {
      widgetToBuild = const SizedBox.shrink();
    }

    return widgetToBuild;
  }
}

class PropertyBuilder extends StatefulWidget {
  const PropertyBuilder({
    super.key,
    required this.properties,
    required this.builder,
  });

  final List<Property> properties;
  final Widget Function(BuildContext context) builder;

  @override
  State<PropertyBuilder> createState() => PropertyBuilderState();
}

class PropertyBuilderState extends State<PropertyBuilder> {
  late List<StreamSubscription> _subscriptions;

  @override
  void initState() {
    _subscriptions = widget.properties.map((property) {
      return property.controller.stream.listen((event) {
        setState(() {});
      });
    }).toList();
    super.initState();
  }

  @override
  void dispose() {
    for (Property element in widget.properties) {
      element.dispose();
    }
    for (var subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context);
  }
}

class _DebounceOperation {
  _DebounceOperation(this.callback, this.timer);

  void Function() callback;
  Timer timer;
}

class _Debounce {
  static Map<int, _DebounceOperation> _operations = {};

  static void debounce({
    required int id,
    required Duration duration,
    required void Function() onExecute,
    void Function()? onDebounce,
    void Function()? afterDebounce,
    ValueChanged<int>? onRemainingTimeChanged,
  }) {
    if (duration == Duration.zero) {
      _operations[id]?.timer.cancel();
      _operations.remove(id);
      onExecute();
    } else {
      onDebounce?.call();
      _operations[id]?.timer.cancel();

      int remainingTime = duration.inMilliseconds;
      _operations[id] = _DebounceOperation(
        () {
          onExecute.call();
        },
        Timer.periodic(
          const Duration(milliseconds: 100),
          (timer) {
            remainingTime -= 100;
            onRemainingTimeChanged?.call(remainingTime);

            if (remainingTime <= 0) {
              timer.cancel();
              _operations[id]?.timer.cancel();
              _operations.remove(id);
              onExecute();
              afterDebounce?.call();
            }
          },
        ),
      );
    }
  }
}

class _ThrottleOperation {
  void Function()? callback;
  void Function()? onAfter;
  Timer timer;
  int remainingTime;

  _ThrottleOperation(
    this.callback,
    this.timer, {
    this.onAfter,
    required this.remainingTime,
  });
}

class _Throttle {
  static Map<int, _ThrottleOperation> _operations = {};

  static void throttle({
    required int id,
    required Duration duration,
    required void Function() onExecute,
    void Function()? beforeThrottle,
    void Function()? onThrottle,
    void Function()? afterThrottle,
    ValueChanged<int>? onRemainingTimeChanged,
    bool immediateTiming = false,
  }) {
    var throttled = _operations.containsKey(id);

    if (throttled) {
      onThrottle?.call();
      return;
    } else {
      int remainingTime = immediateTiming ? 0 : duration.inMilliseconds;

      if (immediateTiming) onExecute();
      beforeThrottle?.call();

      _operations[id] = _ThrottleOperation(
        onExecute,
        Timer.periodic(
          const Duration(milliseconds: 100),
          (timer) {
            remainingTime -= 100;
            onRemainingTimeChanged?.call(remainingTime);

            if (remainingTime <= 0) {
              timer.cancel();
              _ThrottleOperation? removed = _operations.remove(id);
              removed?.onAfter?.call();
              afterThrottle?.call();
            }
          },
        ),
        remainingTime: remainingTime,
        onAfter: () {
          if (!immediateTiming) {
            onExecute.call();
          }
        },
      );
    }
  }
}
