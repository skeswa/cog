import 'common.dart';

abstract interface class CogValueRuntimeTelemetry {
  void recordCogValueAncestryRenewal({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  });
  void recordCogValueAncestryTermination({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  });
  void recordCogValueChangeNotification(CogValueOrdinal cogValueOrdinal);
  void recordCogValueCreation(CogValueOrdinal cogValueOrdinal);
  void recordCogValueListeningPostCreation(CogValueOrdinal cogValueOrdinal);
  void recordCogValueRecalculation(CogValueOrdinal cogValueOrdinal);
  void recordCogValueStalenessChange(CogValueOrdinal cogValueOrdinal);
}

final class NoOpCogValueRuntimeTelemetry implements CogValueRuntimeTelemetry {
  const NoOpCogValueRuntimeTelemetry();

  @override
  void recordCogValueAncestryRenewal({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {}

  @override
  void recordCogValueAncestryTermination({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {}

  @override
  void recordCogValueChangeNotification(CogValueOrdinal cogValueOrdinal) {}

  @override
  void recordCogValueCreation(CogValueOrdinal cogValueOrdinal) {}

  @override
  void recordCogValueListeningPostCreation(CogValueOrdinal cogValueOrdinal) {}

  @override
  void recordCogValueRecalculation(CogValueOrdinal cogValueOrdinal) {}

  @override
  void recordCogValueStalenessChange(CogValueOrdinal cogValueOrdinal) {}
}
