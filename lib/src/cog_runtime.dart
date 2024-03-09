import 'cog.dart';
import 'cog_state.dart';
import 'cog_runtime_logging.dart';
import 'cog_runtime_scheduler.dart';
import 'cog_runtime_telemetry.dart';
import 'common.dart';
import 'mechanism.dart';
import 'priority.dart';

abstract interface class CogRuntime {
  CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      acquire<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
  });

  Stream<CogValueType> acquireValueChangeStream<CogValueType, CogSpinType>({
    required CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
        cogState,
    required Priority priority,
  });

  Future<void> dispose();

  List<CogStateOrdinal> followerOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  );

  void handleError<CogValueType, CogSpinType>({
    CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>?
        cogState,
    required Object error,
    Mechanism? mechanism,
    required StackTrace stackTrace,
  });

  List<CogStateOrdinal> leaderOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  );

  CogRuntimeLogging get logging;

  void maybeNotifyListenersOf(CogStateOrdinal cogStateOrdinal);

  CogState operator [](CogStateOrdinal cogStateOrdinal);

  void pauseMechanism(MechanismOrdinal mechanismOrdinal);

  void renewCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });

  void resumeMechanism(MechanismOrdinal mechanismOrdinal);

  CogRuntimeScheduler get scheduler;

  CogRuntimeTelemetry get telemetry;

  void terminateCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });
}
