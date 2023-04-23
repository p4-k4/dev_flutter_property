
library property;

import 'dart:async';
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

abstract class Option {}

class None<T> extends Option {}

class Some<T> extends Option {
  Some(this.value);
  final T value;
}

class Property<T> {
  Property(
    this.init, {
    this.autoDispose = false,
    this.resetOnDispose = false,
    this.autoDisposeSubscription = false,
    this.maxValues = 1,
  }) {
    initControllers();
    _state = PropertyState.none;
    _value.add(init);
  }

  T init;
  List<T> _value = [];
  late PropertyState _state;

  int maxValues;

  StreamController<PropertyState> _stateController =
      StreamController<PropertyState>.broadcast();
  StreamController<T> _valueController = StreamController<T>.broadcast();

  Object? _error;
  StackTrace? _stackTrace;

  final bool autoDispose;
  final bool autoDisposeSubscription;
  final bool resetOnDispose;

  StreamSubscription? _streamSubscription;

  bool get isSome => _state == PropertyState.some;
  bool get isNone => _state == PropertyState.none;

  T get value => _value.last;
  PropertyState get state => _state;
  Object? get error => _error;
  StackTrace? get stackTrace => _stackTrace;

  void initControllers() {
    if (_stateController.isClosed) {
      _stateController = StreamController<PropertyState>.broadcast();
    }
    if (_valueController.isClosed) {
      _valueController = StreamController<T>.broadcast();
    }
  }

  void resetToNone({
    bool rebuild = true,
  }) {
    _state = PropertyState.none;
    rebuild ? _stateController.add(PropertyState.none) : null;
  }

  Future<void> _applyDebounce(
      Duration debounceDuration,
      void Function()? onDebounce,
      void Function()? afterDebounce,
      FutureOr<T> Function(T value) updateAction) async {
    _state = PropertyState.debouncing;
    _stateController.add(PropertyState.debouncing);
    _Debounce.debounce(
      id: hashCode,
      duration: debounceDuration,
      onExecute: () async {
        _updateInternal(updateAction);
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
      FutureOr<T> Function(T value) updateAction) async {
    _state = PropertyState.throttled;
    _stateController.add(PropertyState.throttled);
    _Throttle.throttle(
      id: hashCode,
      duration: throttleDuration,
      onExecute: () async {
        _updateInternal(updateAction);
      },
      beforeThrottle: beforeThrottle,
      onThrottle: onThrottle,
      afterThrottle: afterThrottle,
      immediateTiming: immediateTiming,
    );
  }

  FutureOr<void> update(
    FutureOr<T> Function(T value) some, {
    Duration? debounceDuration,
    Duration? throttleDuration,
    void Function()? onDebounce,
    void Function()? afterDebounce,
    void Function()? beforeThrottle,
    void Function()? onThrottle,
    void Function()? afterThrottle,
    bool immediateTiming = false,
  }) {
    if (debounceDuration != null) {
      _applyDebounce(debounceDuration, onDebounce, afterDebounce, some);
    } else if (throttleDuration != null) {
      _applyThrottle(throttleDuration, beforeThrottle, onThrottle,
          afterThrottle, immediateTiming, some);
    } else {
      _updateInternal(some);
    }
  }

  FutureOr<void> _updateInternal(
    FutureOr<T> Function(T value) newValue,
  ) {
    try {
      _error = null;
      _stackTrace = null;
      if (value is Future<T>) {
        _state = PropertyState.waiting;
        _stateController.add(PropertyState.waiting);
      }
      FutureOr<T> result = newValue.call(_value.last);
      if (result is Future<T>) {
        result.then((resolvedValue) {
          _value
              .add(resolvedValue); // Add the resolved value to the _value list.
          _valueController.add(resolvedValue);
          _updateState();
          _stateController.add(PropertyState.some);
        });
      } else {
        _value.add(result); // Add the result to the _value list.
        _valueController.add(result);
        _updateState();
        _stateController.add(PropertyState.some);
      }
    } catch (error, stackTrace) {
      _state = PropertyState.error;
      _error = error;
      _stackTrace = stackTrace;
    }
  }

  void _updateState() {
    // TODO We need to clear error and stackktrace at some point
    if (_value.last == null) {
      _state = PropertyState.none;
    } else if (_value.last is List && (_value.last as List).isEmpty) {
      _state = PropertyState.emptyList;
    } else if (_value is Map && (_value as Map).isEmpty) {
      _state = PropertyState.emptyMap;
    } else {
      _state = PropertyState.some;
    }
  }

  void subscribeToStream({required Stream<T> stream}) {
    _streamSubscription = stream.listen(
      (newValue) {
        _valueController.add(newValue);
        _updateState();
        _stateController.add(PropertyState.streamEvent);
      },
      onError: (error, stackTrace) {
        _error = error;
        _stackTrace = stackTrace;
        _state = PropertyState.error;
        _stateController.add(PropertyState.error);
      },
    );
  }

  void pause() {
    _streamSubscription?.pause();
    _state = PropertyState.streamPaused;
    _stateController.add(PropertyState.streamPaused);
  }

  void resume() {
    _streamSubscription?.resume();
    _state = PropertyState.listening;
    _stateController.add(PropertyState.listening);
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
      _stateController.close();
      _valueController.close();
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
    R Function()? onListening,
    R Function(Object error, StackTrace stackTrace)? onError,
    R Function()? onTimeout,
    R Function()? onDebounce,
    R Function()? onThrottle,
    R Function()? onStreamEvent,
    R Function()? onStreamPaused,
    required R fallback,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    switch (state) {
      case PropertyState.some:
        return onSome.call(_value.last);
      case PropertyState.none:
        return onNone.call();
      case PropertyState.waiting:
        return onWaiting?.call() ?? fallback;
      case PropertyState.emptyList:
        return onEmptyList?.call() ?? fallback;
      case PropertyState.emptyMap:
        return onEmptyMap?.call() ?? fallback;
      case PropertyState.listening:
        return onListening?.call() ?? fallback;
      case PropertyState.streamEvent:
        return onStreamEvent?.call() ?? fallback;
      case PropertyState.streamPaused:
        return onStreamPaused?.call() ?? fallback;
      case PropertyState.error:
        return (_error != null && _stackTrace != null && onError != null)
            ? onError.call(_error!, _stackTrace!)
            : fallback;
      case PropertyState.timeout:
        return onTimeout?.call() ?? fallback;
      case PropertyState.debouncing:
        return onDebounce?.call() ?? fallback;
      case PropertyState.throttled:
        return onThrottle?.call() ?? fallback;
      default:
        return fallback;
    }
  }

  Widget widget({
    required Widget Function(T value) onSome,
    required Widget Function() onNone,
    Widget Function()? onWaiting,
    Widget Function()? onNullValue,
    Widget Function()? onEmptyList,
    Widget Function()? onEmptyMap,
    Widget Function()? onListening,
    Widget Function(Object error, StackTrace stackTrace)? onError,
    Widget Function()? onTimeout,
    Widget Function()? onDebounce,
    Widget Function()? onThrottle,
    Widget Function()? onStreamEvent,
    Widget Function()? onStreamPaused,
    required Widget fallback,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    return PropertyWidget<T>(
      property: this,
      onSome: onSome,
      onNone: onNone,
    );
  }

  StreamSubscription<PropertyState>? _onSubscription;

  void on({
    required void Function(T value) onSome,
    void Function()? onNone,
    void Function()? onWaiting,
    void Function()? onNull,
    void Function()? onEmptyList,
    void Function()? onEmptyMap,
    void Function()? onListening,
    void Function()? onStreamEvent,
    void Function()? onStreamPaused,
    void Function(Object error, StackTrace stackTrace)? onError,
    void Function()? onTimeout,
    void Function()? onDebounce,
    void Function()? onThrottle,
  }) {
    _onSubscription?.cancel();
    _onSubscription = _stateController.stream.listen(
      (event) {
        switch (state) {
          case PropertyState.some:
            return onSome.call(_value.last);
          case PropertyState.none:
            return onNone?.call();
          case PropertyState.waiting:
            return onWaiting?.call();
          case PropertyState.emptyList:
            return onEmptyList?.call();
          case PropertyState.emptyMap:
            return onEmptyMap?.call();
          case PropertyState.listening:
            return onListening?.call();
          case PropertyState.streamEvent:
            return onStreamEvent?.call();
          case PropertyState.streamPaused:
            return onStreamPaused?.call();
          case PropertyState.error:
            return (_error != null && _stackTrace != null && onError != null)
                ? onError.call(_error!, _stackTrace!)
                : () {};
          case PropertyState.timeout:
            return onTimeout?.call();
          case PropertyState.debouncing:
            return onDebounce?.call();
          case PropertyState.throttled:
            return onThrottle?.call();
        }
      },
    );
  }
}

class PropertyWidget<T> extends StatefulWidget {
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

  final Property<T> property;
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

class PropertyWidgetState<T> extends State<PropertyWidget<T>> {
  late StreamSubscription<PropertyState> _stateSubscription;
  late StreamSubscription<T> _valueSubscription;
  T? _value;

  @override
  void initState() {
    widget.property.initControllers();

    _stateSubscription =
        widget.property._stateController.stream.listen((event) {
      _onPropertyEvent(event);
      setState(() {});
    });

    _valueSubscription =
        widget.property._valueController.stream.listen((value) {
      if (mounted) {
        _value = value;

        setState(() {});
      }
    });

    super.initState();
  }

  void _onPropertyEvent(PropertyState event) {
    if (mounted && widget.property.state != event) {
      if ((widget.skipWaiting &&
              widget.property.state == PropertyState.waiting) ||
          (widget.skipDebounce &&
              widget.property.state == PropertyState.debouncing) ||
          (widget.skipThrottle &&
              widget.property.state == PropertyState.throttled)) {
        return;
      }
      _value = widget.property.value;
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(PropertyWidget<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.property != widget.property) {
      _stateSubscription.cancel();
      _valueSubscription.cancel();
      widget.property.initControllers();
      _stateSubscription =
          widget.property._stateController.stream.listen((event) {
        _onPropertyEvent(event);
      });

      // Cancel the old value subscription and subscribe to the new value stream
      _valueSubscription.cancel();
      _valueSubscription =
          widget.property._valueController.stream.listen((value) {
        if (mounted) {
          _value = value;
          setState(() {});
        }
      });
    }
  }

  @override
  void dispose() {
    _stateSubscription.cancel();
    _valueSubscription.cancel(); // Cancel the value subscription
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
    T value = _value ?? widget.property.init;
    Object? error = widget.property.error;
    StackTrace? stackTrace = widget.property.stackTrace;
    print(widget.property.state);

    if (state == PropertyState.waiting) {
      widgetToBuild = widget.onWaiting?.call(value) ?? const SizedBox.shrink();
    } else if (state == PropertyState.some) {
      widgetToBuild = widget.onSome.call(value);
    } else if (state == PropertyState.none) {
      widgetToBuild = widget.onNone.call();
    } else if (state == PropertyState.emptyList) {
      widgetToBuild = widget.onEmptyList?.call() ?? const SizedBox.shrink();
    } else if (state == PropertyState.emptyMap) {
      widgetToBuild = widget.onEmptyMap?.call() ?? const SizedBox.shrink();
    } else if (state == PropertyState.listening) {
      widgetToBuild =
          widget.onListening?.call(value) ?? const SizedBox.shrink();
    } else if (state == PropertyState.error) {
      widgetToBuild = widget.onError?.call(value, error!, stackTrace!) ??
          const SizedBox.shrink();
    } else if (state == PropertyState.timeout) {
      widgetToBuild = widget.onTimeout?.call(value) ?? const SizedBox.shrink();
    } else {
      widgetToBuild = const SizedBox.shrink();
    }

    return widgetToBuild;
  }
}

// class PropertyBuilder extends StatefulWidget {
//   const PropertyBuilder({
//     super.key,
//     required this.properties,
//     required this.builder,
//   });

//   final List<Property> properties;
//   final Widget Function(BuildContext context) builder;

//   @override
//   State<PropertyBuilder> createState() => PropertyBuilderState();
// }

// class PropertyBuilderState extends State<PropertyBuilder> {
//   late List<StreamSubscription> _subscriptions;

//   @override
//   void initState() {
//     _subscriptions = widget.properties.map((property) {
//       return property._controller.stream.listen((event) {
//         setState(() {});
//       });
//     }).toList();
//     super.initState();
//   }

//   @override
//   void dispose() {
//     for (Property element in widget.properties) {
//       element.dispose();
//     }
//     for (var subscription in _subscriptions) {
//       subscription.cancel();
//     }
//     super.dispose();
//   }

//   @override
//   Widget build(BuildContext context) {
//     return widget.builder(context);
//   }
// }

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
