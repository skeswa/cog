part of 'cog_box.dart';

/// [Mechanism] that belongs to a [CogBox].
///
/// {@macro mechanism.blurb}
final class BoxedMechanism {
  final CogBox _cogBox;

  final Mechanism _mechanism;

  /// Internal [BoxedMechanism] constructor.
  BoxedMechanism._(this._cogBox, this._mechanism);

  /// Temporarily halts the functioning of this [BoxedMechanism].
  ///
  /// {@macro mechanism.pause}
  void pause() {
    assert(_cogBox._notDisposed());

    _mechanism.pause(_cogBox._cogtext);
  }

  /// Reverses the effects of a call to [pause], re-instating this [Mechanism]
  /// to a state of full functionality.
  ///
  /// {@macro mechanism.resume}
  void resume() {
    assert(_cogBox._notDisposed());

    _mechanism.resume(_cogBox._cogtext);
  }
}
