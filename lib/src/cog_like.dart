part of 'cog.dart';

/// Any entity that behaves like a [Cog].
///
/// This `interface` is implemented by [Cog] and its subclasses. It is also
/// implemented by convenience wrappers around [Cog] that add or tweak
/// functionality.
///
/// The Cog runtime API prefers to deal with [CogLike] instead of [Cog] to be
/// maximally compatible.
abstract interface class CogLike<ValueType, SpinType> {
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  });

  /// Uniquely identifies this Cog relative to all other Cogs registered with
  /// the presiding [CogRegistry].
  ///
  /// Despite being specified as a getter, [ordinal] is expected to never change
  /// and **must** only identify this Cog.
  CogOrdinal get ordinal;

  Spin<SpinType>? get spin;
}
