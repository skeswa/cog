import 'package:cog/cog.dart';

final class NoOpCogStateRuntime implements CogStateRuntime {
  const NoOpCogStateRuntime();

  @override
  noSuchMethod(Invocation invocation) => null;
}
