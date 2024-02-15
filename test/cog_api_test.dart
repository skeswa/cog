import 'dart:math';

import 'package:cog/cog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog API', () {
    late Cogtext cogtext;
    late TestingCogStateRuntimeLogger logging;

    setUpLogging();

    setUp(() {
      logging = TestingCogStateRuntimeLogger();
    });

    group('Auxilliary details', () {
      test('automatic Cogs should be stringifiable', () {
        final fourCog = Cog((c) => 4, spin: Spin<bool>());
        final falseCog = Cog(
          (c) => false,
          debugLabel: 'falseCog',
          ttl: const Duration(seconds: 1),
        );
        final helloCog = Cog(
          (c) => 'hello',
          debugLabel: 'helloCog',
          eq: (a, b) => a.length == b.length,
        );

        expect('$fourCog', 'AutomaticCog<int, bool>()');
        expect(
          '$falseCog',
          'AutomaticCog<bool>(debugLabel: "falseCog", ttl: 0:00:01.000000)',
        );
        expect(
          '$helloCog',
          'AutomaticCog<String>(debugLabel: "helloCog", eq: overridden)',
        );
      });

      test('manual Cogs should be stringifiable', () {
        final fourCog = Cog.man(null.of<int>(), spin: Spin<bool>());
        final falseCog = Cog.man(() => false, debugLabel: 'falseCog');
        final helloCog = Cog.man(
          () => '',
          debugLabel: 'helloCog',
          eq: (a, b) => a.length == b.length,
        );

        expect('$fourCog', 'ManualCog<int?, bool>()');
        expect(
          '$falseCog',
          'ManualCog<bool>(debugLabel: "falseCog")',
        );
        expect(
          '$helloCog',
          'ManualCog<String>(debugLabel: "helloCog", eq: overridden)',
        );
      });

      test('Priority should be stringifiable', () {
        expect('${Priority.asap}', 'asap');
        expect('${Priority.low}', 'low');
        expect('${Priority.high}', 'high');
        expect('${Priority.normal}', 'normal');
      });

      test('Spin<T> requires T', () {
        expect(() => Spin<dynamic>(), throwsArgumentError);
        expect(() => Spin(), throwsArgumentError);
      });

      test('null.of<T>() returns a function that returns null', () {
        expect(null.of<int>(), isA<int? Function()>());
        expect(null.of<int>()(), isNull);
      });

      test('null.of<T>() requires T', () {
        expect(() => null.of<dynamic>(), throwsArgumentError);
        expect(() => null.of(), throwsArgumentError);
      });
    });

    group('Simple reading', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('reading from a spun automatic Cog without specifying spin throws',
          () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test('reading from a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.read(cogtext), throwsArgumentError);
      });

      test(
          'reading from an unspun automatic Cog without specifying spin throws',
          () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('reading from an unspun manual Cog without specifying spin throws',
          () {
        final numberCog = Cog.man(() => 4);

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('reading from a spun manual Cog returns its current value', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('reading from a spun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('reading from an unspun manual Cog returns its value', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.read(cogtext), equals(4));
      });

      test('reading from an unspun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(numberCog.read(cogtext), equals(4));
      });

      test(
          'reading from an automatic Cog that did not initialize '
          'correctly throws', () {
        final numberCog = Cog((c) {
          throw Error();
        }, spin: Spin<bool>());

        expect(
          () => numberCog.read(cogtext, spin: false),
          throwsA(isA<Error>()),
        );
      });
    });

    group('Simple watching', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('watching a spun automatic Cog without specifying spin throws', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test('watching a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test(
          'watching an unspun automatic Cog '
          'without specifying spin throws', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('watching an unspun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4);

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('watching from a spun manual Cog returns its value', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('watching a spun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        }, spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('watching an unspun manual Cog returns its value', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.watch(cogtext).isBroadcast, isTrue);
      });

      test('watching an unspun automatic Cog returns its value', () {
        final numberCog = Cog((c) {
          return 4;
        });

        expect(numberCog.watch(cogtext).isBroadcast, isTrue);
      });
    });

    group('Simple reading and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('writing to a spun manual Cog without specifying spin throws', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.write(cogtext, 5), throwsArgumentError);
      });

      test('writing to an unspun manual Cog and specifying spin throws', () {
        final numberCog = Cog.man(() => 4);

        expect(
          () => numberCog.write(cogtext, 5, spin: false),
          throwsArgumentError,
        );
      });

      test('writing to a spun manual Cog changes its value', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
        expect(numberCog.read(cogtext, spin: true), equals(4));

        numberCog.write(cogtext, 5, spin: false);

        expect(numberCog.read(cogtext, spin: false), equals(5));
        expect(numberCog.read(cogtext, spin: true), equals(4));

        numberCog.write(cogtext, 6, spin: true);

        expect(numberCog.read(cogtext, spin: false), equals(5));
        expect(numberCog.read(cogtext, spin: true), equals(6));
      });

      test('writing to an unspun manual Cog changes its value', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.read(cogtext), equals(4));

        numberCog.write(cogtext, 5);

        expect(numberCog.read(cogtext), equals(5));

        numberCog.write(cogtext, 6);

        expect(numberCog.read(cogtext), equals(6));
      });
    });

    group('Simple watching and writing', () {
      setUp(() {
        cogtext = Cogtext(
          cogStateRuntime: StandardCogStateRuntime(
            logging: logging,
            scheduler: NaiveCogStateRuntimeScheduler(
              logging: logging,
              highPriorityBackgroundTaskDelay: Duration.zero,
              lowPriorityBackgroundTaskDelay: Duration.zero,
            ),
          ),
        );
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('writing to a watched, spun manual Cog triggers a notification',
          () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription =
            numberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test('writing to a watched, unspun manual Cog triggers a notification',
          () async {
        final numberCog = Cog.man(() => 4);

        final emissions = [];
        final subscription = numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test('writing to a watched, spun automatic Cog triggers a notification',
          () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: c.spin);

          return number * number;
        }, debugLabel: 'squaredNumberCog', spin: Spin<bool>());

        final emissions = [];
        final subscription =
            squaredNumberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));
      });

      test('writing to a watched, unspun automatic Cog triggers a notification',
          () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: false);

          return number * number;
        }, debugLabel: 'squaredNumberCog');

        final emissions = [];
        final subscription =
            squaredNumberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([25]));
      });

      test(
          'writing to a watched manual Cog with asap priority '
          'triggers a notification synchronously', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription = numberCog
            .watch(
              cogtext,
              spin: false,
              priority: Priority.asap,
            )
            .listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(emissions, equals([5]));

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to multiple unrelated watched, spun manual Cogs triggers '
          'the right notifications in the right order', () async {
        final boolCog =
            Cog.man(() => true, debugLabel: 'boolCog', spin: Spin<bool>());
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());
        final textCog =
            Cog.man(() => 'hello', debugLabel: 'textCog', spin: Spin<bool>());

        final emissions = [];
        final subscriptions = [
          boolCog
              .watch(
                cogtext,
                priority: Priority.low,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
                spin: true,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                priority: Priority.high,
                spin: false,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, false, spin: false);
        boolCog.write(cogtext, true, spin: false);
        numberCog.write(cogtext, 5, spin: false);
        numberCog.write(cogtext, 6, spin: false);
        numberCog.write(cogtext, 66, spin: true);
        numberCog.write(cogtext, 7, spin: false);
        numberCog.write(cogtext, 7, spin: false);
        numberCog.write(cogtext, 77, spin: true);
        numberCog.write(cogtext, 77, spin: true);
        textCog.write(cogtext, 'world', spin: false);
        textCog.write(cogtext, 'mars', spin: false);
        textCog.write(cogtext, 'jupiter', spin: false);
        textCog.write(cogtext, 'saturn', spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, 7, true]));

        numberCog.write(cogtext, 8, spin: false);
        numberCog.write(cogtext, 8, spin: false);
        numberCog.write(cogtext, 8, spin: false);
        textCog.write(cogtext, 'saturn', spin: false);
        textCog.write(cogtext, 'neptune', spin: false);
        boolCog.write(cogtext, false, spin: false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, 7, true, 'neptune', 8, false]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        numberCog.write(cogtext, 9, spin: false);

        expect(emissions, equals(['saturn', 77, 7, true, 'neptune', 8, false]));

        await Future.delayed(Duration.zero);
      });

      test(
          'writing to multiple unrelated watched, unspun manual Cogs triggers '
          'the right notifications in the right order', () async {
        final boolCog = Cog.man(() => true, debugLabel: 'boolCog');
        final numberCog = Cog.man(() => 4, debugLabel: 'numberCog');
        final textCog = Cog.man(() => 'hello', debugLabel: 'textCog');

        final emissions = [];
        final subscriptions = [
          boolCog
              .watch(
                cogtext,
                priority: Priority.low,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                priority: Priority.normal,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                priority: Priority.high,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, false);
        boolCog.write(cogtext, true);
        numberCog.write(cogtext, 5);
        numberCog.write(cogtext, 6);
        numberCog.write(cogtext, 66);
        numberCog.write(cogtext, 7);
        numberCog.write(cogtext, 7);
        numberCog.write(cogtext, 77);
        numberCog.write(cogtext, 77);
        textCog.write(cogtext, 'world');
        textCog.write(cogtext, 'mars');
        textCog.write(cogtext, 'jupiter');
        textCog.write(cogtext, 'saturn');

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, true]));

        numberCog.write(cogtext, 8);
        numberCog.write(cogtext, 8);
        numberCog.write(cogtext, 8);
        textCog.write(cogtext, 'saturn');
        textCog.write(cogtext, 'neptune');
        boolCog.write(cogtext, false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals(['saturn', 77, true, 'neptune', 8, false]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        numberCog.write(cogtext, 9);

        expect(emissions, equals(['saturn', 77, true, 'neptune', 8, false]));
      });

      test(
          'writing to multiple unrelated watched, spun automatic Cogs '
          'triggers the right notifications in the right order', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog', spin: Spin<bool>());
        final bCog = Cog.man(() => 2, debugLabel: 'bCog', spin: Spin<bool>());
        final cCog = Cog.man(() => 3, debugLabel: 'cCog', spin: Spin<bool>());

        final negativeBCog = Cog((c) {
          final b = c.link(bCog, spin: c.spin);

          return -b;
        }, debugLabel: 'negativeBCog', spin: Spin<bool>());
        final twoACog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);

          return 2 * a;
        }, debugLabel: 'twoACog', spin: Spin<bool>());

        final discriminantCog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);
          final b = c.link(bCog, spin: c.spin);
          final cVal = c.link(cCog, spin: c.spin);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog', spin: Spin<bool>());

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog, spin: c.spin);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
          spin: Spin<bool>(),
        );

        final answerCog = Cog(
          (c) {
            final negativeB = c.link(negativeBCog, spin: c.spin);
            final sqrtDiscriminant = c.link(sqrtDiscriminantCog, spin: c.spin);
            final twoA = c.link(twoACog, spin: c.spin);

            return (
              (negativeB + sqrtDiscriminant) / twoA,
              (negativeB - sqrtDiscriminant) / twoA
            );
          },
          debugLabel: 'sqrtDiscriminantCog',
          spin: Spin<bool>(),
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                priority: Priority.low,
                spin: false,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                priority: Priority.high,
                spin: false,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        aCog.write(cogtext, 6, spin: false);
        bCog.write(cogtext, 11, spin: false);
        cCog.write(cogtext, -35, spin: false);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([961, (5.0 / 3.0, -3.5)]));

        cCog.write(cogtext, 0, spin: false);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
            ]));

        aCog.write(cogtext, -4, spin: false);
        bCog.write(cogtext, 7, spin: false);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
              49,
              (0.0, 1.75),
            ]));

        aCog.write(cogtext, -4, spin: true);
        bCog.write(cogtext, 7, spin: true);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        aCog.write(cogtext, 11, spin: false);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );
      });

      test(
          'writing to multiple unrelated watched, unspun automatic Cogs '
          'triggers the right notifications in the right order', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog');
        final bCog = Cog.man(() => 2, debugLabel: 'bCog');
        final cCog = Cog.man(() => 3, debugLabel: 'cCog');

        final negativeBCog = Cog((c) {
          final b = c.link(bCog);

          return -b;
        }, debugLabel: 'negativeBCog');
        final twoACog = Cog((c) {
          final a = c.link(aCog);

          return 2 * a;
        }, debugLabel: 'twoACog');

        final discriminantCog = Cog((c) {
          final a = c.link(aCog);
          final b = c.link(bCog);
          final cVal = c.link(cCog);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog');

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
        );

        final answerCog = Cog(
          (c) {
            final negativeB = c.link(negativeBCog);
            final sqrtDiscriminant = c.link(sqrtDiscriminantCog);
            final twoA = c.link(twoACog);

            return (
              (negativeB + sqrtDiscriminant) / twoA,
              (negativeB - sqrtDiscriminant) / twoA
            );
          },
          debugLabel: 'sqrtDiscriminantCog',
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                priority: Priority.low,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                priority: Priority.high,
              )
              .listen(emissions.add),
        ];

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        aCog.write(cogtext, 6);
        bCog.write(cogtext, 11);
        cCog.write(cogtext, -35);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([961, (5.0 / 3.0, -3.5)]));

        cCog.write(cogtext, 0);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
            ]));

        aCog.write(cogtext, -4);
        bCog.write(cogtext, 7);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              961,
              (5.0 / 3.0, -3.5),
              121,
              (0.0, -11 / 6),
              49,
              (0.0, 1.75),
            ]));

        for (final subscription in subscriptions) {
          subscription.cancel();
        }

        aCog.write(cogtext, 11);

        expect(
          emissions,
          equals([
            961,
            (5.0 / 3.0, -3.5),
            121,
            (0.0, -11 / 6),
            49,
            (0.0, 1.75),
          ]),
        );
      });

      test(
          'writing to a watched manual Cogs triggers notifications in '
          'the correct order, even after priority is changed', () async {
        final boolCog = Cog.man(() => false);
        final numberCog = Cog.man(() => 4);
        final stringCog = Cog.man(() => '');

        final emissions = [];

        boolCog.watch(cogtext, priority: Priority.high).listen(emissions.add);
        numberCog
            .watch(cogtext, priority: Priority.normal)
            .listen(emissions.add);
        stringCog.watch(cogtext, priority: Priority.low).listen(emissions.add);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        boolCog.write(cogtext, true);
        numberCog.write(cogtext, 5);
        stringCog.write(cogtext, '123');

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            true,
            5,
            '123',
          ]),
        );

        stringCog.watch(cogtext, priority: Priority.high);

        boolCog.write(cogtext, false);
        numberCog.write(cogtext, 6);
        stringCog.write(cogtext, '456');

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            true,
            5,
            '123',
            '456',
            false,
            6,
          ]),
        );
      });

      test('automatic Cogs can mimick a "flatMap"-like behavior', () async {
        final numberedCogs = [
          for (var i = 1; i <= 20; i++)
            Cog.man(() => i, debugLabel: 'numberedCog$i'),
        ];

        final numberedListLengthCog =
            Cog.man(() => 5, debugLabel: 'numberedListLengthCog');
        final numberedListOffsetCog =
            Cog.man(() => 0, debugLabel: 'numberedListOffsetCog');

        final numberedListCog = Cog((c) {
          final numberedListLength = c.link(numberedListLengthCog);
          final numberedListOffset = c.link(numberedListOffsetCog);

          return [
            for (var i = numberedListOffset;
                i < numberedListOffset + numberedListLength;
                i++)
              c.link(numberedCogs[i]),
          ];
        }, debugLabel: 'numberedListCog');

        final emissions = [];

        numberedListCog.watch(cogtext).listen(emissions.add);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberedCogs[1].write(cogtext, -2);
        numberedCogs[3].write(cogtext, -4);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
          ]),
        );

        numberedCogs[11].write(cogtext, -12);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
          ]),
        );

        numberedListOffsetCog.write(cogtext, 4);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
          ]),
        );

        numberedListLengthCog.write(cogtext, 10);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
          ]),
        );

        numberedCogs[2].write(cogtext, -3);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
          ]),
        );

        numberedListOffsetCog.write(cogtext, 17);
        numberedListLengthCog.write(cogtext, 1);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            [1, -2, 3, -4, 5],
            [5, 6, 7, 8, 9],
            [5, 6, 7, 8, 9, 10, 11, -12, 13, 14],
            [18],
          ]),
        );
      });

      test('automatic Cogs can mimick a "switchMap"-like behavior', () async {
        final evenCog = Cog.man(() => 2);
        final oddCog = Cog.man(() => 3);
        final isEvenCog = Cog.man(() => true);

        final numberCog = Cog((c) {
          final isEven = c.link(isEvenCog);

          final number = isEven ? c.link(evenCog) : c.link(oddCog);

          return number;
        });

        final emissions = [];

        numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        evenCog.write(cogtext, 4);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4]));

        isEvenCog.write(cogtext, false);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3]));

        await Future.delayed(Duration.zero);

        oddCog.write(cogtext, 5);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3, 5]));

        evenCog.write(cogtext, 6);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([4, 3, 5]));
      });
    });

    group('Simple reading, watching and writing', () {
      setUp(() {
        cogtext = Cogtext(
          cogStateRuntime: StandardCogStateRuntime(
            logging: logging,
            scheduler: NaiveCogStateRuntimeScheduler(
              logging: logging,
              highPriorityBackgroundTaskDelay: Duration.zero,
              lowPriorityBackgroundTaskDelay: Duration.zero,
            ),
          ),
        );
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'reading from the end of a chain of watched automatic '
          'Cogs triggers notifications all the way up the chain', () async {
        final firstCog = Cog.man(() => 1, debugLabel: 'firstCog');

        final secondCog = Cog(
          (c) => 2 * c.link(firstCog),
          debugLabel: 'secondCog',
        );

        final thirdCog = Cog(
          (c) => 3 * c.link(secondCog),
          debugLabel: 'thirdCog',
        );

        final fourthCog = Cog(
          (c) => 5 * c.link(thirdCog),
          debugLabel: 'fourthCog',
        );

        final emissions = [];

        expect(emissions, isEmpty);

        firstCog.read(cogtext);
        secondCog.read(cogtext);
        thirdCog.read(cogtext);
        fourthCog.read(cogtext);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        firstCog.write(cogtext, 2);

        firstCog
            .watch(
              cogtext,
              priority: Priority.low,
            )
            .listen(emissions.add);
        secondCog
            .watch(
              cogtext,
              priority: Priority.high,
            )
            .listen(emissions.add);
        thirdCog
            .watch(
              cogtext,
              priority: Priority.normal,
            )
            .listen(emissions.add);
        fourthCog
            .watch(
              cogtext,
              priority: Priority.low,
            )
            .listen(emissions.add);

        fourthCog.read(cogtext);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, [4, 12, 60]);
      });

      test(
          'writing to a watched and spun manual Cog triggers a notification, '
          'even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final emissions = [];
        final subscription =
            numberCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(numberCog.read(cogtext, spin: false), 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to a watched and spun automatic Cog triggers a '
          'notification, even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        final numberPlusOneCog = Cog(
          (c) => c.link(numberCog, spin: c.spin) + 1,
          spin: Spin<bool>(),
        );

        final emissions = [];
        final subscription =
            numberPlusOneCog.watch(cogtext, spin: false).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: true);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5, spin: false);

        expect(numberPlusOneCog.read(cogtext, spin: false), 6);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));
      });

      test(
          'writing to a watched and unspun manual Cog triggers a notification, '
          'even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4);

        final emissions = [];
        final subscription = numberCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(numberCog.read(cogtext), 5);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([5]));
      });

      test(
          'writing to a watched and unspun automatic Cog triggers a '
          'notification, even while intermittently reading', () async {
        final numberCog = Cog.man(() => 4);

        final numberPlusOneCog = Cog(
          (c) => c.link(numberCog) + 1,
        );

        final emissions = [];
        final subscription =
            numberPlusOneCog.watch(cogtext).listen(emissions.add);

        expect(emissions, isEmpty);

        numberCog.write(cogtext, 5);

        expect(numberPlusOneCog.read(cogtext), 6);

        expect(emissions, isEmpty);

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));

        await subscription.cancel();

        await Future.delayed(Duration.zero);

        expect(emissions, equals([6]));
      });
    });

    group('Complex reading', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test('you can read from a chain of unspun automatic Cogs', () {
        final isWindyCog = Cog((c) => false, debugLabel: 'isWindyCog');

        final temperatureCog = Cog((c) => 12.0, debugLabel: 'temperatureCog');

        final isNiceOutsideCog = Cog((c) {
          final isWindy = c.link(isWindyCog);
          final temperature = c.link(temperatureCog);

          return !isWindy && temperature > 22.0;
        }, debugLabel: 'isNiceOutsideCog');

        final dayOfTheWeekCog =
            Cog((c) => Day.sunday, debugLabel: 'dayOfTheWeekCog');

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog');

        final shouldGoToTheBeachCog = Cog((c) {
          final isNiceOutside = c.link(isNiceOutsideCog);
          final isWeekend = c.link(isWeekendCog);

          return isNiceOutside && isWeekend;
        }, debugLabel: 'shouldGoToTheBeachCog');

        expect(shouldGoToTheBeachCog.read(cogtext), isFalse);
      });

      test('you can read from a chain of spun automatic Cogs', () {
        final isWindyCog =
            Cog((c) => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog =
            Cog((c) => 12.0, debugLabel: 'temperatureCog', spin: Spin<City>());

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog(
          (c) => Day.sunday,
          debugLabel: 'dayOfTheWeekCog',
          spin: Spin<City>(),
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge), isFalse);
      });

      test(
          'you can read from a chain of Cogs where some are manual, '
          'some are spun, and some are both', () {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog((c) => Day.sunday,
            debugLabel: 'dayOfTheWeekCog', spin: Spin<City>());

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(
            shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge), isFalse);
      });
    });

    group('Complex reading and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'you can read from and write to a chain of Cogs where some are '
          'manual, some are spun, and some are both', () {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog.man(
          () => Day.wednesday,
          debugLabel: 'dayOfTheWeekCog',
          spin: Spin<City>(),
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn),
          isFalse,
        );
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge),
          isFalse,
        );

        temperatureCog
          ..write(cogtext, 24.0, spin: City.austin)
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        expect(isNiceOutsideCog.read(cogtext, spin: City.austin), isTrue);
        expect(isNiceOutsideCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(isNiceOutsideCog.read(cogtext, spin: City.cambridge), isFalse);
        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge),
          isFalse,
        );

        dayOfTheWeekCog.write(cogtext, Day.saturday, spin: City.austin);

        expect(isNiceOutsideCog.read(cogtext, spin: City.austin), isTrue);
        expect(isNiceOutsideCog.read(cogtext, spin: City.brooklyn), isFalse);
        expect(isNiceOutsideCog.read(cogtext, spin: City.cambridge), isFalse);
        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isTrue);
        expect(
          shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn),
          isFalse,
        );

        isWindyCog.write(cogtext, true, spin: City.austin);

        expect(shouldGoToTheBeachCog.read(cogtext, spin: City.austin), isFalse);
      });
    });

    group('Complex watching and writing', () {
      setUp(() {
        cogtext =
            Cogtext(cogStateRuntime: StandardCogStateRuntime(logging: logging));
      });

      tearDown(() async {
        await cogtext.dispose();
      });

      test(
          'you can read from and write to a chain of Cogs where some are '
          'manual, some are spun, and some are both', () async {
        final isWindyCog =
            Cog.man(() => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog.man(
          () => 12.0,
          debugLabel: 'temperatureCog',
          spin: Spin<City>(),
        );

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog.man(
          () => Day.wednesday,
          debugLabel: 'dayOfTheWeekCog',
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog');

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          spin: Spin<City>(),
        );

        final emissions = [];
        final subscriptions = [
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.austin)
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach austin $shouldGoToTheBeach')
              .listen(emissions.add),
          shouldGoToTheBeachCog
              .watch(
                cogtext,
                spin: City.brooklyn,
                priority: Priority.low,
              )
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach brooklyn $shouldGoToTheBeach')
              .listen(emissions.add),
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.cambridge)
              .map((shouldGoToTheBeach) =>
                  'shouldGoToTheBeach cambridge $shouldGoToTheBeach')
              .listen(emissions.add),
          isNiceOutsideCog
              .watch(cogtext, spin: City.brooklyn)
              .map((isNiceOutside) => 'isNiceOutside brooklyn $isNiceOutside')
              .listen(emissions.add),
          isNiceOutsideCog
              .watch(
                cogtext,
                spin: City.austin,
                priority: Priority.high,
              )
              .map((isNiceOutside) => 'isNiceOutside austin $isNiceOutside')
              .listen(emissions.add),
        ];

        temperatureCog
          ..write(cogtext, 24.0, spin: City.austin)
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'isNiceOutside austin true',
            'isNiceOutside brooklyn false',
            'shouldGoToTheBeach brooklyn false',
            'shouldGoToTheBeach austin false',
          ]),
        );

        subscriptions.addAll([
          isWeekendCog
              .watch(cogtext, priority: Priority.asap)
              .map((isWeekend) => 'isWeekendCog $isWeekend')
              .listen(emissions.add),
          temperatureCog
              .watch(cogtext, spin: City.austin)
              .map((temperature) => 'temperature austin $temperature')
              .listen(emissions.add),
        ]);

        await Future.delayed(Duration.zero);

        expect(
          emissions,
          equals([
            'isNiceOutside austin true',
            'isNiceOutside brooklyn false',
            'shouldGoToTheBeach brooklyn false',
            'shouldGoToTheBeach austin false',
          ]),
        );

        dayOfTheWeekCog.write(cogtext, Day.saturday);
        isWindyCog.write(cogtext, true, spin: City.austin);

        await Future.delayed(Duration.zero);

        expect(
            emissions,
            equals([
              'isNiceOutside austin true',
              'isNiceOutside brooklyn false',
              'shouldGoToTheBeach brooklyn false',
              'shouldGoToTheBeach austin false',
              'isWeekendCog true',
              'isNiceOutside austin false',
              'shouldGoToTheBeach cambridge false',
            ]));
      });
    });
  });
}
