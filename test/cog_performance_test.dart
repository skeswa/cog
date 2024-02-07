import 'package:cog/cog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog Performance', () {
    late Cogtext cogtext;
    late SyncTestingCogValueRuntimeScheduler scheduler;
    late TestingCogValueRuntimeTelemetry telemetry;

    setUpLogging();

    setUp(() {
      scheduler = SyncTestingCogValueRuntimeScheduler();
      telemetry = TestingCogValueRuntimeTelemetry();

      cogtext = Cogtext(
        cogValueRuntime: Cogtime(
          scheduler: scheduler,
          telemetry: telemetry,
        ),
      );
    });

    group('Complex sync reading and writing', () {
      test('should do as little work as possible', () {
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

        final meterReads = [telemetry.meter];

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter);

        shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn);
        shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter);

        temperatureCog.write(cogtext, 24.0, spin: City.austin);

        meterReads.add(telemetry.meter);

        temperatureCog
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        meterReads.add(telemetry.meter);

        isNiceOutsideCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter);

        isNiceOutsideCog.read(cogtext, spin: City.brooklyn);
        isNiceOutsideCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter);

        dayOfTheWeekCog.write(cogtext, Day.saturday, spin: City.austin);

        meterReads.add(telemetry.meter);

        isNiceOutsideCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter);

        isNiceOutsideCog.read(cogtext, spin: City.brooklyn);
        isNiceOutsideCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter);

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter);

        isWindyCog.write(cogtext, true, spin: City.austin);

        meterReads.add(telemetry.meter);

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter);

        for (var i = 0; i < 100; i++) {
          shouldGoToTheBeachCog.read(cogtext, spin: City.austin);
        }

        meterReads.add(telemetry.meter);

        expect(
          meterReads,
          equals([
            0,
            68,
            204,
            206,
            208,
            226,
            243,
            244,
            244,
            244,
            278,
            280,
            316,
            316,
          ]),
        );
      });
    });
  });
}
