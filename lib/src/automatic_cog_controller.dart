part of 'cog.dart';

abstract interface class AutomaticCogController<ValueType, SpinType> {
  ValueType get curr;

  CurrValueType currOr<CurrValueType extends ValueType>(
    CurrValueType fallback,
  );

  LinkedCogValueType link<LinkedCogValueType, LinkedCogSpinType>(
    Cog<LinkedCogValueType, LinkedCogSpinType> cog, {
    LinkedCogSpinType? spin,
  });

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

  SpinType get spin;
}

typedef LinkNonCogInit<NonCogType, ValueType> = ValueType Function(
  NonCogType nonCog,
);

typedef LinkNonCogSubscribe<NonCogType, SubscriptionType, ValueType>
    = SubscriptionType Function(
  NonCogType nonCog,
  void Function(ValueType) onNextValue,
);

typedef LinkNonCogUnsubscribe<NonCogType, SubscriptionType, ValueType> = void
    Function(
  NonCogType nonCog,
  void Function(ValueType) onNextValue,
  SubscriptionType subscription,
);
