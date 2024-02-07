import 'package:cog/cog.dart';

final class TestingCogValueRuntimeTelemetry
    implements CogValueRuntimeTelemetry {
  var _meter = 0;

  int get meter => _meter;

  @override
  void recordCogValueAncestryRenewal({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogValueAncestryTermination({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {
    _meter += 1;
  }

  @override
  void recordCogValueChangeNotification(CogValueOrdinal cogValueOrdinal) {
    _meter += 2;
  }

  @override
  void recordCogValueCreation(CogValueOrdinal cogValueOrdinal) {
    _meter += 2;
  }

  @override
  void recordCogValueListeningPostCreation(CogValueOrdinal cogValueOrdinal) {
    _meter += 1;
  }

  @override
  void recordCogValueRecalculation(CogValueOrdinal cogValueOrdinal) {
    _meter += 16;
  }

  @override
  void recordCogValueStalenessChange(CogValueOrdinal cogValueOrdinal) {
    _meter += 1;
  }
}
