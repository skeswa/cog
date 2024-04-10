part of 'cog_box.dart';

final class BoxedMechanism {
  final CogBox _cogBox;

  final Mechanism _mechanism;

  BoxedMechanism._(this._cogBox, this._mechanism);

  void pause() {
    _mechanism.pause(_cogBox._cogtext);
  }

  void resume(Cogtext cogtext) {
    _mechanism.resume(_cogBox._cogtext);
  }
}
