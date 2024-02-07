import 'cog.dart';
import 'cog_state.dart';
import 'cog_state_runtime.dart';
import 'cog_state_runtime_logging.dart';
import 'cog_state_runtime_scheduler.dart';
import 'cog_state_runtime_telemetry.dart';
import 'common.dart';
import 'notification_urgency.dart';

final class StandardCogStateRuntime implements CogStateRuntime {
  @override
  final CogStateRuntimeLogging logging;
  @override
  final CogStateRuntimeScheduler scheduler;
  @override
  final CogStateRuntimeTelemetry telemetry;

  final _cogStateFollowers = <List<CogStateOrdinal>?>[];
  final _cogStateLeaders = <List<CogStateOrdinal>?>[];
  final _cogStateListeningPosts = <CogStateListeningPost?>[];
  final _cogStates = <CogState>[];
  final _cogStateOrdinalByHash = <CogStateHash, CogStateOrdinal>{};
  final _cogStateListeningPostsToMaybeNotify = <CogStateListeningPost>[];

  StandardCogStateRuntime({
    this.logging = const NoOpCogStateRuntimeLogging(),
    CogStateRuntimeScheduler? scheduler,
    this.telemetry = const NoOpCogStateRuntimeTelemetry(),
  }) : scheduler = scheduler ?? NaiveCogStateRuntimeScheduler(logging: logging);

  @override
  CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>
      acquire<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinType? cogSpin,
  }) {
    final cogSpinHash = _hashCogSpin(cogSpin);

    final cogStateHash = _hashCogState(cog: cog, cogSpinHash: cogSpinHash);

    final cogStateOrdinal = _cogStateOrdinalByHash[cogStateHash];

    if (cogStateOrdinal == null) {
      return _createCogState(
        cog: cog,
        cogSpin: cogSpin,
        cogStateHash: cogStateHash,
      );
    }

    final cogState = _cogStates[cogStateOrdinal]
        as CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>;

    assert(() {
      if (cogState.cog != cog) {
        throw StateError(
          'Cog value collision detected! It appears as though the cog value '
          'associated with this cog actually belongs to a different one. '
          'Unfortunately, this state is unrecoverable as a cog value has '
          'collision is exceedingly rare.',
        );
      }

      return true;
    }());

    return _cogStates[cogStateOrdinal]
        as CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>;
  }

  @override
  Stream<CogStateType> acquireValueChangeStream<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required NotificationUrgency urgency,
  }) {
    final cogState = acquire(cog: cog, cogSpin: cogSpin);

    final existingCogStateListeningPost =
        _cogStateListeningPosts[cogState.ordinal];

    CogStateListeningPost<CogStateType, CogSpinType> cogStateListeningPost;

    if (existingCogStateListeningPost != null) {
      cogStateListeningPost = existingCogStateListeningPost
          as CogStateListeningPost<CogStateType, CogSpinType>;
    } else {
      cogStateListeningPost = CogStateListeningPost(
        cogState: cogState,
        onDeactivation: _onCogStateListeningPostDeactivation,
        urgency: urgency,
      );

      _cogStateListeningPosts[cogState.ordinal] = cogStateListeningPost;
    }

    if (cogStateListeningPost.urgency < urgency) {
      cogStateListeningPost.urgency = urgency;
    }

    return cogStateListeningPost.valueChanges;
  }

  @override
  Iterable<CogStateOrdinal> followerOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  ) =>
      _cogStateFollowers[cogStateOrdinal] ?? const [];

  @override
  Iterable<CogStateOrdinal> leaderOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  ) =>
      _cogStateLeaders[cogStateOrdinal] ?? const [];

  @override
  CogState operator [](CogStateOrdinal cogStateOrdinal) =>
      _cogStates[cogStateOrdinal];

  @override
  void maybeNotifyListenersOf(CogStateOrdinal cogStateOrdinal) {
    final listeningPost = _cogStateListeningPosts[cogStateOrdinal];

    if (listeningPost == null) {
      logging.debug(
        cogStateOrdinal,
        'skipping listener notification - no active listening post exists',
      );

      return;
    }

    _cogStateListeningPostsToMaybeNotify.add(listeningPost);

    scheduler.scheduleBackgroundTask(
      _onCogStateListeningPostsReadyForNotification,
      isHighPriority: true,
    );
  }

  @override
  void renewCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {
    logging.debug(
      followerCogStateOrdinal,
      'renewing dependency with leader cog value ordinal',
      leaderCogStateOrdinal,
    );

    telemetry.recordCogStateDependencyRenewal(
      followerCogStateOrdinal: followerCogStateOrdinal,
      leaderCogStateOrdinal: leaderCogStateOrdinal,
    );

    final cogStateLeaders = _cogStateLeaders[followerCogStateOrdinal] ??= [];
    final cogStateFollowers = _cogStateFollowers[leaderCogStateOrdinal] ??= [];

    if (!cogStateLeaders.contains(leaderCogStateOrdinal)) {
      cogStateLeaders.add(leaderCogStateOrdinal);
    }

    if (!cogStateFollowers.contains(followerCogStateOrdinal)) {
      cogStateFollowers.add(followerCogStateOrdinal);
    }
  }

  @override
  void terminateCogStateDependency({
    required CogStateOrdinal followerCogStateOrdinal,
    required CogStateOrdinal leaderCogStateOrdinal,
  }) {
    logging.debug(
      followerCogStateOrdinal,
      'terminating dependency with leader cog value ordinal',
      leaderCogStateOrdinal,
    );

    telemetry.recordCogStateDependencyTermination(
      leaderCogStateOrdinal: leaderCogStateOrdinal,
      followerCogStateOrdinal: followerCogStateOrdinal,
    );

    _cogStateLeaders[followerCogStateOrdinal]?.remove(leaderCogStateOrdinal);
    _cogStateFollowers[leaderCogStateOrdinal]?.remove(followerCogStateOrdinal);
  }

  CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>
      _createCogState<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required CogStateHash cogStateHash,
  }) {
    final ordinal = _cogStates.length;

    final cogState = _instantiateCogState(
      cog: cog,
      cogSpin: cogSpin,
      cogStateOrdinal: ordinal,
    );

    _cogStateFollowers.add(null);
    _cogStateLeaders.add(null);
    _cogStateListeningPosts.add(null);
    _cogStates.add(cogState);
    _cogStateOrdinalByHash[cogStateHash] = ordinal;

    logging.debug(cogState, 'created new cog value');

    return cogState;
  }

  void _cullInactiveCogStateListeningPosts() {
    for (var i = 0; i < _cogStateListeningPosts.length; i++) {
      final cogStateListeningPost = _cogStateListeningPosts[i];

      if (cogStateListeningPost != null && !cogStateListeningPost.isActive) {
        cogStateListeningPost.dispose();

        _cogStateListeningPosts[i] = null;
      }
    }
  }

  CogState<CogStateType, CogSpinType, Cog<CogStateType, CogSpinType>>
      _instantiateCogState<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required CogStateOrdinal cogStateOrdinal,
  }) {
    telemetry.recordCogStateCreation(cogStateOrdinal);

    if (cog is AutomaticCog<CogStateType, CogSpinType>) {
      return AutomaticCogState(
        cog: cog,
        ordinal: cogStateOrdinal,
        runtime: this,
        spin: cogSpin,
      );
    }

    if (cog is ManualCog<CogStateType, CogSpinType>) {
      return ManualCogState(
        cog: cog,
        ordinal: cogStateOrdinal,
        runtime: this,
        spin: cogSpin,
      );
    }

    throw UnsupportedError('Unknown cog type ${cog.runtimeType}');
  }

  CogSpinHash _hashCogSpin<CogSpinType>(CogSpinType? cogSpin) =>
      cogSpin.hashCode;

  CogStateHash _hashCogState<CogStateType, CogSpinType>({
    required Cog<CogStateType, CogSpinType> cog,
    required CogSpinHash cogSpinHash,
  }) =>
      Object.hash(cog.ordinal, cogSpinHash);

  void _onCogStateListeningPostDeactivation() {
    scheduler.scheduleBackgroundTask(_cullInactiveCogStateListeningPosts);
  }

  void _onCogStateListeningPostsReadyForNotification() {
    logging.debug(null, 'executing pending potential listener notifications');

    _cogStateListeningPostsToMaybeNotify
        .sort(_compareCogStateListeningPostsToMaybeNotify);

    CogStateListeningPost? previousCogStateListeningPost;

    for (final cogStateListeningPost in _cogStateListeningPostsToMaybeNotify) {
      if (cogStateListeningPost == previousCogStateListeningPost) {
        continue;
      }

      cogStateListeningPost.maybeNotify();
      previousCogStateListeningPost = cogStateListeningPost;
    }

    _cogStateListeningPostsToMaybeNotify.clear();
  }
}

/// Comparator that sorts a collection of [CogStateListeningPost] instances from
/// most urgent to least urgent, then from high [CogStateOrdinal] to low
/// [CogStateOrdinal].
int _compareCogStateListeningPostsToMaybeNotify(
  CogStateListeningPost a,
  CogStateListeningPost b,
) {
  final urgencyComparison = b.urgency.compareTo(a.urgency);

  if (urgencyComparison != 0) {
    return urgencyComparison;
  }

  return b.cogState.ordinal.compareTo(a.cogState.ordinal);
}
