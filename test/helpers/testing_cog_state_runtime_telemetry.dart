import 'package:cog/cog.dart';

final class TestingCogStateRuntimeTelemetry
    implements CogStateRuntimeTelemetry {
  var _meter = 0;

  int get meter => _meter;

  @override
  void recordCogStateDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogStateDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogStateChangeNotification(CogStateOrdinal cogStateOrdinal) {
    _meter += 2;
  }

  @override
  void recordCogStateCreation(CogStateOrdinal cogStateOrdinal) {
    _meter += 2;
  }

  @override
  void recordCogStateListeningPostCreation(CogStateOrdinal cogStateOrdinal) {
    _meter += 1;
  }

  @override
  void recordCogStateNonCogDependencyRenewal({
    required CogStateOrdinal followerCogStateOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogStateNonCogDependencyTermination({
    required CogStateOrdinal followerCogStateOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogStateRecalculation(CogStateOrdinal cogStateOrdinal) {
    _meter += 16;
  }

  @override
  void recordCogStateStalenessChange(CogStateOrdinal cogStateOrdinal) {
    _meter += 1;
  }
}
