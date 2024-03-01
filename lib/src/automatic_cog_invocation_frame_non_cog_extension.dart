part of 'cog_state.dart';

final class AutomaticCogInvocationFrameNonCogExtension {
  AutomaticCogInvocationFrameNonCogExtension? _base;

  final AutomaticCogState _cogState;

  final _linkedNonCogIndex = <dynamic, _LinkedNonCog>{};

  AutomaticCogInvocationFrameNonCogExtension({
    required AutomaticCogState cogState,
  }) : _cogState = cogState;

  void abandon() {
    _cogState._runtime.logging
        .debug(_cogState, 'abandoning non-cog frame extension');

    final base = _base;

    if (base == null) {
      return;
    }

    for (final linkedNonCog in _linkedNonCogIndex.values) {
      linkedNonCog.unsubscribe();
    }

    _base = null;
  }

  void close() {
    _cogState._runtime.logging
        .debug(_cogState, 'clsoing non-cog frame extension');

    final base = _base;

    if (base == null) {
      return;
    }

    final previouslyLinkedNonCogs = base._linkedNonCogIndex.values;

    for (final previouslyLinkedNonCog in previouslyLinkedNonCogs) {
      final wasPreviouslyLinkedNonCogNotRelinked =
          !_linkedNonCogIndex.containsKey(previouslyLinkedNonCog._nonCog);

      if (wasPreviouslyLinkedNonCogNotRelinked) {
        previouslyLinkedNonCog.unsubscribe();
      }
    }

    _base = null;
  }

  ValueType linkNonCog<NonCogType, SubscriptionType, ValueType>({
    required LinkNonCogInit<NonCogType, ValueType> init,
    required NonCogType nonCog,
    required LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
        unsubscribe,
  }) {
    var existingLinkedNonCog = _linkedNonCogIndex[nonCog];

    if (existingLinkedNonCog == null) {
      existingLinkedNonCog = _base?._linkedNonCogIndex[nonCog];

      if (existingLinkedNonCog != null &&
          existingLinkedNonCog._nonCog == nonCog) {
        _linkedNonCogIndex[nonCog] = existingLinkedNonCog;

        return existingLinkedNonCog.value as ValueType;
      }
    }

    if (existingLinkedNonCog != null &&
        existingLinkedNonCog._nonCog == nonCog) {
      final existingLinkedNonCogValue = existingLinkedNonCog.value as ValueType;

      return existingLinkedNonCogValue;
    }

    final newLinkedNonCog = _LinkedNonCog(
      cogState: _cogState,
      init: init,
      nonCog: nonCog,
      subscribe: subscribe,
      unsubscribe: unsubscribe,
    )..subscribe();

    final linkedNonCogValue = newLinkedNonCog.value;

    _linkedNonCogIndex[nonCog] = newLinkedNonCog;

    return linkedNonCogValue;
  }

  void open({AutomaticCogInvocationFrameNonCogExtension? base}) {
    _cogState._runtime.logging
        .debug(_cogState, 'opening non-cog frame extension');

    _base = base;
  }
}

final class _LinkedNonCog<NonCogType, SubscriptionType, ValueType> {
  final AutomaticCogState _cogState;
  final NonCogType _nonCog;
  final LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType> _subscribe;
  final LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
      _unsubscribe;
  SubscriptionType? _subscription;
  ValueType _value;

  _LinkedNonCog({
    required AutomaticCogState cogState,
    required LinkNonCogInit<NonCogType, ValueType> init,
    required NonCogType nonCog,
    required LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType>
        unsubscribe,
  })  : _cogState = cogState,
        _nonCog = nonCog,
        _subscribe = subscribe,
        _unsubscribe = unsubscribe,
        _value = init(nonCog);

  void subscribe() {
    if (_subscription != null) {
      return;
    }

    _cogState._runtime.logging.debug(
      _cogState,
      'subscribing to non-cog',
      _nonCog,
    );

    _subscription = _subscribe(_nonCog, _onNextValue);
  }

  void unsubscribe() {
    final subscription = _subscription;

    if (subscription == null) {
      return;
    }

    _cogState._runtime.logging.debug(
      _cogState,
      'unsubscribing from non-cog',
      _nonCog,
    );

    _unsubscribe(_nonCog, _onNextValue, subscription);
  }

  ValueType get value => _value;

  void _onNextValue(ValueType value) {
    _value = value;

    _cogState._onNonCogDependencyChange();
  }
}
