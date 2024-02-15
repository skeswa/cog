part of 'cog_state.dart';

final class CogStateListeningPost<ValueType, SpinType> {
  final CogState<ValueType, SpinType, Cog<ValueType, SpinType>> cogState;
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
    required this.cogState,
    required CogStateListeningPostDeactivationCallback onDeactivation,
    required Priority priority,
  })  : _priority = priority,
        _onDeactivation = onDeactivation {
    cogState.runtime.logging.debug(
      cogState,
      'created new listening post',
    );
    cogState.runtime.telemetry
        .recordCogStateListeningPostCreation(cogState.ordinal);
  }

  Future<void> dispose() {
    cogState.runtime.logging.debug(
      cogState,
      'disposing listening post',
    );

    _isActive = false;

    return _streamController.close();
  }

  bool get isActive => _isActive;

  void maybeNotify() {
    if (!_isActive) {
      cogState.runtime.logging.debug(
        cogState,
        'skipping notification due to inactivity',
      );

      return;
    }

    final revision = cogState.revision;

    if (revision == _revisionOfLastNotification) {
      cogState.runtime.logging.debug(
        cogState,
        'skipping notification due to no revision change',
      );

      return;
    }

    cogState.runtime.logging.debug(
      cogState,
      'notifying listeners of value changes',
    );

    _streamController.add(cogState.evaluate());

    _revisionOfLastNotification = revision;

    cogState.runtime.telemetry
        .recordCogStateChangeNotification(cogState.ordinal);
  }

  Priority get priority => _priority;

  set priority(Priority value) {
    if (value == _priority) {
      return;
    }

    cogState.runtime.logging.debug(
      cogState,
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
