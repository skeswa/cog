part of 'cog_state.dart';

final class CogStateListeningPost<ValueType, SpinType> {
  final CogState<ValueType, SpinType, Cog<ValueType, SpinType>> _cogState;
  var _isActive = false;
  final CogStateListeningPostDeactivationCallback _onDeactivation;
  Priority _priority;
  CogStateRevision? _revisionOfLastNotification;
  late final _streamController = StreamController<ValueType>.broadcast(
    sync: true,
    onCancel: _onLastListenerDisconnected,
    onListen: _onFirstListenerConnected,
  );

  CogStateListeningPost({
    required CogState<ValueType, SpinType, Cog<ValueType, SpinType>> cogState,
    required CogStateListeningPostDeactivationCallback onDeactivation,
    required Priority priority,
  })  : _cogState = cogState,
        _priority = priority,
        _onDeactivation = onDeactivation {
    _cogState._runtime.logging.debug(
      _cogState,
      'created new listening post',
    );
    _cogState._runtime.telemetry
        .recordCogStateListeningPostCreation(_cogState.ordinal);
  }

  Future<void> dispose() {
    _cogState._runtime.logging.debug(
      _cogState,
      'disposing listening post',
    );

    _isActive = false;

    return _streamController.close();
  }

  bool get isActive => _isActive;

  void maybeNotify() {
    if (!_isActive) {
      _cogState._runtime.logging.debug(
        _cogState,
        'skipping notification due to inactivity',
      );

      return;
    }

    final revision = _cogState.revision;

    if (revision == _revisionOfLastNotification) {
      _cogState._runtime.logging.debug(
        _cogState,
        'skipping notification due to no revision change',
      );

      return;
    }

    _cogState._runtime.logging.debug(
      _cogState,
      'notifying listeners of value changes',
    );

    _streamController.add(_cogState.evaluate());

    _revisionOfLastNotification = revision;

    _cogState._runtime.telemetry
        .recordCogStateChangeNotification(_cogState.ordinal);
  }

  CogStateOrdinal get ordinal => _cogState.ordinal;

  Priority get priority => _priority;

  set priority(Priority value) {
    if (value == _priority) {
      return;
    }

    _cogState._runtime.logging.debug(
      _cogState,
      'changing notification priority to',
      value,
    );

    _priority = value;
  }

  Stream<ValueType> get valueChanges => _streamController.stream;

  void _onFirstListenerConnected() {
    _isActive = true;
  }

  void _onLastListenerDisconnected() {
    _isActive = false;

    _onDeactivation();
  }
}
