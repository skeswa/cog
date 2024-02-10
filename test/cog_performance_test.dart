import 'package:cog/cog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog Performance', () {
    late Cogtext cogtext;
    late TestingCogStateRuntimeTelemetry telemetry;

    setUpLogging();

    setUp(() {
      telemetry = TestingCogStateRuntimeTelemetry();

      cogtext = Cogtext(
        cogStateRuntime: StandardCogStateRuntime(
          logging: TestingCogStateRuntimeLogger(),
          telemetry: telemetry,
        ),
      );
    });

    tearDown(() async {
      await cogtext.dispose();
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
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

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

        var lastMeterRead = telemetry.meter;
        final meterReads = [lastMeterRead];

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        shouldGoToTheBeachCog.read(cogtext, spin: City.brooklyn);
        shouldGoToTheBeachCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        temperatureCog.write(cogtext, 24.0, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        temperatureCog
          ..write(cogtext, 18.0, spin: City.brooklyn)
          ..write(cogtext, 12.0, spin: City.cambridge);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        isNiceOutsideCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        isNiceOutsideCog.read(cogtext, spin: City.brooklyn);
        isNiceOutsideCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        dayOfTheWeekCog.write(cogtext, Day.saturday);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        isNiceOutsideCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        isNiceOutsideCog.read(cogtext, spin: City.brooklyn);
        isNiceOutsideCog.read(cogtext, spin: City.cambridge);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        isWindyCog.write(cogtext, true, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        shouldGoToTheBeachCog.read(cogtext, spin: City.austin);

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        for (var i = 0; i < 100; i++) {
          shouldGoToTheBeachCog.read(cogtext, spin: City.austin);
        }

        meterReads.add(telemetry.meter - lastMeterRead);
        lastMeterRead = telemetry.meter;

        expect(
          meterReads,
          equals([0, 71, 138, 3, 4, 19, 18, 6, 0, 0, 38, 3, 38, 0]),
        );
      });
    });
  });
}
