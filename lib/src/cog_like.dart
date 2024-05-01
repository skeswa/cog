part of 'cog.dart';

/// Describes anything that behaves like a [Cog].
///
/// This `interface` is implemented by [Cog] and its subclasses. It is also
/// implemented by convenience wrappers around [Cog] that add or tweak
/// functionality.
///
/// The Cog runtime API prefers to deal with [CogLike] instead of [Cog] to be
/// maximally compatible.
abstract interface class CogLike<ValueType, SpinType> {
  /// Creates and returns a new [CogState] that corresponds precisely with this
  /// Cog.
  ///
  /// * [ordinal] is the integer that will uniquely identify the resulting
  ///   [CogState]
  /// * [runtime] is the [CogRuntime] to which the resulting [CogState] belongs
  /// * [spin] is the optionally specifiable [Spin] value of the resulting
  ///   [CogState]
  CogState<ValueType, SpinType, Cog<ValueType, SpinType>> createState({
    required CogStateOrdinal ordinal,
    required CogRuntime runtime,
    required SpinType? spin,
  });

  /// Optional description of the state wrapped by this [Cog].
  ///
  /// This label is used by logging and development tools to make understanding
  /// the application state machine easier.
  String? get debugLabel;

  /// [Function] used to determine if two different values of this Cog should
  /// be treated as equivalent.
  ///
  /// If left unspecified, the `==` operator is used.
  CogValueComparator<ValueType>? get eq;

  /// Integer that uniquely identifies this Cog relative to all other Cogs
  /// registered with the presiding [CogRegistry].
  ///
  /// Despite being specified as a getter, [ordinal] is expected to never change
  /// and **must** only identify this Cog.
  CogOrdinal get ordinal;

  /// Optionally, defines the [SpinType] of this Cog.
  ///
  /// If [spin] is `null`, then this Cog cannot have `spin:` specified when
  /// reading from it or writing to it.
  ///
  /// {@template cog_like.spin}
  /// Cogs either wrap a single value of type [ValueType], or many values of
  /// type [ValueType] indexed by a particular [Spin]. Cogs that specify a
  /// [Spin] act sort of like a hash map, allowing listeners and other Cogs to
  /// subscribe to specific variants of a value. That way, a single Cog can have
  /// the same semantic meaning in all scenarios by allowing for contextual
  /// variation.
  ///
  /// For example, it might make sense for a Cog tracking the time to use time
  /// zone as its [Spin]. This allows a single time Cog to exist: why have
  /// different Cogs for east coast time and west coast time when you could
  /// simply use [Spin] to specify which time you're talking about? In this
  /// instance, [SpinType] might be some `TimeZone` type.
  ///
  /// Cogs that specify a [Spin] require that `spin:` is always specified when
  /// reading from, watching, or writing to that Cog.
  /// {@endtemplate}
  Spin<SpinType>? get spin;
}
