import 'package:cog/cog.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/helpers.dart';

void main() {
  group('Cog Performance Smoke', () {
    late Cogtext cogtext;
    late MechanismRegistry mechanismRegistry;
    late TestingCogRuntimeTelemetry telemetry;

    setUpLogging();

    setUp(() {
      mechanismRegistry = GlobalMechanismRegistry();
      telemetry = TestingCogRuntimeTelemetry();

      cogtext = Cogtext(
        cogRuntime: StandardCogRuntime(
          logging: TestingCogRuntimeLogger(),
          mechanismRegistry: mechanismRegistry,
          telemetry: telemetry,
        ),
      );
    });

    tearDown(() async {
      await cogtext.dispose();
    });

    group('Complex reading and writing', () {
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
          spin: Spin<City>(),
        );

        final dayOfTheWeekCog = Cog.man(
          () => Day.wednesday,
          debugLabel: 'dayOfTheWeekCog',
        );

        final isWeekendCog = Cog((c) {
          final dayOfTheWeek = c.link(dayOfTheWeekCog);

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
          equals([0, 71, 136, 2, 2, 18, 17, 5, 0, 0, 36, 2, 36, 0]),
        );
      });
    });

    group('Complex watching and writing', () {
      test('should do as little work as possible', () {
        fakeAsync((async) {
          final timeOfDayCog = Cog(
            (c) => DateTime(
              2024,
              2,
              26,
              7 + async.elapsed.inHours,
              async.elapsed.inMinutes,
            ),
            ttl: const Duration(hours: 1) + const Duration(minutes: 30),
            debugLabel: 'timeOfDayCog',
          );

          final zipCodeCog = Cog(
            (c) => switch (c.spin) {
              City.austin => 78737,
              City.brooklyn => 11201,
              City.cambridge => 02138,
            },
            debugLabel: 'zipCodeCog',
            spin: Spin<City>(),
          );

          final weatherDataCog = Cog(
            (c) async {
              final timeOfDay = c.link(timeOfDayCog);
              final zipCode = c.link(zipCodeCog, spin: c.spin);

              final weatherData = await fetchWeatherData(
                timeOfDay: timeOfDay,
                zipCode: zipCode,
              );

              return weatherData;
            },
            async: Async.parallelLatestWins,
            debugLabel: 'weatherDataCog',
            init: null.init<WeatherData>(),
            spin: Spin<City>(),
            ttl: const Duration(minutes: 30),
          );

          final isSunnyCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return false;
              }

              return weatherData.cloudCoverPercentage < .3;
            },
            debugLabel: 'isSunnyCog',
            spin: Spin<City>(),
          );

          final willRainLaterCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return false;
              }

              return weatherData.percentChanceOfRain > .5;
            },
            debugLabel: 'willRainLaterCog',
            spin: Spin<City>(),
          );

          final tempInFahrenheitCog = Cog(
            (c) {
              final weatherData = c.link(weatherDataCog, spin: c.spin);

              if (weatherData == null) {
                return null;
              }

              return (weatherData.tempInCelsius * 9 / 5) + 32;
            },
            debugLabel: 'tempInFahrenheitCog',
            spin: Spin<City>(),
          );

          final isNiceOutsideCog = Cog(
            (c) {
              final isSunny = c.link(isSunnyCog, spin: c.spin);
              final tempInFahrenheit =
                  c.link(tempInFahrenheitCog, spin: c.spin);

              if (tempInFahrenheit == null) {
                return false;
              }

              return isSunny && tempInFahrenheit > 70.0;
            },
            debugLabel: 'isNiceOutsideCog',
            spin: Spin<City>(),
          );

          final shouldGoToTheBeachCog = Cog(
            (c) {
              final isNiceOutside = c.link(isNiceOutsideCog, spin: c.spin);
              final willRainLater = c.link(willRainLaterCog, spin: c.spin);

              return isNiceOutside && !willRainLater;
            },
            debugLabel: 'shouldGoToTheBeachCog',
            spin: Spin<City>(),
          );

          final emissions = [];

          isNiceOutsideCog
              .watch(cogtext, spin: City.austin)
              .listen((isNiceOutsideCog) {
            emissions.add(
              'isNiceOutsideCog in austin: $isNiceOutsideCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.austin)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in austin: $shouldGoToTheBeachCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.brooklyn)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in brooklyn: $shouldGoToTheBeachCog',
            );
          });
          shouldGoToTheBeachCog
              .watch(cogtext, spin: City.cambridge)
              .listen((shouldGoToTheBeachCog) {
            emissions.add(
              'shouldGoToTheBeachCog in cambridge: $shouldGoToTheBeachCog',
            );
          });

          var lastMeterRead = telemetry.meter;
          final meterReads = [lastMeterRead];

          async.elapse(const Duration(hours: 2));

          meterReads.add(telemetry.meter - lastMeterRead);
          lastMeterRead = telemetry.meter;

          async.elapse(const Duration(hours: 2));

          meterReads.add(telemetry.meter - lastMeterRead);
          lastMeterRead = telemetry.meter;

          async.elapse(const Duration(hours: 2));

          meterReads.add(telemetry.meter - lastMeterRead);
          lastMeterRead = telemetry.meter;

          async.elapse(const Duration(hours: 2));

          meterReads.add(telemetry.meter - lastMeterRead);
          lastMeterRead = telemetry.meter;

          expect(
            meterReads,
            equals([443, 508, 550, 329, 521]),
          );
        });
      });
    });
  });
}
