import 'dart:async';

import 'package:collection/collection.dart';

import 'cog.dart';
import 'cog_state.dart';
import 'cog_runtime.dart';
import 'cog_runtime_logging.dart';
import 'cog_runtime_scheduler.dart';
import 'cog_runtime_telemetry.dart';
import 'common.dart';
import 'mechanism.dart';
import 'mechanism_state.dart';
import 'mechanism_registry.dart';
import 'priority.dart';

final class StandardCogRuntime implements CogRuntime {
  @override
  final CogRuntimeLogging logging;
  @override
  final CogRuntimeScheduler scheduler;
  @override
  final CogRuntimeTelemetry telemetry;

  final _cogStateFollowers = <List<CogStateOrdinal>?>[];
  final _cogStateLeaders = <List<CogStateOrdinal>?>[];
  final _cogStateListeningPosts = <CogStateListeningPost?>[];
  final _cogStateListeningPostsToMaybeNotify =
      PriorityQueue<CogStateListeningPost>(
    _compareCogStateListeningPostsToMaybeNotify,
  );
  final _cogStateOrdinalByHash = <CogStateHash, CogStateOrdinal>{};
  final _cogStates = <CogState>[];
  final MechanismRegistry _mechanismRegistry;
  StreamSubscription<MechanismOrdinal>? _mechanismRegisteredSubscription;
  final _mechanismStates = <MechanismState?>[];
  final StandardCogRuntimeErrorCallback? _onError;

  StandardCogRuntime({
    this.logging = const NoOpCogRuntimeLogging(),
    MechanismRegistry? mechanismRegistry,
    StandardCogRuntimeErrorCallback? onError,
    CogRuntimeScheduler? scheduler,
    this.telemetry = const NoOpCogRuntimeTelemetry(),
  })  : _mechanismRegistry =
            mechanismRegistry ?? GlobalMechanismRegistry.instance,
        _onError = onError,
        scheduler = scheduler ?? NaiveCogRuntimeScheduler(logging: logging) {
    _mechanismRegisteredSubscription =
        _mechanismRegistry.mechanismRegistered.listen(_onMechanismRegistered);

    _mechanismStates.length = _mechanismRegistry.registeredMechanisms.length;

    for (final mechanism in _mechanismRegistry.registeredMechanisms) {
      _onMechanismRegistered(mechanism.ordinal);
    }
  }

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

    for (final mechanismState in _mechanismStates) {
      mechanismState?.dispose();
    }

    _cogStateFollowers.clear();
    _cogStateLeaders.clear();
    _cogStateListeningPostsToMaybeNotify.clear();
    _cogStateOrdinalByHash.clear();
    _cogStates.clear();
    _mechanismRegisteredSubscription?.cancel();
    _mechanismStates.clear();

    await Future.wait([
      for (final cogStateListeningPost in _cogStateListeningPosts)
        if (cogStateListeningPost != null) cogStateListeningPost.dispose(),
    ]);

    _cogStateListeningPosts.clear();
  }

  @override
  List<CogStateOrdinal> followerOrdinalsOf(
    CogStateOrdinal cogStateOrdinal,
  ) {
    return _cogStateFollowers[cogStateOrdinal] ?? const [];
  }

  @override
  void handleError<CogValueType, CogSpinType>({
    CogState<CogValueType, CogSpinType, Cog<CogValueType, CogSpinType>>?
        cogState,
    required Object error,
    Mechanism? mechanism,
    required StackTrace stackTrace,
  }) {
    final onError = _onError;

    if (onError != null) {
      onError(
        cog: cogState?.cog,
        error: error,
        mechanism: mechanism,
        spin: cogState?.spinOrNull,
        stackTrace: stackTrace,
      );

      return;
    }

    assert(() {
      var errorContext = '';
      if (cogState != null) {
        errorContext =
            ' with Cog ${cogState.cog} that has spin `${cogState.spinOrNull}`';
      }
      if (mechanism != null) {
        errorContext = ' with Mechanism $mechanism';
      }

      throw StateError(
        'Encountered a Cog runtime error$errorContext: $error:\n$stackTrace',
      );
    }());

    logging.error(
      cogState,
      'encountered an error while conveying',
      error,
      stackTrace,
    );
  }

  @override
  List<CogStateOrdinal> leaderOrdinalsOf(
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
  void pauseMechanism(MechanismOrdinal mechanismOrdinal) {
    final mechanismState = _mechanismStates[mechanismOrdinal];

    if (mechanismState == null) {
      return;
    }

    logging.debug(
      null,
      'pausing Mechanism',
      mechanismState.mechanism,
    );

    mechanismState.dispose();

    _mechanismStates[mechanismOrdinal] = null;
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
  void resumeMechanism(MechanismOrdinal mechanismOrdinal) {
    final mechanismState = _acquireMechanismState(mechanismOrdinal);

    logging.debug(
      null,
      'resumed Mechanism',
      mechanismState.mechanism,
    );
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

  MechanismState _acquireMechanismState(MechanismOrdinal mechanismOrdinal) {
    final mechanism = _mechanismRegistry[mechanismOrdinal];

    var mechanismState = mechanismOrdinal < _mechanismStates.length
        ? _mechanismStates[mechanismOrdinal]
        : null;

    if (mechanismState == null) {
      if (mechanismOrdinal < _mechanismStates.length) {
        _mechanismStates.length = mechanismOrdinal + 1;
      }

      logging.debug(null, 'initializing Mechanism', mechanism);

      _mechanismStates[mechanismOrdinal] = mechanismState =
          MechanismState(cogRuntime: this, mechanism: mechanism);

      mechanismState.init();
    }

    return mechanismState;
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

  void _onMechanismRegistered(MechanismOrdinal mechanismOrdinal) {
    _acquireMechanismState(mechanismOrdinal);
  }
}

typedef StandardCogRuntimeErrorCallback = void Function({
  Cog? cog,
  Mechanism? mechanism,
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
