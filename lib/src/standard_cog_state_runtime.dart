import 'package:collection/collection.dart';

import 'cog.dart';
import 'cog_state.dart';
import 'cog_state_runtime.dart';
import 'cog_state_runtime_logging.dart';
import 'cog_state_runtime_scheduler.dart';
import 'cog_state_runtime_telemetry.dart';
import 'common.dart';
import 'priority.dart';

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
  final _cogStateListeningPostsToMaybeNotify =
      PriorityQueue<CogStateListeningPost>(
    _compareCogStateListeningPostsToMaybeNotify,
  );
  final _cogStateOrdinalByHash = <CogStateHash, CogStateOrdinal>{};
  final _cogStates = <CogState>[];
  final StandardCogStateRuntimeErrorCallback? _onError;

  StandardCogStateRuntime({
    this.logging = const NoOpCogStateRuntimeLogging(),
    StandardCogStateRuntimeErrorCallback? onError,
    CogStateRuntimeScheduler? scheduler,
    this.telemetry = const NoOpCogStateRuntimeTelemetry(),
  })  : _onError = onError,
        scheduler =
            scheduler ?? NaiveCogStateRuntimeScheduler(logging: logging);

  @override
  CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      acquire<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
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
        as CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>;

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
        as CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>;
  }

  @override
  Stream<CogValueType> acquireValueChangeStream<CogValueType, CogSpinType>({
    required CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
        cogState,
    required Priority priority,
  }) {
    final existingCogStateListeningPost =
        _cogStateListeningPosts[cogState.ordinal];

    CogStateListeningPost<CogValueType, CogSpinType> cogStateListeningPost;

    if (existingCogStateListeningPost != null) {
      cogStateListeningPost = existingCogStateListeningPost
          as CogStateListeningPost<CogValueType, CogSpinType>;
    } else {
      cogStateListeningPost = CogStateListeningPost(
        cogState: cogState,
        onDeactivation: _onCogStateListeningPostDeactivation,
        priority: priority,
      );

      _cogStateListeningPosts[cogState.ordinal] = cogStateListeningPost;
    }

    if (cogStateListeningPost.priority < priority) {
      cogStateListeningPost.priority = priority;
    }

    return cogStateListeningPost.valueChanges;
  }

  @override
  Future<void> dispose() async {
    await scheduler.dispose();

    _cogStateFollowers.clear();
    _cogStateLeaders.clear();
    _cogStateListeningPostsToMaybeNotify.clear();
    _cogStateOrdinalByHash.clear();
    _cogStates.clear();

    await Future.wait([
      for (final cogStateListeningPost in _cogStateListeningPosts)
        if (cogStateListeningPost != null) cogStateListeningPost.dispose(),
    ]);

    _cogStateListeningPosts.clear();
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

    if (listeningPost.priority == Priority.asap) {
      logging.debug(
        cogStateOrdinal,
        'doing sync notification due to asap priority',
      );

      listeningPost.maybeNotify();

      return;
    }

    logging.debug(
      cogStateOrdinal,
      'scheduling notification background task',
    );

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

  CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      _createCogState<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
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

    cogState.init();

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

  CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
      _instantiateCogState<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinType? cogSpin,
    required CogStateOrdinal cogStateOrdinal,
  }) {
    telemetry.recordCogStateCreation(cogStateOrdinal);

    if (cog is AutomaticCog<CogValueType, CogSpinType>) {
      return AutomaticCogState(
        cog: cog,
        ordinal: cogStateOrdinal,
        runtime: this,
        spin: cogSpin,
      );
    }

    if (cog is ManualCog<CogValueType, CogSpinType>) {
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

  CogStateHash _hashCogState<CogValueType, CogSpinType>({
    required Cog<CogValueType, CogSpinType> cog,
    required CogSpinHash cogSpinHash,
  }) =>
      Object.hash(cog.ordinal, cogSpinHash);

  void _onCogStateListeningPostDeactivation() {
    scheduler.scheduleBackgroundTask(_cullInactiveCogStateListeningPosts);
  }

  void _onCogStateListeningPostsReadyForNotification() {
    logging.debug(null, 'executing pending potential listener notifications');

    var iterationCount = 0;
    CogStateListeningPost? previousCogStateListeningPost;

    while (iterationCount < _listeningPostNotificationLimit &&
        _cogStateListeningPostsToMaybeNotify.isNotEmpty) {
      final cogStateListeningPost =
          _cogStateListeningPostsToMaybeNotify.removeFirst();

      if (cogStateListeningPost == previousCogStateListeningPost) {
        continue;
      }

      cogStateListeningPost.maybeNotify();
      previousCogStateListeningPost = cogStateListeningPost;
      iterationCount++;
    }

    _cogStateListeningPostsToMaybeNotify.clear();

    if (iterationCount >= _listeningPostNotificationLimit) {
      logging.error(null, 'reached listening post notification limit');
    }
  }

  @override
  void handleError<CogValueType, CogSpinType>({
    required CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>
        cogState,
    required Object error,
    required StackTrace stackTrace,
  }) {
    final onError = _onError;

    if (onError != null) {
      onError(
        cog: cogState.cog,
        error: error,
        spin: cogState.spinOrNull,
        stackTrace: stackTrace,
      );

      return;
    }

    assert(() {
      throw StateError(
        'Encountered a Cog runtime error with Cog '
        '${cogState.cog} that has spin `${cogState.spinOrNull}`: '
        '$error',
      );
    }());

    logging.error(
      cogState,
      'encountered an error while conveying',
      error,
      stackTrace,
    );
  }
}

typedef StandardCogStateRuntimeErrorCallback = void Function({
  required Cog cog,
  required Object error,
  required Object? spin,
  required StackTrace stackTrace,
});

/// Maximum number of consecutive listening post notifications.
const _listeningPostNotificationLimit = 1000;

/// Comparator that sorts a collection of [CogStateListeningPost] instances from
/// most normal to least normal, then from high [ordinal] to low [ordinal].
int _compareCogStateListeningPostsToMaybeNotify(
  CogStateListeningPost a,
  CogStateListeningPost b,
) {
  final priorityComparison = b.priority.compareTo(a.priority);

  if (priorityComparison != 0) {
    return priorityComparison;
  }

  return b.ordinal.compareTo(a.ordinal);
}
