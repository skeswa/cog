part of 'cog_state.dart';

/// Conveys subsequent values of [AutomaticCogState].
///
/// [AutomaticCogStateConveyor] is the "engine" of its [AutomaticCogState],
/// precisely scheduling and facilitating value calculation based on the
/// configuration of the underlying [AutomaticCog].
///
/// When a new value is calculated for [_cogState], this
/// [AutomaticCogStateConveyor] invokes [AutomaticCogState._onNextValue] with
/// the appropriate parameters.
sealed class AutomaticCogStateConveyor<ValueType, SpinType> {
  final AutomaticCogState<ValueType, SpinType> _cogState;

  /// Creates a new [AutomaticCogStateConveyor] for the specified [cogState].
  factory AutomaticCogStateConveyor({
    required AutomaticCogState<ValueType, SpinType> cogState,
  }) {
    final invocationFrame = AutomaticCogInvocationFrame(
      cogState: cogState,
      ordinal: _initialInvocationFrameOrdinal,
    );

    final invocation = invocationFrame.open();

    return invocation is Future<ValueType>
        ? AsyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocation: invocation,
            invocationFrame: invocationFrame,
          )
        : SyncAutomaticCogStateConveyor._(
            cogState: cogState,
            invocationFrame: invocationFrame,
            invocationResult: invocation,
          );
  }

  /// Internal constructor used by subclasses of [AutomaticCogStateConveyor].
  AutomaticCogStateConveyor._({
    required AutomaticCogState<ValueType, SpinType> cogState,
  }) : _cogState = cogState;

  /// Attempts to begin the calculation of [_cogState]'s next value.
  ///
  /// [shouldForce] is `true` if the next value should be calculated and applied
  /// to [_cogState] even if it might nomally seem unnecessary due to caching,
  /// scheduling, or unchanged dependencies - defaults to `false`.
  void convey({bool shouldForce = false});

  /// Calculates [_cogState]'s initial value.
  void init();

  /// `true` if the [AutomaticCogState] using this [AutomaticCogStateConveyor]
  /// should eagerly begin the calculation of its next value whenever it becomes
  /// stale.
  bool get isEager;

  /// `true` if the [AutomaticCogState] using this [AutomaticCogStateConveyor]
  /// should mark its followers as potentially stale when it is marked as
  /// potentially stale.
  bool get propagatesPotentialStaleness;
}

/// Ordinal used for the initial [AutomaticCogInvocationFrame] created by a
/// [AutomaticCogStateConveyor].
const _initialInvocationFrameOrdinal = 1;
