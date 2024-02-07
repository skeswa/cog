import 'cog.dart';
import 'cog_value.dart';
import 'cog_value_runtime_logging.dart';
import 'cog_value_runtime_scheduler.dart';
import 'cog_value_runtime_telemetry.dart';
import 'common.dart';
import 'notification_urgency.dart';

abstract interface class CogValueRuntime {
  CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      acquire<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
  });

  Stream<CogValueType> acquireValueChangeStream<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required NotificationUrgency urgency,
  });

  Iterable<CogValueOrdinal> ancestorOrdinalsOf(
    CogValueOrdinal cogValueOrdinal,
  );

  Iterable<CogValueOrdinal> descendantOrdinalsOf(
    CogValueOrdinal cogValueOrdinal,
  );

  CogValueRuntimeLogging get logging;

  void notifyListenersOf(CogValueOrdinal cogValueOrdinal);

  CogValue operator [](CogValueOrdinal cogValueOrdinal);

  void renewCogValueAncestry({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  });

  CogValueRuntimeScheduler get scheduler;

  CogValueRuntimeTelemetry get telemetry;

  void terminateCogValueAncestry({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  });
}
