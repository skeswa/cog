import 'dart:async';
import 'dart:collection';

import 'cog_state_runtime_logging.dart';

abstract interface class CogStateRuntimeScheduler {
  void scheduleBackgroundTask(
    void Function() backgroundTask, {
    bool isHighPriority = false,
  });

  void scheduleDelayedTask(
    void Function() dalayedTask,
    Duration delay,
  );
}

final class NaiveCogStateRuntimeScheduler implements CogStateRuntimeScheduler {
  final _BackgroundTaskScheduler _highPriorityBackgroundTaskScheduler;
  final _BackgroundTaskScheduler _lowPriorityBackgroundTaskScheduler;

  NaiveCogStateRuntimeScheduler({
    Duration highPriorityBackgroundTaskDelay =
        _naiveHighPriorityBackgroundTaskDelay,
    Duration lowPriorityBackgroundTaskDelay =
        _naiveLowPriorityBackgroundTaskDelay,
    required CogStateRuntimeLogging logging,
  })  : _highPriorityBackgroundTaskScheduler = _BackgroundTaskScheduler(
          backgroundTaskDelay: highPriorityBackgroundTaskDelay,
          logging: logging,
          logMessage: 'executing high priority background tasks',
        ),
        _lowPriorityBackgroundTaskScheduler = _BackgroundTaskScheduler(
          backgroundTaskDelay: lowPriorityBackgroundTaskDelay,
          logging: logging,
          logMessage: 'executing low priority background tasks',
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
  void Function()? _inProgressBackgroundTask;
  final String _logMessage;
  final CogStateRuntimeLogging _logging;

  _BackgroundTaskScheduler({
    required Duration backgroundTaskDelay,
    required CogStateRuntimeLogging logging,
    required String logMessage,
  })  : _backgroundTaskDelay = backgroundTaskDelay,
        _logging = logging,
        _logMessage = logMessage;

  void schedule(void Function() backgroundTask) {
    if (backgroundTask != _inProgressBackgroundTask &&
        !_backgroundTasks.contains(backgroundTask)) {
      _backgroundTasks.add(backgroundTask);
    } else {
      _logging.debug(
        null,
        'skipping background task because it is '
        'already in progress or will be soon',
      );
    }

    _backgroundTaskTimer ??= Timer(_backgroundTaskDelay, _onTimerElapsed);
  }

  void _onTimerElapsed() {
    _backgroundTaskTimer = null;

    _logging.debug(null, _logMessage);

    while (_backgroundTasks.isNotEmpty) {
      final backgroundTask = _backgroundTasks.removeFirst();

      _inProgressBackgroundTask = backgroundTask;

      try {
        backgroundTask();
      } catch (e, stackTrace) {
        _logging.error(
            null, 'Failed to execute background task', e, stackTrace);
      } finally {
        _inProgressBackgroundTask = null;
      }
    }
  }
}
