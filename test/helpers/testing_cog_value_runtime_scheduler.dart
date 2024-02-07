import 'package:cog/cog.dart';

final class SyncTestingCogValueRuntimeScheduler
    implements CogValueRuntimeScheduler {
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
