import 'cog.dart';
import 'cog_state.dart';
import 'cog_state_runtime_logging.dart';
import 'cog_state_runtime_scheduler.dart';
import 'cog_state_runtime_telemetry.dart';
import 'common.dart';
import 'priority.dart';

abstract interface class CogStateRuntime {
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

  Iterable<CogStateOrdinal> followerOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  );

  void handleError<CogValueType, CogSpinType>({
    required CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
        cogState,
    required Object error,
    required StackTrace stackTrace,
  });

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
