final class NotificationUrgency {
  static const mostUrgent = NotificationUrgency._(3);
  static const notUrgent = NotificationUrgency._(1);
  static const urgent = NotificationUrgency._(2);

  final int _value;

  const NotificationUrgency._(this._value);

  bool operator <(NotificationUrgency other) => _value < other._value;

  bool operator >(NotificationUrgency other) => _value < other._value;

  int compareTo(NotificationUrgency other) => _value.compareTo(_value);
}
