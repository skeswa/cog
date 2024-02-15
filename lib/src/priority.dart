final class Priority {
  static const asap = Priority._('asap', 0);
  static const low = Priority._('low', 2);
  static const high = Priority._('high', 4);
  static const normal = Priority._('normal', 3);

  final String _label;
  final int _level;

  const Priority._(this._label, this._level);

  bool operator <(Priority other) => _level < other._level;

  int compareTo(Priority other) => _level.compareTo(other._level);

  @override
  String toString() => _label;
}
