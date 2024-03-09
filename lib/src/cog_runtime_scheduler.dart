import 'dart:async';
import 'dart:collection';

import 'cog_runtime_logging.dart';

abstract interface class CogRuntimeScheduler {
  Future<void> dispose();

  void scheduleBackgroundTask(
    void Function() backgroundTask, {
    bool isHighPriority = false,
  });

  void scheduleDelayedTask(
    void Function() dalayedTask,
    Duration delay,
  );
}

final class NaiveCogRuntimeScheduler implements CogRuntimeScheduler {
  final _NaiveBackgroundTaskScheduler _highPriorityBackgroundTaskScheduler;
  final _NaiveBackgroundTaskScheduler _lowPriorityBackgroundTaskScheduler;
  final _scheduledDelayedTasks = <void Function(), Timer>{};

  NaiveCogRuntimeScheduler({
    Duration highPriorityBackgroundTaskDelay =
        _naiveHighPriorityBackgroundTaskDelay,
    Duration lowPriorityBackgroundTaskDelay =
        _naiveLowPriorityBackgroundTaskDelay,
    required CogRuntimeLogging logging,
  })  : _highPriorityBackgroundTaskScheduler = _NaiveBackgroundTaskScheduler(
          backgroundTaskDelay: highPriorityBackgroundTaskDelay,
          logging: logging,
          logMessage: 'executing high priority background tasks',
        ),
        _lowPriorityBackgroundTaskScheduler = _NaiveBackgroundTaskScheduler(
          backgroundTaskDelay: lowPriorityBackgroundTaskDelay,
          logging: logging,
          logMessage: 'executing low priority background tasks',
        );

  @override
  Future<void> dispose() async {
    _highPriorityBackgroundTaskScheduler.dispose();
    _lowPriorityBackgroundTaskScheduler.dispose();

    for (final scheduledDelayedTaskTimer in _scheduledDelayedTasks.values) {
      scheduledDelayedTaskTimer.cancel();
    }

    _scheduledDelayedTasks.clear();
  }

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
    _scheduledDelayedTasks[dalayedTask]?.cancel();
    _scheduledDelayedTasks[dalayedTask] = Timer(delay, () {
      dalayedTask();

      scheduleBackgroundTask(_cullElapsedScheduledDelayedTaskTimers);
    });
  }

  void _cullElapsedScheduledDelayedTaskTimers() {
    _scheduledDelayedTasks.removeWhere((_, timer) => !timer.isActive);
  }
}

const _naiveHighPriorityBackgroundTaskDelay = Duration.zero;
const _naiveLowPriorityBackgroundTaskDelay = Duration(seconds: 3);

final class _NaiveBackgroundTaskScheduler {
  final Duration _backgroundTaskDelay;
  final _backgroundTasks = Queue<void Function()>();
  Timer? _backgroundTaskTimer;
  void Function()? _inProgressBackgroundTask;
  final String _logMessage;
  final CogRuntimeLogging _logging;

  _NaiveBackgroundTaskScheduler({
    required Duration backgroundTaskDelay,
    required CogRuntimeLogging logging,
    required String logMessage,
  })  : _backgroundTaskDelay = backgroundTaskDelay,
        _logging = logging,
        _logMessage = logMessage;

  void dispose() {
    _backgroundTaskTimer?.cancel();
    _backgroundTaskTimer = null;
    _inProgressBackgroundTask = null;
  }

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
          null,
          'Failed to execute background task',
          e,
          stackTrace,
        );
      } finally {
        _inProgressBackgroundTask = null;
      }
    }
  }
}
