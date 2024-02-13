final class NotificationUrgency {
  static const immediate = NotificationUrgency._('immediate', 0);
  static const lessUrgent = NotificationUrgency._('lessUrgent', 2);
  static const moreUrgent = NotificationUrgency._('moreUrgent', 4);
  static const urgent = NotificationUrgency._('urgent', 3);

  final String _label;
  final int _level;

  const NotificationUrgency._(this._label, this._level);

  bool operator <(NotificationUrgency other) => _level < other._level;

  int compareTo(NotificationUrgency other) => _level.compareTo(other._level);

  @override
  String toString() => _label;
}
