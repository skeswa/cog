import 'dart:async';

import 'cog.dart';
import 'cog_value_runtime.dart';
import 'common.dart';
import 'notification_urgency.dart';
import 'staleness.dart';

part 'automatic_cog_value.dart';
part 'cog_value_listening_post.dart';
part 'manual_cog_value.dart';

sealed class CogValue<ValueType, SpinType,
    CogType extends Cog<ValueType, SpinType>> {
  final CogType cog;

  final CogValueOrdinal ordinal;

  final CogValueRuntime runtime;

  CogValueRevision _revision = initialCogValueRevision;

  final SpinType? _spin;

  ValueType _value;

  CogValue({
    required this.cog,
    required this.ordinal,
    required SpinType? spin,
    required this.runtime,
  })  : _spin = spin,
        _value = cog.init();

  void markAsStale() {}

  void markAsMaybeStale() {}

  void maybeRevise(ValueType value) {
    if (!cog.eq(_value, value)) {
      runtime.logging.debug(
        this,
        'new revision - marking descendants as stale and setting value to',
        value,
      );

      _revision++;
      _value = value;

      for (final descendantOrdinal in runtime.descendantOrdinalsOf(ordinal)) {
        runtime[descendantOrdinal].markAsStale();
      }
    } else {
      runtime.logging
          .debug(this, 'no revision - new value was equal to old value');
    }
  }

  CogValueRevision get revision => _revision;

  SpinType get spin {
    assert(() {
      if (cog.spin == null) {
        throw StateError(
          'Cannot read cog spin - '
          'this cog definition does not specify a spin type',
        );
      }

      return true;
    }());

    return _spin as SpinType;
  }

  SpinType? get spinOrNull => _spin;

  ValueType get value => _value;
}
