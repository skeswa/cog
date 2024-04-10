part of 'cog_box.dart';

final class BoxedMechanism {
  final CogBox _cogBox;

  var _isDisposed = false;

  final Mechanism _mechanism;

  BoxedMechanism._(this._cogBox, this._mechanism);

  void pause() {
    assert(_notDisposed());

    _mechanism.pause(_cogBox._cogtext);
  }

  void resume() {
    assert(_notDisposed());

    _mechanism.resume(_cogBox._cogtext);
  }

  bool _notDisposed() {
    if (_isDisposed) {
      throw StateError('This $this has been disposed');
    }

    return true;
  }
}
