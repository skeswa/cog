import 'common.dart';

abstract interface class CogRuntimeTelemetry {
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
  void recordCogStateNonCogDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
  });
  void recordCogStateNonCogDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
  });
  void recordCogStateRecalculation(CogStateOrdinal cogStateOrdinal);
  void recordCogStateStalenessChange(CogStateOrdinal cogStateOrdinal);
}

final class NoOpCogRuntimeTelemetry implements CogRuntimeTelemetry {
  const NoOpCogRuntimeTelemetry();

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
  void recordCogStateNonCogDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
  }) {}

  @override
  void recordCogStateNonCogDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
  }) {}

  @override
  void recordCogStateRecalculation(CogStateOrdinal cogStateOrdinal) {}

  @override
  void recordCogStateStalenessChange(CogStateOrdinal cogStateOrdinal) {}
}
