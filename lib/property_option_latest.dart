
library property;

import 'dart:async';
import 'package:async/async.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:flutter/widgets.dart';

enum LogLevel {
  state,
  dispose,
  init,
  value,
  error,
  all,
  update,
  build,
  compact
}

const List<LogLevel> kDebugLogLevels = [LogLevel.all];

void log(
  String message, {
  LogLevel level = LogLevel.all,
}) {
  List<LogLevel> allowedLogLevels;

  if (kDebugLogLevels.contains(LogLevel.all) && kDebugLogLevels.length == 1) {
    allowedLogLevels = [
      LogLevel.state,
      LogLevel.dispose,
      LogLevel.init,
      LogLevel.value,
      LogLevel.error,
      LogLevel.update,
      LogLevel.build,
    ];
  } else {
    allowedLogLevels =
        kDebugLogLevels.where((logLevel) => logLevel != LogLevel.all).toList();
  }

  if (!allowedLogLevels.contains(level)) {
    return;
  }

  final formattedMessage =
      '[Property] [${level.toString().split('.').last}] $message';

  debugPrint(formattedMessage);
}

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
    this.id = 'Uninitialised',
  }) {
    log('Initialising controller', level: LogLevel.init);
    _controller = StreamController<PropertyEvent>.broadcast();
    _state = PropertyState.none;
    id = id == 'No ID' ? hashCode.toString() : id;
  }

  late String id;

  Option<T> _value = Option<T>.none();

  DefaultValueSupplier<Option> init;

  Object? _error;
  StackTrace? _stackTrace;

  late PropertyState _state;

  final bool autoDispose;
  final bool autoDisposeSubscription;
  final bool resetOnDispose;

  StreamSubscription? _streamSubscription;
  late StreamController<PropertyEvent> _controller;

  bool get isNone => _value.isNone();
  bool get isSome => _value.isSome();

  Option<T> get value => _value;
  PropertyState get state => _state;
  Object? get error => _error;
  StackTrace? get stackTrace => _stackTrace;

  CancelableOperation? _cancelableOperation;

  void initController() {
    if (_controller.isClosed) {
      log('Initialising controller on ${id}', level: LogLevel.init);
      _controller = StreamController<PropertyEvent>.broadcast();
    }
  }

  void resetToNone({
    bool rebuild = true,
  }) {
    _value = const None();
    _state = PropertyState.none;
    rebuild ? _controller.add(PropertyEvent.rebuild) : null;
    log(state.name, level: LogLevel.state);
  }

  Future<void> _applyDebounce(
      Duration debounceDuration,
      void Function()? onDebounce,
      void Function()? afterDebounce,
      FutureOr<Option<T>> Function(Option<T> value) updateAction) async {
    _state = PropertyState.debouncing;
    log(state.name, level: LogLevel.state);
    _controller.add(PropertyEvent.rebuild);
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
      FutureOr<Option<T>> Function(Option<T> value) updateAction) async {
    _state = PropertyState.throttled;
    log(state.name, level: LogLevel.state);
    _controller.add(PropertyEvent.rebuild);
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

  FutureOr<void> update({
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
  }) {
    FutureOr<Option<T>> updateAction(Option<T> value) {
      return value.match(
        () => ifNone(),
        (v) => ifSome(v),
      );
    }

    if (debounceDuration != null) {
      _applyDebounce(
        debounceDuration,
        onDebounce,
        afterDebounce,
        updateAction,
      );
    } else if (throttleDuration != null) {
      _applyThrottle(
        throttleDuration,
        beforeThrottle,
        onThrottle,
        afterThrottle,
        immediateTiming,
        updateAction,
      );
    } else {
      _updateInternal(updateAction);
    }
  }

  FutureOr<void> _updateInternal(
    FutureOr<Option<T>> Function(Option<T> value) newValue,
  ) {
    if (_cancelableOperation != null) {
      _cancelableOperation!.cancel();
      _cancelableOperation = null;
    }
    try {
      _error = null;
      _stackTrace = null;

      // Prevent spammy rebuilds on an already waiting state
      if (_state != PropertyState.waiting) {
        _state = PropertyState.waiting;
        log(state.name, level: LogLevel.state);
        _controller.add(PropertyEvent.rebuild);
      }

      FutureOr<Option<T>> result = newValue.call(_value);

      if (result is Future<Option<T>>) {
        _cancelableOperation = CancelableOperation<Option<T>>.fromFuture(
          result,
          onCancel: () {
            log(
              'Canceled previous Future operation',
              level: LogLevel.update,
            );
          },
        );

        _cancelableOperation!.value.then((resolvedValue) {
          _value = resolvedValue;
          _updateState();
          _controller.add(PropertyEvent.rebuild);
        }).catchError((e, s) {
          _state = PropertyState.error;
          log(state.name, level: LogLevel.state);
          _error = e;
          _stackTrace = s;
        });

        _cancelableOperation!.value.whenComplete(() {
          _cancelableOperation = null;
          log(
            'Async operation completed',
            level: LogLevel.update,
          );
        });
      } else {
        if (_cancelableOperation?.isCanceled != true) {
          _value = result;
          log(
            'Sync operation completed',
            level: LogLevel.update,
          );
          _updateState();
          _controller.add(PropertyEvent.rebuild);
        }
      }
    } catch (error, stackTrace) {
      _state = PropertyState.error;
      log(state.name, level: LogLevel.state);
      _error = error;
      _stackTrace = stackTrace;
    }
    value.match(
        () => null, (t) => log('Updated value to: $t', level: LogLevel.update));
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
    log(state.name, level: LogLevel.state);
  }

  void subscribeToStream({required Stream<Option<T>> stream}) {
    _streamSubscription = stream.listen(
      (newValue) {
        _value = newValue;
        _updateState();
        _controller.add(PropertyEvent.rebuild);
      },
      onError: (error, stackTrace) {
        _state = PropertyState.error;
        log(state.name, level: LogLevel.state);
        _error = error;
        _stackTrace = stackTrace;
        _controller.add(PropertyEvent.rebuild);
      },
    );
  }

  void pause() {
    _streamSubscription?.pause();
    _state = PropertyState.streamPaused;
    log(state.name, level: LogLevel.state);
    _controller.add(PropertyEvent.rebuild);
  }

  void resume() {
    _streamSubscription?.resume();
    _state = PropertyState.listening;
    log(state.name, level: LogLevel.state);
    _controller.add(PropertyEvent.rebuild);
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
      _controller.close();
      log('Disposing Controller on ${hashCode}', level: LogLevel.dispose);
    }
    if (autoDisposeSubscription) {
      log('Disposing StreamSubscription on ${hashCode}',
          level: LogLevel.dispose);
      _streamSubscription?.cancel();
    }
  }

  R match<R>({
    required R Function(T value) onSome,
    required R Function() onNone,
    R Function()? onWaiting,
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
    Widget Function(Option<T> value)? onWaiting,
    Widget Function(Option<T> value)? onEmptyList,
    Widget Function(Option<T> value)? onEmptyMap,
    Widget Function(T value)? onListening,
    Widget Function(Option<T> value, Object error, StackTrace stackTrace)?
        onError,
    Widget Function(Option<T> value)? onTimeout,
    Widget Function(Option<T> value)? onDebounce,
    Widget Function(Option<T> value)? onThrottle,
    bool skipWaiting = false,
    bool skipDebounce = false,
    bool skipThrottle = false,
  }) {
    return PropertyWidget<T>(
      key: ValueKey(hashCode),
      property: this,
      onSome: (v) => value.match(() => onNone(), (t) => onSome(t)),
      onNone: () => onNone(),
      onWaiting: (v) => value.match(
        () => onWaiting?.call(value) ?? fallback,
        (t) => onWaiting?.call(value) ?? fallback,
      ),
      onEmptyList: (v) => value.match(
        () => onEmptyList?.call(value) ?? fallback,
        (t) => onEmptyList?.call(value) ?? fallback,
      ),
      onEmptyMap: (v) => value.match(
        () => onEmptyMap?.call(value) ?? fallback,
        (t) => onEmptyMap?.call(value) ?? fallback,
      ),
      onListening: (v) => value.match(
        () => onWaiting?.call(value) ?? fallback,
        (t) => onListening?.call(t) ?? fallback,
      ),
      onError: (v, error, stackTrace) => value.match(
        () => onError?.call(value, error, stackTrace) ?? fallback,
        (t) => onError?.call(value, error, stackTrace) ?? fallback,
      ),
      onTimeout: (v) => value.match(
        () => onTimeout?.call(value) ?? fallback,
        (t) => onTimeout?.call(value) ?? fallback,
      ),
      onDebounce: (v) => value.match(
        () => onDebounce?.call(value) ?? fallback,
        (t) => onDebounce?.call(value) ?? fallback,
      ),
      onThrottle: (v) => value.match(
        () => onThrottle?.call(value) ?? fallback,
        (t) => onThrottle?.call(value) ?? fallback,
      ),
      skipWaiting: skipWaiting,
      skipDebounce: skipDebounce,
      skipThrottle: skipThrottle,
    );
  }

  StreamSubscription<PropertyEvent>? _onSubscription;

  void on({
    required void Function(T value) onSome,
    void Function()? onNone,
    void Function()? onWaiting,
    void Function()? onEmptyList,
    void Function()? onEmptyMap,
    void Function()? onListening,
    void Function(Option<T> event)? onStreamEvent,
    void Function()? onStreamPaused,
    void Function(T value, Object error, StackTrace stackTrace)? onError,
    void Function()? onTimeout,
    void Function(T value)? onDebounce,
    void Function(T value)? onThrottle,
  }) {
    _onSubscription?.cancel();
    _onSubscription = _controller.stream.listen(
      (event) {
        switch (state) {
          case PropertyState.some:
            return value.match(
                () => const Option.none(), (t) => onSome.call(t));
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
            return onStreamEvent?.call(_value);
          case PropertyState.streamPaused:
            return onStreamPaused?.call();
          case PropertyState.error:
            return value.match(
                () => const Option.none(),
                (t) => onError?.call(t, _error ?? Object(),
                    _stackTrace ?? StackTrace.fromString('')));
          case PropertyState.timeout:
            return onTimeout?.call();
          case PropertyState.debouncing:
            return value.match(
                () => const Option.none(), (t) => onDebounce?.call(t));
          case PropertyState.throttled:
            return value.match(
                () => const Option.none(), (t) => onThrottle?.call(t));
        }
      },
    );
  }
}

class CancellationToken {
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
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
    this.fallback = const SizedBox.shrink(),
  }) : super(key: key);

  final Property<T> property;
  final Widget Function() onNone;
  final Widget Function(Option<T> value)? onEmptyMap;
  final Widget Function(Option<T> value)? onEmptyList;
  final Widget Function(T value) onSome;
  final Widget Function(Option<T> value)? onWaiting;
  final Widget Function(Option<T> value)? onListening;
  final Widget Function(Option<T> value, Object error, StackTrace stackTrace)?
      onError;
  final Widget Function(Option<T> value)? onTimeout;
  final Widget Function(Option<T> value)? onDebounce;
  final Widget Function(Option<T> value)? onThrottle;
  final bool skipWaiting;
  final bool skipDebounce;
  final bool skipThrottle;
  final Widget fallback;

  @override
  PropertyWidgetState<T> createState() => PropertyWidgetState<T>();
}

class PropertyWidgetState<T extends Object> extends State<PropertyWidget<T>> {
  late StreamSubscription<PropertyEvent> _subscription;

  @override
  void initState() {
    widget.property.initController();
    _subscription = widget.property._controller.stream.listen((event) {
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
      _subscription = widget.property._controller.stream.listen((event) {
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
    Widget widgetToBuild;
    PropertyState state = widget.property.state;
    Object? error = widget.property.error;
    StackTrace? stackTrace = widget.property.stackTrace;

    if (state == PropertyState.waiting) {
      widgetToBuild =
          widget.onWaiting?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.some) {
      widgetToBuild = widget.property.value.match(
        () => widget.fallback,
        (t) => widget.onSome.call(t),
      );
    } else if (state == PropertyState.none) {
      widgetToBuild = widget.onNone.call();
    } else if (state == PropertyState.emptyList) {
      widgetToBuild =
          widget.onEmptyList?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.emptyMap) {
      widgetToBuild =
          widget.onEmptyMap?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.listening) {
      widgetToBuild =
          widget.onListening?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.error) {
      widgetToBuild =
          widget.onError?.call(widget.property.value, error!, stackTrace!) ??
              widget.fallback;
    } else if (state == PropertyState.timeout) {
      widgetToBuild =
          widget.onTimeout?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.debouncing) {
      widgetToBuild =
          widget.onDebounce?.call(widget.property.value) ?? widget.fallback;
    } else if (state == PropertyState.throttled) {
      widgetToBuild =
          widget.onDebounce?.call(widget.property.value) ?? widget.fallback;
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
      return property._controller.stream.listen((event) {
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
