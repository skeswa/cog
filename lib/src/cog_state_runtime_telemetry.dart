import 'common.dart';

abstract interface class CogStateRuntimeTelemetry {
  void recordCogStateDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });
  void recordCogStateDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  });
  void recordCogStateChangeNotification(CogStateOrdinal cogStateOrdinal);
  void recordCogStateCreation(CogStateOrdinal cogStateOrdinal);
  void recordCogStateListeningPostCreation(CogStateOrdinal cogStateOrdinal);
  void recordCogStateRecalculation(CogStateOrdinal cogStateOrdinal);
  void recordCogStateStalenessChange(CogStateOrdinal cogStateOrdinal);
}

final class NoOpCogStateRuntimeTelemetry implements CogStateRuntimeTelemetry {
  const NoOpCogStateRuntimeTelemetry();

  @override
  void recordCogStateDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {}

  @override
  void recordCogStateDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {}

  @override
  void recordCogStateChangeNotification(CogStateOrdinal cogStateOrdinal) {}

  @override
  void recordCogStateCreation(CogStateOrdinal cogStateOrdinal) {}

  @override
  void recordCogStateListeningPostCreation(CogStateOrdinal cogStateOrdinal) {}

  @override
  void recordCogStateRecalculation(CogStateOrdinal cogStateOrdinal) {}

  @override
  void recordCogStateStalenessChange(CogStateOrdinal cogStateOrdinal) {}
}
