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
        }, init: null.of<int>(), spin: Spin<bool>());

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
        }, init: null.of<int>());

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('reading from an unspun manual Cog without specifying spin throws',
          () {
        final numberCog = Cog.man(() => 4);

        expect(() => numberCog.read(cogtext, spin: false), throwsArgumentError);
      });

      test('you can read from a spun manual Cog', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('you can read from a spun automatic Cog', () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>(), spin: Spin<bool>());

        expect(numberCog.read(cogtext, spin: false), equals(4));
      });

      test('you can read from an unspun manual Cog', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.read(cogtext), equals(4));
      });

      test('you can read from an unspun automatic Cog', () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>());

        expect(numberCog.read(cogtext), equals(4));
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

      test('watching from a spun automatic Cog without specifying spin throws',
          () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>(), spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test('watching from a spun manual Cog without specifying spin throws',
          () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(() => numberCog.watch(cogtext), throwsArgumentError);
      });

      test(
          'watching from an unspun automatic Cog '
          'without specifying spin throws', () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>());

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('watching from an unspun manual Cog without specifying spin throws',
          () {
        final numberCog = Cog.man(() => 4);

        expect(
            () => numberCog.watch(cogtext, spin: false), throwsArgumentError);
      });

      test('you can watch from a spun manual Cog', () {
        final numberCog = Cog.man(() => 4, spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('you can watch from a spun automatic Cog', () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>(), spin: Spin<bool>());

        expect(numberCog.watch(cogtext, spin: false).isBroadcast, isTrue);
      });

      test('you can watch from an unspun manual Cog', () {
        final numberCog = Cog.man(() => 4);

        expect(numberCog.watch(cogtext).isBroadcast, isTrue);
      });

      test('you can watch from an unspun automatic Cog', () {
        final numberCog = Cog((c) {
          return 4;
        }, init: null.of<int>());

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

      test('you can read from and write to a spun manual Cog', () {
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

      test('you can read from and write to an unspun manual Cog', () {
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

      test(
          'watching a spun manual Cog to which a value is '
          'written triggers a notification', () async {
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

      test(
          'watching an unspun manual Cog to which a value is '
          'written triggers a notification', () async {
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

      test(
          'watching a spun automatic Cog to which a value is '
          'written triggers a notification', () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: c.spin);

          return number * number;
        }, debugLabel: 'squaredNumberCog', init: () => -1, spin: Spin<bool>());

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

      test(
          'watching an unspun automatic Cog to which a value is '
          'written triggers a notification', () async {
        final numberCog =
            Cog.man(() => 4, debugLabel: 'numberCog', spin: Spin<bool>());

        final squaredNumberCog = Cog((c) {
          final number = c.link(numberCog, spin: false);

          return number * number;
        }, debugLabel: 'squaredNumberCog', init: () => -1);

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

      test('you can watch and write multiple spun manual Cogs', () async {
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
                urgency: NotificationUrgency.lessUrgent,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.urgent,
                spin: false,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.urgent,
                spin: true,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.moreUrgent,
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

      test('you can watch and write to multiple unspun manual Cogs', () async {
        final boolCog = Cog.man(() => true, debugLabel: 'boolCog');
        final numberCog = Cog.man(() => 4, debugLabel: 'numberCog');
        final textCog = Cog.man(() => 'hello', debugLabel: 'textCog');

        final emissions = [];
        final subscriptions = [
          boolCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.lessUrgent,
              )
              .listen(emissions.add),
          numberCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.urgent,
              )
              .listen(emissions.add),
          textCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.moreUrgent,
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

      test('you can watch and write multiple spun automatic Cogs', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog', spin: Spin<bool>());
        final bCog = Cog.man(() => 2, debugLabel: 'bCog', spin: Spin<bool>());
        final cCog = Cog.man(() => 3, debugLabel: 'cCog', spin: Spin<bool>());

        final negativeBCog = Cog((c) {
          final b = c.link(bCog, spin: c.spin);

          return -b;
        }, debugLabel: 'negativeBCog', init: () => 0, spin: Spin<bool>());
        final twoACog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);

          return 2 * a;
        }, debugLabel: 'twoACog', init: () => 0, spin: Spin<bool>());

        final discriminantCog = Cog((c) {
          final a = c.link(aCog, spin: c.spin);
          final b = c.link(bCog, spin: c.spin);
          final cVal = c.link(cCog, spin: c.spin);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog', init: () => 0, spin: Spin<bool>());

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog, spin: c.spin);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
          init: () => 0.0,
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
          init: () => (0.0, 0.0),
          spin: Spin<bool>(),
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.lessUrgent,
                spin: false,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.moreUrgent,
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

      test('you can watch and write multiple unspun automatic Cogs', () async {
        final aCog = Cog.man(() => 1, debugLabel: 'aCog');
        final bCog = Cog.man(() => 2, debugLabel: 'bCog');
        final cCog = Cog.man(() => 3, debugLabel: 'cCog');

        final negativeBCog = Cog((c) {
          final b = c.link(bCog);

          return -b;
        }, debugLabel: 'negativeBCog', init: () => 0);
        final twoACog = Cog((c) {
          final a = c.link(aCog);

          return 2 * a;
        }, debugLabel: 'twoACog', init: () => 0);

        final discriminantCog = Cog((c) {
          final a = c.link(aCog);
          final b = c.link(bCog);
          final cVal = c.link(cCog);

          return b * b - 4 * a * cVal;
        }, debugLabel: 'discriminantCog', init: () => 0);

        final sqrtDiscriminantCog = Cog(
          (c) {
            final discriminant = c.link(discriminantCog);

            return sqrt(discriminant);
          },
          debugLabel: 'sqrtDiscriminantCog',
          init: () => 0.0,
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
          init: () => (0.0, 0.0),
        );

        final emissions = [];
        final subscriptions = [
          answerCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.lessUrgent,
              )
              .listen(emissions.add),
          discriminantCog
              .watch(
                cogtext,
                urgency: NotificationUrgency.moreUrgent,
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
        final isWindyCog =
            Cog((c) => false, debugLabel: 'isWindyCog', init: () => false);

        final temperatureCog =
            Cog((c) => 12.0, debugLabel: 'temperatureCog', init: () => 12.0);

        final isNiceOutsideCog = Cog((c) {
          final isWindy = c.link(isWindyCog);
          final temperature = c.link(temperatureCog);

          return !isWindy && temperature > 22.0;
        }, debugLabel: 'isNiceOutsideCog', init: () => false);

        final dayOfTheWeekCog = Cog((c) => Day.sunday,
            debugLabel: 'dayOfTheWeekCog', init: () => Day.sunday);

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', init: () => false);

        final shouldGoToTheBeachCog = Cog((c) {
          final isNiceOutside = c.link(isNiceOutsideCog);
          final isWeekend = c.link(isWeekendCog);

          return isNiceOutside && isWeekend;
        }, debugLabel: 'shouldGoToTheBeachCog', init: () => false);

        expect(shouldGoToTheBeachCog.read(cogtext), isFalse);
      });

      test('you can read from a chain of spun automatic Cogs', () {
        final isWindyCog = Cog((c) => false,
            init: () => false, debugLabel: 'isWindyCog', spin: Spin<City>());

        final temperatureCog = Cog((c) => 12.0,
            debugLabel: 'temperatureCog', init: () => 12.0, spin: Spin<City>());

        final isNiceOutsideCog = Cog(
          (c) {
            final isWindy = c.link(isWindyCog, spin: c.spin);
            final temperature = c.link(temperatureCog, spin: c.spin);

            return !isWindy && temperature > 22.0;
          },
          debugLabel: 'isNiceOutsideCog',
          init: () => false,
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog(
          (c) => Day.sunday,
          debugLabel: 'dayOfTheWeekCog',
          init: () => Day.sunday,
          spin: Spin<City>(),
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', init: () => false, spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          init: () => false,
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
          init: () => false,
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog((c) => Day.sunday,
            debugLabel: 'dayOfTheWeekCog',
            init: () => Day.sunday,
            spin: Spin<City>());

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog, spin: c.spin);

          return dayOfTheWeek == Day.saturday || dayOfTheWeek == Day.sunday;
        }, debugLabel: 'isWeekendCog', init: () => false, spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          init: () => false,
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
          init: () => false,
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
        }, debugLabel: 'isWeekendCog', init: () => false, spin: Spin<City>());

        final shouldGoToTheBeachCog = Cog(
          (c) {
            final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
            final isWeekend = c.link(isWeekendCog, spin: c.spin);

            return isNiceOutside && isWeekend;
          },
          debugLabel: 'shouldGoToTheBeachCog',
          init: () => false,
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
  });
}
