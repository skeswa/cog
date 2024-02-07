import 'package:cog/cog.dart';

final class SyncTestingCogStateRuntimeScheduler
    implements CogStateRuntimeScheduler {
  @override
  void scheduleBackgroundTask(
    void Function() backgroundTask, {
    bool isHighPriority = false,
  }) {
    backgroundTask();
  }

  @override
  void scheduleDelayedTask(void Function() dalayedTask, Duration delay) {
    dalayedTask();
  }
}
