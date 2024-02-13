part of 'cog_state.dart';

final class CogStateListeningPost<ValueType, SpinType> {
  final CogState<ValueType, SpinType, Cog<ValueType, SpinType>> cogState;
  var _isActive = false;
  final CogStateListeningPostDeactivationCallback _onDeactivation;
  late final _streamController = StreamController<ValueType>.broadcast(
    sync: true,
    onCancel: _onLastListenerDisconnected,
    onListen: _onFirstListenerConnected,
  );
  CogStateRevision? _revisionOfLastNotification;
  NotificationUrgency _urgency;

  CogStateListeningPost({
    required this.cogState,
    required CogStateListeningPostDeactivationCallback onDeactivation,
    required NotificationUrgency urgency,
  })  : _onDeactivation = onDeactivation,
        _urgency = urgency {
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

    _streamController.add(cogState._value);

    _revisionOfLastNotification = revision;

    cogState.runtime.telemetry
        .recordCogStateChangeNotification(cogState.ordinal);
  }

  NotificationUrgency get urgency => _urgency;

  set urgency(NotificationUrgency value) {
    if (value == _urgency) {
      return;
    }

    cogState.runtime.logging.debug(
      cogState,
      'changing notification urgency to',
      value,
    );

    _urgency = value;
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
