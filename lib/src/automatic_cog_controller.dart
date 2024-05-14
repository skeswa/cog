part of 'cog.dart';

/// Allows the closure that defines an automatic [Cog] to access [Cog] state and
/// establish persist links to dependencies, [Cog] or otherwise.
abstract interface class AutomaticCogController<ValueType, SpinType> {
  /// Reads the current value of this [Cog], throwing if this [Cog] does not yet
  /// have a value.
  ValueType get curr;

  /// Returns the current value of this [Cog], instead returning [fallback] if
  /// this [Cog] does not yet have a value.
  CurrValueType currOr<CurrValueType extends ValueType>(
    CurrValueType fallback,
  );

  /// Returns the current value from the specified [spin] of the specified
  /// [cog], establishing dependency on the next value emission.
  ///
  /// As long as each invocation of this automatic [Cog]'s defintion re-invokes
  /// [link] with this pair of [cog] and [spin], this [Cog] will remain
  /// "subscribed" to future updates. Being "subscribed" means that this [Cog]
  /// will invalidate its cached value whenever the specified [spin] of the
  /// specified [cog] changes value. If a subsequent invocation of this
  /// automatic [Cog]'s defintion does not re-invoke [link] with this pair of
  /// [cog] and [spin], this [Cog] "unsubscribes" from future updates.
  LinkedCogValueType link<LinkedCogValueType, LinkedCogSpinType>(
    CogLike<LinkedCogValueType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  });

  /// Returns the current value of this automatic [Cog]'s subscription to
  /// [nonCog], creating a new subscription if one does not already exist.
  ///
  /// As long as each invocation of this automatic [Cog]'s defintion re-invokes
  /// [linkNonCog] with the specified [nonCog], this [Cog] will remain
  /// "subscribed" to future updates. Being "subscribed" means that this [Cog]
  /// will invalidate its cached value whenever the specified [nonCog] changes
  /// value. If a subsequent invocation of this automatic [Cog]'s defintion does
  /// not re-invoke [linkNonCog] with specified [nonCog], this [Cog]
  /// "unsubscribes" from future updates.
  ///
  /// * [nonCog] is the non-[Cog] long-lived, value-emitting object being this
  ///   automatic [Cog] should subscribe
  /// * [init] returns the value of [nonCog] that should be used before [nonCog]
  ///   emits its first value
  /// * [subscribe] creates and returns a new subscription to [nonCog] value
  ///   changes
  /// * [unsubscribe] terminates an existing subscription to [nonCog] value
  ///   changes
  NonCogValueType linkNonCog<NonCogType extends Object, NonCogSubscriptionType,
      NonCogValueType>(
    NonCogType nonCog, {
    required LinkNonCogInit<NonCogType, NonCogValueType> init,
    required LinkNonCogSubscribe<NonCogType, NonCogSubscriptionType,
            NonCogValueType>
        subscribe,
    required LinkNonCogUnsubscribe<NonCogType, NonCogSubscriptionType,
            NonCogValueType>
        unsubscribe,
  });

  /// Returns the spin of this automatic [Cog], throwing if no such spin exists.
  ///
  /// {@macro cog_like.spin}
  SpinType get spin;
}

/// Returns the initial value of this automatic [Cog]'s subscription to
/// [nonCog].
typedef LinkNonCogInit<NonCogType, ValueType> = ValueType Function(
  NonCogType nonCog,
);

/// Creates and returns a new subscription to [nonCog] value changes for this
/// automatic [Cog].
///
/// [onNextValue] is a callback function that gets invoked with [nonCog]'s
/// latest value whenever it changes.
typedef LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
    = SubscriptionType Function(
  NonCogType nonCog,
  void Function(ValueType) onNextValue,
);

/// Terminates this automatic [Cog]'s [subscription] to [nonCog] value changes.
///
/// * [onNextValue] is a callback function that got invoked with [nonCog]'s
///   latest value whenever it changed
/// * [subscription] is the subscription object returned by the corresponding
///   `subscribe` function
typedef LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType> = void
    Function(
  NonCogType nonCog,
  void Function(ValueType) onNextValue,
  SubscriptionType subscription,
);
