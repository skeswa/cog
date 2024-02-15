import 'cog.dart';
import 'cog_state.dart';
import 'cog_state_runtime_logging.dart';
import 'cog_state_runtime_scheduler.dart';
import 'cog_state_runtime_telemetry.dart';
import 'common.dart';
import 'priority.dart';

abstract interface class CogStateRuntime {
  CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>
      acquire<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinType? cogSpin,
  });

  Stream<CogStateType> acquireValueChangeStream<CogStateType, CogSpinType>({
    required CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>
        cogState,
    required Priority priority,
  });

  Future<void> dispose();

  Iterable<CogStateOrdinal> followerOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  );

  Iterable<CogStateOrdinal> leaderOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  );

  CogStateRuntimeLogging get logging;

  void maybeNotifyListenersOf(CogStateOrdinal cogStateOrdinal);

  CogState operator [](CogStateOrdinal cogStateOrdinal);

  void renewCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });

  CogStateRuntimeScheduler get scheduler;

  CogStateRuntimeTelemetry get telemetry;

  void terminateCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });
}
