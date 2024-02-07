import 'dart:async';
import 'dart:collection';

import 'cog_value_runtime_logging.dart';

abstract interface class CogValueRuntimeScheduler {
  void scheduleBackgroundTask(
    void Function() backgroundTask, {
    bool isHighPriority = false,
  });

  void scheduleDelayedTask(
    void Function() dalayedTask,
    Duration delay,
  );
}

final class NaiveCogValueRuntimeScheduler implements CogValueRuntimeScheduler {
  final _BackgroundTaskScheduler _highPriorityBackgroundTaskScheduler;
  final _BackgroundTaskScheduler _lowPriorityBackgroundTaskScheduler;

  NaiveCogValueRuntimeScheduler({
    Duration highPriorityBackgroundTaskDelay =
        _naiveHighPriorityBackgroundTaskDelay,
    Duration lowPriorityBackgroundTaskDelay =
        _naiveLowPriorityBackgroundTaskDelay,
    required CogValueRuntimeLogging logging,
  })  : _highPriorityBackgroundTaskScheduler = _BackgroundTaskScheduler(
          backgroundTaskDelay: highPriorityBackgroundTaskDelay,
          logging: logging,
        ),
        _lowPriorityBackgroundTaskScheduler = _BackgroundTaskScheduler(
          backgroundTaskDelay: lowPriorityBackgroundTaskDelay,
          logging: logging,
        );

  @override
  void scheduleBackgroundTask(
    void Function() backgroundTask, {
    bool isHighPriority = false,
  }) {
    if (isHighPriority) {
      _highPriorityBackgroundTaskScheduler.schedule(backgroundTask);
    } else {
      _lowPriorityBackgroundTaskScheduler.schedule(backgroundTask);
    }
  }

  @override
  void scheduleDelayedTask(void Function() dalayedTask, Duration delay) {
    // TODO(skeswa): should we cluster these to make cog value updates more
    // bursty?
    Timer(delay, dalayedTask);
  }
}

const _naiveHighPriorityBackgroundTaskDelay = Duration.zero;
const _naiveLowPriorityBackgroundTaskDelay = Duration(seconds: 3);

final class _BackgroundTaskScheduler {
  final Duration _backgroundTaskDelay;
  final _backgroundTasks = Queue<void Function()>();
  Timer? _backgroundTaskTimer;
  final CogValueRuntimeLogging _logging;

  _BackgroundTaskScheduler({
    required Duration backgroundTaskDelay,
    required CogValueRuntimeLogging logging,
  })  : _backgroundTaskDelay = backgroundTaskDelay,
        _logging = logging;

  void schedule(void Function() backgroundTask) {
    if (!_backgroundTasks.contains(backgroundTask)) {
      _backgroundTasks.add(backgroundTask);
    }

    _backgroundTaskTimer ??= Timer(_backgroundTaskDelay, _onTimerElapsed);
  }

  void _onTimerElapsed() {
    _backgroundTaskTimer = null;

    _logging.debug(null, 'Executing background tasks');

    while (_backgroundTasks.isNotEmpty) {
      final backgroundTask = _backgroundTasks.removeFirst();

      try {
        backgroundTask();
      } catch (e, stackTrace) {
        _logging.error(
            null, 'Failed to execute background task', e, stackTrace);
      }
    }
  }
}
