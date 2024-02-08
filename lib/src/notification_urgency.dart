final class NotificationUrgency {
  static const lessUrgent = NotificationUrgency._('lessUrgent', 1);
  static const moreUrgent = NotificationUrgency._('moreUrgent', 3);
  static const urgent = NotificationUrgency._('urgent', 2);

  final String _label;
  final int _value;

  const NotificationUrgency._(this._label, this._value);

  bool operator <(NotificationUrgency other) => _value < other._value;

  bool operator >(NotificationUrgency other) => _value < other._value;

  int compareTo(NotificationUrgency other) => _value.compareTo(other._value);

  @override
  String toString() => _label;
}
