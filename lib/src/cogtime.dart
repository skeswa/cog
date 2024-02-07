import 'cog.dart';
import 'cog_value.dart';
import 'cog_value_runtime.dart';
import 'cog_value_runtime_logging.dart';
import 'cog_value_runtime_scheduler.dart';
import 'cog_value_runtime_telemetry.dart';
import 'common.dart';
import 'notification_urgency.dart';

final class Cogtime implements CogValueRuntime {
  @override
  final CogValueRuntimeLogging logging;
  @override
  final CogValueRuntimeScheduler scheduler;
  @override
  final CogValueRuntimeTelemetry telemetry;

  final _cogValueAncestors = <List<CogValueOrdinal>?>[];
  final _cogValueDescendants = <List<CogValueOrdinal>?>[];
  final _cogValueListeningPosts = <CogValueListeningPost?>[];
  final _cogValues = <CogValue>[];
  final _cogValueOrdinalByHash = <CogValueHash, CogValueOrdinal>{};
  final _cogValueListeningPostsToMaybeNotify = <CogValueListeningPost>[];

  Cogtime({
    this.logging = const NoOpCogValueRuntimeLogging(),
    CogValueRuntimeScheduler? scheduler,
    this.telemetry = const NoOpCogValueRuntimeTelemetry(),
  }) : scheduler = scheduler ?? NaiveCogValueRuntimeScheduler(logging: logging);

  @override
  CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      acquire<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
  }) {
    final cogSpinHash = _hashCogSpin(cogSpin);

    final cogValueHash = _hashCogValue(cog: cog, cogSpinHash: cogSpinHash);

    final cogValueOrdinal = _cogValueOrdinalByHash[cogValueHash];

    if (cogValueOrdinal == null) {
      return _createCogValue(
        cog: cog,
        cogSpin: cogSpin,
        cogValueHash: cogValueHash,
      );
    }

    final cogValue = _cogValues[cogValueOrdinal]
        as CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>;

    assert(() {
      if (cogValue.cog != cog) {
        throw StateError(
          'Cog value collision detected! It appears as though the cog value '
          'associated with this cog actually belongs to a different one. '
          'Unfortunately, this state is unrecoverable as a cog value has '
          'collision is exceedingly rare.',
        );
      }

      return true;
    }());

    return _cogValues[cogValueOrdinal]
        as CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>;
  }

  @override
  Stream<CogValueType> acquireValueChangeStream<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required NotificationUrgency urgency,
  }) {
    final cogValue = acquire(cog: cog, cogSpin: cogSpin);

    final existingCogValueListeningPost =
        _cogValueListeningPosts[cogValue.ordinal];

    final cogValueListeningPost = existingCogValueListeningPost != null
        ? existingCogValueListeningPost
            as CogValueListeningPost<CogValueType, CogSpinType>
        : CogValueListeningPost(
            cogValue: cogValue,
            onDeactivation: _onCogValueListeningPostDeactivation,
            urgency: urgency,
          );

    if (cogValueListeningPost.urgency < urgency) {
      cogValueListeningPost.urgency = urgency;
    }

    // Assume, pessimistically, that the called of this method never subscribes
    // to the the listening post stream.
    _onCogValueListeningPostDeactivation();

    return cogValueListeningPost.valueChanges;
  }

  @override
  Iterable<CogValueOrdinal> ancestorOrdinalsOf(
    CogValueOrdinal cogValueOrdinal,
  ) =>
      _cogValueAncestors[cogValueOrdinal] ?? const [];

  @override
  Iterable<CogValueOrdinal> descendantOrdinalsOf(
    CogValueOrdinal cogValueOrdinal,
  ) =>
      _cogValueDescendants[cogValueOrdinal] ?? const [];

  @override
  CogValue operator [](CogValueOrdinal cogValueOrdinal) =>
      _cogValues[cogValueOrdinal];

  @override
  void notifyListenersOf(CogValueOrdinal cogValueOrdinal) {
    final listeningPost = _cogValueListeningPosts[cogValueOrdinal];

    if (listeningPost == null) {
      return;
    }

    _cogValueListeningPostsToMaybeNotify.add(listeningPost);

    scheduler.scheduleBackgroundTask(
      _onCogValueListeningPostsReadyForNotification,
      isHighPriority: true,
    );
  }

  @override
  void renewCogValueAncestry({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {
    if (logging.isEnabled) {
      logging.debug(
        null,
        'Renewing ancestry between ancestor '
        '[?::$ancestorCogValueOrdinal] and descendant '
        '[?::$descendantCogValueOrdinal]',
      );
    }

    telemetry.recordCogValueAncestryRenewal(
      ancestorCogValueOrdinal: ancestorCogValueOrdinal,
      descendantCogValueOrdinal: descendantCogValueOrdinal,
    );

    final cogValueAncestors =
        _cogValueAncestors[descendantCogValueOrdinal] ??= [];
    final cogValueDescendants =
        _cogValueDescendants[ancestorCogValueOrdinal] ??= [];

    if (!cogValueAncestors.contains(ancestorCogValueOrdinal)) {
      cogValueAncestors.add(ancestorCogValueOrdinal);
    }

    if (!cogValueDescendants.contains(descendantCogValueOrdinal)) {
      cogValueDescendants.add(descendantCogValueOrdinal);
    }
  }

  @override
  void terminateCogValueAncestry({
    required CogValueOrdinal ancestorCogValueOrdinal,
    required CogValueOrdinal descendantCogValueOrdinal,
  }) {
    if (logging.isEnabled) {
      logging.debug(
        null,
        'Terminating ancestry between ancestor [?|$ancestorCogValueOrdinal] '
        'and descendant [?|$ancestorCogValueOrdinal]',
      );
    }

    telemetry.recordCogValueAncestryTermination(
      ancestorCogValueOrdinal: ancestorCogValueOrdinal,
      descendantCogValueOrdinal: descendantCogValueOrdinal,
    );

    _cogValueAncestors[descendantCogValueOrdinal]
        ?.remove(ancestorCogValueOrdinal);
    _cogValueDescendants[ancestorCogValueOrdinal]
        ?.remove(descendantCogValueOrdinal);
  }

  CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      _createCogValue<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required CogValueHash cogValueHash,
  }) {
    final ordinal = _cogValues.length;

    final cogValue = _instantiateCogValue(
      cog: cog,
      cogSpin: cogSpin,
      cogValueOrdinal: ordinal,
    );

    _cogValueAncestors.add(null);
    _cogValueDescendants.add(null);
    _cogValueListeningPosts.add(null);
    _cogValues.add(cogValue);
    _cogValueOrdinalByHash[cogValueHash] = ordinal;

    logging.debug(cogValue, 'Created new cog value');

    return cogValue;
  }

  void _cullInactiveCogValueListeningPosts() {
    for (var i = 0; i < _cogValueListeningPosts.length; i++) {
      final cogValueListeningPost = _cogValueListeningPosts[i];

      if (cogValueListeningPost != null && !cogValueListeningPost.isActive) {
        cogValueListeningPost.dispose();

        _cogValueListeningPosts[i] = null;
      }
    }
  }

  CogValue<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      _instantiateCogValue<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required CogValueOrdinal cogValueOrdinal,
  }) {
    telemetry.recordCogValueCreation(cogValueOrdinal);

    if (cog is AutomaticCog<CogValueType, CogSpinType>) {
      return AutomaticCogValue(
        cog: cog,
        ordinal: cogValueOrdinal,
        runtime: this,
        spin: cogSpin,
      );
    }

    if (cog is ManualCog<CogValueType, CogSpinType>) {
      return ManualCogValue(
        cog: cog,
        ordinal: cogValueOrdinal,
        runtime: this,
        spin: cogSpin,
      );
    }

    throw UnsupportedError('Unknown cog type ${cog.runtimeType}');
  }

  CogSpinHash _hashCogSpin<CogSpinType>(CogSpinType? cogSpin) =>
      cogSpin.hashCode;

  CogValueHash _hashCogValue<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinHash cogSpinHash,
  }) =>
      Object.hash(cog.ordinal, cogSpinHash);

  void _onCogValueListeningPostDeactivation() {
    scheduler.scheduleBackgroundTask(_cullInactiveCogValueListeningPosts);
  }

  void _onCogValueListeningPostsReadyForNotification() {
    _cogValueListeningPostsToMaybeNotify
        .sort(_compareCogValueListeningPostsToMaybeNotify);

    for (final cogValueListeningPost in _cogValueListeningPostsToMaybeNotify) {
      cogValueListeningPost.maybeNotify();
    }

    _cogValueListeningPostsToMaybeNotify.clear();
  }
}

/// Comparator that sorts a collection of [CogValueListeningPost] in descending
/// order from most urgent to least urgent.
int _compareCogValueListeningPostsToMaybeNotify(
  CogValueListeningPost a,
  CogValueListeningPost b,
) =>
    b.urgency.compareTo(a.urgency);
