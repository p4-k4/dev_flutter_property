// Make your state flow like the rapids of a mighty
// river and propell its pod from whence it came.
//
// Unveil the hidden treasure troves, marking X on the map.
//
// Introducing... GetRiverProviderX.
//
// Jokes aside...
//
// The Property class is used to manage state and values of a property
// in Flutter. While the Property class itself manages its state and value,
// it relies on PropertyWidget or PropertyBuilder to handle rebuilds in the
// widget tree when its state changes.
//
// The value and state of a Property object are exposed as read-only properties,
// preventing unexpected state changes and race conditions. The update method is
// the primary way to update a Property object's state and value. However,
// subscribeToStream, pause, and resume methods also modify the state of the Property.
//
// Using Property objects allows for greater flexibility and customizability,
// as it decentralizes state management and reduces coupling to the API design.
// PropertyWidget and PropertyBuilder make it easy to react to state changes and
// build the widget tree accordingly.
//
// The Property class also provides additional methods for managing its behavior
// and lifecycle, such as subscribeToStream, pause, resume, debounceRemainingTime,
// throttleRemainingTime, and dispose.

// PropertyWidget is a StatefulWidget that reacts to changes in a Property's state.
// It uses various callbacks to handle different Property states and build the
// widget tree accordingly. PropertyWidget relies on the state managed by the
// Property class and ensures proper rebuilds when the state changes.

// PropertyBuilder is a StatefulWidget that takes a list of Property objects and
// a builder function. It rebuilds the widget tree whenever any of the Property
// objects in the list update their state. PropertyBuilder enables handling multiple
// Property objects in the same widget tree, ensuring that the widgets react to
// state changes in all the provided properties.
library property;

import 'dart:async';

import 'package:flutter/widgets.dart';

enum PropertyState {
  init,
  value,
  waiting,
  Null,
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

abstract class Option<T> {
  const Option();

  bool get isSome;
  bool get isNone;
  T get value;

  factory Option.some(T value) => Some(value);
  factory Option.none() => const None();

  R map<R>(R Function(T) mapper);

  Option<U> flatMap<U>(Option<U> Function(T) f);

  FutureOr<R> fold<R>({
    required FutureOr<R> Function() ifNone,
    required FutureOr<R> Function(T value) ifSome,
  });

  T getOrElse(T Function() defaultValue) {
    return isSome ? value : defaultValue();
  }

  static Option<T> fromValue<T>(T value) =>
      value == null ? Option.none() : Option.some(value);
}

class Some<T> extends Option<T> {
  final T _value;

  const Some(this._value) : super();

  @override
  bool get isSome => true;

  @override
  bool get isNone => false;

  @override
  T get value => _value;

  @override
  R map<R>(R Function(T) mapper) => mapper(_value);

  @override
  Option<U> flatMap<U>(Option<U> Function(T) f) {
    return f(value);
  }

  @override
  FutureOr<R> fold<R>({
    required FutureOr<R> Function() ifNone,
    required FutureOr<R> Function(T value) ifSome,
  }) async =>
      await ifSome(_value);
}

class None<T> extends Option<T> {
  const None() : super();

  @override
  bool get isSome => false;

  @override
  bool get isNone => true;

  @override
  T get value => throw Exception('Cannot get value from None.');

  @override
  R map<R>(R Function(T) mapper) => throw Exception('Cannot map None.');

  @override
  Option<U> flatMap<U>(Option<U> Function(T) f) {
    return None<U>();
  }

  @override
  FutureOr<R> fold<R>({
    required FutureOr<R> Function() ifNone,
    required FutureOr<R> Function(T value) ifSome,
  }) =>
      ifNone();
}

class Property<T extends Object> {
  Property(
    this.init, {
    this.autoDisposeSubscription = false,
    this.autoDispose = false,
  }) {
    controller = StreamController<PropertyEvent>.broadcast();
    _state = PropertyState.init;
  }

  DefaultValueSupplier<Option> init;
  Option<T> _value = Option.none();
  late StreamController<PropertyEvent> controller;
  StreamSubscription? _streamSubscription;
  late PropertyState _state;
  Object? _error;
  StackTrace? _stackTrace;
  final bool autoDispose;
  final bool autoDisposeSubscription;
  AsyncSnapshot? _lastSnapshot;

  bool get isNone => _value.isNone;
  bool get isSome => _value.isSome;

  Option<T> get value => _value;
  PropertyState get state => _state;
  Object? get error => _error;
  StackTrace? get stackTrace => _stackTrace;

  T get _defaultValue => const None() as T;

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

  Future<void> update(
    FutureOr<T> Function(Option<T> value) valueFn, {
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
      T result = await valueFn(value);
      return Option.some(result);
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
      _state = PropertyState.Null;
    } else if (_value is List && (_value as List).isEmpty) {
      _state = PropertyState.emptyList;
    } else if (_value is Map && (_value as Map).isEmpty) {
      _state = PropertyState.emptyMap;
    } else {
      _state = PropertyState.value;
    }
  }

  void subscribeToStream<E>(
      {required Stream<E> stream, Function(E event)? onEvent}) {
    _streamSubscription?.cancel();
    _state = PropertyState.listening;
    _streamSubscription = stream.listen((event) {
      _state = PropertyState.value;
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

  Widget map({
    required Widget Function(T value) onSome,
    required Widget Function() onInit,
    Widget Function()? onNone,
    Widget fallback = const SizedBox.shrink(),
    Widget Function(T value)? onWaiting,
    Widget Function()? onNull,
    Widget Function()? onEmptyList,
    Widget Function()? onEmptyMap,
    Widget Function(T value)? onListening,
    Widget Function(T value, Object error, StackTrace stackTrace)? onError,
    Widget Function(T value)? onTimeout,
    Widget Function(T value, int timeRemaining)? onDebounce,
    Widget Function(T value, int timeRemaining)? onThrottle,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    return PropertyWidget<Option<T>>(
      key: ValueKey(hashCode),
      property: this,
      onValue: (Option<T> value) {
        final result = value.fold<Widget>(
          ifNone: onNone ?? (() => fallback),
          ifSome: (T val) => onSome(val),
        );
        return result is Future<Widget>
            ? FutureBuilder<Widget>(
                future: result,
                initialData: _lastSnapshot?.data ?? onInit.call(),
                builder:
                    (BuildContext context, AsyncSnapshot<Widget> snapshot) {
                  _lastSnapshot = snapshot;
                  if (_lastSnapshot == null) {
                    return onInit.call();
                  } else if (snapshot.connectionState == ConnectionState.done &&
                      snapshot.data != null) {
                    return snapshot.data!;
                  } else {
                    return _lastSnapshot!.data as Widget;
                  }
                },
              )
            : result;
      },
      onNull: onNone != null ? () => onNone() : () => fallback,
      onInit: onInit != null
          ? (Option<T> value) => onInit.call()
          : (Option<T> value) => fallback,
      onWaiting: onWaiting != null
          ? (Option<T> value) => onWaiting(value.getOrElse(() => _defaultValue))
          : null,
      onEmptyList: onEmptyList != null ? () => onEmptyList() : null,
      onEmptyMap: onEmptyMap != null ? () => onEmptyMap() : null,
      onListening: onListening != null
          ? (Option<T> value) =>
              onListening(value.getOrElse(() => _defaultValue))
          : null,
      onError: onError != null
          ? (Option<T> value, Object error, StackTrace stackTrace) =>
              onError(value.getOrElse(() => _defaultValue), error, stackTrace)
          : null,
      onTimeout: onTimeout != null
          ? (Option<T> value) => onTimeout(value.getOrElse(() => _defaultValue))
          : null,
      onDebounce: onDebounce != null
          ? (Option<T> value, int timeRemaining) =>
              onDebounce(value.getOrElse(() => _defaultValue), timeRemaining)
          : null,
      onThrottle: onThrottle != null
          ? (Option<T> value, int timeRemaining) =>
              onThrottle(value.getOrElse(() => _defaultValue), timeRemaining)
          : null,
      skipWaiting: skipWaiting,
      skipDebounce: skipDebounce,
      skipThrottle: skipThrottle,
    );
  }

  void on({
    required void Function(T value) onValue,
    void Function()? onNone,
    void Function()? onInit,
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
      case PropertyState.init:
        if (onInit != null) {
          onInit.call();
        }
        break;
      case PropertyState.value:
        onValue(_value as T);
        break;
      case PropertyState.Null:
        if (onNone != null) {
          onNone.call();
        }
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
    required this.onValue,
    this.onInit,
    this.onWaiting,
    this.onNull,
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
  final Widget Function()? onNull;
  final Widget Function()? onEmptyMap;
  final Widget Function()? onEmptyList;
  final Widget Function(T value) onValue;
  final Widget Function(T defaultValue)? onInit;
  final Widget Function(T value)? onWaiting;
  final Widget Function(T value)? onListening;
  final Widget Function(T value, Object error, StackTrace stackTrace)? onError;
  final Widget Function(T value)? onTimeout;
  final Widget Function(T value, int timeRemaining)? onDebounce;
  final Widget Function(T value, int timeRemaining)? onThrottle;
  final bool skipWaiting;
  final bool skipDebounce;
  final bool skipThrottle;

  @override
  _PropertyWidgetState<T> createState() => _PropertyWidgetState<T>();
}

class _PropertyWidgetState<T extends Object> extends State<PropertyWidget<T>> {
  late StreamSubscription<PropertyEvent> _subscription;

  @override
  void initState() {
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

    if (state == PropertyState.init) {
      widgetToBuild = widget.onInit?.call(widget.property.value as T) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.value) {
      widgetToBuild = widget.onValue.call(value);
    } else if (state == PropertyState.waiting) {
      widgetToBuild = widget.onWaiting?.call(widget.property.value as T) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.Null) {
      widgetToBuild = widget.onNull?.call() ?? const SizedBox.shrink();
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
