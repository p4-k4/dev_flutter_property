import 'package:flutter_test/flutter_test.dart';
import 'package:property/property.dart';
import 'dart:async';
import 'package:fpdart/fpdart.dart';

void main() {
  group('[Property.state]', () {
    test('Initial state is PropertyState.none', () {
      final property = Property<int>(() => const Option.none());
      expect(property.state, PropertyState.none);
    });

    test('Update method with valid value updates state to PropertyState.some',
        () {
      final property = Property<int>(() => const Option.none());
      property.update(
        ifSome: (value) => Some(value + 1),
        ifNone: () => const Some(1),
      );
      expect(property.value, const Some(1));
      expect(property.state, PropertyState.some);
    });

    test('Update method with error updates state to PropertyState.error', () {
      final property = Property<int>(() => const Option.none());
      try {
        property.update(
          ifSome: (value) => throw Exception('Error updating value'),
          ifNone: () => throw Exception('Error updating value'),
        );
      } catch (_) {}
      expect(property.state, PropertyState.error);
    });

    test('Resetting property resets the state to PropertyState.none', () {
      final property = Property<int>(() => const Option.none());
      property.update(
        ifSome: (value) => Some(value + 1),
        ifNone: () => const Some(1),
      );
      property.resetToNone();

      expect(property.state, PropertyState.none);
    });

    test('Subscribe to stream updates state to PropertyState.some on receiving events', () async {
      final property = Property<int>(() => const Option.none());
      final streamController = StreamController<Option<int>>();
      property.subscribeToStream(stream: streamController.stream);

      streamController.add(const Some(1));
      await Future.delayed(const Duration(milliseconds: 100));

      expect(property.state, PropertyState.some);
      expect(property.value, const Some(1));

      streamController.close();
    });
  });
}
