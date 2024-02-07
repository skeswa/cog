part of 'cog_value.dart';

final class CogValueListeningPost<ValueType, SpinType> {
  final CogValue<ValueType, SpinType, Cog<ValueType, SpinType>> _cogValue;
  var _isActive = false;
  final CogValueListeningPostDeactivationCallback _onDeactivation;
  late final _streamController = StreamController<ValueType>.broadcast(
    onCancel: _onLastListenerDisconnected,
    onListen: _onFirstListenerConnected,
  );
  NotificationUrgency _urgency;

  CogValueListeningPost({
    required CogValue<ValueType, SpinType, Cog<ValueType, SpinType>> cogValue,
    required CogValueListeningPostDeactivationCallback onDeactivation,
    required NotificationUrgency urgency,
  })  : _cogValue = cogValue,
        _onDeactivation = onDeactivation,
        _urgency = urgency {
    _cogValue.runtime.telemetry
        .recordCogValueListeningPostCreation(_cogValue.ordinal);
  }

  void dispose() {
    _cogValue.runtime.logging.debug(
      _cogValue,
      'disposing listening post due to inactivity',
    );

    _isActive = false;
    _streamController.close();
  }

  bool get isActive => _isActive;

  void maybeNotify() {
    if (!_isActive) {
      return;
    }

    final initialRevision = _cogValue._revision;
    final latestRevision = _cogValue.revision;

    if (initialRevision == latestRevision) {
      return;
    }

    _cogValue.runtime.logging.debug(
      _cogValue,
      'notifying listeners of value changes',
    );

    _streamController.add(_cogValue._value);

    _cogValue.runtime.telemetry
        .recordCogValueChangeNotification(_cogValue.ordinal);
  }

  NotificationUrgency get urgency => _urgency;

  set urgency(NotificationUrgency value) {
    if (value == _urgency) {
      return;
    }

    _cogValue.runtime.logging.debug(
      _cogValue,
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
