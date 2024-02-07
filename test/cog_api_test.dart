import 'package:cog/cog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog API', () {
    late Cogtext cogtext;
    late TestingCogValueRuntimeLogger logging;

    setUpLogging();

    setUp(() {
      logging = TestingCogValueRuntimeLogger();
    });

    group('Simple sync reading', () {
      setUp(() {
        cogtext = Cogtext(cogValueRuntime: Cogtime(logging: logging));
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

    group('Simple sync watching', () {
      setUp(() {
        cogtext = Cogtext(
          cogValueRuntime: Cogtime(
            logging: logging,
            scheduler: SyncTestingCogValueRuntimeScheduler(),
          ),
        );
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

    group('Simple sync reading and writing', () {
      setUp(() {
        cogtext = Cogtext(cogValueRuntime: Cogtime(logging: logging));
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

    group('Complex sync reading', () {
      setUp(() {
        cogtext = Cogtext(cogValueRuntime: Cogtime(logging: logging));
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

    group('Complex sync reading and writing', () {
      setUp(() {
        cogtext = Cogtext(cogValueRuntime: Cogtime(logging: logging));
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
