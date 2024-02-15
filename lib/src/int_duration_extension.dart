extension IntDurationExtension on int {
  Duration get days => Duration(days: this);
  Duration get hours => Duration(hours: this);
  Duration get microseconds => Duration(microseconds: this);
  Duration get milliseconds => Duration(milliseconds: this);
  Duration get minutes => Duration(minutes: this);
  Duration get seconds => Duration(seconds: this);
}
